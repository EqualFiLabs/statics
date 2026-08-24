// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {
    GenesisCreditConfig,
    GenesisCreditRecoveryQuote,
    GenesisPurchaseQuote,
    IStaticsGenesisVault
} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {GenesisNFTFacet} from "../../src/facets/GenesisNFTFacet.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {LibGenesisIntegration} from "../../src/libraries/LibGenesisIntegration.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract GenesisIntegrationFeeSource {
    address public statics;
    address public numeraire;
    address public beneficiary;
    uint256 public pendingStatics;
    uint256 public pendingNumeraire;

    function configure(address statics_, address numeraire_, address beneficiary_) external {
        statics = statics_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function queue(uint256 staticsAmount, uint256 numeraireAmount) external {
        if (staticsAmount != 0) IERC20(statics).transferFrom(msg.sender, address(this), staticsAmount);
        if (numeraireAmount != 0) IERC20(numeraire).transferFrom(msg.sender, address(this), numeraireAmount);
        pendingStatics += staticsAmount;
        pendingNumeraire += numeraireAmount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 staticsAmount = pendingStatics;
        uint256 numeraireAmount = pendingNumeraire;
        delete pendingStatics;
        delete pendingNumeraire;
        if (staticsAmount != 0) IERC20(statics).transfer(msg.sender, staticsAmount);
        if (numeraireAmount != 0) IERC20(numeraire).transfer(msg.sender, numeraireAmount);
        return (uint128(staticsAmount), uint128(numeraireAmount));
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        (currency0, currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract GenesisIntegrationInitHarness {
    function initializeGenesisIntegration(LibGenesisIntegration.InitArgs calldata args) external {
        LibGenesisIntegration.initialize(args);
    }
}

contract GenesisPositionIntegrationTest is StaticsTestBase {
    uint256 private constant GENESIS_PRICE = 180_000 ether;
    uint256 private constant ORIGINATION_FEE = 0.003 ether;
    uint256 private constant EXTENSION_FEE = 0.003 ether;
    bytes32 private constant POOL_ID = keccak256("GENESIS_POSITION_INTEGRATION");

    MockERC20 private numeraire;
    GenesisIntegrationFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private activationRegistry;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;
    IStaticsGenesisIntegration private integration;
    uint256 private epochEnd;

    struct ComposedRecoverySnapshot {
        bytes32 collateralHash;
        bytes32 loanHash;
        bytes32 portfolioHash;
        uint256 rewardA;
        uint256 rewardB;
        uint40 pendingEligibleAt;
        uint256 positionNonce;
        uint256 positionObligations;
    }

    function setUp() public override {
        super.setUp();
        numeraire = new MockERC20("Wrapped Native", "WETH", 18);
        feeSource = new GenesisIntegrationFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(numeraire), address(this));
        feeSource.configure(address(stakingAsset), address(numeraire), address(feeReceiver));
        feeReceiver.bindMarket(address(stakingAsset), POOL_ID);

        activationRegistry = new GenesisActivationRegistry(stakingAsset, address(this), address(this), treasury);
        epochEnd = block.timestamp + 7 days;
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: ORIGINATION_FEE,
            extensionFee: EXTENSION_FEE,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(stakingAsset, address(this), address(this), epochEnd, creditConfig);
        genesis = new StaticsGenesis(
            address(vault),
            address(this),
            address(activationRegistry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            address(this),
            treasury,
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        activationRegistry.bindGenesisCollection(address(genesis));
        stakingAsset.mint(address(vault), vault.INITIAL_TOKEN_BACKING());
        vault.finalizeGenesisCollection(address(genesis));
        feeReceiver.bindReserveVault(address(vault));

        _installGenesisIntegration();
        integration = IStaticsGenesisIntegration(address(diamond));
        GenesisIntegrationInitHarness(address(diamond))
            .initializeGenesisIntegration(
                LibGenesisIntegration.InitArgs({
                genesis: address(genesis),
                vault: address(vault),
                activationRegistry: address(activationRegistry),
                feeReceiver: address(feeReceiver),
                statics: address(stakingAsset),
                numeraire: address(numeraire),
                genesisRewardShareBps: 9_000
            })
            );

        feeReceiver.proposeDistributor(address(diamond));
        integration.acceptGenesisDistributorRole();
        activationRegistry.proposeConsumer(address(diamond));
        integration.acceptGenesisConsumerRole();
        genesis.bindProtocol(address(diamond));
        assertTrue(integration.genesisIntegrationReady());
        stakingAsset.approve(address(feeSource), type(uint256).max);
        numeraire.approve(address(feeSource), type(uint256).max);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function testTierZeroLinkLocksBothNFTsWithoutChangingBaseWeight() external {
        _buyGenesis(alice, 1);
        uint256 positionId = _createPosition(alice);

        vm.prank(alice);
        integration.linkGenesis(positionId, 1);

        assertEq(integration.linkedPosition(1), positionId);
        assertEq(integration.linkedGenesis(positionId), 1);
        assertTrue(genesis.locked(1));
        assertTrue(IERC5192(address(diamond)).locked(positionId));
        assertTrue(
            IStaticsPosition(address(diamond)).isLegActive(positionId, LibPosition.genesisLegKey(address(diamond), 1))
        );
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, alice, positionId);
        vm.prank(alice);
        genesis.transferFrom(alice, alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionLocked.selector, positionId));
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
        genesis.transferFrom(alice, bob, 1);
    }

    function testTierFourLinkUsesEffectiveWeightWithoutChangingPrincipal() external {
        _buyGenesis(alice, 2);
        _activate(alice, 2, 4);
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt;
        vm.warp(eligibleAt);
        globalRewards.checkpointRewardAssets(_asset(address(assetA)));
        integration.linkGenesis(positionId, 2);
        vm.stopPrank();

        IStaticsGlobalRewards.RewardAssetView memory book = globalRewards.rewardAsset(address(assetA));
        vm.prank(alice);
        IStaticsGlobalRewards.StakePositionView memory stake = globalRewards.stakePosition(positionId);
        assertEq(stake.stakedBalance, 100 ether);
        assertEq(stake.rewardMultiplierBps, 12_500);
        assertEq(globalRewards.totalStaked(), 100 ether);
        assertEq(book.eligibleStake, 100 ether);
        assertEq(book.eligibleWeight, 125 ether);
    }

    function testActivationWhileLinkedChangesOnlyFutureRewardWeight() external {
        _buyGenesis(alice, 3);
        _activate(alice, 3, 1);
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        integration.linkGenesis(positionId, 3);
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt;
        vm.stopPrank();
        _fundActivation(alice, 90_000 ether);
        vm.prank(alice);
        activationRegistry.activate(3, 4);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));

        assertEq(selection.pendingStake, 100 ether);
        assertEq(selection.pendingWeight, 125 ether);
        assertEq(selection.eligibleAt, eligibleAt);
    }

    function testOnlyActualOwnersCanLinkEvenWhenOperatorApprovalsExist() external {
        _buyGenesis(alice, 4);
        uint256 positionId = _createPosition(alice);
        vm.startPrank(alice);
        genesis.approve(bob, 4);
        IERC721(address(diamond)).approve(bob, positionId);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFTFacet.NotAssetOwner.selector, 4, bob, alice));
        integration.linkGenesis(positionId, 4);
    }

    function testUnlinkDuringActiveCreditRemovesBoostButPreservesCredit() external {
        _buyGenesis(alice, 5);
        _activate(alice, 5, 4);
        uint256 positionId = _createPosition(alice);
        vm.prank(alice);
        integration.linkGenesis(positionId, 5);
        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(5, 100_000 ether);

        vm.prank(alice);
        integration.unlinkGenesis(positionId, 5);

        assertTrue(vault.creditActive(5));
        assertEq(genesis.ownerOf(5), alice);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
        assertEq(integration.linkedPosition(5), 0);
        assertEq(integration.linkedGenesis(positionId), 0);
        assertFalse(IERC5192(address(diamond)).locked(positionId));
        assertTrue(genesis.locked(5));
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);
    }

    function testCreditOpenExtendAndRepayPreserveLinkAndMultiplier() external {
        _buyGenesis(alice, 7);
        _activate(alice, 7, 4);
        uint256 positionId = _createPosition(alice);
        vm.prank(alice);
        integration.linkGenesis(positionId, 7);
        vm.warp(epochEnd);

        vm.startPrank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(7, 100_000 ether);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(7);
        stakingAsset.approve(address(vault), 100_000 ether);
        vault.repayGenesisCredit(7);
        vm.stopPrank();

        assertFalse(vault.creditActive(7));
        assertEq(integration.linkedPosition(7), positionId);
        assertEq(integration.linkedGenesis(positionId), 7);
        assertTrue(genesis.locked(7));
        assertTrue(IERC5192(address(diamond)).locked(positionId));
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 12_500);
    }

    function testUnlinkRestoresIndependentTransfersWithoutMovingCustody() external {
        _buyGenesis(alice, 6);
        uint256 positionId = _createPosition(alice);
        vm.startPrank(alice);
        integration.linkGenesis(positionId, 6);
        integration.unlinkGenesis(positionId, 6);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        genesis.transferFrom(alice, bob, 6);
        vm.stopPrank();

        assertEq(IERC721(address(diamond)).ownerOf(positionId), bob);
        assertEq(genesis.ownerOf(6), bob);
        assertEq(activationRegistry.multiplierBps(6), 10_000);
    }

    function testRegistrationPersistsAcrossTransferAndRewardsFollowNewOwner() external {
        _buyAndRegister(alice, 8);
        _buyAndRegister(bob, 9);
        _queueRewards(2_000 ether, 200 ether);
        feeReceiver.harvest();

        assertEq(stakingAsset.balanceOf(address(diamond)), 0, "transfer setup pulled rewards");
        vm.prank(alice);
        genesis.transferFrom(alice, bob, 8);

        assertTrue(integration.genesisRegistered(8));
        assertEq(integration.genesisEffectiveWeight(8), 10_000);
        assertEq(integration.genesisOwnerClaimable(alice, address(stakingAsset)), 900 ether);
        assertEq(integration.genesisOwnerClaimable(alice, address(numeraire)), 90 ether);
        assertEq(stakingAsset.balanceOf(address(diamond)), 0, "transfer moved reward tokens");

        _queueRewards(2_000 ether, 200 ether);
        integration.accrueGenesisRewards();
        vm.prank(bob);
        assertEq(integration.claimGenesisRewards(8, address(stakingAsset), bob), 900 ether);
        vm.prank(alice);
        assertEq(integration.claimGenesisOwnerRewards(address(stakingAsset), alice), 900 ether);
    }

    function testTransferResetsActivationWithoutResettingRegistration() external {
        _buyAndRegister(alice, 10);
        _activate(alice, 10, 4);
        assertEq(integration.genesisEffectiveWeight(10), 12_500);

        vm.prank(alice);
        genesis.transferFrom(alice, bob, 10);

        assertEq(activationRegistry.tierOf(10), 0);
        assertTrue(integration.genesisRegistered(10));
        assertEq(integration.genesisEffectiveWeight(10), 10_000);
    }

    function testRewardsUseIsolatedCustodyAndTreasuryReceivesConfiguredShare() external {
        _buyAndRegister(alice, 11);
        _queueRewards(1_000 ether, 100 ether);
        integration.accrueGenesisRewards();

        bytes32 account = custody.genesisRewardCustodyAccount();
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), 1_000 ether);
        assertEq(custody.reservedByAccount(account, address(numeraire)), 100 ether);
        IStaticsGenesisIntegration.GenesisRewardBookView memory book =
            integration.genesisRewardBook(address(stakingAsset));
        assertEq(book.treasuryClaimable, 100 ether);
        assertEq(integration.pendingGenesisRewards(11, address(stakingAsset)), 900 ether);

        vm.prank(treasury);
        assertEq(integration.claimGenesisTreasuryRewards(address(stakingAsset), treasury), 100 ether);
        vm.prank(alice);
        assertEq(integration.claimGenesisRewards(11, address(stakingAsset), alice), 900 ether);
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), 0);
    }

    function testRecoveryPreservesRegistrationButRemovesBothRewardWeights() external {
        _buyAndRegister(alice, 12);
        _activate(alice, 12, 4);
        uint256 positionId = _createPosition(alice);
        vm.prank(alice);
        integration.linkGenesis(positionId, 12);
        _queueRewards(1_000 ether, 0);
        integration.accrueGenesisRewards();

        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(12, 100_000 ether);
        vm.warp(uint256(vault.creditRecoverableAt(12)) + 1);
        vm.prank(bob);
        vault.recoverGenesisCredit(12);

        assertTrue(integration.genesisRegistered(12));
        assertEq(integration.genesisEffectiveWeight(12), 0);
        assertEq(integration.genesisTotalWeight(), 0);
        assertEq(integration.linkedPosition(12), 0);
        assertEq(integration.linkedGenesis(positionId), 0);
        assertEq(genesis.ownerOf(12), address(vault));
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
        assertEq(activationRegistry.tierOf(12), 0);
        assertGt(integration.pendingGenesisRecovery(), 0);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);
        vm.prank(alice);
        assertEq(integration.claimGenesisOwnerRewards(address(stakingAsset), alice), 900 ether);
    }

    function testDeferredRecoveryIndexesWhenSameGenesisIsReacquired() external {
        _buyAndRegister(alice, 13);
        assertEq(integration.genesisTotalWeight(), 10_000);

        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(13, 100_000 ether);
        GenesisCreditRecoveryQuote memory recoveryQuote = vault.quoteGenesisCreditRecovery(13);
        vm.warp(uint256(recoveryQuote.recoverableAt) + 1);
        vm.prank(bob);
        vault.recoverGenesisCredit(13);

        assertTrue(integration.genesisRegistered(13));
        assertEq(integration.genesisEffectiveWeight(13), 0);
        assertEq(integration.genesisTotalWeight(), 0);
        assertEq(integration.pendingGenesisRecovery(), recoveryQuote.genesisDistribution);
        assertEq(genesis.ownerOf(13), address(vault));

        stakingAsset.mint(bob, GENESIS_PRICE);
        GenesisPurchaseQuote memory purchaseQuote = vault.quoteGenesisPurchase();
        vm.startPrank(bob);
        stakingAsset.approve(address(vault), GENESIS_PRICE);
        vault.buyGenesis{value: purchaseQuote.requiredNative}(13, bob);
        vm.stopPrank();

        assertEq(genesis.ownerOf(13), bob);
        assertTrue(integration.genesisRegistered(13));
        assertEq(integration.genesisEffectiveWeight(13), 10_000);
        assertEq(integration.genesisTotalWeight(), 10_000);
        assertEq(integration.pendingGenesisRecovery(), 0);
        assertEq(integration.pendingGenesisRewards(13, address(stakingAsset)), recoveryQuote.genesisDistribution);
        vm.prank(bob);
        assertEq(integration.claimGenesisRewards(13, address(stakingAsset), bob), recoveryQuote.genesisDistribution);
    }

    function testPermissionlessRecoveryPreservesComposedPositionState() external {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        _buyAndRegister(alice, 14);
        _activate(alice, 14, 4);

        address[] memory rewardAssets = _assets(address(assetA), address(assetB));
        stakingAsset.mint(alice, 130 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 130 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.warp(globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt);
        globalRewards.checkpointRewardAssets(rewardAssets);
        integration.linkGenesis(positionId, 14);
        vm.stopPrank();

        uint256[] memory mintInputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, mintInputs[0], mintInputs[1]);
        vm.startPrank(alice);
        basketCollateral.mintBasketCollateral(positionId, basketId, 10 ether, mintInputs);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        vm.stopPrank();

        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(14, 100_000 ether);
        uint256 recoverableAt = vault.creditRecoverableAt(14);
        vm.warp(recoverableAt - 25 hours);
        vm.prank(alice);
        globalRewards.stake(positionId, 10 ether);
        vm.warp(recoverableAt + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibGlobalRewards.RewardBookNeedsCheckpoint.selector, address(assetA)));
        vault.recoverGenesisCredit(14);
        vm.prank(bob);
        globalRewards.checkpointRewardAssets(rewardAssets);

        vm.prank(alice);
        globalRewards.stake(positionId, 20 ether);
        ComposedRecoverySnapshot memory beforeRecovery =
            _composedRecoverySnapshot(positionId, basketId, loanId, rewardAssets);
        assertGt(beforeRecovery.rewardA, 0);
        assertGt(beforeRecovery.rewardB, 0);

        vm.prank(bob);
        vault.recoverGenesisCredit(14);

        ComposedRecoverySnapshot memory afterRecovery =
            _composedRecoverySnapshot(positionId, basketId, loanId, rewardAssets);
        assertEq(afterRecovery.collateralHash, beforeRecovery.collateralHash);
        assertEq(afterRecovery.loanHash, beforeRecovery.loanHash);
        assertEq(afterRecovery.portfolioHash, beforeRecovery.portfolioHash);
        assertEq(afterRecovery.rewardA, beforeRecovery.rewardA);
        assertEq(afterRecovery.rewardB, beforeRecovery.rewardB);
        assertEq(afterRecovery.pendingEligibleAt, beforeRecovery.pendingEligibleAt);
        assertEq(afterRecovery.positionObligations, beforeRecovery.positionObligations);
        assertGt(afterRecovery.positionNonce, beforeRecovery.positionNonce);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
        assertEq(integration.linkedPosition(14), 0);
        assertEq(integration.linkedGenesis(positionId), 0);
        assertFalse(IERC5192(address(diamond)).locked(positionId));
        assertTrue(
            IStaticsPosition(address(diamond)).isLegActive(positionId, LibPosition.stakingLegKey(address(diamond)))
        );
        assertTrue(
            IStaticsPosition(address(diamond))
                .isLegActive(positionId, LibPosition.basketLegKey(address(diamond), basketId))
        );

        vm.prank(alice);
        IStaticsGlobalRewards.StakePositionView memory stake = globalRewards.stakePosition(positionId);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        assertEq(stake.stakedBalance, 130 ether);
        assertEq(stake.rewardMultiplierBps, 10_000);
        assertEq(selection.eligibleStake, 110 ether);
        assertEq(selection.eligibleWeight, 110 ether);
        assertEq(selection.pendingStake, 20 ether);
        assertEq(selection.pendingWeight, 20 ether);

        uint256[] memory minimums = new uint256[](2);
        minimums[0] = beforeRecovery.rewardA;
        minimums[1] = beforeRecovery.rewardB;
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(positionId, rewardAssets, alice, minimums);
        assertEq(claimed[0], beforeRecovery.rewardA);
        assertEq(claimed[1], beforeRecovery.rewardB);
    }

    function testMaximumAssetRecoveryUsesPermissionlessCheckpointBatches() external {
        uint256 maximumGas = 16_000_000;
        address[] memory rewardAssets = new address[](64);
        for (uint256 i; i < rewardAssets.length; ++i) {
            rewardAssets[i] = address(new MockERC20("Reward", "RWD", 18));
        }
        _buyAndRegister(alice, 15);
        _activate(alice, 15, 4);
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        uint256 positionId = globalRewards.createAndStake(1 ether, alice, rewardAssets);
        integration.linkGenesis(positionId, 15);
        vm.warp(epochEnd);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(15, 100_000 ether);
        vm.stopPrank();
        vm.warp(uint256(vault.creditRecoverableAt(15)) + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibGlobalRewards.RewardBookNeedsCheckpoint.selector, rewardAssets[0]));
        vault.recoverGenesisCredit(15);
        _checkpointRewardAssetsInBatches(bob, rewardAssets);

        uint256 gasBefore = gasleft();
        vm.prank(bob);
        vault.recoverGenesisCredit(15);
        uint256 recoveryGas = gasBefore - gasleft();

        emit log_named_uint("64-asset composed Genesis recovery gas", recoveryGas);
        assertLt(recoveryGas, maximumGas);
        assertEq(genesis.ownerOf(15), address(vault));
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);
        vm.prank(alice);
        assertEq(globalRewards.rewardSelection(positionId, rewardAssets[63]).eligibleWeight, 1 ether);
    }

    function _installGenesisIntegration() private {
        GenesisNFTFacet genesisFacet = new GenesisNFTFacet();
        GenesisIntegrationInitHarness initHarness = new GenesisIntegrationInitHarness();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(genesisFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: StaticsSelectors.genesisNFT()
        });
        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = GenesisIntegrationInitHarness.initializeGenesisIntegration.selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(initHarness), action: IDiamondCut.FacetCutAction.Add, functionSelectors: initSelectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _buyGenesis(address owner, uint256 genesisId) private {
        stakingAsset.mint(owner, GENESIS_PRICE);
        GenesisPurchaseQuote memory quote = vault.quoteGenesisPurchase();
        vm.startPrank(owner);
        stakingAsset.approve(address(vault), GENESIS_PRICE);
        vault.buyGenesis{value: quote.requiredNative}(genesisId, owner);
        vm.stopPrank();
    }

    function _buyAndRegister(address owner, uint256 genesisId) private {
        _buyGenesis(owner, genesisId);
        vm.prank(owner);
        integration.registerGenesis(genesisId);
    }

    function _queueRewards(uint256 staticsAmount, uint256 numeraireAmount) private {
        if (staticsAmount != 0) stakingAsset.mint(address(this), staticsAmount);
        if (numeraireAmount != 0) numeraire.mint(address(this), numeraireAmount);
        feeSource.queue(staticsAmount, numeraireAmount);
    }

    function _createPosition(address owner) private returns (uint256 positionId) {
        vm.prank(owner);
        positionId = IStaticsPosition(address(diamond)).createPosition(owner);
    }

    function _activate(address owner, uint256 genesisId, uint8 tier) private {
        uint256 amount = tier == 1 ? 10_000 ether : 100_000 ether;
        _fundActivation(owner, amount);
        vm.prank(owner);
        activationRegistry.activate(genesisId, tier);
    }

    function _fundActivation(address owner, uint256 amount) private {
        stakingAsset.mint(owner, amount);
        vm.prank(owner);
        stakingAsset.approve(address(activationRegistry), type(uint256).max);
    }

    function _composedRecoverySnapshot(
        uint256 positionId,
        uint256 basketId,
        uint256 loanId,
        address[] memory rewardAssets
    ) private returns (ComposedRecoverySnapshot memory snapshot) {
        vm.startPrank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, rewardAssets);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, rewardAssets[0]);
        vm.stopPrank();
        IModularPositionNFT.PositionState memory structural =
            IModularPositionNFT(address(diamond)).positionState(positionId);
        IStaticsBasketCollateral.BasketCollateralPosition memory collateral =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        IStaticsPositionPortfolio.PositionPortfolioCounts memory portfolio =
            positionPortfolio.positionPortfolioCounts(positionId);
        snapshot = ComposedRecoverySnapshot({
            collateralHash: keccak256(abi.encode(collateral)),
            loanHash: keccak256(abi.encode(loan)),
            portfolioHash: keccak256(abi.encode(portfolio)),
            rewardA: pending[0],
            rewardB: pending[1],
            pendingEligibleAt: selection.eligibleAt,
            positionNonce: structural.stateNonce,
            positionObligations: structural.unresolvedObligationCount
        });
    }

    function _checkpointRewardAssetsInBatches(address caller, address[] memory assets) private {
        for (uint256 offset; offset < assets.length; offset += 8) {
            address[] memory batch = new address[](8);
            for (uint256 i; i < 8; ++i) {
                batch[i] = assets[offset + i];
            }
            vm.prank(caller);
            globalRewards.checkpointRewardAssets(batch);
        }
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _assets(address first, address second) private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return true;
    }
}
