// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";

library LibProtocolRevenue {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.protocol.revenue.v1");
    uint16 internal constant DEFAULT_PARTNER_TIP_BPS = 100;
    uint16 internal constant MAX_PARTNER_TIP_BPS = 500;

    struct RevenueStorage {
        mapping(address creator => mapping(address asset => uint256 amount)) creatorRewardCredit;
        mapping(address recipient => mapping(address asset => uint256 amount)) partnerAccrued;
        mapping(address asset => uint256 amount) totalCreatorLiability;
        mapping(address asset => uint256 amount) totalPartnerLiability;
        address partnerRecipient;
        uint16 partnerTipBps;
    }

    error InvalidPartnerTip(uint16 tipBps);
    error InvalidPartnerRecipient(address recipient);

    function revenueStorage() internal pure returns (RevenueStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := slot
        }
    }

    function initialize(address partnerRecipient) internal {
        if (partnerRecipient == address(this)) revert InvalidPartnerRecipient(partnerRecipient);
        RevenueStorage storage rs = revenueStorage();
        rs.partnerRecipient = partnerRecipient;
        rs.partnerTipBps = DEFAULT_PARTNER_TIP_BPS;
    }

    function creditCreator(address creator, address asset, uint256 amount) internal {
        if (amount == 0) return;
        RevenueStorage storage rs = revenueStorage();
        rs.creatorRewardCredit[creator][asset] += amount;
        rs.totalCreatorLiability[asset] += amount;
        emit IStaticsProtocolRevenue.CreatorRevenueAccrued(creator, asset, amount);
    }

    function creditPartner(address recipient, address asset, uint256 amount) internal {
        if (amount == 0) return;
        RevenueStorage storage rs = revenueStorage();
        rs.partnerAccrued[recipient][asset] += amount;
        rs.totalPartnerLiability[asset] += amount;
        emit IStaticsProtocolRevenue.PartnerRevenueAccrued(recipient, asset, amount);
    }

    function setPartnerTip(uint16 tipBps) internal returns (uint16 previousTipBps) {
        if (tipBps > MAX_PARTNER_TIP_BPS) revert InvalidPartnerTip(tipBps);
        RevenueStorage storage rs = revenueStorage();
        previousTipBps = rs.partnerTipBps;
        rs.partnerTipBps = tipBps;
    }
}
