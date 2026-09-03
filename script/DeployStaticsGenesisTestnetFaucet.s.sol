// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {StaticsGenesisTestnetFaucet} from "../src/testnet/StaticsGenesisTestnetFaucet.sol";

contract GenesisTestnetFaucetSwapSeeder {
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    error OnlyPoolManager(address caller);
    error InvalidSwapDelta(int128 inputDelta, int128 outputDelta);
    error InputAboveMaximum(uint256 input, uint256 maximum);
    error NativeInputUnsupported();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function swapExactOutput(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 maximumInput,
        address recipient
    ) external returns (uint256 input) {
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        address inputToken = Currency.unwrap(inputCurrency);
        if (inputToken == address(0)) revert NativeInputUnsupported();
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), maximumInput);
        input =
            abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountOut, maximumInput, recipient)), (uint256));
        IERC20(inputToken).safeTransfer(msg.sender, maximumInput - input);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
        (PoolKey memory key, bool zeroForOne, uint128 amountOut, uint128 maximumInput, address recipient) =
            abi.decode(data, (PoolKey, bool, uint128, uint128, address));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(uint256(amountOut)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0 || uint128(outputDelta) != amountOut) {
            revert InvalidSwapDelta(inputDelta, outputDelta);
        }
        uint256 input = uint256(-int256(inputDelta));
        if (input > maximumInput) revert InputAboveMaximum(input, maximumInput);

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        inputCurrency.settle(poolManager, address(this), input, false);
        outputCurrency.take(poolManager, recipient, amountOut, false);
        return abi.encode(input);
    }
}

contract DeployStaticsGenesisTestnetFaucet is Script {
    using SafeERC20 for IERC20;

    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint256 public constant MAX_NATIVE_INPUT = 0.012 ether;
    uint256 public constant MAX_INPUT_BPS = 10_100;
    uint256 public constant CLAIM_AMOUNT = 200_000e18;
    uint24 public constant DOPPLER_FEE = 15_000;
    int24 public constant DOPPLER_TICK_SPACING = 100;

    error UnsupportedChain(uint256 chainId);
    error InvalidDependency(address dependency);
    error InvalidStaticsDecimals(uint8 actual);
    error NativeInputAboveCap(uint256 maximumInput, uint256 cap);
    error IncorrectSwapOutput(uint256 expected, uint256 actual);

    struct FaucetFlow {
        address statics;
        address weth;
        address poolManager;
        PoolKey key;
        bool zeroForOne;
    }

    function run() external returns (StaticsGenesisTestnetFaucet faucet, uint256 quotedInput, uint256 maximumInput) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        FaucetFlow memory flow = _loadFlow();
        (quotedInput,) = IV4Quoter(_quoter())
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                poolKey: flow.key, zeroForOne: flow.zeroForOne, exactAmount: uint128(CLAIM_AMOUNT), hookData: bytes("")
            })
            );
        maximumInput = maximumInputForQuote(quotedInput);

        faucet = _deployAndFund(privateKey, flow, maximumInput);
    }

    function _loadFlow() private view returns (FaucetFlow memory flow) {
        string memory genesisArtifact = vm.readFile(vm.envString("STATICS_GENESIS_TESTNET_ARTIFACT"));
        string memory chainManifest = vm.readFile("deployments/robinhood-chain-testnet-46630.json");

        address statics = vm.parseJsonAddress(genesisArtifact, ".statics");
        address weth = vm.parseJsonAddress(genesisArtifact, ".weth");
        address poolInitializer = vm.parseJsonAddress(genesisArtifact, ".dopplerPoolInitializer");
        address quoter = vm.parseJsonAddress(chainManifest, ".contracts.quoter.address");
        address poolManager = vm.parseJsonAddress(chainManifest, ".contracts.poolManager.address");
        _validateDependencies(statics, weth, poolInitializer, quoter, poolManager);

        flow = FaucetFlow({
            statics: statics,
            weth: weth,
            poolManager: poolManager,
            key: _poolKey(statics, weth, poolInitializer),
            zeroForOne: weth < statics
        });
    }

    function _quoter() private view returns (address) {
        string memory chainManifest = vm.readFile("deployments/robinhood-chain-testnet-46630.json");
        return vm.parseJsonAddress(chainManifest, ".contracts.quoter.address");
    }

    function _deployAndFund(uint256 privateKey, FaucetFlow memory flow, uint256 maximumInput)
        private
        returns (StaticsGenesisTestnetFaucet faucet)
    {
        address deployer = vm.addr(privateKey);
        vm.startBroadcast(privateKey);
        faucet = new StaticsGenesisTestnetFaucet(flow.statics);
        GenesisTestnetFaucetSwapSeeder seeder = new GenesisTestnetFaucetSwapSeeder(IPoolManager(flow.poolManager));
        uint256 staticsBefore = IERC20(flow.statics).balanceOf(deployer);
        IWETH9(flow.weth).deposit{value: maximumInput}();
        IERC20(flow.weth).forceApprove(address(seeder), maximumInput);
        seeder.swapExactOutput(flow.key, flow.zeroForOne, uint128(CLAIM_AMOUNT), uint128(maximumInput), deployer);
        uint256 received = IERC20(flow.statics).balanceOf(deployer) - staticsBefore;
        if (received != CLAIM_AMOUNT) {
            revert IncorrectSwapOutput(CLAIM_AMOUNT, received);
        }
        IERC20(flow.statics).safeTransfer(address(faucet), received);
        uint256 refund = IERC20(flow.weth).balanceOf(deployer);
        if (refund != 0) IWETH9(flow.weth).withdraw(refund);
        vm.stopBroadcast();
    }

    function deploy(address statics) public returns (StaticsGenesisTestnetFaucet faucet) {
        if (statics.code.length == 0) revert InvalidDependency(statics);
        (bool success, bytes memory result) = statics.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success || result.length < 32) revert InvalidDependency(statics);
        uint8 decimals = abi.decode(result, (uint8));
        if (decimals != 18) revert InvalidStaticsDecimals(decimals);
        faucet = new StaticsGenesisTestnetFaucet(statics);
    }

    function maximumInputForQuote(uint256 quotedInput) public pure returns (uint256 maximumInput) {
        maximumInput = (quotedInput * MAX_INPUT_BPS + 9_999) / 10_000;
        if (maximumInput > MAX_NATIVE_INPUT) revert NativeInputAboveCap(maximumInput, MAX_NATIVE_INPUT);
    }

    function _validateDependencies(
        address statics,
        address weth,
        address initializer,
        address quoter,
        address poolManager
    ) private view {
        address[5] memory dependencies = [statics, weth, initializer, quoter, poolManager];
        for (uint256 i; i < dependencies.length; ++i) {
            if (dependencies[i].code.length == 0) revert InvalidDependency(dependencies[i]);
        }
        (bool success, bytes memory result) = statics.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success || result.length < 32) revert InvalidDependency(statics);
        uint8 decimals = abi.decode(result, (uint8));
        if (decimals != 18) revert InvalidStaticsDecimals(decimals);
    }

    function _poolKey(address statics, address weth, address initializer) private pure returns (PoolKey memory key) {
        (address currency0, address currency1) = statics < weth ? (statics, weth) : (weth, statics);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: DOPPLER_FEE,
            tickSpacing: DOPPLER_TICK_SPACING,
            hooks: IHooks(initializer)
        });
    }
}
