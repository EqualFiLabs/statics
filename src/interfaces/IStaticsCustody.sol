// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsCustody {
    function globalReservedByToken(address token) external view returns (uint256);

    function reservedByAccount(bytes32 account, address token) external view returns (uint256);

    function unreservedBalance(address token) external view returns (uint256);

    function dollarCustodyAccount() external pure returns (bytes32);

    function basketCustodyAccount(uint256 basketId) external pure returns (bytes32);

    function feeCustodyAccount() external pure returns (bytes32);

    function stakingCustodyAccount() external pure returns (bytes32);

    function genesisRewardCustodyAccount() external pure returns (bytes32);
}
