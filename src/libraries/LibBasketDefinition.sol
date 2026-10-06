// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibLending} from "./LibLending.sol";

/// @dev Creation and launch previews must reject the same immutable definition.
library LibBasketDefinition {
    error InvalidBasketDefinition();
    error FeeExceedsCap(uint16 feeBps);
    error LtvExceedsMaximum(uint16 ltvBps);
    error InvalidRecoveryParameters(uint16 ltvBps, uint16 recoveryPenaltyBps);

    function validate(IStaticsBasket.CreateBasketParams calldata params) internal pure {
        uint256 length = params.assets.length;
        if (length == 0 || length > LibBasket.MAX_ASSETS || length != params.bundleAmounts.length) {
            revert InvalidBasketDefinition();
        }
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0 || params.loanDuration == 0) {
            revert InvalidBasketDefinition();
        }
        _validateFee(params.flashFeeBps);
        _validateFee(params.originationFeeBps);
        _validateFee(params.extensionFeeBps);
        _validateFee(params.recoveryPenaltyBps);
        if (params.ltvBps > LibLending.MAX_LTV_BPS) revert LtvExceedsMaximum(params.ltvBps);
        uint256 maximumRecoverySharesBps = uint256(params.ltvBps)
            + Math.mulDiv(params.ltvBps, params.recoveryPenaltyBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (maximumRecoverySharesBps > LibBasket.BPS) {
            revert InvalidRecoveryParameters(params.ltvBps, params.recoveryPenaltyBps);
        }

        for (uint256 i; i < length; ++i) {
            address asset = params.assets[i];
            if (asset == address(0) || params.bundleAmounts[i] == 0) revert InvalidBasketDefinition();
            for (uint256 j = i + 1; j < length; ++j) {
                if (asset == params.assets[j]) revert InvalidBasketDefinition();
            }
        }
    }

    function _validateFee(uint16 feeBps) private pure {
        if (feeBps > LibBasket.MAX_FEE_BPS) revert FeeExceedsCap(feeBps);
    }
}
