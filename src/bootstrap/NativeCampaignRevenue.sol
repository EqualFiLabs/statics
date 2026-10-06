// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MeasuredCampaignRevenue} from "./MeasuredCampaignRevenue.sol";
import {BasketBootstrapFactory} from "./BasketBootstrapFactory.sol";

interface IRevenueWeth {
    function deposit() external payable;
}

/// @notice Wraps explicitly delivered native revenue into the campaign's bound WETH constituent.
/// @dev This is delivery plumbing, not a source collector. No receive hook credits unsolicited balances.
contract NativeCampaignRevenue is MeasuredCampaignRevenue {
    bytes32 public immutable wethRuntimeHash;

    constructor(address owner, address wrappedNative, bytes32 approvedRuntimeHash, BasketBootstrapFactory campaigns)
        MeasuredCampaignRevenue(owner, wrappedNative, campaigns)
    {
        if (approvedRuntimeHash == bytes32(0) || wrappedNative.codehash != approvedRuntimeHash) {
            revert InvalidRevenueIntegration();
        }
        wethRuntimeHash = approvedRuntimeHash;
    }

    function deliverNative() external payable nonReentrant {
        if (msg.value == 0 || address(payoutAsset).codehash != wethRuntimeHash) revert InvalidRevenueIntegration();
        address destination = recipient();
        uint256 tokenFloor = payoutAsset.balanceOf(address(this));
        uint256 nativeFloor = address(this).balance - msg.value;
        IRevenueWeth(address(payoutAsset)).deposit{value: msg.value}();
        if (address(this).balance != nativeFloor) revert InexactRevenue();
        _deliverReceived(msg.sender, destination, msg.value, tokenFloor);
        if (address(this).balance != nativeFloor) revert InexactRevenue();
    }
}
