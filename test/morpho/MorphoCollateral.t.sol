// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MorphoMarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {MorphoFacet} from "../../src/facets/MorphoFacet.sol";
import {MorphoSettlementFacet} from "../../src/facets/MorphoSettlementFacet.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {LibGenesisIntegration} from "../../src/libraries/LibGenesisIntegration.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibMorpho} from "../../src/libraries/LibMorpho.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketRewards} from "../../src/libraries/LibBasketRewards.sol";
import {StaticsTestBase, StaticsTestDeployer} from "../helpers/StaticsTestBase.sol";
import {MockERC20, MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";
import {MockMorphoBlue} from "../mocks/MockMorphoBlue.sol";

contract MorphoGenesisHarnessFacet {
    function seedGenesisIntegration(bool initialized, uint256 totalWeight) external {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        gs.initialized = initialized;
        gs.totalWeight = totalWeight;
    }

    function morphoGenesisBook(address asset)
        external
        view
        returns (uint256 indexRay, uint256 indexedAmount, uint256 treasuryClaimable, uint256 accountedCustody)
    {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        return (book.indexRay, book.indexedAmount, book.treasuryClaimable, gs.accountedCustody[asset]);
    }

    function accrueGlobalFee(address asset, uint256 amount) external {
        bytes32 source = keccak256("statics.test.morpho.fee.source");
        require(LibCustody.pullAndReserve(source, asset, msg.sender, amount) == amount, "incompatible token");
        LibGlobalRewards.accrueNonSwapFee(source, asset, amount);
    }

    function accrueBasketReward(uint256 basketId, address asset, uint256 amount) external {
        require(
            LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount) == amount,
            "incompatible token"
        );
        LibBasketRewards.accrueReserved(basketId, LibBasket.basketStorage().baskets[basketId], asset, amount);
    }
}

contract AlternateMorphoAccount {}

contract MorphoViewUpgradeHarnessFacet {
    function morphoAccount(uint256 positionId) external view returns (address account, bool deployed) {
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        account = ms.accounts[positionId];
        if (account != address(0)) return (account, true);
        bytes32 initCodeHash = keccak256(type(AlternateMorphoAccount).creationCode);
        account = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(positionId), initCodeHash)))
            )
        );
    }
}

contract MorphoCollateralTest is StaticsTestBase {
    IStaticsMorpho internal morphoApi;
    MockMorphoBlue internal morphoBlue;
    MockERC20 internal usdStx;
    MorphoGenesisHarnessFacet internal genesisHarness;

    function setUp() public override {
        super.setUp();
        morphoApi = IStaticsMorpho(address(diamond));
        morphoBlue = new MockMorphoBlue();
        usdStx = new MockERC20("Test USDstx", "USDstx", 18);
        morphoApi.initializeMorphoIntegration(address(morphoBlue), address(usdStx), 500);
        usdStx.mint(address(morphoBlue), 1_000_000 ether);
        MorphoGenesisHarnessFacet implementation = new MorphoGenesisHarnessFacet();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MorphoGenesisHarnessFacet.seedGenesisIntegration.selector;
        selectors[1] = MorphoGenesisHarnessFacet.morphoGenesisBook.selector;
        selectors[2] = MorphoGenesisHarnessFacet.accrueGlobalFee.selector;
        selectors[3] = MorphoGenesisHarnessFacet.accrueBasketReward.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(implementation), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        genesisHarness = MorphoGenesisHarnessFacet(address(diamond));
    }

    function testBasketCollateralMovesToOneDeterministicAccountAndCanReturn() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 10 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);

        (address predicted, bool deployedBefore) = morphoApi.morphoAccount(positionId);
        assertFalse(deployedBefore);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 8 ether);

        (address account, bool deployed) = morphoApi.morphoAccount(positionId);
        assertEq(account, predicted);
        assertTrue(deployed);
        assertTrue(morphoBlue.isAuthorized(account, address(diamond)));
        IStaticsMorpho.PositionMarketView memory state = morphoApi.morphoPositionMarket(positionId, marketId);
        assertEq(state.trackedCollateral, 8 ether);
        assertEq(state.actualCollateral, 8 ether);
        assertEq(IERC20(token).balanceOf(address(diamond)), 2 ether);

        vm.prank(alice);
        morphoApi.recallMorphoCollateral(positionId, marketId, 3 ether);
        state = morphoApi.morphoPositionMarket(positionId, marketId);
        assertEq(state.trackedCollateral, 5 ether);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 5 ether, alice);
        assertEq(IERC20(token).balanceOf(alice), 5 ether);
    }

    function testStakedStaticsKeepsPositionAccountingWhileBorrowingUsdStx() public {
        stakingAsset.mint(alice, 20 ether);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        address[] memory rewardAssets = new address[](0);
        vm.prank(alice);
        uint256 positionId = globalRewards.createAndStake(20 ether, alice, rewardAssets);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);

        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 15 ether);
        vm.prank(alice);
        (uint256 borrowed, uint256 shares) = morphoApi.borrowMorphoUsd(positionId, marketId, 5 ether, 5 ether, alice);
        assertEq(borrowed, 5 ether);
        assertEq(shares, 5 ether);
        assertEq(usdStx.balanceOf(alice), 5 ether);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).stakedBalance, 20 ether);

        vm.expectRevert(abi.encodeWithSignature("InsufficientStake(uint256,uint256)", 6 ether, 5 ether));
        vm.prank(alice);
        globalRewards.unstake(positionId, 6 ether, alice);
    }

    function testRepeatedBorrowCanBeFullyRepaidBeforeCollateralRecall() public {
        stakingAsset.mint(alice, 10 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, new address[](0));
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        morphoApi.borrowMorphoUsd(positionId, marketId, 3 ether, 3 ether, alice);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).borrowShares, 5 ether);

        usdStx.approve(address(diamond), 5 ether);
        morphoApi.repayMorphoUsd(positionId, marketId, 5 ether, 0, 5 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).borrowShares, 0);
        morphoApi.recallMorphoCollateral(positionId, marketId, 10 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 0);
        vm.stopPrank();
    }

    function testLiquidationHelperForwardsCollateralAndSynchronizesLoss() public {
        stakingAsset.mint(alice, 10 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, new address[](0));
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();

        address liquidator = makeAddr("helperLiquidator");
        usdStx.mint(liquidator, 2 ether);
        vm.startPrank(liquidator);
        usdStx.approve(address(diamond), 2 ether);
        (uint256 seized, uint256 repaid) =
            morphoApi.liquidateMorphoAndSync(positionId, marketId, 2 ether, 0, 2 ether, 2 ether, liquidator);
        vm.stopPrank();

        assertEq(seized, 2 ether);
        assertEq(repaid, 2 ether);
        assertEq(stakingAsset.balanceOf(liquidator), 2 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 8 ether);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).stakedBalance, 8 ether);
    }

    function testDirectMorphoLiquidationIsReconciledPermissionlessly() public {
        stakingAsset.mint(alice, 10 ether);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.prank(alice);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, new address[](0));
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();

        address liquidator = makeAddr("liquidator");
        usdStx.mint(liquidator, 2 ether);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 2 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 0, "");
        vm.stopPrank();

        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        assertEq(morphoApi.syncMorpho(positionId, marketId), 2 ether);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).stakedBalance, 8 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 8 ether);
        vm.prank(keeper);
        assertEq(morphoApi.syncMorpho(positionId, marketId), 0);
    }

    function testUntrackedSurplusCanOnlyBeWithdrawnAboveTrackedCollateral() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 5 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 5 ether);
        (address account,) = morphoApi.morphoAccount(positionId);

        deal(token, bob, 2 ether);
        vm.startPrank(bob);
        IERC20(token).approve(address(morphoBlue), 2 ether);
        morphoBlue.supplyCollateral(morphoApi.morphoMarket(marketId).params, 2 ether, account, "");
        vm.stopPrank();
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).untrackedSurplus, 2 ether);

        vm.prank(alice);
        morphoApi.withdrawUntrackedMorphoCollateral(positionId, marketId, 2 ether, alice);
        assertEq(IERC20(token).balanceOf(alice), 2 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 5 ether);
    }

    function testAccountAddressPersistsAcrossFacetCreationCodeChange() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 5 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 5 ether);
        (address original,) = morphoApi.morphoAccount(positionId);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStaticsMorpho.morphoAccount.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(new MorphoViewUpgradeHarnessFacet()),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        (address afterUpgrade, bool deployed) = morphoApi.morphoAccount(positionId);
        assertEq(afterUpgrade, original);
        assertTrue(deployed);
        vm.prank(alice);
        morphoApi.recallMorphoCollateral(positionId, marketId, 1 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 4 ether);
    }

    function testUntrackedSurplusPreventsPositionCloseUntilWithdrawn() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 5 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 5 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        deal(token, bob, 1 ether);
        vm.startPrank(bob);
        IERC20(token).approve(address(morphoBlue), 1 ether);
        morphoBlue.supplyCollateral(morphoApi.morphoMarket(marketId).params, 1 ether, account, "");
        vm.stopPrank();

        vm.startPrank(alice);
        morphoApi.recallMorphoCollateral(positionId, marketId, 5 ether);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 5 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 1));
        IStaticsPosition(address(diamond)).closePosition(positionId);
        morphoApi.withdrawUntrackedMorphoCollateral(positionId, marketId, 1 ether, alice);
        IStaticsPosition(address(diamond)).closePosition(positionId);
        vm.stopPrank();
    }

    function testHistoricalMarketSurplusPreventsPositionCloseAfterLegDeactivation() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 5 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 5 ether);
        morphoApi.recallMorphoCollateral(positionId, marketId, 5 ether);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 5 ether, alice);
        vm.stopPrank();

        (address account,) = morphoApi.morphoAccount(positionId);
        deal(token, bob, 1 ether);
        vm.startPrank(bob);
        IERC20(token).approve(address(morphoBlue), 1 ether);
        morphoBlue.supplyCollateral(morphoApi.morphoMarket(marketId).params, 1 ether, account, "");
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibMorpho.MorphoPositionNotEmpty.selector, positionId, marketId));
        IStaticsPosition(address(diamond)).closePosition(positionId);

        vm.startPrank(alice);
        morphoApi.syncMorpho(positionId, marketId);
        morphoApi.withdrawUntrackedMorphoCollateral(positionId, marketId, 1 ether, alice);
        IStaticsPosition(address(diamond)).closePosition(positionId);
        vm.stopPrank();
    }

    function testBorrowRejectsKnownMorphoAccountReceiver() public {
        stakingAsset.mint(alice, 10 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, new address[](0));
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.expectRevert(abi.encodeWithSelector(MorphoFacet.InvalidReceiver.selector, account));
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, account);
        vm.stopPrank();

        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).borrowShares, 0);
    }

    function testRecoverRawAccountTokenHonorsAuthorizationAndMinimumReceipt() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 1 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 1 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        taxed.mint(account, 100 ether);

        vm.prank(bob);
        vm.expectRevert();
        morphoApi.recoverMorphoAccountToken(positionId, address(taxed), 100 ether, bob, 99 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSettlementFacet.MinimumRecoveryNotMet.selector, address(taxed), 100 ether, 99 ether
            )
        );
        morphoApi.recoverMorphoAccountToken(positionId, address(taxed), 100 ether, alice, 100 ether);
        assertEq(taxed.balanceOf(account), 100 ether);

        vm.prank(alice);
        uint256 received = morphoApi.recoverMorphoAccountToken(positionId, address(taxed), 100 ether, alice, 99 ether);
        assertEq(received, 99 ether);
        assertEq(taxed.balanceOf(alice), 99 ether);
    }

    function testMorphoAccountPredictionRequiresInitialization() public {
        MockERC20 statics = new MockERC20("Statics", "STAT", 18);
        IStaticsMorpho uninitialized = IStaticsMorpho(
            address(new StaticsTestDeployer().deploy(address(this), guardian, treasury, address(statics)))
        );
        vm.expectRevert(LibMorpho.MorphoNotInitialized.selector);
        uninitialized.morphoAccount(1);
    }

    function testBountyClaimRejectsDiamondWithoutClearingLiability() public {
        stakingAsset.mint(alice, 10 ether);
        address[] memory rewards = new address[](1);
        rewards[0] = address(assetA);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewards);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();
        vm.warp(selection.eligibleAt);
        assetA.mint(address(this), 100 ether);
        assetA.approve(address(diamond), 100 ether);
        genesisHarness.accrueGlobalFee(address(assetA), 100 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);
        address keeper = makeAddr("bountyKeeper");
        vm.prank(keeper);
        morphoApi.syncMorpho(positionId, marketId);
        uint256 bounty = morphoApi.morphoSyncBounty(keeper, address(assetA));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MorphoFacet.InvalidReceiver.selector, address(diamond)));
        morphoApi.claimMorphoSyncBounties(rewards, address(diamond));
        assertEq(morphoApi.morphoSyncBounty(keeper, address(assetA)), bounty);
    }

    function testPerformanceFeeRoutesOnlyToOperatorIndexAndTreasury() public {
        genesisHarness.seedGenesisIntegration(true, 0);
        address router = makeAddr("router");
        morphoApi.setMorphoPerformanceFeeConfig(router, 1_000, 6_000);
        genesisHarness.seedGenesisIntegration(true, 10_000);
        usdStx.mint(router, 10 ether);
        vm.startPrank(router);
        usdStx.approve(address(diamond), 10 ether);
        assertEq(morphoApi.routeMorphoPerformanceFee(100 ether), 10 ether);
        vm.stopPrank();

        (uint256 indexRay, uint256 indexedAmount, uint256 treasuryAmount, uint256 accounted) =
            genesisHarness.morphoGenesisBook(address(usdStx));
        assertEq(indexRay, 6 ether * 1e27 / 10_000);
        assertEq(indexedAmount, 6 ether);
        assertEq(treasuryAmount, 4 ether);
        assertEq(accounted, 10 ether);
        assertEq(globalRewards.treasuryAccrued(address(usdStx)), 0);
    }

    function testPerformanceFeeIsDisabledWithoutRouterAndCappedAtTwentyPercent() public {
        (uint256 feeAmount,,) = morphoApi.quoteMorphoPerformanceFee(100 ether);
        assertEq(feeAmount, 0);
        vm.expectRevert(abi.encodeWithSignature("InvalidPerformanceFee(uint256)", 2_001));
        morphoApi.setMorphoPerformanceFeeConfig(makeAddr("router"), 2_001, 5_000);
    }

    function testLiquidationForfeiturePaysKeeperAndRoutesRemainderToTreasury() public {
        stakingAsset.mint(alice, 10 ether);
        address[] memory rewards = new address[](1);
        rewards[0] = address(assetA);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewards);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.stopPrank();
        vm.warp(selection.eligibleAt);

        assetA.mint(address(this), 100 ether);
        assetA.approve(address(diamond), 100 ether);
        genesisHarness.accrueGlobalFee(address(assetA), 100 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();

        address liquidator = makeAddr("rewardLiquidator");
        usdStx.mint(liquidator, 2 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 2 ether);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 0, "");
        vm.stopPrank();

        address keeper = makeAddr("rewardKeeper");
        vm.prank(keeper);
        morphoApi.syncMorpho(positionId, marketId);
        assertEq(morphoApi.morphoSyncBounty(keeper, address(assetA)), 0.9 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 27.1 ether);
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, rewards);
        assertEq(pending[0], 72 ether);

        vm.prank(keeper);
        morphoApi.claimMorphoSyncBounties(rewards, keeper);
        assertEq(assetA.balanceOf(keeper), 0.9 ether);
    }

    function testBasketLiquidationUsesSameForfeitureAndKeeperPolicy() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        assetA.mint(address(this), 100 ether);
        assetA.approve(address(diamond), 100 ether);
        genesisHarness.accrueBasketReward(basketId, address(assetA), 100 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();

        address liquidator = makeAddr("basketLiquidator");
        usdStx.mint(liquidator, 2 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 2 ether);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 0, "");
        vm.stopPrank();
        address keeper = makeAddr("basketKeeper");
        vm.prank(keeper);
        morphoApi.syncMorpho(positionId, marketId);

        assertEq(morphoApi.morphoSyncBounty(keeper, address(assetA)), 1 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 19 ether);
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertEq(pending[1], 80 ether);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 8 ether);
    }

    function testStakeSynchronizesDirectLiquidationBeforeSettlingRewards() public {
        stakingAsset.mint(alice, 11 ether);
        address[] memory rewards = new address[](1);
        rewards[0] = address(assetA);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, rewards);
        vm.stopPrank();
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));
        vm.warp(selection.eligibleAt);

        assetA.mint(address(this), 100 ether);
        assetA.approve(address(diamond), 100 ether);
        genesisHarness.accrueGlobalFee(address(assetA), 100 ether);
        bytes32 marketId = _registerMarket(address(stakingAsset), IStaticsMorpho.CollateralKind.StakedStatics, 0);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);

        vm.prank(alice);
        globalRewards.stake(positionId, 1 ether);

        assertEq(morphoApi.morphoSyncBounty(alice, address(assetA)), 0.9 ether);
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(positionId, rewards);
        assertEq(pending[0], 72 ether);
    }

    function testBasketMintSynchronizesDirectLiquidationBeforeSettlingRewards() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        _accrueBasketReward(basketId, 100 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);

        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        basketCollateral.mintBasketCollateral(positionId, basketId, 1 ether, quote);

        assertEq(morphoApi.morphoSyncBounty(alice, address(assetA)), 1 ether);
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertEq(pending[1], 80 ether);
    }

    function testBasketWithdrawalSynchronizesDirectLiquidationBeforeSettlingRewards() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 10 ether);
        vm.warp(block.timestamp + 25 hours);
        _accrueBasketReward(basketId, 100 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 8 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);

        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 1 ether, alice);

        assertEq(morphoApi.morphoSyncBounty(alice, address(assetA)), 1 ether);
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertEq(pending[1], 80 ether);
    }

    function testNativeRepaySynchronizesDirectLiquidationBeforeSettlingRewards() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 20 ether);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);
        _accrueBasketReward(basketId, 100 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        assertGt(morphoApi.morphoSyncBounty(alice, address(assetA)), 0);
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertLt(pending[1], 100 ether);
    }

    function testNativeRecoverySynchronizesDirectLiquidationBeforeSettlingRewards() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintBasketPosition(basketId, 20 ether);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        _accrueBasketReward(basketId, 100 ether);
        bytes32 marketId = _registerMarket(token, IStaticsMorpho.CollateralKind.Basket, basketId);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, 10 ether);
        morphoApi.borrowMorphoUsd(positionId, marketId, 2 ether, 2 ether, alice);
        vm.stopPrank();
        _directLiquidate(positionId, marketId, 2 ether);

        vm.warp(lending.quoteRecovery(loanId).recoverableAt + 1);
        vm.prank(bob);
        lending.recover(loanId);

        assertGt(morphoApi.morphoSyncBounty(bob, address(assetA)), 0);
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertLt(pending[1], 100 ether);
    }

    function _mintBasketPosition(uint256 basketId, uint256 shares) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, shares, alice, quote);
    }

    function _accrueBasketReward(uint256 basketId, uint256 amount) private {
        assetA.mint(address(this), amount);
        assetA.approve(address(diamond), amount);
        genesisHarness.accrueBasketReward(basketId, address(assetA), amount);
    }

    function _directLiquidate(uint256 positionId, bytes32 marketId, uint256 seizedAssets) private {
        address liquidator = makeAddr("directLiquidator");
        usdStx.mint(liquidator, seizedAssets);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), seizedAssets);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, seizedAssets, 0, "");
        vm.stopPrank();
    }

    function _registerMarket(address collateral, IStaticsMorpho.CollateralKind kind, uint256 basketId)
        private
        returns (bytes32 marketId)
    {
        MorphoMarketParams memory params = MorphoMarketParams({
            loanToken: address(usdStx),
            collateralToken: collateral,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 0.8 ether
        });
        marketId = morphoBlue.createMarket(params);
        assertEq(morphoApi.registerMorphoMarket(params, kind, basketId, IStaticsMorpho.MarketMode.Active), marketId);
    }
}
