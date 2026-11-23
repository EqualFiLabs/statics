// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IGenesisTransferTracking {
    event GenesisTransferTrackingStarted(uint64 startedAt);
    event GenesisTransferObserved(uint256 indexed genesisId, uint64 nonce, uint64 transferredAt);
    event GenesisOperatorFeeRouterBound(address indexed router);

    function genesisTransferTrackingStartedAt() external view returns (uint64);
    function genesisTransferState(uint256 genesisId) external view returns (uint64 nonce, uint64 lastTransferAt);
    function genesisOperatorFeeRouter() external view returns (address);
    function bindGenesisOperatorFeeRouter(address router) external;
}

interface IGenesisOperatorTransitionReceiver {
    function operatorCollection() external view returns (address);
    function operatorVault() external view returns (address);
    function activationRegistry() external view returns (address);
    function genesisTransitionSource() external view returns (address);
    function transferTrackingStartedAt() external view returns (uint64);

    function onOperatorTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplierBps,
        uint16 nextMultiplierBps,
        uint64 nonce
    ) external returns (bytes4);
}
