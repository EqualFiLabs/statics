// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {PonsRevenueAdapter} from "../../src/bootstrap/PonsRevenueAdapter.sol";
import {IPonsRevenueFactory, IPonsRevenueEscrow} from "../../src/bootstrap/IPonsRevenueSource.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {RejectingRevenueWeth} from "./NativeCampaignRevenue.t.sol";

interface IPonsForkLaunch {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchFee() external view returns (uint256);
    function previewLaunchEconomics(uint256 config, address pair) external view returns (bytes32);
    function launchToken(TokenParams calldata terms, uint256 config, address pair)
        external
        payable
        returns (address token, address curve);
    function memeHook() external view returns (address);
}

interface IPonsForkCurve {
    function buy(uint256 amount, uint256 minimum, address receiver) external payable returns (uint256);
    function sweepFees(uint256 minimum) external;
    function deployer() external view returns (address);
}

interface IPonsForkPolicy {
    function feeSweepOperator() external view returns (address);
}

interface IPonsForkEscrowCredit {
    function credit(address receiver) external payable;
}

interface IPonsForkWeth {
    function deposit() external payable;
}

contract PonsReentrantRevenueWeth is WETH {
    bool public blocked;

    function deposit() public payable override {
        (bool entered, bytes memory reason) = msg.sender.call(abi.encodeCall(PonsRevenueAdapter.collect, (1)));
        require(!entered, "nested collection must revert");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
            "must fail at reentrancy guard"
        );
        blocked = true;
        super.deposit();
    }
}

/// @dev Executes real Pons launches, curve trades, escrow collection and factory handoffs at block 80,155,273.
/// Existing sweep-operator impersonation only realizes upstream revenue; the adapter gains no such authority.
contract RobinhoodPonsRevenueForkTest is CampaignTestBase {
    IPonsRevenueFactory private constant SOURCE = IPonsRevenueFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    bytes32 private constant FACTORY_HASH = 0x89a27da6f703e0a7cdd4f233e7cb57604ff75b164530962d3ff7cf8483a67d84;
    bytes32 private constant ESCROW_HASH = 0xf25f75cfbc1637ba068dc34f69098fa4e8a80f8ee8fe7bf7820594e0b3fed2f1;
    address private constant QUOTE = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3;
    address private payout;
    address private sourceToken;
    address private sourceCurve;
    PonsRevenueAdapter private adapter;
    BasketBootstrapCampaign private destination;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "Robinhood RPC not configured");
            return;
        }
        vm.createSelectFork(rpc, 80_155_273);
        super.setUp();
        assertEq(address(SOURCE).codehash, FACTORY_HASH);
        assertEq(SOURCE.feeEscrow().codehash, ESCROW_HASH);
        string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");
        payout = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        assertEq(payout.codehash, vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash"));
        _launch(address(0), payout);
    }

    function _launch(address quote, address asset) private {
        IPonsForkLaunch.TokenParams memory terms;
        terms.name = "Statics revenue fork";
        terms.symbol = "SRF";
        terms.creatorFeeRecipient = vm.addr(CREATOR_KEY);
        terms.creatorTaxBps = 100;
        terms.expectedEconomics = IPonsForkLaunch(address(SOURCE)).previewLaunchEconomics(0, quote);
        terms.salt = keccak256(abi.encode(quote, asset));
        uint256 fee = IPonsForkLaunch(address(SOURCE)).launchFee();
        vm.deal(vm.addr(CREATOR_KEY), 100 ether);
        vm.prank(vm.addr(CREATOR_KEY));
        (sourceToken, sourceCurve) = IPonsForkLaunch(address(SOURCE)).launchToken{value: fee}(terms, 0, quote);
        adapter = new PonsRevenueAdapter(vm.addr(CREATOR_KEY), asset, campaignFactory, sourceToken, _pins(asset));
        vm.prank(vm.addr(CREATOR_KEY));
        SOURCE.transferCreatorFeeRecipient(sourceToken, address(adapter));
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, address(adapter));
        assertEq(IPonsForkCurve(sourceCurve).deployer(), address(adapter));
        BasketBootstrapCampaign.Terms memory campaignTerms = _terms(false);
        campaignTerms.projectToken = sourceToken;
        campaignTerms.basket.assets[0] = asset;
        campaignTerms.adapters = new address[](1);
        campaignTerms.adapters[0] = address(adapter);
        destination = _campaign(campaignTerms, keccak256(abi.encode("Pons campaign", quote, asset)));
        vm.prank(vm.addr(CREATOR_KEY));
        adapter.bindCampaign(destination, 0);
        vm.warp(block.timestamp + 1 minutes); // Wait out the actual launch's anti-snipe tax.
    }

    function _pins(address asset) private view returns (PonsRevenueAdapter.SourcePins memory) {
        return PonsRevenueAdapter.SourcePins(4663, SOURCE, FACTORY_HASH, ESCROW_HASH, asset.codehash);
    }

    function _tradeAndRealize(bool native, uint256 amount) private returns (uint256 credited) {
        IPonsRevenueEscrow ledger = adapter.escrow();
        uint256 beforeCredit = native
            ? ledger.balanceOf(address(adapter))
            : ledger.balanceOfToken(address(adapter), address(adapter.payoutAsset()));
        if (native) {
            assertGt(IPonsForkCurve(sourceCurve).buy{value: amount}(amount, 1, address(this)), 0);
        } else {
            IERC20 quote = adapter.payoutAsset();
            // Balance provisioning only; the actual deployed token, curve and escrow execute all movements.
            deal(address(quote), address(this), amount);
            quote.approve(sourceCurve, amount);
            assertGt(IPonsForkCurve(sourceCurve).buy(amount, 1, address(this)), 0);
        }
        vm.prank(IPonsForkPolicy(IPonsForkLaunch(address(SOURCE)).memeHook()).feeSweepOperator());
        IPonsForkCurve(sourceCurve).sweepFees(0);
        uint256 afterCredit = native
            ? ledger.balanceOf(address(adapter))
            : ledger.balanceOfToken(address(adapter), address(adapter.payoutAsset()));
        credited = afterCredit - beforeCredit;
        assertGt(credited, 0);
    }

    function testNativeSourceCollectionMeasuresReceiptAndLeavesUnsolicitedBalances() public {
        IPonsForkWeth(payout).deposit{value: 7 ether}();
        IERC20(payout).transfer(address(adapter), 7 ether);
        vm.deal(address(adapter), 5 ether);
        uint256 amount = _tradeAndRealize(true, 0.01 ether);
        assertFalse(destination.ready());
        vm.prank(makeAddr("permissionless collector"));
        assertEq(adapter.collect(type(uint256).max), amount);
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, amount);
        assertEq(adapter.totalDelivered(), amount);
        assertEq(adapter.escrow().balanceOf(address(adapter)), 0);
        assertEq(IERC20(payout).balanceOf(address(adapter)), 7 ether);
        assertEq(address(adapter).balance, 5 ether);
        assertEq(IERC20(payout).allowance(address(adapter), address(destination)), 0);
        assertEq(adapter.collect(type(uint256).max), 0);
        (bool received,) = address(adapter).call{value: 1}("");
        assertFalse(received);
    }

    function testQuotedSourceCollectionUsesActualPairTokenAndPartialClaims() public {
        _launch(QUOTE, QUOTE);
        uint256 amount = _tradeAndRealize(false, 100 ether);
        assertFalse(adapter.nativeQuote());
        uint256 first = amount / 3;
        assertEq(adapter.collect(first), first);
        assertEq(adapter.escrow().balanceOfToken(address(adapter), QUOTE), amount - first);
        assertEq(adapter.collect(type(uint256).max), amount - first);
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, amount);
        assertEq(IERC20(QUOTE).balanceOf(address(destination)), amount);
        assertEq(IERC20(QUOTE).allowance(address(adapter), address(destination)), 0);
    }

    function testTerminalHandoffKeepsOldCreditsAndSendsFutureFeesToBeneficiary() public {
        uint256 oldCredits = _tradeAndRealize(true, 0.01 ether);
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        adapter.handoff();
        vm.warp(destination.deadline());
        vm.prank(makeAddr("permissionless handoff"));
        adapter.handoff();
        assertTrue(adapter.handedOff());
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, bob);
        assertEq(IPonsForkCurve(sourceCurve).deployer(), bob);
        assertEq(adapter.escrow().balanceOf(address(adapter)), oldCredits);
        adapter.handoff();
        assertEq(adapter.collect(type(uint256).max), oldCredits);
        assertEq(IERC20(payout).balanceOf(bob), oldCredits);
        uint256 beforeBeneficiary = adapter.escrow().balanceOf(bob);
        assertGt(IPonsForkCurve(sourceCurve).buy{value: 0.01 ether}(0.01 ether, 1, address(this)), 0);
        vm.prank(IPonsForkPolicy(IPonsForkLaunch(address(SOURCE)).memeHook()).feeSweepOperator());
        IPonsForkCurve(sourceCurve).sweepFees(0);
        assertGt(adapter.escrow().balanceOf(bob), beforeBeneficiary);
        assertEq(adapter.escrow().balanceOf(address(adapter)), 0);
    }

    function testHandoffFailureDoesNotBlockCollectionAndCanRetry() public {
        uint256 amount = _tradeAndRealize(true, 0.01 ether);
        vm.warp(destination.deadline());
        // Only the upstream failure branch is synthetic; successful transfer retries use the deployed factory.
        vm.mockCallRevert(
            address(SOURCE),
            abi.encodeCall(IPonsRevenueFactory.transferCreatorFeeRecipient, (sourceToken, bob)),
            hex"deadbeef"
        );
        vm.expectRevert(bytes4(0xdeadbeef));
        adapter.handoff();
        assertFalse(adapter.handedOff());
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, address(adapter));
        assertEq(adapter.collect(type(uint256).max), amount);
        assertEq(IERC20(payout).balanceOf(bob), amount);
        vm.clearMockedCalls();
        adapter.handoff();
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, bob);
    }

    function testSuccessfulRealPolLaunchDoesNotHarvestOrHandoffFees() public {
        uint256 priorCredits = _tradeAndRealize(true, 0.01 ether);
        (, uint256 target,,) = destination.inventory(0);
        IPonsForkWeth(payout).deposit{value: target}();
        IERC20(payout).approve(address(destination), target);
        destination.fund(0, target);
        (, uint256 otherTarget,,) = destination.inventory(1);
        assetB.mint(address(this), otherTarget);
        assetB.approve(address(destination), otherTarget);
        destination.fund(1, otherTarget);
        destination.fundNative{value: destination.nativeRequired()}();
        (uint256 id,) = destination.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        for (uint256 i; i < 2; ++i) {
            (address asset,,,) = destination.inventory(i);
            assertEq(
                IStaticsProtocolPools(address(diamond))
                .protocolPool(basketLiquidity.canonicalPool(id, asset).poolId)
                .activePolPositions,
                1
            );
        }
        assertFalse(adapter.handedOff());
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, address(adapter));
        assertEq(adapter.escrow().balanceOf(address(adapter)), priorCredits);
        assertEq(adapter.collect(type(uint256).max), priorCredits);
        assertEq(IERC20(payout).balanceOf(bob), priorCredits);
        adapter.handoff();
        assertEq(SOURCE.getLaunchedToken(sourceToken).creatorFeeRecipient, bob);
    }

    function testRealEscrowCollectionRejectsWrapperReentrancyAtGuard() public {
        PonsReentrantRevenueWeth hostile = new PonsReentrantRevenueWeth();
        _launch(address(0), address(hostile));
        uint256 amount = _tradeAndRealize(true, 0.01 ether);
        assertEq(adapter.collect(type(uint256).max), amount);
        assertTrue(hostile.blocked());
        assertEq(hostile.balanceOf(address(destination)), amount);
        assertEq(adapter.escrow().balanceOf(address(adapter)), 0);
    }

    function testDeliveryFailureRestoresActualEscrowCreditAndApprovals() public {
        RejectingRevenueWeth bad = new RejectingRevenueWeth();
        _launch(address(0), address(bad));
        uint256 amount = _tradeAndRealize(true, 0.01 ether);
        vm.expectRevert(RejectingRevenueWeth.DeliveryBlocked.selector);
        adapter.collect(type(uint256).max);
        assertEq(adapter.escrow().balanceOf(address(adapter)), amount);
        assertEq(address(adapter).balance, 0);
        assertEq(bad.balanceOf(address(adapter)), 0);
        assertEq(bad.allowance(address(adapter), address(destination)), 0);
        assertEq(adapter.totalDelivered(), 0);
        vm.warp(destination.deadline());
        assertEq(adapter.collect(type(uint256).max), amount);
        assertEq(bad.balanceOf(bob), amount);
    }

    function testPinnedSourceRejectsWrongOwnerAndRuntime() public {
        PonsRevenueAdapter.SourcePins memory pins = _pins(payout);
        pins.factoryRuntimeHash = bytes32(uint256(1));
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        new PonsRevenueAdapter(vm.addr(CREATOR_KEY), payout, campaignFactory, sourceToken, pins);
        pins = _pins(payout);
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        new PonsRevenueAdapter(bob, payout, campaignFactory, sourceToken, pins);
        pins.escrowRuntimeHash = bytes32(uint256(1));
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        new PonsRevenueAdapter(vm.addr(CREATOR_KEY), payout, campaignFactory, sourceToken, pins);
    }

    function testQuotedSourceRejectsWrongPayoutAndChain() public {
        _launch(QUOTE, QUOTE);
        PonsRevenueAdapter.SourcePins memory pins = _pins(payout);
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        new PonsRevenueAdapter(address(adapter), payout, campaignFactory, sourceToken, pins);
        pins = _pins(QUOTE);
        pins.chainId = 1;
        vm.expectRevert(PonsRevenueAdapter.InvalidPonsSource.selector);
        new PonsRevenueAdapter(address(adapter), QUOTE, campaignFactory, sourceToken, pins);
    }

    function testExplicitEscrowCreditCannotSweepPriorNativeBalance() public {
        vm.deal(address(adapter), 1 ether);
        // The verified escrow allows explicit credits; these are realized funding, not future fees or principal.
        IPonsForkEscrowCredit(address(adapter.escrow())).credit{value: 10}(address(adapter));
        assertEq(adapter.collect(3), 3);
        assertEq(address(adapter).balance, 1 ether);
        assertEq(adapter.escrow().balanceOf(address(adapter)), 7);
        assertEq(adapter.collect(0), 0);
    }
}
