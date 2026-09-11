// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";

library LibFlashLoan {
    bytes32 internal constant FLASH_LOAN_STORAGE_POSITION = keccak256("statics.storage.flash.loan.v1");
    uint256 internal constant BPS = 10_000;

    struct FlashLoanStorage {
        uint16 singleAssetFlashFeeBps;
    }

    error InvalidSingleAssetFlashFeeBps(uint256 feeBps);

    function flashLoanStorage() internal pure returns (FlashLoanStorage storage fs) {
        bytes32 position = FLASH_LOAN_STORAGE_POSITION;
        assembly ("memory-safe") {
            fs.slot := position
        }
    }

    function initialize(uint256 singleAssetFlashFeeBps_) internal {
        _validateFee(singleAssetFlashFeeBps_);
        flashLoanStorage().singleAssetFlashFeeBps = uint16(singleAssetFlashFeeBps_);
    }

    function singleAssetFlashFeeBps() internal view returns (uint16) {
        return flashLoanStorage().singleAssetFlashFeeBps;
    }

    function setSingleAssetFlashFeeBps(uint16 newFeeBps) internal {
        _validateFee(newFeeBps);
        FlashLoanStorage storage fs = flashLoanStorage();
        uint16 previousFeeBps = fs.singleAssetFlashFeeBps;
        fs.singleAssetFlashFeeBps = newFeeBps;
        emit IStaticsFlashLoan.SingleAssetFlashFeeBpsUpdated(previousFeeBps, newFeeBps);
    }

    function _validateFee(uint256 feeBps) private pure {
        if (feeBps > BPS) revert InvalidSingleAssetFlashFeeBps(feeBps);
    }
}
