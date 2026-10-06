// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Narrow V2 interfaces matching the published Pons factory and verified fee escrow.
/// @dev The escrow aggregates credits per recipient, not per launch. Only realized quote receipts are funding.
interface IPonsRevenueFactory {
    struct Launch {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (Launch memory);
    function feeEscrow() external view returns (address);
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

interface IPonsRevenueEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
    function claim(uint256 amount) external returns (uint256);
    function claimToken(address token, uint256 amount) external returns (uint256);
}

interface IPonsRevenueCurve {
    function factory() external view returns (address);
    function token() external view returns (address);
    function pairToken() external view returns (address);
    function feeEscrow() external view returns (address);
}
