// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Proves that launch liquidity is held in independently managed PositionManager NFTs and
/// that removing selected positions does not disable the pool or its hook fee routing.
contract LaunchLiquidityPositionManagerTest is Test, Deployers, DeployPermit2, LiquidityOperations {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    uint24 private constant LP_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint128 private constant INITIAL_LIQUIDITY = 1e18;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("feeReceiver");
    address private positionOwner = makeAddr("positionOwner");
    address private externalLp = makeAddr("externalLp");
    IAllowanceTransfer private permit2;
    PositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        lpm = IPositionManager(address(positionManager));
        hook = _deployHook();
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        hook.registerPool(key, SQRT_PRICE_1_1, 50, 50, positionOwner);
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);
    }

    function testInitializesAndMintsSingleSidedCurrency0PositionAtomically() public {
        PositionConfig memory launchPosition = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 600});
        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        _initializeAndMint(launchPosition, INITIAL_LIQUIDITY, type(uint128).max, 0, positionOwner);

        assertEq(positionManager.ownerOf(tokenId), positionOwner);
        assertEq(lpm.getPositionLiquidity(tokenId), INITIAL_LIQUIDITY);
        assertLt(currency0.balanceOfSelf(), balance0Before);
        assertEq(currency1.balanceOfSelf(), balance1Before);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertTrue(hook.poolRegistration(key.toId()).initialized);
        assertFalse(hook.poolRegistration(key.toId()).active);
    }

    function testMintsSingleSidedCurrency1WhenPriceStartsAboveRange() public {
        PositionConfig memory launchPosition = PositionConfig({poolKey: key, tickLower: -600, tickUpper: -60});
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        _initializeAndMint(launchPosition, INITIAL_LIQUIDITY, 0, type(uint128).max, positionOwner);

        assertEq(currency0.balanceOfSelf(), balance0Before);
        assertLt(currency1.balanceOfSelf(), balance1Before);
    }

    function testFirstConvertingSwapSucceedsWithoutCounterassetInventory() public {
        PositionConfig memory launchPosition = PositionConfig({poolKey: key, tickLower: 60, tickUpper: 600});
        _initializeAndMint(launchPosition, INITIAL_LIQUIDITY, type(uint128).max, 0, positionOwner);
        assertEq(currency1.balanceOf(address(manager)), 0);

        vm.prank(positionOwner);
        hook.activatePool(key.toId());
        swap(key, false, -int256(0.001 ether), ZERO_BYTES);

        assertGt(manager.balanceOf(feeReceiver, currency1.toId()), 0);
        assertGt(manager.balanceOf(feeReceiver, currency0.toId()), 0);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function testMultipleOwnerPositionsCanBePartiallyRemovedWhilePoolStaysLive() public {
        PositionConfig memory first = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        PositionConfig memory second = PositionConfig({poolKey: key, tickLower: -240, tickUpper: 240});
        PositionConfig memory independent = PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600});

        uint256 firstId = lpm.nextTokenId();
        _initializeAndMint(first, INITIAL_LIQUIDITY, type(uint128).max, type(uint128).max, positionOwner);
        uint256 secondId = lpm.nextTokenId();
        _mint(second, INITIAL_LIQUIDITY, type(uint128).max, type(uint128).max, positionOwner);
        uint256 independentId = lpm.nextTokenId();
        _mint(independent, INITIAL_LIQUIDITY, type(uint128).max, type(uint128).max, externalLp);

        assertEq(positionManager.ownerOf(firstId), positionOwner);
        assertEq(positionManager.ownerOf(secondId), positionOwner);
        assertEq(positionManager.ownerOf(independentId), externalLp);

        vm.prank(positionOwner);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(firstId, first, INITIAL_LIQUIDITY / 2, ZERO_BYTES), block.timestamp + 1
        );
        assertEq(lpm.getPositionLiquidity(firstId), INITIAL_LIQUIDITY / 2);

        vm.prank(positionOwner);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(firstId, first, INITIAL_LIQUIDITY / 2, ZERO_BYTES), block.timestamp + 1
        );
        vm.prank(positionOwner);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(secondId, second, INITIAL_LIQUIDITY, ZERO_BYTES), block.timestamp + 1
        );
        assertEq(lpm.getPositionLiquidity(firstId), 0);
        assertEq(lpm.getPositionLiquidity(secondId), 0);
        assertEq(lpm.getPositionLiquidity(independentId), INITIAL_LIQUIDITY);

        vm.prank(positionOwner);
        hook.activatePool(key.toId());
        uint256 receiverBefore = manager.balanceOf(feeReceiver, currency0.toId());
        swap(key, true, -int256(0.001 ether), ZERO_BYTES);
        assertGt(manager.balanceOf(feeReceiver, currency0.toId()), receiverBefore);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function testPositionOwnerAndFeeReceiverAreIndependent() public {
        PositionConfig memory launchPosition = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        _initializeAndMint(launchPosition, INITIAL_LIQUIDITY, type(uint128).max, type(uint128).max, positionOwner);

        assertEq(positionManager.ownerOf(tokenId), positionOwner);
        assertTrue(positionOwner != hook.feeReceiver());
        vm.prank(positionOwner);
        hook.activatePool(key.toId());
        uint256 receiverBefore = manager.balanceOf(feeReceiver, currency1.toId());
        swap(key, false, -int256(0.001 ether), ZERO_BYTES);
        assertGt(manager.balanceOf(feeReceiver, currency1.toId()), receiverBefore);
        assertEq(currency0.balanceOf(positionOwner), 0);
        assertEq(currency1.balanceOf(positionOwner), 0);
    }

    function testTransferredPositionCanBeRemovedAndBurnedWithoutDisablingPool() public {
        PositionConfig memory managed = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        uint256 tokenId = lpm.nextTokenId();
        _initializeAndMint(managed, INITIAL_LIQUIDITY, type(uint128).max, type(uint128).max, positionOwner);
        _mint(
            PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}),
            INITIAL_LIQUIDITY,
            type(uint128).max,
            type(uint128).max,
            positionOwner
        );

        vm.prank(positionOwner);
        hook.activatePool(key.toId());

        vm.prank(positionOwner);
        positionManager.transferFrom(positionOwner, externalLp, tokenId);
        assertEq(positionManager.ownerOf(tokenId), externalLp);

        vm.prank(positionOwner);
        vm.expectRevert();
        positionManager.modifyLiquidities(
            getDecreaseEncoded(tokenId, managed, INITIAL_LIQUIDITY, ZERO_BYTES), block.timestamp + 1
        );

        vm.prank(externalLp);
        positionManager.modifyLiquidities(
            getDecreaseEncoded(tokenId, managed, INITIAL_LIQUIDITY, ZERO_BYTES), block.timestamp + 1
        );
        vm.prank(externalLp);
        positionManager.modifyLiquidities(getBurnEncoded(tokenId, managed, ZERO_BYTES), block.timestamp + 1);
        vm.expectRevert();
        positionManager.ownerOf(tokenId);

        assertTrue(hook.poolRegistration(key.toId()).active);
        uint256 receiverBefore = manager.balanceOf(feeReceiver, currency0.toId());
        swap(key, true, -int256(0.001 ether), ZERO_BYTES);
        assertGt(manager.balanceOf(feeReceiver, currency0.toId()), receiverBefore);
    }

    function _initializeAndMint(
        PositionConfig memory config,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) private {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(positionManager.initializePool, (key, SQRT_PRICE_1_1));
        calls[1] = abi.encodeCall(
            positionManager.modifyLiquidities,
            (_mintPlan(config, liquidity, amount0Max, amount1Max, recipient), block.timestamp + 1)
        );
        positionManager.multicall(calls);
    }

    function _mint(
        PositionConfig memory config,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) private {
        positionManager.modifyLiquidities(
            _mintPlan(config, liquidity, amount0Max, amount1Max, recipient), block.timestamp + 1
        );
    }

    function _mintPlan(
        PositionConfig memory config,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) private pure returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                recipient,
                ZERO_BYTES
            )
        );
        return plan.finalizeModifyLiquidityWithSettlePair(config.poolKey);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        IPositionManager lpm_ = IPositionManager(address(positionManager));
        bytes memory args = abi.encode(manager, lpm_, address(this), feeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(IPoolManager(manager), lpm_, address(this), feeReceiver);
        assertEq(address(deployed), expected);
    }
}
