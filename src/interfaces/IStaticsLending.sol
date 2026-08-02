// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsLending {
    struct LoanView {
        uint256 positionId;
        uint256 basketId;
        uint256 collateralShares;
        uint256 feeShares;
        uint40 maturity;
        address[] assets;
        uint256[] principals;
    }

    event LoanOriginated(
        uint256 indexed loanId,
        uint256 indexed positionId,
        uint256 indexed basketId,
        address operator,
        address receiver,
        uint256 sharesIn,
        uint256 feeShares,
        uint256 collateralShares,
        uint40 maturity
    );
    event LoanRepaid(uint256 indexed loanId, uint256 indexed positionId, address indexed payer);
    event LoanExtended(uint256 indexed loanId, uint40 maturity);
    event LoanExtensionFeePaid(
        uint256 indexed loanId, address indexed asset, uint256 requiredFee, uint256 receivedFee
    );
    event LoanRecovered(
        uint256 indexed loanId, uint256 indexed positionId, address indexed caller, uint256 collateralShares
    );

    function borrow(uint256 positionId, uint256 basketId, uint256 sharesIn, address receiver)
        external
        returns (uint256 loanId, uint256[] memory principals);
    function repay(uint256 loanId) external;
    function extend(uint256 loanId, uint256[] calldata grossAmountsIn)
        external
        returns (uint256[] memory receivedAmounts);
    function recover(uint256 loanId) external;
    function quoteBorrow(uint256 basketId, uint256 sharesIn)
        external
        view
        returns (uint256 feeShares, uint256 collateralShares, address[] memory assets, uint256[] memory principals);
    function quoteExtension(uint256 loanId)
        external
        view
        returns (address[] memory assets, uint256[] memory requiredFees);
    function loan(uint256 loanId) external view returns (LoanView memory);
    function outstandingPrincipal(uint256 basketId, address asset) external view returns (uint256);
    function recoverySurplus(uint256 basketId, address asset) external view returns (uint256);
}
