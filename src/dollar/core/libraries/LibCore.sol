// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISequencerAwareOracle} from "../../interfaces/ISequencerAwareOracle.sol";
import {IUsdOracle} from "../../interfaces/IUsdOracle.sol";

library LibCore {
    error ContractExpected(address account);
    error OracleValidationFailed(address oracle);
    error InvalidSequencerRequirement(address requiredFeed, uint256 minimumGracePeriod);
    error SequencerProtectionRequired(address oracle);
    error SequencerFeedMismatch(address oracle, address configuredFeed, address requiredFeed);
    error SequencerGracePeriodTooShort(address oracle, uint256 configuredGracePeriod, uint256 minimumGracePeriod);

    function requireContract(address account) internal view {
        if (account.code.length == 0) revert ContractExpected(account);
    }

    function validateOracle(address oracle, address requiredFeed, uint256 minimumGracePeriod) internal view {
        requireContract(oracle);
        try IUsdOracle(oracle).priceWad() returns (uint256 price) {
            if (price == 0) revert OracleValidationFailed(oracle);
        } catch {
            revert OracleValidationFailed(oracle);
        }
        if (requiredFeed == address(0)) return;
        address configuredFeed;
        uint256 configuredGrace;
        try ISequencerAwareOracle(oracle).sequencerUptimeFeed() returns (address feed) {
            configuredFeed = feed;
        } catch {
            revert SequencerProtectionRequired(oracle);
        }
        try ISequencerAwareOracle(oracle).sequencerGracePeriod() returns (uint256 grace) {
            configuredGrace = grace;
        } catch {
            revert SequencerProtectionRequired(oracle);
        }
        if (configuredFeed != requiredFeed) revert SequencerFeedMismatch(oracle, configuredFeed, requiredFeed);
        if (configuredGrace < minimumGracePeriod) {
            revert SequencerGracePeriodTooShort(oracle, configuredGrace, minimumGracePeriod);
        }
    }

    function validateSequencerRequirement(address requiredFeed, uint256 minimumGracePeriod) internal view {
        if ((requiredFeed == address(0)) != (minimumGracePeriod == 0)) {
            revert InvalidSequencerRequirement(requiredFeed, minimumGracePeriod);
        }
        if (requiredFeed != address(0)) requireContract(requiredFeed);
    }
}
