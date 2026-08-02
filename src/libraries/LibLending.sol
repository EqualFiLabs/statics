// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibLending {
    bytes32 internal constant LENDING_STORAGE_POSITION = keccak256("statics.storage.lending");
    uint40 internal constant RECOVERY_GRACE_PERIOD = 1 hours;
    uint16 internal constant MAX_LTV_BPS = 9_500;

    struct Loan {
        uint256 positionId;
        uint256 basketId;
        uint256 collateralShares;
        uint256 feeShares;
        uint40 maturity;
    }

    struct LendingStorage {
        uint256 nextLoanId;
        mapping(uint256 loanId => Loan) loans;
        mapping(uint256 loanId => mapping(address asset => uint256 amount)) principals;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) outstandingPrincipal;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) recoverySurplus;
    }

    function lendingStorage() internal pure returns (LendingStorage storage ls) {
        bytes32 position = LENDING_STORAGE_POSITION;
        assembly ("memory-safe") {
            ls.slot := position
        }
    }
}
