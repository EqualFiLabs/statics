// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GaugeIncentiveViewFacet} from "../../src/facets/GaugeIncentiveViewFacet.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RangeGaugeLifecycleTestBase} from "./RangeGaugeLifecycleTestBase.sol";

/// @dev Real custody, LP manager and reward funding; no injected reward accounting.
abstract contract BatchRewardsFlowTestBase is RangeGaugeLifecycleTestBase {
    IStaticsGaugeIncentives internal incentives;
    IStaticsBatchRewards internal batch;

    function setUp() public virtual override {
        super.setUp();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut(
            address(new GaugeIncentiveFacet()), IDiamondCut.FacetCutAction.Add, _newIncentiveSelectors()
        );
        cut[1] = IDiamondCut.FacetCut(
            address(new GaugeIncentiveViewFacet()),
            IDiamondCut.FacetCutAction.Add,
            StaticsSelectors.gaugeIncentiveViews()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        incentives = IStaticsGaugeIncentives(address(diamond));
        batch = IStaticsBatchRewards(address(diamond));
    }

    function _newIncentiveSelectors() private pure returns (bytes4[] memory selectors) {
        bytes4[] memory all = StaticsSelectors.gaugeIncentiveActions();
        selectors = new bytes4[](all.length - 2);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (
                all[i] != IStaticsGaugeIncentives.checkpointGaugePool.selector
                    && all[i] != IStaticsGaugeIncentives.syncGaugeAllocationsAfterStakeLoss.selector
            ) selectors[n++] = all[i];
        }
    }

    function _installBatch() internal {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new BatchRewardsFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.batchRewards()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _stake(address owner, address[] memory assets) internal returns (uint256 id) {
        stakingAsset.mint(owner, 100 ether);
        vm.startPrank(owner);
        stakingAsset.approve(address(diamond), 100 ether);
        id = globalRewards.createAndStake(100 ether, owner, assets);
        vm.stopPrank();
    }

    function _allocate(uint256 id, PoolId poolId) internal {
        vm.prank(alice);
        (uint40 nextAt,,,) = incentives.gaugePositionAllocations(id);
        if (block.timestamp < nextAt) vm.warp(nextAt);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        vm.prank(alice);
        incentives.setGaugeAllocations(id, pools, amounts);
    }

    function _activateReserve() internal {
        stakingAsset.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1_000 ether);
        incentives.fundGaugeReserve(1_000 ether);
        vm.stopPrank();
        incentives.activateGaugeSchedule();
    }

    function _bribe(PoolId poolId, MockERC20 reward, uint16 allocatorShare) internal returns (uint8 slot) {
        slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, allocatorShare);
        reward.mint(bob, 100 ether);
        vm.startPrank(bob);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, allocatorShare);
        vm.stopPrank();
    }

    function _poolClaims(uint256 id, PoolId pool, uint8[] memory slots)
        internal
        pure
        returns (IStaticsBatchRewards.PoolClaim[] memory claims)
    {
        claims = new IStaticsBatchRewards.PoolClaim[](1);
        claims[0] = IStaticsBatchRewards.PoolClaim(id, PoolId.unwrap(pool), slots, new uint256[](slots.length));
    }

    function _slots(uint8 first, bool includeProtocol) internal pure returns (uint8[] memory slots) {
        slots = new uint8[](includeProtocol ? 2 : 1);
        if (includeProtocol) slots[1] = first;
        else slots[0] = first;
    }

    function _lpBatch(IStaticsBatchRewards.PoolClaim[] memory claims) internal returns (uint256[][] memory amounts) {
        vm.prank(alice);
        (, amounts,) = batch.batchClaimRewards(
            new IStaticsBatchRewards.GlobalClaim[](0), claims, new IStaticsBatchRewards.PoolClaim[](0), alice
        );
    }
}
