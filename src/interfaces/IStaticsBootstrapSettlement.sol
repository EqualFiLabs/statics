// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IStaticsBootstrapSettlement {
    function installBootstrapFactory(address factory, bytes32 runtimeHash, bytes32 creationCodeHash) external;
    function bootstrapFactoryApproved(address factory) external view returns (bool);
    function registerBootstrapCampaign(address campaign) external;
    function settleBootstrapToken(address token, address sender, address receiver, uint256 amount) external;
}

interface IBootstrapCustodyFactory {
    function diamond() external view returns (address);
    function creationCodeHash() external view returns (bytes32);
    function isCampaign(address campaign) external view returns (bool);
}

interface IBootstrapCustodyCampaign {
    function diamond() external view returns (address);
    function factory() external view returns (address);
    function projectToken() external view returns (address);
    function assetCount() external view returns (uint256);
    function custodyAsset(uint256 index) external view returns (address);
}
