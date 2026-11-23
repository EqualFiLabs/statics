// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGenesisTransferTracking, IGenesisOperatorTransitionReceiver} from "../interfaces/IGenesisTransferTracking.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisTransferTracking} from "../libraries/LibGenesisTransferTracking.sol";

contract GenesisTransferTrackingFacet is IGenesisTransferTracking, ReentrancyGuard {
    error GenesisIntegrationNotReady();
    error GenesisOperatorFeeRouterAlreadyBound();
    error InvalidGenesisOperatorFeeRouter(address router);

    function genesisTransferTrackingStartedAt() external view returns (uint64) {
        return LibGenesisTransferTracking.layout().startedAt;
    }

    function genesisTransferState(uint256 genesisId) external view returns (uint64 nonce, uint64 lastTransferAt) {
        LibGenesisTransferTracking.TransferState storage state =
            LibGenesisTransferTracking.layout().transfers[genesisId];
        return (state.nonce, state.lastTransferAt);
    }

    function genesisOperatorFeeRouter() external view returns (address) {
        return LibGenesisTransferTracking.layout().router;
    }

    function bindGenesisOperatorFeeRouter(address router) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibGenesisTransferTracking.Layout storage tracking = LibGenesisTransferTracking.layout();
        if (tracking.router != address(0)) revert GenesisOperatorFeeRouterAlreadyBound();
        if (tracking.startedAt == 0 || !LibGenesisIntegration.integrationReady()) revert GenesisIntegrationNotReady();
        if (router.code.length == 0) revert InvalidGenesisOperatorFeeRouter(router);
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        IGenesisOperatorTransitionReceiver receiver = IGenesisOperatorTransitionReceiver(router);
        if (
            receiver.operatorCollection() != gs.genesis || receiver.operatorVault() != gs.vault
                || receiver.activationRegistry() != gs.activationRegistry
                || receiver.genesisTransitionSource() != address(this)
                || receiver.transferTrackingStartedAt() != tracking.startedAt
        ) revert InvalidGenesisOperatorFeeRouter(router);
        tracking.router = router;
        emit GenesisOperatorFeeRouterBound(router);
    }
}
