// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MeasuredCampaignRevenue} from "./MeasuredCampaignRevenue.sol";
import {IRevenueWeth} from "./NativeCampaignRevenue.sol";
import {BasketBootstrapCampaign} from "./BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "./BasketBootstrapFactory.sol";
import {IPonsRevenueFactory, IPonsRevenueEscrow, IPonsRevenueCurve} from "./IPonsRevenueSource.sol";

/// @notice Collects a dedicated Pons V2 recipient's realized quote revenue into one fixed campaign.
/// @dev No source principal, upstream swaps, buyback release, arbitrary calls or administrator override authority.
/// Already credited escrow balances remain collectible after the separately retryable terminal handoff.
contract PonsRevenueAdapter is MeasuredCampaignRevenue {
    struct SourcePins {
        uint256 chainId;
        IPonsRevenueFactory sourceFactory;
        bytes32 factoryRuntimeHash;
        bytes32 escrowRuntimeHash;
        bytes32 payoutRuntimeHash;
    }

    IPonsRevenueFactory public immutable sourceFactory;
    IPonsRevenueEscrow public immutable escrow;
    address public immutable sourceToken;
    address public immutable curve;
    bool public immutable nativeQuote;
    bytes32 public immutable factoryRuntimeHash;
    bytes32 public immutable escrowRuntimeHash;
    bytes32 public immutable curveRuntimeHash;
    bytes32 public immutable payoutRuntimeHash;
    bool public handedOff;
    bool private collecting;
    uint256 private nativeReceived;

    error InvalidPonsSource();
    event CreatorRevenueHandedOff(address indexed token, address indexed beneficiary);

    constructor(address owner, address payout, BasketBootstrapFactory campaigns, address token, SourcePins memory pins)
        MeasuredCampaignRevenue(owner, payout, campaigns)
    {
        if (
            pins.chainId != block.chainid || pins.factoryRuntimeHash == bytes32(0)
                || address(pins.sourceFactory).codehash != pins.factoryRuntimeHash
                || pins.escrowRuntimeHash == bytes32(0) || pins.payoutRuntimeHash == bytes32(0)
                || payout.codehash != pins.payoutRuntimeHash
        ) revert InvalidPonsSource();
        IPonsRevenueFactory.Launch memory launch = pins.sourceFactory.getLaunchedToken(token);
        address ledger = pins.sourceFactory.feeEscrow();
        if (
            !launch.exists || launch.token != token || token.code.length == 0 || launch.curve.code.length == 0
                || ledger.code.length == 0 || ledger.codehash != pins.escrowRuntimeHash
                || (launch.creatorFeeRecipient != owner && launch.creatorFeeRecipient != address(this))
                || (launch.pairToken != address(0) && launch.pairToken != payout)
                || IPonsRevenueCurve(launch.curve).factory() != address(pins.sourceFactory)
                || IPonsRevenueCurve(launch.curve).token() != token
                || IPonsRevenueCurve(launch.curve).pairToken() != launch.pairToken
                || IPonsRevenueCurve(launch.curve).feeEscrow() != ledger
        ) revert InvalidPonsSource();
        sourceFactory = pins.sourceFactory;
        escrow = IPonsRevenueEscrow(ledger);
        sourceToken = token;
        curve = launch.curve;
        nativeQuote = launch.pairToken == address(0);
        factoryRuntimeHash = pins.factoryRuntimeHash;
        escrowRuntimeHash = pins.escrowRuntimeHash;
        curveRuntimeHash = launch.curve.codehash;
        payoutRuntimeHash = pins.payoutRuntimeHash;
    }

    function _validateCampaignBinding(BasketBootstrapCampaign destination) internal view override {
        _runtime();
        if (
            address(payoutAsset).codehash != payoutRuntimeHash || destination.projectToken() != sourceToken
                || sourceFactory.getLaunchedToken(sourceToken).creatorFeeRecipient != address(this)
        ) revert InvalidPonsSource();
    }

    receive() external payable {
        if (!nativeQuote || !collecting || msg.sender != address(escrow)) revert InvalidPonsSource();
        nativeReceived += msg.value;
    }

    /// @notice Permissionless partial claims avoid making an enlarged escrow ledger a transfer-limit denial of service.
    /// @dev Exact ledger debit and receipt are checked. Unsolicited balances are never swept.
    function collect(uint256 maximum) external nonReentrant returns (uint256 amount) {
        _runtime();
        if (address(payoutAsset).codehash != payoutRuntimeHash) revert InvalidPonsSource();
        address destination = recipient();
        uint256 available =
            nativeQuote ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), address(payoutAsset));
        amount = available < maximum ? available : maximum;
        if (amount == 0) return 0;
        uint256 tokenFloor = payoutAsset.balanceOf(address(this));
        uint256 reported;
        if (nativeQuote) {
            uint256 nativeFloor = address(this).balance;
            collecting = true;
            nativeReceived = 0;
            reported = escrow.claim(amount);
            collecting = false;
            if (nativeReceived != amount || address(this).balance != nativeFloor + amount) revert InexactRevenue();
            nativeReceived = 0;
            IRevenueWeth(address(payoutAsset)).deposit{value: amount}();
            if (address(this).balance != nativeFloor) revert InexactRevenue();
        } else {
            reported = escrow.claimToken(address(payoutAsset), amount);
        }
        uint256 remaining =
            nativeQuote ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), address(payoutAsset));
        if (reported != amount || remaining + amount != available) revert InexactRevenue();
        _deliverReceived(address(escrow), destination, amount, tokenFloor);
    }

    /// @notice Transfers future fee rights only after success/expiry; independent from finalization and collection.
    /// @dev Upstream failure reverts just this operation. Old escrow credits still route through collect().
    function handoff() external nonReentrant {
        _runtime();
        recipient(); // Requires a bound, prepared campaign, even if it already expired.
        if (campaign.state() == BasketBootstrapCampaign.State.Funding) revert InvalidPonsSource();
        if (handedOff) return;
        address beneficiary = campaign.beneficiary();
        if (sourceFactory.getLaunchedToken(sourceToken).creatorFeeRecipient != address(this)) {
            revert InvalidPonsSource();
        }
        sourceFactory.transferCreatorFeeRecipient(sourceToken, beneficiary);
        if (sourceFactory.getLaunchedToken(sourceToken).creatorFeeRecipient != beneficiary) revert InvalidPonsSource();
        handedOff = true;
        emit CreatorRevenueHandedOff(sourceToken, beneficiary);
    }

    function _runtime() private view {
        if (
            address(sourceFactory).codehash != factoryRuntimeHash || address(escrow).codehash != escrowRuntimeHash
                || curve.codehash != curveRuntimeHash || sourceFactory.feeEscrow() != address(escrow)
        ) revert InvalidPonsSource();
    }
}
