// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {GenesisFacet} from "../../src/facets/GenesisFacet.sol";
import {IStaticsGenesisStaking} from "../../src/interfaces/IStaticsGenesisStaking.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibGenesis} from "../../src/libraries/LibGenesis.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract GenesisFeeAccrualHarness {
    bytes32 private constant SOURCE_ACCOUNT = keccak256("statics.test.genesis.fee.source");

    function accrueNonSwapFee(address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(SOURCE_ACCOUNT, asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibGlobalRewards.accrueNonSwapFee(SOURCE_ACCOUNT, asset, amount);
    }
}

contract GenesisRewardsTest is StaticsTestBase {
    uint256 internal constant MAX_TRANSACTION_GAS = 16_000_000;
    IStaticsGenesisStaking internal genesisStaking;
    IStaticsProtocolRevenue internal protocolRevenue;
    IERC721 internal genesisNFT;
    GenesisFeeAccrualHarness internal feeHarness;

    function setUp() public override {
        super.setUp();
        genesisStaking = IStaticsGenesisStaking(address(diamond));
        protocolRevenue = IStaticsProtocolRevenue(address(diamond));
        genesisNFT = IERC721(genesisStaking.genesisCollection());
        feeHarness = new GenesisFeeAccrualHarness();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = GenesisFeeAccrualHarness.accrueNonSwapFee.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(feeHarness), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        feeHarness = GenesisFeeAccrualHarness(address(diamond));
    }

    function test_CumulativeActivationBurnsSequentialTierCosts() public {
        _giveGenesis(alice, 1);
        stakingAsset.mint(alice, 100_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisFacet.ActivationBurnExceedsMaximum.selector, 100_000 ether, 99_999 ether)
        );
        genesisStaking.activateGenesis(1, 4, 99_999 ether);
        genesisStaking.activateGenesis(1, 4, 100_000 ether);
        vm.stopPrank();

        IStaticsGenesisStaking.GenesisState memory state = genesisStaking.genesisState(1);
        assertEq(state.tier, 4);
        assertEq(state.multiplierBps, 12_500);
        assertEq(stakingAsset.balanceOf(alice), 0);
        assertEq(genesisStaking.genesisActivationCost(1), 10_000 ether);
        assertEq(genesisStaking.genesisActivationCost(4), 40_000 ether);
    }

    function test_LinkedActivationChangesWeightWithoutResettingEligibility() public {
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint256 alicePosition = _stake(alice, 100 ether, address(reward));
        uint256 bobPosition = _stake(bob, 100 ether, address(reward));
        _warpBothEligible(alicePosition, bobPosition, address(reward));
        _giveGenesis(alice, 2);

        vm.prank(alice);
        genesisStaking.linkGenesis(2, alicePosition);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory unactivatedSelection =
            globalRewards.rewardSelection(alicePosition, address(reward));
        assertEq(unactivatedSelection.effectiveEligibleWeight, 100 ether);
        stakingAsset.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10_000 ether);
        genesisStaking.activateGenesis(2, 1, 10_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory aliceSelection =
            globalRewards.rewardSelection(alicePosition, address(reward));
        assertEq(aliceSelection.actualEligibleStake, 100 ether);
        assertEq(aliceSelection.effectiveEligibleWeight, 110 ether);
        assertEq(aliceSelection.actualPendingStake, 0);

        _accrue(reward, alice, 210 ether);
        vm.prank(alice);
        assertEq(globalRewards.pendingRewards(alicePosition, _asset(address(reward)))[0], 99 ether);
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(bobPosition, _asset(address(reward)))[0], 90 ether);
    }

    function test_PositionTransferDetachesRewardsAndClearsGenesisWeight() public {
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint256 positionId = _stake(alice, 100 ether, address(reward));
        _warpEligible(positionId, address(reward), alice);
        _giveGenesis(alice, 3);
        stakingAsset.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10_000 ether);
        genesisStaking.activateGenesis(3, 1, 10_000 ether);
        genesisStaking.linkGenesis(3, positionId);
        vm.stopPrank();
        _accrue(reward, alice, 100 ether);
        vm.prank(alice);
        uint256 expectedCredit = globalRewards.pendingRewards(positionId, _asset(address(reward)))[0];

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);

        assertEq(genesisStaking.linkedGenesis(positionId), 0);
        assertEq(genesisStaking.linkedPosition(3), 0);
        assertEq(genesisStaking.positionRewardMultiplierBps(positionId), 10_000);
        uint256 credit = protocolRevenue.positionTransferRewardCredit(alice, address(reward));
        assertEq(credit, expectedCredit);
        vm.prank(bob);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(reward));
        assertEq(selection.actualEligibleStake, 100 ether);
        assertEq(selection.effectiveEligibleWeight, 100 ether);

        vm.prank(alice);
        uint256 received = protocolRevenue.claimPositionTransferRevenue(address(reward), alice, credit);
        assertEq(received, credit);
        assertEq(reward.balanceOf(alice), credit);
    }

    function test_GenesisCannotTransferWhileLinkedAndResetsActivationAfterUnlink() public {
        uint256 positionId = _stake(alice, 1 ether, address(assetA));
        _giveGenesis(alice, 4);
        stakingAsset.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10_000 ether);
        genesisStaking.activateGenesis(4, 1, 10_000 ether);
        genesisStaking.linkGenesis(4, positionId);
        vm.expectRevert(abi.encodeWithSelector(LibGenesis.GenesisLinkedOnTransfer.selector, 4, positionId));
        genesisNFT.transferFrom(alice, bob, 4);
        genesisStaking.unlinkGenesis(4);
        genesisNFT.transferFrom(alice, bob, 4);
        vm.stopPrank();

        assertEq(genesisStaking.genesisTier(4), 0);
        assertEq(genesisNFT.ownerOf(4), bob);
    }

    function test_UnactivatedGenesisCanUnlinkWithoutRewardBookCheckpoint() public {
        uint256 positionId = _stake(alice, 1 ether, address(assetA));
        _giveGenesis(alice, 6);
        vm.prank(alice);
        genesisStaking.linkGenesis(6, positionId);

        vm.warp(block.timestamp + 25 hours);
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));

        vm.prank(alice);
        genesisStaking.unlinkGenesis(6);
        assertEq(genesisStaking.linkedPosition(6), 0);
    }

    function test_ActivatedGenesisTransitionRequiresAndRecoversThroughCheckpoint() public {
        uint256 positionId = _stake(alice, 1 ether, address(assetA));
        _warpEligible(positionId, address(assetA), alice);
        _giveGenesis(alice, 7);
        stakingAsset.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10_000 ether);
        genesisStaking.activateGenesis(7, 1, 10_000 ether);
        genesisStaking.linkGenesis(7, positionId);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        assertTrue(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibGlobalRewards.RewardBookNeedsCheckpoint.selector, address(assetA)));
        genesisStaking.unlinkGenesis(7);

        globalRewards.checkpointRewardAssets(_asset(address(assetA)));
        assertFalse(globalRewards.rewardBookNeedsCheckpoint(address(assetA)));
        vm.prank(alice);
        genesisStaking.unlinkGenesis(7);
        assertEq(genesisStaking.linkedPosition(7), 0);
    }

    function test_GovernanceActivationCostBoundsAreEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(LibGenesis.InvalidActivationCost.selector, 999 ether));
        genesisStaking.setGenesisActivationCost(1, 999 ether);
        vm.expectRevert(abi.encodeWithSelector(LibGenesis.InvalidActivationCost.selector, 100_001 ether));
        genesisStaking.setGenesisActivationCost(1, 100_001 ether);

        genesisStaking.setGenesisActivationCost(1, 25_000 ether);
        assertEq(genesisStaking.genesisActivationCost(1), 25_000 ether);
    }

    function test_MaximumRewardAssetGenesisTransitionsAndPositionTransferFitGasCap() public {
        address[] memory rewardAssets = new address[](64);
        for (uint256 i; i < rewardAssets.length; ++i) {
            rewardAssets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        stakingAsset.mint(alice, 100_100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100_100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.stopPrank();
        _warpEligible(positionId, rewardAssets[0], alice);
        _giveGenesis(alice, 5);

        vm.startPrank(alice);
        uint256 gasBefore = gasleft();
        genesisStaking.linkGenesis(5, positionId);
        uint256 linkGas = gasBefore - gasleft();
        emit log_named_uint("64-asset Genesis link gas", linkGas);
        assertLt(linkGas, MAX_TRANSACTION_GAS);

        gasBefore = gasleft();
        genesisStaking.activateGenesis(5, 4, 100_000 ether);
        uint256 activationGas = gasBefore - gasleft();
        emit log_named_uint("64-asset Tier 4 activation gas", activationGas);
        assertLt(activationGas, MAX_TRANSACTION_GAS);

        gasBefore = gasleft();
        genesisStaking.unlinkGenesis(5);
        uint256 unlinkGas = gasBefore - gasleft();
        emit log_named_uint("64-asset Genesis unlink gas", unlinkGas);
        assertLt(unlinkGas, MAX_TRANSACTION_GAS);
        genesisStaking.linkGenesis(5, positionId);
        vm.stopPrank();

        for (uint256 i; i < rewardAssets.length; ++i) {
            MockERC20 reward = MockERC20(rewardAssets[i]);
            reward.mint(alice, 1 ether);
            vm.startPrank(alice);
            reward.approve(address(diamond), 1 ether);
            feeHarness.accrueNonSwapFee(address(reward), 1 ether);
            vm.stopPrank();
        }

        vm.startPrank(alice);
        gasBefore = gasleft();
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        uint256 transferGas = gasBefore - gasleft();
        emit log_named_uint("64-asset PositionNFT transfer gas", transferGas);
        vm.stopPrank();
        assertLt(transferGas, MAX_TRANSACTION_GAS);
        assertEq(genesisStaking.linkedGenesis(positionId), 0);
        for (uint256 i; i < rewardAssets.length; ++i) {
            assertGt(protocolRevenue.positionTransferRewardCredit(alice, rewardAssets[i]), 0);
        }
    }

    function _stake(address owner, uint256 amount, address rewardAsset) private returns (uint256 positionId) {
        stakingAsset.mint(owner, amount);
        vm.startPrank(owner);
        stakingAsset.approve(address(diamond), amount);
        positionId = globalRewards.createAndStake(amount, owner, _asset(rewardAsset));
        vm.stopPrank();
    }

    function _giveGenesis(address owner, uint256 genesisId) private {
        vm.prank(treasury);
        genesisNFT.transferFrom(treasury, owner, genesisId);
    }

    function _warpEligible(uint256 positionId, address asset, address owner) private {
        vm.prank(owner);
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, asset).eligibleAt;
        vm.warp(eligibleAt);
        _checkpointPosition(positionId, owner);
    }

    function _warpBothEligible(uint256 first, uint256 second, address asset) private {
        vm.prank(alice);
        uint40 firstAt = globalRewards.rewardSelection(first, asset).eligibleAt;
        vm.prank(bob);
        uint40 secondAt = globalRewards.rewardSelection(second, asset).eligibleAt;
        vm.warp(firstAt > secondAt ? firstAt : secondAt);
        _checkpointPosition(first, alice);
    }

    function _checkpointPosition(uint256 positionId, address owner) private {
        vm.prank(owner);
        address[] memory assets = globalRewards.positionRewardAssets(positionId);
        for (uint256 offset; offset < assets.length; offset += 8) {
            uint256 count = assets.length - offset;
            if (count > 8) count = 8;
            address[] memory batch = new address[](count);
            for (uint256 i; i < count; ++i) {
                batch[i] = assets[offset + i];
            }
            globalRewards.checkpointRewardAssets(batch);
        }
    }

    function _accrue(MockERC20 reward, address payer, uint256 amount) private {
        reward.mint(payer, amount);
        vm.startPrank(payer);
        reward.approve(address(diamond), amount);
        feeHarness.accrueNonSwapFee(address(reward), amount);
        vm.stopPrank();
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }
}

contract ColdGenesisLinkGasTest is StaticsTestBase {
    uint256 private constant MAX_TRANSACTION_GAS = 16_000_000;

    IStaticsGenesisStaking private genesisStaking;
    IERC721 private genesisNFT;
    uint256 private positionId;

    function setUp() public override {
        super.setUp();
        genesisStaking = IStaticsGenesisStaking(address(diamond));
        genesisNFT = IERC721(genesisStaking.genesisCollection());
        address[] memory rewardAssets = new address[](64);
        for (uint256 i; i < rewardAssets.length; ++i) {
            rewardAssets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.stopPrank();
        vm.prank(alice);
        vm.warp(globalRewards.rewardSelection(positionId, rewardAssets[0]).eligibleAt);
        vm.prank(treasury);
        genesisNFT.transferFrom(treasury, alice, 6);
    }

    function test_ColdMaximumRewardAssetGenesisLinkFitsTransactionGasCap() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        genesisStaking.linkGenesis(6, positionId);
        uint256 linkGas = gasBefore - gasleft();
        emit log_named_uint("cold 64-asset Genesis link gas", linkGas);
        assertLt(linkGas, MAX_TRANSACTION_GAS);
    }
}

contract ColdActivatedGenesisLinkGasTest is StaticsTestBase {
    uint256 private constant MAX_TRANSACTION_GAS = 16_000_000;

    IStaticsGenesisStaking private genesisStaking;
    IERC721 private genesisNFT;
    uint256 private positionId;

    function setUp() public override {
        super.setUp();
        genesisStaking = IStaticsGenesisStaking(address(diamond));
        genesisNFT = IERC721(genesisStaking.genesisCollection());
        address[] memory rewardAssets = new address[](64);
        for (uint256 i; i < rewardAssets.length; ++i) {
            rewardAssets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        stakingAsset.mint(alice, 100_100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100_100 ether);
        positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.stopPrank();
        vm.prank(alice);
        vm.warp(globalRewards.rewardSelection(positionId, rewardAssets[0]).eligibleAt);
        for (uint256 offset; offset < rewardAssets.length; offset += 8) {
            address[] memory batch = new address[](8);
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = rewardAssets[offset + i];
            }
            globalRewards.checkpointRewardAssets(batch);
        }
        vm.prank(treasury);
        genesisNFT.transferFrom(treasury, alice, 7);
        vm.prank(alice);
        genesisStaking.activateGenesis(7, 4, 100_000 ether);
    }

    function test_ColdMaximumRewardAssetActivatedGenesisLinkFitsTransactionGasCap() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        genesisStaking.linkGenesis(7, positionId);
        uint256 linkGas = gasBefore - gasleft();
        emit log_named_uint("cold 64-asset activated Genesis link gas", linkGas);
        assertLt(linkGas, MAX_TRANSACTION_GAS);
    }
}

contract ColdRewardCheckpointGasTest is StaticsTestBase {
    uint256 private constant MAX_TRANSACTION_GAS = 16_000_000;

    address[] private checkpointAssets;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 8; ++i) {
            checkpointAssets.push(address(new MockERC20("Reward", "RWD", 18)));
        }
        for (uint256 bucket; bucket < 24; ++bucket) {
            stakingAsset.mint(alice, 1 ether);
            vm.startPrank(alice);
            stakingAsset.approve(address(diamond), 1 ether);
            globalRewards.createAndStake(1 ether, alice, checkpointAssets);
            vm.stopPrank();
            if (bucket != 23) vm.warp(block.timestamp + 1 hours);
        }
        vm.warp(block.timestamp + 25 hours);
    }

    function test_ColdEightAssetMaximumBucketCheckpointFitsTransactionGasCap() public {
        address[] memory assets = checkpointAssets;
        uint256 gasBefore = gasleft();
        globalRewards.checkpointRewardAssets(assets);
        uint256 checkpointGas = gasBefore - gasleft();
        emit log_named_uint("cold 8-asset 24-bucket checkpoint gas", checkpointGas);
        assertLt(checkpointGas, MAX_TRANSACTION_GAS);
        for (uint256 i; i < assets.length; ++i) {
            assertFalse(globalRewards.rewardBookNeedsCheckpoint(assets[i]));
        }
    }
}

contract ColdPositionTransferGasTest is StaticsTestBase {
    uint256 private constant MAX_TRANSACTION_GAS = 16_000_000;

    uint256 private positionId;
    IStaticsGenesisStaking private genesisStaking;
    IERC721 private genesisNFT;

    function setUp() public override {
        super.setUp();
        genesisStaking = IStaticsGenesisStaking(address(diamond));
        genesisNFT = IERC721(genesisStaking.genesisCollection());
        GenesisFeeAccrualHarness implementation = new GenesisFeeAccrualHarness();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = GenesisFeeAccrualHarness.accrueNonSwapFee.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(implementation), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        GenesisFeeAccrualHarness feeHarness = GenesisFeeAccrualHarness(address(diamond));

        address[] memory rewardAssets = new address[](64);
        for (uint256 i; i < rewardAssets.length; ++i) {
            rewardAssets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.stopPrank();
        vm.prank(alice);
        vm.warp(globalRewards.rewardSelection(positionId, rewardAssets[0]).eligibleAt);
        for (uint256 offset; offset < rewardAssets.length; offset += 8) {
            address[] memory batch = new address[](8);
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = rewardAssets[offset + i];
            }
            globalRewards.checkpointRewardAssets(batch);
        }
        for (uint256 i; i < rewardAssets.length; ++i) {
            MockERC20 reward = MockERC20(rewardAssets[i]);
            reward.mint(alice, 1 ether);
            vm.startPrank(alice);
            reward.approve(address(diamond), 1 ether);
            feeHarness.accrueNonSwapFee(address(reward), 1 ether);
            vm.stopPrank();
        }
        vm.prank(treasury);
        genesisNFT.transferFrom(treasury, alice, 8);
        stakingAsset.mint(alice, 100_000 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100_000 ether);
        genesisStaking.activateGenesis(8, 4, 100_000 ether);
        genesisStaking.linkGenesis(8, positionId);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        for (uint256 i; i < rewardAssets.length; ++i) {
            assertTrue(globalRewards.rewardBookNeedsCheckpoint(rewardAssets[i]));
        }
        for (uint256 offset; offset < rewardAssets.length; offset += 8) {
            address[] memory batch = new address[](8);
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = rewardAssets[offset + i];
            }
            globalRewards.checkpointRewardAssets(batch);
        }
        vm.warp(block.timestamp + 23 hours);
        for (uint256 i; i < rewardAssets.length; ++i) {
            assertFalse(globalRewards.rewardBookNeedsCheckpoint(rewardAssets[i]));
        }
    }

    function test_ColdMaximumRewardAssetPositionTransferFitsTransactionGasCap() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        uint256 transferGas = gasBefore - gasleft();
        emit log_named_uint("cold 64-asset boosted PositionNFT transfer gas after 23 empty epochs", transferGas);
        assertLt(transferGas, MAX_TRANSACTION_GAS);
    }
}
