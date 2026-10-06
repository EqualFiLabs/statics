// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BatchRewardsFlowTestBase} from "../helpers/BatchRewardsFlowTestBase.sol";
import {PrepareStaticsBatchRewardsUpgrade} from "../../script/PrepareStaticsBatchRewardsUpgrade.s.sol";
import {BatchRewardsFacet} from "../../src/facets/BatchRewardsFacet.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BatchRewardsUpgradeTest is BatchRewardsFlowTestBase {
    PrepareStaticsBatchRewardsUpgrade private preparation;
    address private facet;

    function setUp() public override {
        super.setUp();
        preparation = new PrepareStaticsBatchRewardsUpgrade();
        facet = address(new BatchRewardsFacet());
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new StaticsInterfaceInit()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.interfaceInit()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = type(IStaticsBatchRewards).interfaceId;
        StaticsInterfaceInit(address(diamond)).setInterfaces(ids, new bool[](1));
    }

    function testTimelockAddsBatchToPopulatedDiamondWithoutMigration() public {
        PoolId pool = _createRangeGaugePool(alice);
        uint256 id = _stake(alice, new address[](0));
        _provide(id, pool, alice);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _bribe(pool, reward, 0);
        vm.warp(block.timestamp + 1 days);
        uint256 balanceBefore = reward.balanceOf(address(diamond));
        _executeTimelockUpgrade();
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBatchRewards).interfaceId));
        assertEq(globalRewards.stakePosition(id).stakedBalance, 100 ether);
        assertEq(reward.balanceOf(address(diamond)), balanceBefore);
        assertGt(_lpBatch(_poolClaims(id, pool, _slots(slot, false)))[0][0], 0);
    }

    function _executeTimelockUpgrade() private {
        address[] memory members = new address[](1);
        members[0] = address(this);
        StaticsTimelock timelock = new StaticsTimelock(members, members, members, address(this));
        IERC173(address(diamond)).transferOwnership(address(timelock));
        (address owner, bytes32 operation, bytes memory schedule, bytes memory execute) =
            preparation.buildTimelockCalldata(address(diamond), facet, keccak256("batch"));
        assertEq(owner, address(timelock));
        (bool ok, bytes memory result) = owner.call(schedule);
        assertTrue(ok, string(result));
        assertTrue(timelock.isOperationPending(operation));
        vm.warp(block.timestamp + timelock.getMinDelay());
        (ok, result) = owner.call(execute);
        assertTrue(ok, string(result));
        assertTrue(timelock.isOperationDone(operation));
    }

    function testRejectsMissingClaimRoutesAndSelectorCollisions() public {
        _installBatch();
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.BatchSelectorAlreadyInstalled.selector);
        preparation.buildBatch(address(diamond), facet);
        bytes4[] memory remove = StaticsSelectors.batchRewards();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, remove);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        remove = new bytes4[](1);
        remove[0] = IStaticsGlobalRewards.claimRewards.selector;
        cut[0].functionSelectors = remove;
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(PrepareStaticsBatchRewardsUpgrade.RequiredClaimRouteMissing.selector, remove[0])
        );
        preparation.buildBatch(address(diamond), facet);
    }

    function testRejectsUnverifiedFacetAndNonTimelockOwner() public {
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.InvalidBatchFacet.selector);
        preparation.buildBatch(address(diamond), alice);
        vm.expectPartialRevert(PrepareStaticsBatchRewardsUpgrade.InvalidTimelock.selector);
        preparation.buildTimelockCalldata(address(diamond), facet, bytes32(0));
    }
}
