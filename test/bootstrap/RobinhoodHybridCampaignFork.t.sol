// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMoshSwarm, IMoshClaimMarket} from "../../src/interfaces/IMoshSwarm.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {MeasuredCampaignRevenue} from "../../src/bootstrap/MeasuredCampaignRevenue.sol";
import {MoshShareRevenueAdapter} from "../../src/bootstrap/MoshShareRevenueAdapter.sol";
import {MoshTeamRevenueAdapter} from "../../src/bootstrap/MoshTeamRevenueAdapter.sol";
import {IPonsRevenueFactory, IPonsRevenueEscrow} from "../../src/bootstrap/IPonsRevenueSource.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {MoshForkFeeHook} from "./RobinhoodMoshClaimFork.t.sol";
import {IPonsForkLaunch, IPonsForkCurve, IPonsForkPolicy, IPonsForkWeth} from "./RobinhoodPonsRevenueFork.t.sol";
import {IMoshTeamCollection} from "./RobinhoodMoshTeamAdapterFork.t.sol";

/// @dev One real Statics campaign combines direct funding, firm procurement and both venues.
/// PONS belongs to an independent launched token: its authorized recipient collects and wraps
/// actual escrow receipts, then uses the production generic measured-delivery adapter. The
/// source-bound PonsRevenueAdapter intentionally cannot bind that different token to this campaign.
/// Mosh's source-bound team and temporary-share adapters both use the actual campaign project token.
/// Existing upstream sweep-operator impersonation realizes fees only; Statics obtains no such role.
contract RobinhoodHybridCampaignForkTest is CampaignTestBase, IUnlockCallback {
    IPonsRevenueFactory private constant PONS = IPonsRevenueFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    IMoshSwarm private constant SWARM = IMoshSwarm(0x6A3800dD7b3F1e03e29BEfE2A9238549a9642Ac8);
    IMoshClaimMarket private constant MARKET = IMoshClaimMarket(0xA8C83951eE2431106f0aAea6ae79F97A530521aA);
    IPoolManager private constant SOURCE_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address private constant HOLDER = 0x8B86B1C726F7a1c09f7c4c31e53621a27e4C8AdC;
    address private constant TOKEN = 0xD68f57B08CD9732e4Ddd1a04bA4d26629DC44B8E;
    address private constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    uint256 private constant TEMPORARY_CLAIMS = 0.005 ether;
    uint256 private constant TEAM_CLAIMS = 0.005 ether;

    address private wrapped;
    address private independentCurve;
    MeasuredCampaignRevenue private ponsDelivery;
    MoshShareRevenueAdapter private shareDelivery;
    MoshTeamRevenueAdapter private teamDelivery;
    BasketBootstrapCampaign private destination;
    PoolKey private sourceKey;
    uint256 private holderBeforeTemporaryDeposit;
    uint256 private supplierPayment;
    uint256 private ponsReceipt;
    uint256 private shareReceipt;
    uint256 private teamReceipt;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "Robinhood RPC not configured");
            return;
        }
        vm.createSelectFork(rpc, 80_155_273);
        super.setUp();
        string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");
        wrapped = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        bytes32 wrapperHash = vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash");
        assertEq(wrapped.codehash, wrapperHash);
        assertEq(address(PONS).codehash, 0x89a27da6f703e0a7cdd4f233e7cb57604ff75b164530962d3ff7cf8483a67d84);
        assertEq(PONS.feeEscrow().codehash, 0xf25f75cfbc1637ba068dc34f69098fa4e8a80f8ee8fe7bf7820594e0b3fed2f1);
        vm.deal(HOLDER, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(vm.addr(CREATOR_KEY), 100 ether);
        ponsDelivery = new MeasuredCampaignRevenue(vm.addr(CREATOR_KEY), wrapped, campaignFactory);
        shareDelivery = new MoshShareRevenueAdapter(
            vm.addr(CREATOR_KEY), wrapped, wrapperHash, campaignFactory, SWARM, _sourcePins(), _marketPins()
        );
        teamDelivery = new MoshTeamRevenueAdapter(
            vm.addr(CREATOR_KEY), wrapped, wrapperHash, campaignFactory, _sourcePins(), _marketPins(), 1000
        );
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.projectToken = TOKEN;
        terms.basket.assets[0] = wrapped;
        terms.adapters = new address[](3);
        terms.adapters[0] = address(ponsDelivery);
        terms.adapters[1] = address(shareDelivery);
        terms.adapters[2] = address(teamDelivery);
        for (uint256 i; i < 2; ++i) {
            terms.auctions[i].targetCap = type(uint128).max;
            terms.auctions[i].minimumFill = 0.001 ether;
        }
        destination = _campaign(terms, keccak256("hybrid venue campaign"));
        vm.startPrank(vm.addr(CREATOR_KEY));
        ponsDelivery.bindCampaign(destination, 0);
        shareDelivery.bindCampaign(destination, 0);
        teamDelivery.bindCampaign(destination, 0);
        teamDelivery.bindSource(SWARM);
        vm.stopPrank();
        _enterClaims();
        _launchIndependentPonsSource();
        sourceKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0, 200, IHooks(HOOK));
        vm.warp(block.timestamp + 1 minutes); // Actual PONS launch anti-snipe period.
        _swapMosh(); // Actual project-token inventory, not a storage-dealt or mock token balance.
    }

    function _sourcePins() private pure returns (LibMoshValidation.SourcePins memory) {
        return LibMoshValidation.SourcePins(
            4663,
            0x9073cb17846398fB8B379Ab06C2B840dEA7f0069,
            0x82edd64be0bedd5f9462e948447c6416adad6c77c71945e1cba585387f553423,
            0x71BDDCfee17b718c92f0Be80910D2f06542ff379,
            0x93f0f1391a76bb2aa72c310f33636f9049002ef16584a9b0370e199edb26702e,
            0x42B0b14C6e6bCAa2e9B29F87aA3DE19290a5c572,
            0x210393a615dd4a801aaa9449b8e65d6b0ba7b98d6ef5ed9f2400833643fd44ac
        );
    }

    function _marketPins() private pure returns (LibMoshValidation.MarketPins memory) {
        return LibMoshValidation.MarketPins(
            address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
        );
    }

    function _enterClaims() private {
        assertEq(SWARM.teamRecipient(), HOLDER);
        bytes32 principal = _principalHash();
        vm.prank(HOLDER);
        uint256 teamOffer =
            MARKET.list(address(SWARM), TEAM_CLAIMS, 1, address(teamDelivery), uint64(block.timestamp + 1 hours));
        vm.prank(HOLDER);
        teamDelivery.acceptTeamHandoff{value: 1}(teamOffer, TEAM_CLAIMS);
        holderBeforeTemporaryDeposit = SWARM.claim(HOLDER);
        vm.prank(HOLDER);
        uint256 shareOffer =
            MARKET.list(address(SWARM), TEMPORARY_CLAIMS, 1, address(shareDelivery), uint64(block.timestamp + 1 hours));
        vm.prank(HOLDER);
        shareDelivery.deposit{value: 1}(shareOffer, TEMPORARY_CLAIMS);
        assertEq(SWARM.claim(HOLDER) + TEMPORARY_CLAIMS, holderBeforeTemporaryDeposit);
        assertEq(SWARM.claim(address(shareDelivery)), TEMPORARY_CLAIMS);
        assertEq(SWARM.claim(address(teamDelivery)), TEAM_CLAIMS);
        assertEq(_principalHash(), principal, "fee-right entry never moves Swarm principal");
    }

    function _launchIndependentPonsSource() private {
        IPonsForkLaunch.TokenParams memory terms;
        terms.name = "Statics independent hybrid revenue";
        terms.symbol = "SIHR";
        terms.creatorFeeRecipient = vm.addr(CREATOR_KEY);
        terms.creatorTaxBps = 100;
        terms.expectedEconomics = IPonsForkLaunch(address(PONS)).previewLaunchEconomics(0, address(0));
        terms.salt = keccak256("independent PONS hybrid source");
        uint256 fee = IPonsForkLaunch(address(PONS)).launchFee();
        vm.prank(vm.addr(CREATOR_KEY));
        (address independentToken, address curve) =
            IPonsForkLaunch(address(PONS)).launchToken{value: fee}(terms, 0, address(0));
        independentCurve = curve;
        assertTrue(independentToken != TOKEN);
        assertEq(PONS.getLaunchedToken(independentToken).creatorFeeRecipient, vm.addr(CREATOR_KEY));
        assertEq(PONS.getLaunchedToken(TOKEN).creatorFeeRecipient, address(SWARM), "Mosh fee source stays with Swarm");
    }

    function _fundDirect(uint256 index, uint256 amount) private {
        if (index == 0) IPonsForkWeth(wrapped).deposit{value: amount}();
        else assetB.mint(address(this), amount);
        IERC20(index == 0 ? wrapped : address(assetB)).approve(address(destination), amount);
        destination.fund(index, amount);
    }

    function _fillProcurement(uint256 index, uint256 amount) private {
        if (index == 0) {
            vm.prank(alice);
            IPonsForkWeth(wrapped).deposit{value: amount}();
        } else {
            assetB.mint(alice, amount);
        }
        uint256 beforePayment = IERC20(TOKEN).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(index == 0 ? wrapped : address(assetB)).approve(address(destination), amount);
        uint256 payment = destination.fill(index, amount, amount, alice, destination.deadline());
        vm.stopPrank();
        assertEq(IERC20(TOKEN).balanceOf(alice) - beforePayment, payment, "supplier trade settles immediately");
        supplierPayment += payment;
    }

    function _deliverPonsReceipt() private returns (uint256 amount) {
        IPonsRevenueEscrow escrow = IPonsRevenueEscrow(PONS.feeEscrow());
        address recipient = vm.addr(CREATOR_KEY);
        uint256 beforeCredit = escrow.balanceOf(recipient);
        assertGt(IPonsForkCurve(independentCurve).buy{value: 0.01 ether}(0.01 ether, 1, address(this)), 0);
        vm.prank(IPonsForkPolicy(IPonsForkLaunch(address(PONS)).memeHook()).feeSweepOperator());
        IPonsForkCurve(independentCurve).sweepFees(0);
        amount = escrow.balanceOf(recipient) - beforeCredit;
        assertGt(amount, 0);
        uint256 nativeBefore = recipient.balance;
        vm.prank(recipient);
        assertEq(escrow.claim(amount), amount);
        assertEq(recipient.balance - nativeBefore, amount, "actual PONS native receipt");
        vm.startPrank(recipient);
        IPonsForkWeth(wrapped).deposit{value: amount}();
        IERC20(wrapped).approve(address(ponsDelivery), amount);
        ponsDelivery.deliverRealized(amount);
        vm.stopPrank();
        assertEq(IERC20(wrapped).balanceOf(address(ponsDelivery)), 0);
        assertEq(IERC20(wrapped).allowance(address(ponsDelivery), address(destination)), 0);
    }

    function _collectMoshReceipts() private returns (uint256 temporary, uint256 team) {
        // Already-swapped, unconverted fees and externally held share principal are not campaign funding.
        (,, uint256 beforeHeld,) = destination.inventory(0);
        assertEq(shareDelivery.sync(), 0);
        assertEq(teamDelivery.sync(), 0);
        (,, uint256 afterUnconverted,) = destination.inventory(0);
        assertEq(afterUnconverted, beforeHeld);
        vm.prank(MoshForkFeeHook(HOOK).feeSweepOperator());
        MoshForkFeeHook(HOOK).sweepPoolFees(keccak256(abi.encode(sourceKey)), 1, 1);
        assertGt(SWARM.syncFees(), 0);
        temporary = shareDelivery.sync();
        team = teamDelivery.sync();
        assertGt(temporary, 0);
        assertGt(team, 0);
        shareDelivery.flushCampaignRevenue();
        teamDelivery.flushTeamRevenue();
        assertEq(IERC20(wrapped).allowance(address(shareDelivery), address(destination)), 0);
        assertEq(IERC20(wrapped).allowance(address(teamDelivery), address(destination)), 0);
    }

    function _hybridFunding() private {
        (, uint256 firstRequired,,) = destination.inventory(0);
        (, uint256 secondRequired,,) = destination.inventory(1);
        _fundDirect(0, firstRequired / 4);
        _fundDirect(1, secondRequired / 4);
        destination.fundNative{value: destination.nativeRequired()}();
        uint256 escrow = destination.capLiability(0, destination.deficit(0))
            + destination.capLiability(1, destination.deficit(1)) + 1 ether;
        assertGe(IERC20(TOKEN).balanceOf(address(this)), escrow, "real project-token launch inventory");
        IERC20(TOKEN).approve(address(destination), escrow);
        destination.fundPayment(escrow);
        destination.activateAuction(0);
        destination.activateAuction(1);
        _fillProcurement(0, firstRequired / 8);
        _fillProcurement(1, secondRequired / 8);
        uint256 reservedBefore = destination.reservedPayment();
        uint256 freeBefore = destination.freePayment();
        uint256 heldBefore = IERC20(wrapped).balanceOf(address(destination));
        ponsReceipt = _deliverPonsReceipt();
        (shareReceipt, teamReceipt) = _collectMoshReceipts();
        assertEq(IERC20(wrapped).balanceOf(address(destination)) - heldBefore, ponsReceipt + shareReceipt + teamReceipt);
        uint256 released = reservedBefore - destination.reservedPayment();
        assertGt(released, 0, "overlapping realized revenue releases unused firm procurement liability");
        assertEq(destination.freePayment() - freeBefore, released);
        assertEq(
            IERC20(TOKEN).balanceOf(address(destination)), destination.freePayment() + destination.reservedPayment()
        );
        assertEq(ponsDelivery.totalDelivered(), ponsReceipt);
        assertEq(shareDelivery.totalDelivered(), shareReceipt);
        assertEq(teamDelivery.totalDelivered(), teamReceipt);
        assertFalse(destination.ready());
    }

    function _returnTemporaryClaims() private {
        bytes32 principal = _principalHash();
        vm.prank(HOLDER);
        uint256 offer = shareDelivery.withdraw(TEMPORARY_CLAIMS, block.timestamp + 1 hours);
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(offer);
        vm.prank(makeAddr("permissionless hybrid reconciler"));
        shareDelivery.checkpointWithdrawal(HOLDER);
        assertEq(shareDelivery.totalShares(), 0);
        assertEq(SWARM.claim(HOLDER), holderBeforeTemporaryDeposit);
        assertEq(SWARM.claim(address(teamDelivery)), TEAM_CLAIMS);
        assertEq(_principalHash(), principal, "independent user return never moves Swarm principal");
        uint256 beforeReward = IERC20(wrapped).balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 reward = shareDelivery.claimRewards();
        assertGe(reward, 1, "one-wei return proceeds belong to depositor");
        assertEq(IERC20(wrapped).balanceOf(HOLDER) - beforeReward, reward);
    }

    function _assertActualPol(uint256 id) private view {
        IStaticsProtocolPools protocol = IStaticsProtocolPools(address(diamond));
        (address manager, bool installed) = basketLiquidity.liquidityManager();
        assertTrue(installed);
        for (uint256 i; i < 2; ++i) {
            (address asset,,,) = destination.inventory(i);
            uint256[] memory ids = protocol.protocolPolPositionIds(basketLiquidity.canonicalPool(id, asset).poolId);
            assertEq(ids.length, 1);
            IStaticsProtocolPools.ProtocolPolPositionView memory position = protocol.protocolPolPosition(ids[0]);
            assertTrue(position.active);
            assertGt(position.liquidity, 0);
            assertEq(position.manager, manager);
            assertEq(
                IERC721(IStaticsLiquidityManager(manager).positionManager()).ownerOf(position.posmTokenId), manager
            );
            assertEq(IERC20(asset).allowance(address(destination), address(diamond)), 0);
        }
    }

    function _claimTerminalInventory() private {
        uint256 payment = IERC20(TOKEN).balanceOf(address(destination));
        uint256 first = IERC20(wrapped).balanceOf(address(destination));
        uint256 second = assetB.balanceOf(address(destination));
        uint256 native = address(destination).balance;
        uint256 beforePayment = IERC20(TOKEN).balanceOf(bob);
        uint256 beforeFirst = IERC20(wrapped).balanceOf(bob);
        uint256 beforeSecond = assetB.balanceOf(bob);
        uint256 beforeNative = bob.balance;
        destination.claimTerminalInventory();
        assertEq(IERC20(TOKEN).balanceOf(bob) - beforePayment, payment);
        assertEq(IERC20(wrapped).balanceOf(bob) - beforeFirst, first);
        assertEq(assetB.balanceOf(bob) - beforeSecond, second);
        assertEq(bob.balance - beforeNative, native);
        assertEq(destination.reservedPayment(), 0);
        assertEq(IERC20(TOKEN).balanceOf(address(destination)), 0);
        assertEq(IERC20(wrapped).balanceOf(address(destination)), 0);
        assertEq(assetB.balanceOf(address(destination)), 0);
        assertEq(IERC20(TOKEN).balanceOf(alice), supplierPayment, "supplier trades are final, not refunded/clawed back");
    }

    function testHybridFundingFinalizesRealPolAndLeavesIndependentUserReturn() public {
        _hybridFunding();
        _fundDirect(0, destination.deficit(0) + 0.001 ether);
        _fundDirect(1, destination.deficit(1) + 1 ether);
        assertEq(destination.reservedPayment(), 0);
        assertTrue(destination.ready());
        (uint256 id, address token) = destination.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        assertEq(token, destination.preparedToken());
        assertEq(IERC20(token).balanceOf(alice), 0);
        assertEq(IERC20(token).balanceOf(HOLDER), 0);
        _assertActualPol(id);
        _claimTerminalInventory();
        _swapMosh();
        uint256 beneficiaryBefore = IERC20(wrapped).balanceOf(bob);
        uint256 independentReceipt = _deliverPonsReceipt();
        (uint256 userReceipt, uint256 permanentReceipt) = _collectMoshReceipts();
        assertEq(IERC20(wrapped).balanceOf(bob) - beneficiaryBefore, independentReceipt + permanentReceipt);
        assertGe(shareDelivery.userNativeReserved(), userReceipt);
        assertEq(shareDelivery.campaignNativeReserved(), 0);
        _returnTemporaryClaims();
        assertEq(uint256(destination.state()), uint256(BasketBootstrapCampaign.State.Launched));
    }

    function testHybridExpiryClosesAcquiredInventoryWithoutReversingSupplierTrades() public {
        _hybridFunding();
        uint256 end = destination.deadline();
        vm.warp(end);
        vm.expectRevert(BasketBootstrapCampaign.CampaignNotReady.selector);
        destination.finalize();
        vm.expectRevert(BasketBootstrapCampaign.InvalidFill.selector);
        destination.fill(0, 0.001 ether, 0, alice, end);
        vm.expectRevert(BasketBootstrapCampaign.CampaignNotFunding.selector);
        destination.fundNative{value: 1}();
        _swapMosh();
        uint256 beneficiaryBefore = IERC20(wrapped).balanceOf(bob);
        uint256 independentReceipt = _deliverPonsReceipt();
        (uint256 userReceipt, uint256 permanentReceipt) = _collectMoshReceipts();
        assertEq(IERC20(wrapped).balanceOf(bob) - beneficiaryBefore, independentReceipt + permanentReceipt);
        assertGe(shareDelivery.userNativeReserved(), userReceipt);
        _claimTerminalInventory();
        _returnTemporaryClaims();
        assertEq(uint256(destination.state()), uint256(BasketBootstrapCampaign.State.Expired));
        assertEq(destination.basketId(), 0);
    }

    function _swapMosh() private {
        SOURCE_MANAGER.unlock(abi.encode(0.01 ether));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(SOURCE_MANAGER));
        BalanceDelta delta = SOURCE_MANAGER.swap(
            sourceKey, SwapParams(true, -int256(abi.decode(data, (uint256))), TickMath.MIN_SQRT_PRICE + 1), ""
        );
        SOURCE_MANAGER.settle{value: uint256(-int256(delta.amount0()))}();
        SOURCE_MANAGER.take(sourceKey.currency1, address(this), uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }

    function _principalHash() private view returns (bytes32 commitment) {
        IMoshTeamCollection source = IMoshTeamCollection(address(SWARM));
        uint256 count = source.vaultCount();
        for (uint256 i; i < count; ++i) {
            address vault = source.vaults(i);
            commitment = keccak256(abi.encode(commitment, vault, vault.balance, IERC20(TOKEN).balanceOf(vault)));
        }
    }
}
