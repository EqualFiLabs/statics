// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Uses the real v4 PositionManager flow to prove launch-hook pools do not gate or custody
/// unrelated concentrated-liquidity positions.
contract LaunchLiquidityPositionManagerTest is Test, Deployers, DeployPermit2, LiquidityOperations {
    uint24 private constant LP_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint128 private constant INITIAL_LIQUIDITY = 1e18;
    uint128 private constant ADDED_LIQUIDITY = 5e17;
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("feeReceiver");
    address private liquidityReceiver = makeAddr("liquidityReceiver");
    address private externalLp = makeAddr("externalLp");
    IAllowanceTransfer private permit2;
    PositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;
    PositionConfig private position;
    uint256 private tokenId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        hook = _deployHook();
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        hook.registerAndInitialize(key, SQRT_PRICE_1_1);

        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        lpm = IPositionManager(address(positionManager));
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);

        position = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        tokenId = lpm.nextTokenId();
        mint(position, INITIAL_LIQUIDITY, address(this), ZERO_BYTES);
    }

    function testExternalPositionManagerLifecycleSurvivesProtocolRetirement() public {
        assertEq(positionManager.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), INITIAL_LIQUIDITY);
        assertEq(position.tickLower, -120);
        assertEq(position.tickUpper, 120);
        assertTrue(position.tickLower != TickMath.minUsableTick(TICK_SPACING));
        assertTrue(position.tickUpper != TickMath.maxUsableTick(TICK_SPACING));

        increaseLiquidity(tokenId, position, ADDED_LIQUIDITY, ZERO_BYTES);
        assertEq(lpm.getPositionLiquidity(tokenId), INITIAL_LIQUIDITY + ADDED_LIQUIDITY);

        swap(key, true, -int256(0.001 ether), ZERO_BYTES);
        swap(key, false, -int256(0.001 ether), ZERO_BYTES);
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        collect(tokenId, position, ZERO_BYTES);
        assertTrue(
            currency0.balanceOfSelf() > balance0Before || currency1.balanceOfSelf() > balance1Before,
            "external LP earned no native fees"
        );

        positionManager.transferFrom(address(this), externalLp, tokenId);
        vm.prank(externalLp);
        positionManager.transferFrom(externalLp, address(this), tokenId);
        hook.retireAndReleasePOL(key);

        decreaseLiquidity(tokenId, position, INITIAL_LIQUIDITY + ADDED_LIQUIDITY, ZERO_BYTES);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        burn(tokenId, position, ZERO_BYTES);
        vm.expectRevert();
        positionManager.ownerOf(tokenId);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(manager, address(this), feeReceiver, liquidityReceiver, address(this));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(manager), address(this), feeReceiver, liquidityReceiver, address(this)
        );
        assertEq(address(deployed), expected);
    }
}
