// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";

/// @notice Custody and claim accounting for creator-funded gauge allocator rewards.
library LibGaugeBribes {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.bribes.v1");
    bytes32 internal constant ACCOUNT_DOMAIN = keccak256("statics.custody.account.gauge.bribes.v1");
    uint64 internal constant CLAIM_WINDOW_EPOCHS = 26;

    struct Budget {
        address asset;
        bytes32 eligibilityVersion;
        bool finalized;
        uint40 expiresAt;
        uint256 funded;
        uint256 totalWeight;
        uint256 distributable;
        uint256 remainingLiability;
    }

    struct BribeStorage {
        mapping(PoolId poolId => mapping(uint8 slot => mapping(uint64 epoch => Budget budget))) budgets;
        mapping(
            uint256 positionId => mapping(PoolId poolId => mapping(uint8 slot => mapping(uint64 epoch => bool)))
        ) claimed;
    }

    error GaugeBribeAssetMismatch(address expected, address actual);

    function bribeStorage() internal pure returns (BribeStorage storage bs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            bs.slot := position
        }
    }

    function account(PoolId poolId, uint8 slot, uint64 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_DOMAIN, PoolId.unwrap(poolId), slot, epoch));
    }

    /// @dev A restriction-version change invalidates prior funding for the same future epoch.
    ///      The invalidated reservation becomes treasury revenue before the new tranche is recorded.
    function recordFunding(
        PoolId poolId,
        uint8 slot,
        uint64 epoch,
        address asset,
        bytes32 eligibilityVersion,
        uint256 amount
    ) internal returns (uint256 invalidated) {
        Budget storage budget = bribeStorage().budgets[poolId][slot][epoch];
        address recordedAsset = budget.asset;
        if (recordedAsset != address(0) && recordedAsset != asset) {
            revert GaugeBribeAssetMismatch(recordedAsset, asset);
        }
        if (budget.eligibilityVersion != bytes32(0) && budget.eligibilityVersion != eligibilityVersion) {
            invalidated = budget.funded;
            if (invalidated != 0) {
                LibCustody.moveReservation(account(poolId, slot, epoch), LibCustody.feeAccount(), asset, invalidated);
                LibGlobalRewards.accrueReservedTreasuryFee(asset, invalidated);
            }
            delete bribeStorage().budgets[poolId][slot][epoch];
        }
        budget.asset = asset;
        budget.eligibilityVersion = eligibilityVersion;
        budget.funded += amount;
    }
}
