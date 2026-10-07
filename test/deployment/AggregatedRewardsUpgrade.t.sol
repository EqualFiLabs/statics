// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BatchRewardsUpgradeTest} from "./BatchRewardsUpgrade.t.sol";
import {PrepareStaticsBatchRewardsUpgrade} from "../../script/PrepareStaticsBatchRewardsUpgrade.s.sol";
import {PrepareStaticsAggregatedRewardsUpgrade} from "../../script/PrepareStaticsAggregatedRewardsUpgrade.s.sol";
import {IStaticsAggregatedBatchRewards} from "../../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract AggregatedRewardsUpgradeTest is BatchRewardsUpgradeTest {
    PrepareStaticsAggregatedRewardsUpgrade private upgrade;
    address private globalFacet;
    address private lpFacet;
    address private allocatorFacet;

    function setUp() public override {
        super.setUp();
        upgrade = new PrepareStaticsAggregatedRewardsUpgrade();
        globalFacet = address(new GlobalRewardsFacet());
        lpFacet = address(new RangeGaugeLivenessFacet());
        allocatorFacet = address(new GaugeIncentiveFacet());
    }

    // Execute the pinned #115 runtime against real funded state before the atomic upgrade.
    function _priorBatch() private {
        string memory fixture = vm.readFile("test/fixtures/phase-one-batch-parent.json");
        assertEq(vm.parseJsonString(fixture, ".revision"), "de38102e13998468242db7efd31d58a243df4361");
        vm.etch(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGlobalRewards.claimRewards.selector),
            vm.parseJsonBytes(fixture, ".GlobalRewardsFacet")
        );
        vm.etch(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsRangeGauge.claimLpRewards.selector),
            vm.parseJsonBytes(fixture, ".RangeGaugeLivenessFacet")
        );
        vm.etch(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector),
            vm.parseJsonBytes(fixture, ".GaugeIncentiveFacet")
        );
        address oldBatch = address(new BatchRewardsFacet());
        vm.etch(oldBatch, vm.parseJsonBytes(fixture, ".BatchRewardsFacet"));
        // Aggregation needs no replacement of the ordinary custody/view facet.
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(IStaticsCustody.globalReservedByToken.selector).codehash,
            keccak256(vm.parseJsonBytes(fixture, ".CustodyFacet"))
        );
        assertEq(oldBatch.codehash, 0x22a64a82b3504f7618d770ad1f46b1b8b2e40fdc9799f5a6b5c109e88f697757);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IStaticsBatchRewards.batchClaimRewards.selector;
        selectors[1] = IStaticsBatchRewards.batchClaimLimits.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(oldBatch, IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function testAtomicUpgradePreservesPopulatedRewardsAndRegistersBothInterfaces() public {
        _priorBatch();
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        _provide(id, pool, alice);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _bribe(pool, reward, 0);
        vm.warp(block.timestamp + 1 days);
        uint256 backing = reward.balanceOf(address(diamond));
        _executeAggregatedUpgrade();
        assertEq(reward.balanceOf(address(diamond)), backing);
        assertEq(globalRewards.stakePosition(id).stakedBalance, 100 ether);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBatchRewards).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsAggregatedBatchRewards).interfaceId));
        _assertRoutes(StaticsSelectors.globalRewards(), globalFacet);
        _assertRoutes(StaticsSelectors.rangeGaugeLiveness(), lpFacet);
        _assertRoutes(StaticsSelectors.gaugeIncentiveActions(), allocatorFacet);
        _assertRoutes(StaticsSelectors.batchRewards(), facet);
        vm.prank(alice);
        (, uint256[][] memory amounts,) = IStaticsAggregatedBatchRewards(address(diamond))
            .batchClaimRewardsAggregated(
                new IStaticsBatchRewards.GlobalClaim[](0),
                _poolClaims(id, pool, _slots(slot, false)),
                new IStaticsBatchRewards.PoolClaim[](0),
                alice
            );
        assertGt(amounts[0][0], 0);
    }

    function _executeAggregatedUpgrade() private {
        address[] memory members = new address[](1);
        members[0] = address(this);
        StaticsTimelock timelock = new StaticsTimelock(members, members, members, address(this));
        IERC173(address(diamond)).transferOwnership(address(timelock));
        (address owner, bytes32 operation, bytes memory schedule, bytes memory execute) = upgrade.buildAggregatedTimelockCalldata(
            address(diamond), facet, globalFacet, lpFacet, allocatorFacet, keccak256("aggregated")
        );
        (bool ok,) = owner.call(schedule);
        assertTrue(ok);
        vm.warp(block.timestamp + timelock.getMinDelay());
        (ok,) = owner.call(execute);
        assertTrue(ok);
        assertTrue(timelock.isOperationDone(operation));
    }

    function _assertRoutes(bytes4[] memory selectors, address expected) private view {
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(IDiamondLoupe(address(diamond)).facetAddress(selectors[i]), expected);
        }
    }

    function _prepare() private view {
        upgrade.buildAggregatedBatch(address(diamond), facet, globalFacet, lpFacet, allocatorFacet);
    }

    function testAggregatedPreparationRejectsAbsentLegacyBatchAndCollisions() public {
        vm.expectRevert(PrepareStaticsBatchRewardsUpgrade.ExistingBatchRequired.selector);
        _prepare();
        _installBatch();
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.BatchSelectorAlreadyInstalled.selector);
        _prepare();
    }

    function testAggregatedPreparationRejectsIncompleteOwnershipAndWrongRuntime() public {
        _priorBatch();
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.InvalidClaimFacet.selector);
        upgrade.buildAggregatedBatch(address(diamond), facet, globalFacet, lpFacet, alice);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = StaticsSelectors.gaugeIncentiveActions()[0];
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(allocatorFacet, IDiamondCut.FacetCutAction.Replace, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.UnexpectedSelectorOwner.selector);
        _prepare();
    }

    function testAggregatedPreparationRejectsUnverifiedInterfaceInitializer() public {
        _priorBatch();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = StaticsInterfaceInit.setInterfaces.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(globalFacet, IDiamondCut.FacetCutAction.Replace, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.InvalidUpgradeRoute.selector);
        _prepare();
    }

    function testAggregatedPreparationRejectsNonTimelockOwner() public {
        _priorBatch();
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.InvalidTimelock.selector);
        _prepare();
    }
}
