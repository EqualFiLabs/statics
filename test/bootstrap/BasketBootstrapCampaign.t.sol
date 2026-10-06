// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketDelegation} from "../../src/interfaces/IStaticsBasketDelegation.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "../../src/bootstrap/BasketBootstrapFactory.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";
import {MockERC20, MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";

abstract contract CampaignTestBase is PreparedBasketTestBase {
    uint256 internal constant CREATOR_KEY = 0xC0FFEE;
    BasketBootstrapFactory internal campaignFactory;
    MockERC20 internal project;

    function setUp() public virtual override {
        super.setUp();
        project = new MockERC20("Project", "PRJ", 18);
        campaignFactory = new BasketBootstrapFactory(address(diamond));
    }

    function _terms(bool projectConstituent) internal returns (BasketBootstrapCampaign.Terms memory terms) {
        terms.creator = vm.addr(CREATOR_KEY);
        terms.beneficiary = bob;
        terms.projectToken = address(project);
        terms.deadline = block.timestamp + 7 days;
        terms.basket = _defaultParams(0, 0);
        if (projectConstituent) terms.basket.assets[0] = address(project);
        (terms.pools, terms.maximums) = _fundDefaultLaunch(terms.basket.assets, alice);
        terms.auctions = new BasketBootstrapCampaign.AuctionTerms[](2);
        for (uint256 i; i < 2; ++i) {
            terms.auctions[i] =
                BasketBootstrapCampaign.AuctionTerms(100 ether, 1e18, 2e18, block.timestamp, terms.deadline, 1 ether);
        }
        terms.adapters = new address[](0);
    }

    function _campaign(BasketBootstrapCampaign.Terms memory terms, bytes32 salt)
        internal
        returns (BasketBootstrapCampaign campaign)
    {
        address predicted = campaignFactory.predict(terms, salt);
        campaign = BasketBootstrapCampaign(campaignFactory.create(terms, salt));
        assertEq(address(campaign), predicted);
        assertTrue(campaignFactory.isCampaign(predicted));
        _prepareCampaign(campaign, terms);
    }

    function _prepareCampaign(BasketBootstrapCampaign campaign, BasketBootstrapCampaign.Terms memory terms) internal {
        bytes32 configuration =
            preparation.basketCreationConfigurationHash(terms.basket, terms.pools, terms.maximums, terms.deadline);
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(address(campaign), terms.creator, configuration, terms.deadline, 1);
        bytes32 tokenSalt_ = factory.preparedSaltFor(intent, 0);
        uint256[] memory nonces = new uint256[](2);
        bytes32[] memory salts = new bytes32[](2);
        uint256 start;
        for (uint256 i; i < 2; ++i) {
            (nonces[i], salts[i]) = _minePreparedTestHook(factory, intent, start);
            start = nonces[i] + 1;
        }
        IStaticsBasketDelegation.Authorization memory auth = IStaticsBasketDelegation.Authorization(
            terms.creator,
            address(campaign),
            factory.preparationId(intent, tokenSalt_, salts),
            configuration,
            513,
            terms.deadline,
            1 ether
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(CREATOR_KEY, IStaticsBasketDelegation(address(diamond)).creationAuthorizationDigest(auth));
        campaign.prepare(0, nonces, auth, abi.encodePacked(r, s, v));
        assertTrue(campaign.prepared());
    }

    function _fundLaunch(BasketBootstrapCampaign campaign, bool nativeFee) internal {
        for (uint256 i; i < 2; ++i) {
            (address token, uint256 target,,) = campaign.inventory(i);
            MockERC20(token).mint(alice, target);
            vm.startPrank(alice);
            IERC20(token).approve(address(campaign), target);
            campaign.fund(i, target);
            vm.stopPrank();
        }
        if (nativeFee) campaign.fundNative{value: campaign.nativeRequired()}();
    }

    function _fundPayment(BasketBootstrapCampaign campaign, uint256 amount) internal {
        project.mint(alice, amount);
        vm.startPrank(alice);
        project.approve(address(campaign), amount);
        campaign.fundPayment(amount);
        vm.stopPrank();
    }
}

contract BasketBootstrapCampaignTest is CampaignTestBase {
    function testFullFundingCreatesRealPolWithCreatorIdentityAndFixedSurplus() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("launch"));
        _fundLaunch(campaign, true);
        _fundPayment(campaign, 20 ether);
        assertTrue(campaign.ready());
        vm.prank(alice);
        (uint256 id, address token) = campaign.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        assertEq(token, campaign.preparedToken());
        assertEq(uint256(campaign.state()), uint256(BasketBootstrapCampaign.State.Launched));
        assertEq(IERC20(token).balanceOf(address(campaign)), 0);
        assertEq(IERC20(token).balanceOf(alice), 0);
        for (uint256 i; i < 2; ++i) {
            (address asset,, uint256 held,) = campaign.inventory(i);
            assertEq(held, 0);
            assertEq(IERC20(asset).allowance(address(campaign), address(diamond)), 0);
            assertEq(
                IStaticsProtocolPools(address(diamond))
                .protocolPool(basketLiquidity.canonicalPool(id, asset).poolId)
                .activePolPositions,
                1
            );
        }
        uint256 beforeBalance = project.balanceOf(bob);
        campaign.claimTerminalInventory();
        assertEq(project.balanceOf(bob) - beforeBalance, 20 ether);
        campaign.claimTerminalInventory();
        assertEq(project.balanceOf(address(campaign)), 0);
    }

    function testProjectConstituentPaymentIsNotLaunchInventory() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(true), keccak256("separate"));
        _fundPayment(campaign, 100 ether);
        (, uint256 target, uint256 held, uint256 missing) = campaign.inventory(0);
        assertGt(target, 0);
        assertEq(held, 0);
        assertEq(missing, target);
        assertFalse(campaign.ready());
        _fundLaunch(campaign, true);
        campaign.finalize();
        assertEq(project.balanceOf(address(campaign)), 100 ether);
        campaign.claimTerminalInventory();
        assertEq(project.balanceOf(bob), 100 ether);
    }

    function testFirmAuctionFragmentedFillsConserveFullCapEscrow() public {
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.auctions[0] = BasketBootstrapCampaign.AuctionTerms(
            101, uint256(1e18) / 3, uint256(1e18) / 3 + 1, block.timestamp, terms.deadline, 10
        );
        BasketBootstrapCampaign campaign = _campaign(terms, keccak256("fragmented"));
        vm.expectRevert(BasketBootstrapCampaign.InsufficientPaymentInventory.selector);
        campaign.activateAuction(0);
        uint256 liability = campaign.capLiability(0, 101);
        _fundPayment(campaign, liability);
        campaign.activateAuction(0);
        vm.startPrank(alice);
        assetA.approve(address(campaign), 101);
        uint256 beforeBalance = project.balanceOf(alice);
        for (uint256 i; i < 10; ++i) {
            campaign.fill(0, 10, 3, alice, terms.deadline);
        }
        campaign.fill(0, 1, 1, alice, terms.deadline);
        vm.stopPrank();
        (, BasketBootstrapCampaign.Auction memory book) = campaign.auction(0);
        assertEq(book.acquired, 101);
        assertEq(book.remaining, 0);
        assertEq(book.reservedPayment, 0);
        assertEq(campaign.reservedPayment(), 0);
        assertEq(book.paid, project.balanceOf(alice) - beforeBalance);
        assertLe(book.paid, liability);
        assertEq(project.balanceOf(address(campaign)), campaign.freePayment());
        vm.expectRevert(BasketBootstrapCampaign.InvalidFill.selector);
        campaign.fill(0, 1, 0, alice, terms.deadline);
    }

    function testDirectFundingShrinksProcurementAndReleasesUnusedReserve() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("overlap"));
        uint256 missing = campaign.deficit(0);
        _fundPayment(campaign, campaign.capLiability(0, missing));
        campaign.activateAuction(0);
        uint256 initialReserve = campaign.reservedPayment();
        vm.startPrank(alice);
        assetA.approve(address(campaign), missing);
        campaign.fund(0, missing / 2);
        vm.stopPrank();
        assertLt(campaign.reservedPayment(), initialReserve);
        assertGt(campaign.freePayment(), 0);
        (, BasketBootstrapCampaign.Auction memory book) = campaign.auction(0);
        vm.startPrank(alice);
        campaign.fill(0, book.remaining, 0, alice, campaign.deadline());
        vm.stopPrank();
        assertEq(campaign.deficit(0), 0);
        assertEq(campaign.reservedPayment(), 0);
    }

    function testStrictExpiryIncludesFundedUnfinalizedCampaignAndFinalTrades() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("expiry"));
        _fundPayment(campaign, 50 ether);
        campaign.activateAuction(0);
        vm.startPrank(alice);
        assetA.approve(address(campaign), 1 ether);
        campaign.fill(0, 1 ether, 1 ether, alice, campaign.deadline());
        vm.stopPrank();
        uint256 supplierPaid = project.balanceOf(alice);
        _fundLaunch(campaign, true);
        assertTrue(campaign.ready());
        vm.expectRevert(BasketBootstrapCampaign.CampaignNotTerminal.selector);
        campaign.claimTerminalInventory();
        vm.warp(campaign.deadline());
        assertFalse(campaign.ready());
        vm.expectRevert(BasketBootstrapCampaign.CampaignNotReady.selector);
        campaign.finalize();
        vm.expectRevert(BasketBootstrapCampaign.InvalidFill.selector);
        campaign.fill(0, 1 ether, 0, alice, type(uint256).max);
        campaign.claimTerminalInventory();
        assertEq(project.balanceOf(alice), supplierPaid);
        assertEq(assetA.balanceOf(address(campaign)), 0);
        assertEq(campaign.reservedPayment(), 0);
    }

    function testUnsolicitedTokensAndNativeDoNotCountTowardReadiness() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("unsolicited"));
        project.mint(address(campaign), 100 ether);
        assetA.mint(address(campaign), 100 ether);
        vm.deal(address(campaign), 5 ether);
        assertEq(campaign.freePayment(), 0);
        assertEq(campaign.nativeInventory(), 0);
        assertFalse(campaign.ready());
        vm.expectRevert(BasketBootstrapCampaign.InsufficientPaymentInventory.selector);
        campaign.activateAuction(0);
    }

    function testSeparateCampaignsCannotShareInventoryOrClaims() public {
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        BasketBootstrapCampaign first = _campaign(terms, keccak256("first"));
        BasketBootstrapCampaign second = _campaign(terms, keccak256("second"));
        _fundLaunch(first, true);
        assertTrue(first.ready());
        assertFalse(second.ready());
        assertTrue(first.preparedToken() != second.preparedToken());
        vm.expectRevert(BasketBootstrapCampaign.InvalidRevenueAdapter.selector);
        second.deliverRevenue(0, 1);
    }

    function testTaxedAssetReceiptRejectsAtomically() public {
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        terms.basket.assets[0] = address(taxed);
        BasketBootstrapCampaign campaign = _campaign(terms, keccak256("taxed"));
        taxed.mint(alice, 100 ether);
        vm.prank(alice);
        taxed.approve(address(campaign), 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketBootstrapCampaign.InexactTransfer.selector, address(taxed)));
        campaign.fund(0, 1 ether);
        assertEq(taxed.balanceOf(address(campaign)), 0);
    }

    function testCampaignAndTypedFactoryFitDeploymentLimits() public view {
        assertLt(address(campaignFactory).code.length, 24577);
        assertLt(campaignFactory.codeStore0().code.length, 24577);
        assertLt(campaignFactory.codeStore1().code.length, 24577);
    }
}
