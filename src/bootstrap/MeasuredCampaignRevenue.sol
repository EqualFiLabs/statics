// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BasketBootstrapCampaign} from "./BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "./BasketBootstrapFactory.sol";

/// @notice Delivers explicitly realized ERC-20 revenue, never future fees or externally held principal.
/// @dev External protocol adapters can use this fixed destination instead of campaign-controlled harvesting.
contract MeasuredCampaignRevenue is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable creator;
    IERC20 public immutable payoutAsset;
    BasketBootstrapFactory public immutable factory;
    BasketBootstrapCampaign public campaign;
    uint256 public assetIndex;
    uint256 public totalDelivered;
    error InvalidRevenueIntegration();
    error InexactRevenue();
    event CampaignBound(address indexed campaign, uint256 indexed assetIndex);
    event RealizedRevenueDelivered(address indexed sender, address indexed recipient, uint256 amount);

    constructor(address owner, address asset, BasketBootstrapFactory campaigns) {
        if (owner == address(0) || asset.code.length == 0 || address(campaigns).code.length == 0) {
            revert InvalidRevenueIntegration();
        }
        creator = owner;
        payoutAsset = IERC20(asset);
        factory = campaigns;
    }

    function bindCampaign(BasketBootstrapCampaign destination, uint256 index) external nonReentrant {
        if (
            msg.sender != creator || address(campaign) != address(0) || !factory.isCampaign(address(destination))
                || destination.creator() != creator || destination.beneficiary() == address(this)
                || !destination.revenueAdapters(address(this))
        ) {
            revert InvalidRevenueIntegration();
        }
        (address asset,,,) = destination.inventory(index);
        if (asset != address(payoutAsset)) revert InvalidRevenueIntegration();
        campaign = destination;
        assetIndex = index;
        emit CampaignBound(address(destination), index);
    }

    function recipient() public view returns (address) {
        if (address(campaign) == address(0) || !campaign.prepared()) revert InvalidRevenueIntegration();
        return campaign.revenueRecipient();
    }

    /// @dev Anyone can forward actual revenue; only this call's measured receipt is delivered.
    function deliverRealized(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidRevenueIntegration();
        address destination = recipient();
        uint256 floor = payoutAsset.balanceOf(address(this));
        uint256 senderBefore = payoutAsset.balanceOf(msg.sender);
        payoutAsset.safeTransferFrom(msg.sender, address(this), amount);
        if (
            payoutAsset.balanceOf(address(this)) != floor + amount
                || payoutAsset.balanceOf(msg.sender) + amount != senderBefore
        ) revert InexactRevenue();
        _deliverReceived(msg.sender, destination, amount, floor);
    }

    /// @dev Derived source integrations must first attribute an exact receipt, excluding existing balances.
    function _deliverReceived(address source, address destination, uint256 amount, uint256 floor) internal {
        if (amount == 0 || payoutAsset.balanceOf(address(this)) != floor + amount) revert InexactRevenue();
        if (destination == address(campaign)) {
            payoutAsset.forceApprove(destination, amount);
            campaign.deliverRevenue(assetIndex, amount);
            payoutAsset.forceApprove(destination, 0);
        } else {
            uint256 beforeBalance = payoutAsset.balanceOf(destination);
            payoutAsset.safeTransfer(destination, amount);
            if (payoutAsset.balanceOf(destination) != beforeBalance + amount) revert InexactRevenue();
        }
        if (payoutAsset.balanceOf(address(this)) != floor) revert InexactRevenue();
        totalDelivered += amount;
        emit RealizedRevenueDelivered(source, destination, amount);
    }
}
