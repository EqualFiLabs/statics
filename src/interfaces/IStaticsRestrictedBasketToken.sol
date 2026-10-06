// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Protocol-only, transaction-local settlement capabilities; allowances are independent.
interface IStaticsRestrictedBasketToken {
    function authorizeProtocolTransfer(address from, address to, uint256 amount) external;
    function authorizePoolSettlement(uint256 inbound, uint256 outbound) external;
    function authorizePoolClaim(address receiver, uint256 amount) external;
    function configureMorpho(address morpho) external;
    function authorizeMorphoIngress(uint256 amount) external;
    function settlementBudgets() external view returns (uint256 inbound, uint256 outbound);
}
