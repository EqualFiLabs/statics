// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

contract ProtocolRevenueFacet is IStaticsProtocolRevenue, ReentrancyGuard {
    error InvalidReceiver();
    error NoRevenue(address account, address asset);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error IncompatibleRevenueAsset(address asset, uint256 expected, uint256 spent, uint256 received);

    function claimCreatorRevenue(address asset, address receiver, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        LibProtocolRevenue.RevenueStorage storage rs = LibProtocolRevenue.revenueStorage();
        uint256 amount = rs.creatorRewardCredit[msg.sender][asset];
        if (amount == 0) revert NoRevenue(msg.sender, asset);
        rs.creatorRewardCredit[msg.sender][asset] = 0;
        rs.totalCreatorLiability[asset] -= amount;
        (uint256 spent, uint256 actualReceived) =
            LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
        if (spent != amount) revert IncompatibleRevenueAsset(asset, amount, spent, actualReceived);
        if (actualReceived < minReceived) revert MinimumOutputNotMet(asset, actualReceived, minReceived);
        emit CreatorRevenueClaimed(msg.sender, asset, receiver, amount);
        return actualReceived;
    }

    function distributePartnerRevenue(address recipient, address asset)
        external
        nonReentrant
        returns (uint256 distributed, uint256 tip)
    {
        LibProtocolRevenue.RevenueStorage storage rs = LibProtocolRevenue.revenueStorage();
        uint256 amount = rs.partnerAccrued[recipient][asset];
        if (amount == 0) return (0, 0);
        tip = amount * rs.partnerTipBps / LibBasket.BPS;
        distributed = amount - tip;
        rs.partnerAccrued[recipient][asset] = 0;
        rs.totalPartnerLiability[asset] -= amount;

        (uint256 recipientSpent, uint256 recipientReceived) =
            LibCustody.pushReserved(LibCustody.feeAccount(), asset, recipient, distributed, distributed);
        if (recipientSpent != distributed || recipientReceived != distributed) {
            revert IncompatibleRevenueAsset(asset, distributed, recipientSpent, recipientReceived);
        }
        if (tip != 0) {
            (uint256 tipSpent, uint256 tipReceived) =
                LibCustody.pushReserved(LibCustody.feeAccount(), asset, msg.sender, tip, tip);
            if (tipSpent != tip || tipReceived != tip) {
                revert IncompatibleRevenueAsset(asset, tip, tipSpent, tipReceived);
            }
        }
        emit PartnerRevenueDistributed(recipient, asset, msg.sender, amount, distributed, tip);
    }

    function setPartnerRecipient(address recipient) external {
        LibDiamond.enforceIsContractOwner();
        if (recipient == address(this)) revert LibProtocolRevenue.InvalidPartnerRecipient(recipient);
        LibProtocolRevenue.RevenueStorage storage rs = LibProtocolRevenue.revenueStorage();
        address previousRecipient = rs.partnerRecipient;
        rs.partnerRecipient = recipient;
        emit PartnerRecipientSet(previousRecipient, recipient);
    }

    function setPartnerDistributionTipBps(uint16 tipBps) external {
        LibDiamond.enforceIsContractOwner();
        uint16 previousTipBps = LibProtocolRevenue.setPartnerTip(tipBps);
        emit PartnerDistributionTipSet(previousTipBps, tipBps);
    }

    function creatorRewardCredit(address creator, address asset) external view returns (uint256) {
        return LibProtocolRevenue.revenueStorage().creatorRewardCredit[creator][asset];
    }

    function partnerAccrued(address recipient, address asset) external view returns (uint256) {
        return LibProtocolRevenue.revenueStorage().partnerAccrued[recipient][asset];
    }

    function partnerRecipient() external view returns (address) {
        return LibProtocolRevenue.revenueStorage().partnerRecipient;
    }

    function partnerDistributionTipBps() external view returns (uint16) {
        return LibProtocolRevenue.revenueStorage().partnerTipBps;
    }

    function protocolRevenueLiabilities(address asset) external view returns (uint256 creator, uint256 partner) {
        LibProtocolRevenue.RevenueStorage storage rs = LibProtocolRevenue.revenueStorage();
        return (rs.totalCreatorLiability[asset], rs.totalPartnerLiability[asset]);
    }
}
