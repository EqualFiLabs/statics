// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibDiamond} from "../../../libraries/LibDiamond.sol";
import {LibSolvencyIndex} from "./LibSolvencyIndex.sol";

library LibCoreStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.dollar.core.storage.v1");

    struct CS {
        address staticsDollar;
        address staticsDollarRisk;
        address initialOracle;
        address requiredSequencerUptimeFeed;
        uint256 minimumSequencerGracePeriod;
        address profileGuardian;
        address bootstrapAuthority;
        address periphery;
        bool initialized;
        bool bootstrapFinalized;
        uint256 nextProfileId;
        uint256 nextSeriesId;
        uint256 totalSeniorOutstanding;
        bool globalImpairmentLatched;
        uint64 globalRecoveryStartedAt;
        mapping(uint256 profileId => IStaticsDollarCoreTypes.StableCollateralProfile profile) collateralProfiles;
        mapping(uint256 seriesId => IStaticsDollarCoreTypes.RiskSeries series) riskSeries;
        mapping(uint256 profileId => uint256[] seriesIds) profileSeries;
        mapping(uint256 seriesId => IStaticsDollarCoreTypes.SeriesRecoveryState state) seriesRecovery;
        mapping(uint256 seriesId => mapping(address holder => uint256 shares)) returnedRiskShares;
        mapping(address collateralToken => uint256 amount) accountedCollateralByToken;
        mapping(address collateralToken => uint256 profileId) profileIdByCollateralToken;
        mapping(uint256 profileId => uint64 revision) profileOracleRevision;
        mapping(uint256 profileId => LibSolvencyIndex.Tree tree) solvencyIndex;
        mapping(uint256 profileId => uint256 operations) pausedProfileOperations;
        mapping(address payer => mapping(address collateralToken => uint256 amount)) cumulativeFeesPaid;
        mapping(uint256 seriesId => ExpiredRecoveryBook book) expiredRecoveryBook;
        mapping(uint256 seriesId => TransitionSnapshot snapshot) transitionSnapshot;
        mapping(address holder => bool managed) managedRecoveryHolder;
        ExpectedRiskIngress expectedRiskIngress;
        uint256 pendingDownsideTransitions;
        bool peggedRedemptionLatched;
        uint64 peggedRecoveryStartedAt;
        mapping(uint256 seriesId => bool pending) downsideTransitionPending;
    }

    struct ExpiredRecoveryBook {
        uint256 remainingShares;
        uint256 remainingCollateral;
        uint256 remainingSeniorCollateral;
        uint256 remainingBountyCollateral;
    }

    struct TransitionSnapshot {
        address oracle;
        uint64 oracleRevision;
        uint16 collateralRatioBps;
        uint16 priceBandBps;
    }

    struct ExpectedRiskIngress {
        address from;
        uint256 seriesId;
        uint256 amount;
        bool active;
    }

    error Unauthorized(address caller);

    function s() internal pure returns (CS storage cs) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            cs.slot := slot
        }
    }

    function enforceProtocolOwner() internal view {
        LibDiamond.enforceIsContractOwner();
    }

    function enforceBootstrapAuthority() internal view {
        if (msg.sender != s().bootstrapAuthority) revert Unauthorized(msg.sender);
    }

    function enforceGuardianOrOwner() internal view {
        CS storage cs = s();
        if (msg.sender != LibDiamond.contractOwner() && msg.sender != cs.profileGuardian) {
            revert Unauthorized(msg.sender);
        }
    }
}
