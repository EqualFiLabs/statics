// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsProtocolRevenue {
    event CreatorRevenueAccrued(address indexed creator, address indexed asset, uint256 amount);
    event PositionTransferRevenueAccrued(address indexed owner, address indexed asset, uint256 amount);
    event PartnerRevenueAccrued(address indexed recipient, address indexed asset, uint256 amount);
    event CreatorRevenueClaimed(
        address indexed creator, address indexed asset, address indexed receiver, uint256 amount
    );
    event PositionTransferRevenueClaimed(
        address indexed owner, address indexed asset, address indexed receiver, uint256 amount
    );
    event PartnerRevenueDistributed(
        address indexed recipient,
        address indexed asset,
        address indexed caller,
        uint256 grossAmount,
        uint256 distributedAmount,
        uint256 tip
    );
    event PartnerRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event PartnerDistributionTipSet(uint16 previousTipBps, uint16 newTipBps);

    function claimCreatorRevenue(address asset, address receiver, uint256 minReceived)
        external
        returns (uint256 received);
    function claimPositionTransferRevenue(address asset, address receiver, uint256 minReceived)
        external
        returns (uint256 received);
    function distributePartnerRevenue(address recipient, address asset)
        external
        returns (uint256 distributed, uint256 tip);
    function setPartnerRecipient(address recipient) external;
    function setPartnerDistributionTipBps(uint16 tipBps) external;

    function creatorRewardCredit(address creator, address asset) external view returns (uint256);
    function positionTransferRewardCredit(address owner, address asset) external view returns (uint256);
    function partnerAccrued(address recipient, address asset) external view returns (uint256);
    function partnerRecipient() external view returns (address);
    function partnerDistributionTipBps() external view returns (uint16);
    function protocolRevenueLiabilities(address asset)
        external
        view
        returns (uint256 creator, uint256 positionTransfer, uint256 partner);
}
