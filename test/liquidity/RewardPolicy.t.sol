// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {RewardPolicyFacet} from "../../src/facets/RewardPolicyFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract RewardPolicyTest is StaticsTestBase {
    IStaticsRewardPolicy private policy;

    function setUp() public override {
        super.setUp();
        policy = IStaticsRewardPolicy(address(diamond));
    }

    function testGuardianMayAddButCannotRemoveRestriction() external {
        vm.prank(guardian);
        policy.addRewardRestriction(address(assetA));
        assertTrue(policy.rewardRestricted(address(assetA)));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(this)));
        policy.removeRewardRestriction(address(assetA));

        policy.removeRewardRestriction(address(assetA));
        assertFalse(policy.rewardRestricted(address(assetA)));
    }

    function testRestrictionBlocksNewOptInButPreservesClaimAndExit() external {
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, _asset(address(assetA)));
        vm.stopPrank();

        vm.prank(guardian);
        policy.addRewardRestriction(address(assetB));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibGlobalRewards.RewardAssetRestricted.selector, address(assetB)));
        globalRewards.optInRewardAssets(positionId, _asset(address(assetB)));
        globalRewards.optOutRewardAssets(positionId, _asset(address(assetA)));
        globalRewards.unstake(positionId, 10 ether, alice);
        vm.stopPrank();
    }

    function testRestrictedSwapShareFallsBackToTreasuryWithEligibleStake() external {
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, _asset(address(assetA)));
        vm.stopPrank();
        vm.prank(alice);
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt;
        vm.warp(eligibleAt);
        globalRewards.checkpointRewardAssets(_asset(address(assetA)));

        vm.prank(guardian);
        policy.addRewardRestriction(address(assetA));
        _installSwapAccrualHarness().accrue(address(assetA), 1 ether);

        assertEq(globalRewards.treasuryAccrued(address(assetA)), 1 ether);
        vm.prank(alice);
        assertEq(globalRewards.pendingRewards(positionId, _asset(address(assetA)))[0], 0);
    }

    function _installSwapAccrualHarness() private returns (SwapAccrualHarness harness) {
        SwapAccrualHarness implementation = new SwapAccrualHarness();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SwapAccrualHarness.accrue.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(implementation), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        harness = SwapAccrualHarness(address(diamond));
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }
}

contract SwapAccrualHarness {
    function accrue(address asset, uint256 amount) external {
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, amount);
    }
}
