// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {ProtocolPoolAdminFacet} from "../../src/facets/ProtocolPoolAdminFacet.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugeManagerMigrationTest is RangeGaugeFeatureTestBase {
    uint128 private constant INITIAL_LIQUIDITY = 5 ether;
    uint256 private constant TOKEN_MAXIMUM = 10 ether;

    function testLegacyManagerRemainsUsableAndRebalanceMigratesLazily() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 positionId = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided = _provide(positionId, poolId, key);
        _fundStatics(poolId, 700 ether);
        vm.warp(block.timestamp + 1 days);

        StaticsLiquidityManager replacement =
            _replacement(address(diamond), address(rangePositionManager), address(poolManager), address(rangePermit2));
        IStaticsProtocolPools(address(diamond)).replaceLiquidityManager(address(replacement));
        (address activeManager, bool installed) = rangeGauge.liquidityManager();
        assertTrue(installed);
        assertEq(activeManager, address(replacement));

        _fundAndApprovePoolAssets(key, alice, 3 ether);
        vm.prank(alice);
        rangeGauge.increaseLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.IncreaseLiquidityParams({
                liquidity: 1 ether,
                amount0Maximum: 3 ether,
                amount1Maximum: 3 ether,
                deadline: block.timestamp + 1 hours
            })
        );
        IStaticsRangeGauge.LpLegView memory legacy = rangeGauge.lpLeg(positionId, poolId);
        assertEq(legacy.manager, address(rangeLiquidityManager));
        assertEq(legacy.posmTokenId, provided.posmTokenId);
        assertEq(legacy.liquidity, 6 ether);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(legacy.posmTokenId), address(rangeLiquidityManager));
        assertEq(legacy.claimable[1], 100 ether);

        _fundAndApprovePoolAssets(key, alice, 3 ether);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory rebalanced = rangeGauge.rebalanceLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.RebalanceLiquidityParams({
                tickLower: -100,
                tickUpper: 100,
                liquidity: 6 ether,
                amount0Maximum: 3 ether,
                amount1Maximum: 3 ether,
                amount0Minimum: 0,
                amount1Minimum: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        IStaticsRangeGauge.LpLegView memory migrated = rangeGauge.lpLeg(positionId, poolId);
        assertEq(migrated.manager, address(replacement));
        assertEq(migrated.posmTokenId, rebalanced.posmTokenId);
        assertTrue(migrated.posmTokenId != legacy.posmTokenId);
        assertEq(migrated.tickLower, -100);
        assertEq(migrated.tickUpper, 100);
        assertEq(migrated.liquidity, 6 ether);
        assertEq(migrated.claimable[0], legacy.claimable[0]);
        assertEq(migrated.rewardRemainderRay[0], legacy.rewardRemainderRay[0]);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(migrated.posmTokenId), address(replacement));
        vm.expectRevert();
        IERC721(address(rangePositionManager)).ownerOf(legacy.posmTokenId);
        assertEq(rangeGauge.posmBinding(legacy.posmTokenId), bytes32(0));
        assertEq(rangeGauge.posmBinding(migrated.posmTokenId), LibRangeGauge.bindingFor(positionId, poolId));
    }

    function testReplacementRejectsEveryMismatchedImmutableBinding() public {
        _expectReplacementRejected(
            _replacement(alice, address(rangePositionManager), address(poolManager), address(rangePermit2))
        );
        _expectReplacementRejected(
            _replacement(address(diamond), address(rangePositionManager), address(rangePermit2), address(rangePermit2))
        );
        _expectReplacementRejected(
            _replacement(address(diamond), address(rangePermit2), address(poolManager), address(rangePermit2))
        );
        _expectReplacementRejected(
            _replacement(
                address(diamond), address(rangePositionManager), address(poolManager), address(rangePositionManager)
            )
        );
        (address activeManager,) = rangeGauge.liquidityManager();
        assertEq(activeManager, address(rangeLiquidityManager));
    }

    function _expectReplacementRejected(StaticsLiquidityManager candidate) private {
        vm.expectPartialRevert(ProtocolPoolAdminFacet.LiquidityManagerBindingMismatch.selector);
        IStaticsProtocolPools(address(diamond)).replaceLiquidityManager(address(candidate));
    }

    function _replacement(address boundDiamond, address posm, address manager, address permit)
        private
        returns (StaticsLiquidityManager replacement)
    {
        replacement = new StaticsLiquidityManager(boundDiamond, posm, manager, permit);
    }

    function _provide(uint256 positionId, PoolId poolId, PoolKey memory key)
        private
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        _fundAndApprovePoolAssets(key, alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        movement = rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _fundAndApprovePoolAssets(PoolKey memory key, address user, uint256 amount) private {
        MockERC20(Currency.unwrap(key.currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(key.currency0)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _fundStatics(PoolId poolId, uint256 amount) private {
        vm.prank(alice);
        uint8 slot = rangeGauge.appendPoolRewardAsset(poolId, address(stakingAsset));
        stakingAsset.mint(alice, amount);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), amount);
        rangeGauge.fundPoolReward(poolId, slot, amount, uint40(7 days));
        vm.stopPrank();
    }

    function _createPosition(address owner) private returns (uint256 positionId) {
        vm.prank(owner);
        positionId = IStaticsPosition(address(diamond)).createPosition(owner);
    }

    function _poolKey(PoolId poolId) private view returns (PoolKey memory key) {
        key = IStaticsProtocolPools(address(diamond)).protocolPool(poolId).key;
    }
}
