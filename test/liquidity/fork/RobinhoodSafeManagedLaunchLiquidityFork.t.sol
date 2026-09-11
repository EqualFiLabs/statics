// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchFeeClaimRedeemer} from "../../../src/liquidity/StaticsLaunchFeeClaimRedeemer.sol";
import {StaticsLaunchLiquidityHook} from "../../../src/liquidity/StaticsLaunchLiquidityHook.sol";

interface IRobinhoodSafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 safeNonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

interface IRobinhoodMultiSend {
    function multiSend(bytes memory transactions) external payable;
}

interface IRobinhoodUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Rehearses Safe-controlled registration, launch, management, swaps, and claim redemption
/// against a block-pinned Robinhood mainnet state using the deployed token and Uniswap v4 contracts.
contract RobinhoodSafeManagedLaunchLiquidityForkTest is Test, LiquidityOperations {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    address private constant STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    address private constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant GOVERNANCE_SAFE = 0x603A8A2f22ac1d61E9c932A4F6Fa23170CEcb9Ff;
    address private constant OPERATIONS_SAFE = 0x0Ce4140f3Ab03024623a75F248D467912C7E1725;
    address private constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    uint256 private constant FORK_BLOCK = 47_690_599;
    bytes32 private constant FORK_BLOCK_HASH = 0x4ca3ce6b00d4603804be596b721c738caf54c2a08515f84a8ca020f33613837b;
    bytes32 private constant SAFE_PROXY_CODEHASH = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    bytes32 private constant MULTISEND_CODEHASH = 0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;

    uint160 private constant INITIAL_SQRT_PRICE_X96 = 689_904_386_145_184_590_450_493_103;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    int24 private constant TICK_SPACING = 60;
    int24 private constant STATICS_ONLY_LOWER = -94_860;
    int24 private constant STATICS_ONLY_UPPER = -90_780;
    int24 private constant NVDA_ONLY_LOWER = -99_000;
    int24 private constant NVDA_ONLY_UPPER = -95_400;
    int24 private constant TWO_SIDED_LOWER = -96_000;
    int24 private constant TWO_SIDED_UPPER = -93_600;
    int24 private constant BROAD_LOWER = -102_000;
    int24 private constant BROAD_UPPER = -87_000;

    uint256 private constant STATICS_LAUNCH_AMOUNT = 600_000 ether;
    uint256 private constant NVDA_LAUNCH_AMOUNT = 50 ether;
    uint256 private constant BROAD_STATICS_AMOUNT = 25_000_000 ether;
    uint256 private constant BROAD_NVDA_AMOUNT = 2_000 ether;
    uint256 private constant STATICS_SWAP_AMOUNT = 25_000 ether;
    uint256 private constant NVDA_SWAP_AMOUNT = 2 ether;
    uint256 private constant STATICS_USD_NUMERATOR = 1_744;
    uint256 private constant STATICS_USD_DENOMINATOR = 100_000;
    uint256 private constant NVDA_USD_PRICE = 230;
    uint256 private constant REQUIRED_SWAP_COUNT = 256;
    bytes1 private constant V4_SWAP_COMMAND = 0x10;

    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    IV4Quoter private quoter;
    IRobinhoodUniversalRouter private universalRouter;
    IRobinhoodSafe private governanceSafe;
    IRobinhoodSafe private operationsSafe;
    PoolSwapTest private swapRouter;
    StaticsLaunchLiquidityHook private hook;
    StaticsLaunchFeeClaimRedeemer private redeemer;
    TimelockController private timelock;

    PoolKey[3] private keys;
    PositionConfig[3] private launchConfigs;
    PositionConfig[3] private broadConfigs;
    uint256[3] private launchTokenIds;
    uint256[3] private broadTokenIds;
    uint128[3] private launchLiquidities;
    uint128[3] private broadLiquidities;

    function setUp() public {
        if (!_selectPinnedFork()) return;
        _loadDependencies();
        _assertPinnedContracts();
        _deployLaunchContracts();
        _fundAndApproveActors();
        _configurePoolKeys();
        _registerPoolsThroughGovernanceSafe();
        _launchPoolsThroughOperationsSafe();
    }

    function testSafeManagedLaunchSurvivesHighVolumeAndRepeatedPositionChanges() public {
        _assertLaunchShapesAndOwnership();
        _assertDeployedQuoterHandlesEverySwapMode();
        _swapThroughDeployedUniversalRouter();

        uint256[4] memory modeCounts;
        uint256 totalUsdNotional;
        for (uint256 i; i < REQUIRED_SWAP_COUNT; ++i) {
            uint256 mode = i % 4;
            PoolKey memory selected = keys[i % keys.length];
            bool zeroForOne = mode == 0 || mode == 2;
            bool exactInput = mode < 2;
            uint256 amount = mode == 0 || mode == 3 ? STATICS_SWAP_AMOUNT : NVDA_SWAP_AMOUNT;
            swapRouter.swap(
                selected,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: exactInput ? -int256(amount) : int256(amount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            modeCounts[mode]++;
            totalUsdNotional += mode == 0 || mode == 3
                ? amount * STATICS_USD_NUMERATOR / STATICS_USD_DENOMINATOR
                : amount * NVDA_USD_PRICE;

            if ((i + 1) % 32 == 0) _changeManagedLiquidity((i + 1) / 32 - 1);
        }

        for (uint256 mode; mode < modeCounts.length; ++mode) {
            assertEq(modeCounts[mode], 64);
        }
        assertGe(totalUsdNotional, 100_000 ether);
        assertGt(poolManager.balanceOf(OPERATIONS_SAFE, Currency.wrap(STATICS).toId()), 0);
        assertGt(poolManager.balanceOf(OPERATIONS_SAFE, Currency.wrap(NVDA).toId()), 0);
        assertEq(IERC20(STATICS).balanceOf(address(hook)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(hook)), 0);

        _redeemClaimsThroughOperationsSafe();
        _assertManagedPositions();
    }

    function _loadDependencies() private {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        universalRouter = IRobinhoodUniversalRouter(vm.parseJsonAddress(manifest, ".contracts.universalRouter.address"));
        governanceSafe = IRobinhoodSafe(GOVERNANCE_SAFE);
        operationsSafe = IRobinhoodSafe(OPERATIONS_SAFE);
        lpm = positionManager;
        _deadline = block.timestamp + 1 hours;
        swapRouter = new PoolSwapTest(poolManager);
    }

    function _assertPinnedContracts() private view {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        assertEq(address(quoter).codehash, vm.parseJsonBytes32(manifest, ".contracts.quoter.runtimeCodeHash"));
        assertEq(
            address(universalRouter).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.universalRouter.runtimeCodeHash")
        );
        assertEq(GOVERNANCE_SAFE.codehash, SAFE_PROXY_CODEHASH);
        assertEq(OPERATIONS_SAFE.codehash, SAFE_PROXY_CODEHASH);
        assertEq(MULTISEND.codehash, MULTISEND_CODEHASH);
        assertEq(governanceSafe.getThreshold(), 2);
        assertEq(operationsSafe.getThreshold(), 2);
        assertEq(governanceSafe.getOwners().length, 2);
        assertEq(operationsSafe.getOwners().length, 2);
    }

    function _deployLaunchContracts() private {
        address[] memory proposers = new address[](1);
        proposers[0] = GOVERNANCE_SAFE;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(24 hours, proposers, executors, address(0));
        bytes memory args = abi.encode(poolManager, positionManager, address(timelock), OPERATIONS_SAFE);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        hook = new StaticsLaunchLiquidityHook{salt: salt}(
            poolManager, positionManager, address(timelock), OPERATIONS_SAFE
        );
        assertEq(address(hook), expected);
        redeemer = new StaticsLaunchFeeClaimRedeemer(poolManager);
    }

    function _fundAndApproveActors() private {
        deal(STATICS, OPERATIONS_SAFE, 250_000_000 ether, true);
        deal(NVDA, OPERATIONS_SAFE, 25_000 ether, true);
        deal(STATICS, address(this), 250_000_000 ether, true);
        deal(NVDA, address(this), 25_000 ether, true);
        IERC20(STATICS).approve(address(swapRouter), type(uint256).max);
        IERC20(NVDA).approve(address(swapRouter), type(uint256).max);

        address[] memory targets = new address[](7);
        bytes[] memory calls = new bytes[](7);
        targets[0] = STATICS;
        calls[0] = abi.encodeCall(IERC20.approve, (address(permit2), type(uint256).max));
        targets[1] = NVDA;
        calls[1] = abi.encodeCall(IERC20.approve, (address(permit2), type(uint256).max));
        targets[2] = address(permit2);
        calls[2] =
            abi.encodeCall(permit2.approve, (STATICS, address(positionManager), type(uint160).max, type(uint48).max));
        targets[3] = address(permit2);
        calls[3] =
            abi.encodeCall(permit2.approve, (NVDA, address(positionManager), type(uint160).max, type(uint48).max));
        targets[4] = address(permit2);
        calls[4] =
            abi.encodeCall(permit2.approve, (STATICS, address(universalRouter), type(uint160).max, type(uint48).max));
        targets[5] = address(permit2);
        calls[5] =
            abi.encodeCall(permit2.approve, (NVDA, address(universalRouter), type(uint160).max, type(uint48).max));
        targets[6] = address(poolManager);
        calls[6] = abi.encodeCall(poolManager.setOperator, (address(redeemer), true));
        _executeSafeBatch(operationsSafe, targets, calls);
    }

    function _configurePoolKeys() private {
        uint24[3] memory lpFees = [uint24(3_000), uint24(5_000), uint24(10_000)];
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = PoolKey({
                currency0: Currency.wrap(STATICS),
                currency1: Currency.wrap(NVDA),
                fee: lpFees[i],
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });
        }
        launchConfigs[0] =
            PositionConfig({poolKey: keys[0], tickLower: STATICS_ONLY_LOWER, tickUpper: STATICS_ONLY_UPPER});
        launchConfigs[1] = PositionConfig({poolKey: keys[1], tickLower: NVDA_ONLY_LOWER, tickUpper: NVDA_ONLY_UPPER});
        launchConfigs[2] = PositionConfig({poolKey: keys[2], tickLower: TWO_SIDED_LOWER, tickUpper: TWO_SIDED_UPPER});
        for (uint256 i; i < broadConfigs.length; ++i) {
            broadConfigs[i] = PositionConfig({poolKey: keys[i], tickLower: BROAD_LOWER, tickUpper: BROAD_UPPER});
        }

        launchLiquidities[0] = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(STATICS_ONLY_LOWER),
            TickMath.getSqrtPriceAtTick(STATICS_ONLY_UPPER),
            STATICS_LAUNCH_AMOUNT
        );
        launchLiquidities[1] = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(NVDA_ONLY_LOWER),
            TickMath.getSqrtPriceAtTick(NVDA_ONLY_UPPER),
            NVDA_LAUNCH_AMOUNT
        );
        launchLiquidities[2] = LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(TWO_SIDED_LOWER),
            TickMath.getSqrtPriceAtTick(TWO_SIDED_UPPER),
            STATICS_LAUNCH_AMOUNT,
            NVDA_LAUNCH_AMOUNT
        );
        for (uint256 i; i < broadLiquidities.length; ++i) {
            broadLiquidities[i] = LiquidityAmounts.getLiquidityForAmounts(
                INITIAL_SQRT_PRICE_X96,
                TickMath.getSqrtPriceAtTick(BROAD_LOWER),
                TickMath.getSqrtPriceAtTick(BROAD_UPPER),
                BROAD_STATICS_AMOUNT,
                BROAD_NVDA_AMOUNT
            );
        }
    }

    function _registerPoolsThroughGovernanceSafe() private {
        address[] memory targets = new address[](keys.length);
        bytes[] memory calls = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            targets[i] = address(hook);
            calls[i] = abi.encodeCall(hook.registerPool, (keys[i], INITIAL_SQRT_PRICE_X96, 50, 80, OPERATIONS_SAFE));
        }
        _executeSafeBatch(governanceSafe, targets, calls);
        for (uint256 i; i < keys.length; ++i) {
            assertTrue(hook.poolRegistration(keys[i].toId()).registered);
        }
    }

    function _launchPoolsThroughOperationsSafe() private {
        for (uint256 i; i < keys.length; ++i) {
            launchTokenIds[i] = lpm.nextTokenId();
            uint256 staticsBefore = IERC20(STATICS).balanceOf(OPERATIONS_SAFE);
            uint256 nvdaBefore = IERC20(NVDA).balanceOf(OPERATIONS_SAFE);
            _executeSafe(
                operationsSafe,
                address(positionManager),
                abi.encodeCall(positionManager.multicall, (_initializeAndMintCalls(i))),
                0
            );
            uint256 staticsSpent = staticsBefore - IERC20(STATICS).balanceOf(OPERATIONS_SAFE);
            uint256 nvdaSpent = nvdaBefore - IERC20(NVDA).balanceOf(OPERATIONS_SAFE);
            if (i == 0) {
                assertGt(staticsSpent, 0);
                assertEq(nvdaSpent, 0);
            } else if (i == 1) {
                assertEq(staticsSpent, 0);
                assertGt(nvdaSpent, 0);
            } else {
                assertGt(staticsSpent, 0);
                assertGt(nvdaSpent, 0);
            }

            broadTokenIds[i] = lpm.nextTokenId();
            _executeSafe(
                operationsSafe,
                address(positionManager),
                abi.encodeCall(
                    positionManager.modifyLiquidities,
                    (
                        getMintEncoded(broadConfigs[i], broadLiquidities[i], OPERATIONS_SAFE, ""),
                        block.timestamp + 1 hours
                    )
                ),
                0
            );
        }

        address[] memory targets = new address[](keys.length);
        bytes[] memory calls = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            targets[i] = address(hook);
            calls[i] = abi.encodeCall(hook.activatePool, (keys[i].toId()));
        }
        _executeSafeBatch(operationsSafe, targets, calls);
    }

    function _initializeAndMintCalls(uint256 index) private view returns (bytes[] memory calls) {
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(positionManager.initializePool, (keys[index], INITIAL_SQRT_PRICE_X96));
        calls[1] = abi.encodeCall(
            positionManager.modifyLiquidities,
            (
                getMintEncoded(
                    launchConfigs[index],
                    launchLiquidities[index],
                    _amount0Maximum(index),
                    _amount1Maximum(index),
                    OPERATIONS_SAFE,
                    ""
                ),
                block.timestamp + 1 hours
            )
        );
    }

    function _amount0Maximum(uint256 index) private pure returns (uint128) {
        return index == 1 ? 0 : uint128(STATICS_LAUNCH_AMOUNT + 1);
    }

    function _amount1Maximum(uint256 index) private pure returns (uint128) {
        return index == 0 ? 0 : uint128(NVDA_LAUNCH_AMOUNT + 1);
    }

    function _assertLaunchShapesAndOwnership() private view {
        assertLt(INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(STATICS_ONLY_LOWER));
        assertGe(INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(NVDA_ONLY_UPPER));
        assertGt(INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(TWO_SIDED_LOWER));
        assertLt(INITIAL_SQRT_PRICE_X96, TickMath.getSqrtPriceAtTick(TWO_SIDED_UPPER));
        for (uint256 i; i < keys.length; ++i) {
            assertEq(IERC721(address(positionManager)).ownerOf(launchTokenIds[i]), OPERATIONS_SAFE);
            assertEq(IERC721(address(positionManager)).ownerOf(broadTokenIds[i]), OPERATIONS_SAFE);
            assertEq(lpm.getPositionLiquidity(launchTokenIds[i]), launchLiquidities[i]);
            assertEq(lpm.getPositionLiquidity(broadTokenIds[i]), broadLiquidities[i]);
            assertTrue(hook.poolRegistration(keys[i].toId()).active);
        }
    }

    function _assertDeployedQuoterHandlesEverySwapMode() private {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                bool zeroForOne = direction == 0;
                uint128 amount = zeroForOne ? uint128(1_000 ether) : uint128(0.1 ether);
                IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
                    poolKey: keys[i], zeroForOne: zeroForOne, exactAmount: amount, hookData: ""
                });
                (uint256 output, uint256 exactInputGas) = quoter.quoteExactInputSingle(params);
                (uint256 input, uint256 exactOutputGas) = quoter.quoteExactOutputSingle(params);
                assertGt(output, 0);
                assertGt(input, 0);
                assertGt(exactInputGas, 0);
                assertGt(exactOutputGas, 0);
            }
        }
    }

    function _swapThroughDeployedUniversalRouter() private {
        uint128 amountIn = 1_000 ether;
        (uint256 quotedOutput,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: keys[2], zeroForOne: true, exactAmount: amountIn, hookData: ""})
        );
        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                RouterExactInputSingleParams({
                    poolKey: keys[2],
                    zeroForOne: true,
                    amountIn: amountIn,
                    amountOutMinimum: uint128(quotedOutput),
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(STATICS), amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(NVDA), uint128(quotedOutput)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = plan.encode();

        uint256 staticsBefore = IERC20(STATICS).balanceOf(OPERATIONS_SAFE);
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(OPERATIONS_SAFE);
        _executeSafe(
            operationsSafe,
            address(universalRouter),
            abi.encodeCall(
                universalRouter.execute, (abi.encodePacked(V4_SWAP_COMMAND), inputs, block.timestamp + 1 hours)
            ),
            0
        );
        assertEq(staticsBefore - IERC20(STATICS).balanceOf(OPERATIONS_SAFE), amountIn);
        assertEq(IERC20(NVDA).balanceOf(OPERATIONS_SAFE) - nvdaBefore, quotedOutput);
    }

    function _changeManagedLiquidity(uint256 managementIndex) private {
        uint256 poolIndex = managementIndex % keys.length;
        uint128 amount = broadLiquidities[poolIndex] / 1_000;
        bytes memory liquidityCall;
        if (managementIndex % 2 == 0) {
            liquidityCall = getIncreaseEncoded(broadTokenIds[poolIndex], broadConfigs[poolIndex], amount, "");
            broadLiquidities[poolIndex] += amount;
        } else {
            liquidityCall = getDecreaseEncoded(broadTokenIds[poolIndex], broadConfigs[poolIndex], amount, "");
            broadLiquidities[poolIndex] -= amount;
        }
        _executeSafe(
            operationsSafe,
            address(positionManager),
            abi.encodeCall(positionManager.modifyLiquidities, (liquidityCall, block.timestamp + 1 hours)),
            0
        );
        assertEq(lpm.getPositionLiquidity(broadTokenIds[poolIndex]), broadLiquidities[poolIndex]);
    }

    function _redeemClaimsThroughOperationsSafe() private {
        uint256 outstanding = poolManager.balanceOf(OPERATIONS_SAFE, Currency.wrap(STATICS).toId());
        uint256 amount = outstanding / 2;
        assertGt(amount, 0);
        address recipient = address(0xA11CE);
        uint256 recipientBefore = IERC20(STATICS).balanceOf(recipient);
        _executeSafe(
            operationsSafe,
            address(redeemer),
            abi.encodeCall(redeemer.redeem, (Currency.wrap(STATICS), amount, recipient)),
            0
        );
        assertEq(poolManager.balanceOf(OPERATIONS_SAFE, Currency.wrap(STATICS).toId()), outstanding - amount);
        assertEq(IERC20(STATICS).balanceOf(recipient) - recipientBefore, amount);
    }

    function _assertManagedPositions() private view {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(IERC721(address(positionManager)).ownerOf(launchTokenIds[i]), OPERATIONS_SAFE);
            assertEq(IERC721(address(positionManager)).ownerOf(broadTokenIds[i]), OPERATIONS_SAFE);
            assertEq(lpm.getPositionLiquidity(broadTokenIds[i]), broadLiquidities[i]);
            assertTrue(hook.poolRegistration(keys[i].toId()).active);
        }
    }

    function _executeSafeBatch(IRobinhoodSafe safe, address[] memory targets, bytes[] memory calls) private {
        assertEq(targets.length, calls.length);
        bytes memory transactions;
        for (uint256 i; i < targets.length; ++i) {
            transactions = bytes.concat(
                transactions, abi.encodePacked(uint8(0), targets[i], uint256(0), calls[i].length, calls[i])
            );
        }
        _executeSafe(safe, MULTISEND, abi.encodeCall(IRobinhoodMultiSend.multiSend, (transactions)), 1);
    }

    function _executeSafe(IRobinhoodSafe safe, address to, bytes memory data, uint8 operation) private {
        uint256 safeNonce = safe.nonce();
        bytes32 transactionHash =
            safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safeNonce);
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 2);
        if (owners[0] > owners[1]) (owners[0], owners[1]) = (owners[1], owners[0]);
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            safe.approveHash(transactionHash);
        }
        bytes memory signatures = abi.encodePacked(
            bytes32(uint256(uint160(owners[0]))),
            bytes32(0),
            uint8(1),
            bytes32(uint256(uint160(owners[1]))),
            bytes32(0),
            uint8(1)
        );
        assertTrue(safe.execTransaction(to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures));
        assertEq(safe.nonce(), safeNonce + 1);
    }

    function _selectPinnedFork() private returns (bool selected) {
        if (block.chainid == 4_663 && block.number == FORK_BLOCK) return true;
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return false;
        }
        uint256 forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "fork block hash drift");
        vm.rollFork(forkId, FORK_BLOCK);
        assertEq(block.chainid, 4_663);
        assertEq(block.number, FORK_BLOCK);
        return true;
    }
}
