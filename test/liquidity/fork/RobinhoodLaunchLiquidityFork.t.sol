// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Fork proof against the deployed Robinhood v4 core, PositionManager, and Permit2. The
/// latest-state mode additionally exercises the deployed STATICS and NVDA token contracts.
contract RobinhoodLaunchLiquidityForkTest is Test, LiquidityOperations {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    address private constant STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    address private constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    StaticsLaunchLiquidityHook private hook;
    PoolSwapTest private swapRouter;
    PoolKey private key;
    Currency private currency0;
    Currency private currency1;
    Currency private staticsCurrency;
    address private feeReceiver = makeAddr("feeReceiver");
    address private positionOwner = makeAddr("positionOwner");
    PositionConfig private launchPosition;
    PositionConfig private activePosition;
    uint256 private launchTokenId;
    uint256 private activeTokenId;

    function setUp() public {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        bool latest = _selectFork(manifest);
        _deadline = block.timestamp + 1 hours;
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        lpm = positionManager;
        swapRouter = new PoolSwapTest(poolManager);

        address statics;
        address pairedToken;
        if (latest) {
            assertGt(STATICS.code.length, 0);
            assertGt(NVDA.code.length, 0);
            statics = STATICS;
            pairedToken = NVDA;
            deal(statics, address(this), 100_000_000 ether, true);
            deal(pairedToken, address(this), 100_000_000 ether, true);
        } else {
            MockERC20 staticsMock = new MockERC20("STATICS", "STATICS", 18);
            MockERC20 pairedMock = new MockERC20("Stock", "STOCK", 18);
            staticsMock.mint(address(this), 100_000_000 ether);
            pairedMock.mint(address(this), 100_000_000 ether);
            statics = address(staticsMock);
            pairedToken = address(pairedMock);
        }
        (currency0, currency1) = statics < pairedToken
            ? (Currency.wrap(statics), Currency.wrap(pairedToken))
            : (Currency.wrap(pairedToken), Currency.wrap(statics));
        staticsCurrency = Currency.wrap(statics);

        hook = _deployHook();
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        hook.registerPool(key, SQRT_PRICE_1_1, 50, 50, positionOwner);
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        bool staticsIsCurrency0 = Currency.unwrap(currency0) == statics;
        launchPosition = PositionConfig({
            poolKey: key,
            tickLower: staticsIsCurrency0 ? int24(60) : int24(-600),
            tickUpper: staticsIsCurrency0 ? int24(600) : int24(-60)
        });
        launchTokenId = lpm.nextTokenId();
        _initializeAndMintSingleSided(staticsIsCurrency0);
        activePosition = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});
        activeTokenId = lpm.nextTokenId();
        mint(activePosition, 1e25, positionOwner, "");
        vm.prank(positionOwner);
        hook.activatePool(key.toId());
    }

    function testDeployedDependenciesSupportExternalLaunchAndHundredThousandVolume() public {
        assertEq(IERC721(address(positionManager)).ownerOf(launchTokenId), positionOwner);
        assertEq(IERC721(address(positionManager)).ownerOf(activeTokenId), positionOwner);
        assertEq(lpm.getPositionLiquidity(launchTokenId), 1e25);
        assertEq(lpm.getPositionLiquidity(activeTokenId), 1e25);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);

        uint256 totalInput;
        for (uint256 i; i < 20; ++i) {
            bool zeroForOne = i % 2 == 0;
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(5_000 ether),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            totalInput += 5_000 ether;
        }
        assertEq(totalInput, 100_000 ether);
        assertGt(poolManager.balanceOf(feeReceiver, currency0.toId()), 0);
        assertGt(poolManager.balanceOf(feeReceiver, currency1.toId()), 0);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);

        vm.prank(positionOwner);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(launchTokenId, launchPosition, 5e24, ""), block.timestamp + 1
        );
        assertEq(lpm.getPositionLiquidity(launchTokenId), 5e24);

        uint256 staticsBefore = poolManager.balanceOf(feeReceiver, staticsCurrency.toId());
        bool staticsIsCurrency0 = Currency.unwrap(currency0) == Currency.unwrap(staticsCurrency);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: staticsIsCurrency0,
                amountSpecified: -int256(1_000 ether),
                sqrtPriceLimitX96: staticsIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(poolManager.balanceOf(feeReceiver, staticsCurrency.toId()), staticsBefore);
    }

    function _initializeAndMintSingleSided(bool staticsIsCurrency0) private {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key,
                launchPosition.tickLower,
                launchPosition.tickUpper,
                uint128(1e25),
                staticsIsCurrency0 ? type(uint128).max : 0,
                staticsIsCurrency0 ? 0 : type(uint128).max,
                positionOwner,
                bytes("")
            )
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(positionManager.initializePool, (key, SQRT_PRICE_1_1));
        calls[1] = abi.encodeCall(
            positionManager.modifyLiquidities, (plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp + 1)
        );
        positionManager.multicall(calls);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(poolManager, positionManager, address(this), feeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(poolManager, positionManager, address(this), feeReceiver);
        assertEq(address(deployed), expected);
    }

    function _selectFork(string memory manifest) private returns (bool latest) {
        uint256 chainId = vm.parseJsonUint(manifest, ".chainId");
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        if (block.chainid == chainId) return vm.envOr("ROBINHOOD_FORK_LATEST", false);
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return false;
        }
        latest = vm.envOr("ROBINHOOD_FORK_LATEST", false);
        if (latest) {
            vm.createSelectFork(rpcUrl);
            assertEq(block.chainid, chainId);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
            assertEq(block.chainid, chainId);
            assertEq(block.number, forkBlock);
        }
    }
}
