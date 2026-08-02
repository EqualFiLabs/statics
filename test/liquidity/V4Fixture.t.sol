// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

contract V4FixtureTest is Test, Deployers, DeployPermit2, LiquidityOperations {
    using StateLibrary for IPoolManager;

    uint24 private constant LP_FEE = 500;
    int24 private constant TICK_SPACING = 10;
    uint256 private constant POSITION_LIQUIDITY = 100 ether;

    IAllowanceTransfer private permit2;
    PositionManager private positionManager;
    PoolId private poolId;
    PositionConfig private position;
    uint256 private tokenId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        lpm = IPositionManager(address(positionManager));

        _approvePositionManager(currency0);
        _approvePositionManager(currency1);

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), LP_FEE, TICK_SPACING, SQRT_PRICE_1_1);
        position = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING)
        });

        tokenId = lpm.nextTokenId();
        mint(position, POSITION_LIQUIDITY, address(this), ZERO_BYTES);
    }

    function test_realV4FixtureInitializesAndMintsPosition() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(positionManager.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), POSITION_LIQUIDITY);
        assertTrue(address(manager).code.length != 0);
        assertTrue(address(lpm).code.length != 0);
        assertTrue(address(permit2).code.length != 0);
    }

    function test_realV4FixtureExecutesExactInputAndExactOutput() public {
        uint256 outputBefore = currency1.balanceOfSelf();
        BalanceDelta exactInputDelta = swap(key, true, -int256(1 ether), ZERO_BYTES);

        assertLt(exactInputDelta.amount0(), 0);
        assertGt(exactInputDelta.amount1(), 0);
        assertEq(currency1.balanceOfSelf() - outputBefore, uint256(uint128(exactInputDelta.amount1())));

        uint256 exactOutput = 0.25 ether;
        outputBefore = currency0.balanceOfSelf();
        BalanceDelta exactOutputDelta = swap(key, false, int256(exactOutput), ZERO_BYTES);

        assertGt(exactOutputDelta.amount0(), 0);
        assertLt(exactOutputDelta.amount1(), 0);
        assertEq(uint256(uint128(exactOutputDelta.amount0())), exactOutput);
        assertEq(currency0.balanceOfSelf() - outputBefore, exactOutput);
    }

    function test_realV4FixtureCollectsFeesAndRemovesPosition() public {
        swap(key, true, -int256(1 ether), ZERO_BYTES);
        swap(key, false, -int256(1 ether), ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        collect(tokenId, position, ZERO_BYTES);

        assertTrue(
            currency0.balanceOfSelf() > balance0Before || currency1.balanceOfSelf() > balance1Before,
            "position earns no fees"
        );

        decreaseLiquidity(tokenId, position, POSITION_LIQUIDITY, ZERO_BYTES);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(manager.balanceOf(address(lpm), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(lpm), currency1.toId()), 0);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }
}
