// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBootstrapSettlement} from "../../src/interfaces/IStaticsBootstrapSettlement.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsAssetZap} from "../../src/periphery/StaticsAssetZap.sol";
import {LibBootstrapSettlement} from "../../src/libraries/LibBootstrapSettlement.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "../../src/bootstrap/BasketBootstrapFactory.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";

contract RestrictedCampaignSettlementTest is CampaignTestBase {
    IERC20 private restricted;
    IStaticsBootstrapSettlement private settlement;
    uint256 private parentId;

    function setUp() public override {
        super.setUp();
        settlement = IStaticsBootstrapSettlement(address(diamond));
        settlement.installBootstrapFactory(
            address(campaignFactory), address(campaignFactory).codehash, campaignFactory.creationCodeHash()
        );
        _queueFirst();
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        parentId = id;
        restricted = IERC20(token);
        assetA.mint(alice, 10_000 ether);
        assetB.mint(alice, 25_000 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        baskets.mint(id, 5_000 ether, alice, _defaultLaunchMaximums(2));
        vm.stopPrank();
    }

    function _restrictedTerms() private returns (BasketBootstrapCampaign.Terms memory terms) {
        terms = _terms(false);
        terms.projectToken = address(restricted);
        terms.basket.assets[0] = address(restricted);
    }

    function testRestrictedCampaignFundingAuctionAndExpiryUseExactDiamondBridge() public {
        BasketBootstrapCampaign campaign = _campaign(_restrictedTerms(), keccak256("restricted expiry"));
        uint256 floor = restricted.balanceOf(address(diamond));
        vm.startPrank(alice);
        restricted.approve(address(diamond), 101 ether);
        campaign.fundPayment(100 ether);
        vm.stopPrank();
        assertEq(restricted.balanceOf(address(campaign)), 100 ether);
        campaign.activateAuction(0);
        uint256 supplierBefore = restricted.balanceOf(alice);
        vm.prank(alice);
        uint256 payment = campaign.fill(0, 1 ether, 1 ether, bob, block.timestamp);
        assertEq(supplierBefore - restricted.balanceOf(alice), 1 ether);
        assertEq(restricted.balanceOf(bob), payment);
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 1 ether);
        assertEq(restricted.allowance(address(campaign), address(diamond)), 0);
        assertEq(restricted.balanceOf(address(diamond)), floor);
        vm.warp(campaign.deadline());
        uint256 terminal = restricted.balanceOf(address(campaign));
        campaign.claimTerminalInventory();
        assertEq(restricted.balanceOf(bob), payment + terminal);
        assertEq(restricted.balanceOf(address(campaign)), 0);
        assertEq(restricted.balanceOf(address(diamond)), floor);
        vm.expectRevert();
        vm.prank(bob);
        restricted.transfer(alice, 1);
    }

    function testRestrictedConstituentFinalizesActualPolAndPreservesPaymentInventory() public {
        BasketBootstrapCampaign.Terms memory terms = _restrictedTerms();
        BasketBootstrapCampaign campaign = _campaign(terms, keccak256("restricted POL"));
        (, uint256 firstRequired,,) = campaign.inventory(0);
        (, uint256 secondRequired,,) = campaign.inventory(1);
        vm.startPrank(alice);
        restricted.approve(address(diamond), firstRequired + 20 ether);
        campaign.fund(0, firstRequired);
        campaign.fundPayment(20 ether);
        assetB.approve(address(campaign), secondRequired);
        campaign.fund(1, secondRequired);
        vm.stopPrank();
        campaign.fundNative{value: campaign.nativeRequired()}();
        uint256 floor = restricted.balanceOf(address(diamond));
        (uint256 id, address token) = campaign.finalize();
        assertEq(baskets.basket(id).creator, terms.creator);
        assertEq(IERC20(token).balanceOf(address(campaign)), 0);
        assertEq(restricted.balanceOf(address(campaign)), 20 ether);
        assertEq(restricted.allowance(address(campaign), address(diamond)), 0);
        assertGt(restricted.balanceOf(address(diamond)), floor); // Nested basket backing is now reserved by Statics.
        campaign.claimTerminalInventory();
        assertEq(restricted.balanceOf(bob), 20 ether);
    }

    function testCampaignApprovalIsNotRestrictedTransferAuthority() public {
        BasketBootstrapCampaign campaign = _campaign(_restrictedTerms(), keccak256("approval"));
        vm.startPrank(alice);
        restricted.approve(address(campaign), 1 ether);
        vm.expectRevert();
        campaign.fund(0, 1 ether);
        vm.expectRevert();
        restricted.transfer(address(campaign), 1 ether);
        restricted.approve(address(diamond), 1 ether);
        campaign.fund(0, 1 ether);
        vm.stopPrank();
        assertEq(restricted.balanceOf(address(campaign)), 1 ether);
    }

    function testActualZapAcquiresRestrictedConstituentAndPaysRestrictedProjectDirectly() public {
        BasketBootstrapCampaign.Terms memory terms = _restrictedTerms();
        terms.auctions[0].minimumFill = 0.001 ether;
        BasketBootstrapCampaign campaign = _campaign(terms, keccak256("restricted purchase"));
        vm.startPrank(alice);
        restricted.approve(address(diamond), 100 ether);
        campaign.fundPayment(100 ether);
        vm.stopPrank();
        campaign.activateAuction(0);
        StaticsAssetZap zap = new StaticsAssetZap(address(diamond), address(new WETH()), campaignFactory);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(parentId, address(assetA));
        StaticsAssetZap.Route[] memory routes = new StaticsAssetZap.Route[](1);
        routes[0].currencies = new address[](2);
        routes[0].currencies[0] = address(assetA);
        routes[0].currencies[1] = address(restricted);
        routes[0].pools = new PoolKey[](1);
        routes[0].pools[0] = PoolKey(
            Currency.wrap(pool.currency0),
            Currency.wrap(pool.currency1),
            pool.lpFee,
            pool.tickSpacing,
            IHooks(pool.hook)
        );
        routes[0].maximumInput = 1 ether;
        StaticsAssetZap.Purchase[] memory purchases = new StaticsAssetZap.Purchase[](1);
        purchases[0] = StaticsAssetZap.Purchase(0, 0.001 ether, 0.001 ether);
        assetA.mint(alice, 1 ether);
        vm.startPrank(alice);
        assetA.approve(address(zap), 1 ether);
        (uint256 spent, uint256 payment) = zap.purchaseCampaign(
            StaticsAssetZap.Input(address(assetA), 1 ether, bob, block.timestamp),
            address(campaign),
            purchases,
            0.001 ether,
            routes
        );
        vm.stopPrank();
        assertGt(spent, 0);
        assertEq(restricted.balanceOf(bob), payment);
        assertEq(restricted.balanceOf(address(zap)), 0);
        assertEq(restricted.allowance(address(zap), address(diamond)), 0);
        assertEq(restricted.allowance(address(zap), address(campaign)), 0);
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 0.001 ether);
        vm.prank(alice);
        assetA.approve(address(zap), 1 ether);
        uint256 userInput = assetA.balanceOf(alice);
        uint256 managerInput = assetA.balanceOf(address(poolManager));
        uint256 managerOutput = restricted.balanceOf(address(poolManager));
        vm.expectRevert(StaticsAssetZap.OutputBoundsExceeded.selector);
        vm.prank(alice);
        zap.purchaseCampaign(
            StaticsAssetZap.Input(address(assetA), 1 ether, bob, block.timestamp),
            address(campaign),
            purchases,
            1 ether,
            routes
        );
        assertEq(assetA.balanceOf(alice), userInput);
        assertEq(assetA.balanceOf(address(poolManager)), managerInput);
        assertEq(restricted.balanceOf(address(poolManager)), managerOutput);
        assertEq(restricted.balanceOf(bob), payment);
        (,, uint256 afterHeld,) = campaign.inventory(0);
        assertEq(afterHeld, held);
        assertEq(restricted.allowance(address(zap), address(diamond)), 0);
    }

    function testRegisteredCampaignCannotBridgeUnconfiguredTokenOrReregister() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("unconfigured asset"));
        // Negative unreachable fixed-code calls isolate the registry's asset/replay guards.
        vm.expectRevert(LibBootstrapSettlement.InvalidBootstrapSettlement.selector);
        vm.prank(address(campaign));
        settlement.settleBootstrapToken(address(restricted), alice, address(campaign), 1 ether);
        vm.expectRevert(LibBootstrapSettlement.InvalidBootstrapSettlement.selector);
        vm.prank(address(campaignFactory));
        settlement.registerBootstrapCampaign(address(campaign));
    }

    function testUnregisteredCallerCannotUseVictimAllowanceOrProtocolBalances() public {
        uint256 beforeVictim = restricted.balanceOf(alice);
        vm.prank(alice);
        restricted.approve(address(diamond), type(uint256).max);
        vm.expectRevert(LibBootstrapSettlement.InvalidBootstrapSettlement.selector);
        vm.prank(bob);
        settlement.settleBootstrapToken(address(restricted), alice, bob, 1 ether);
        assertEq(restricted.balanceOf(alice), beforeVictim);
        assertEq(restricted.balanceOf(bob), 0);
    }

    function testUnapprovedFactoryCannotCreateRestrictedCampaign() public {
        BasketBootstrapFactory other = new BasketBootstrapFactory(address(diamond));
        BasketBootstrapCampaign.Terms memory terms = _restrictedTerms();
        bytes32 creationHash = other.creationCodeHash();
        vm.expectRevert(BasketBootstrapFactory.CampaignDeploymentFailed.selector);
        other.create(terms, keccak256("unapproved"));
        vm.expectRevert(LibBootstrapSettlement.InvalidBootstrapSettlement.selector);
        settlement.installBootstrapFactory(address(other), bytes32(uint256(1)), creationHash);
        vm.expectRevert();
        vm.prank(alice);
        settlement.installBootstrapFactory(address(other), address(other).codehash, creationHash);
    }
}
