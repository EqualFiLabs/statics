// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MorphoMarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {LibGenesisIntegration} from "../../src/libraries/LibGenesisIntegration.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketRewards} from "../../src/libraries/LibBasketRewards.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
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
        usdStx.mint(liquidator, 1 ether);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 1 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 1 ether, "");
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
        usdStx.mint(liquidator, 1 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 1 ether);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 1 ether, "");
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
        usdStx.mint(liquidator, 1 ether);
        (address account,) = morphoApi.morphoAccount(positionId);
        vm.startPrank(liquidator);
        usdStx.approve(address(morphoBlue), 1 ether);
        morphoBlue.liquidate(morphoApi.morphoMarket(marketId).params, account, 2 ether, 1 ether, "");
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

    function _mintBasketPosition(uint256 basketId, uint256 shares) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, shares, alice, quote);
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
