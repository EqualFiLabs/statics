// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsCustody} from "../interfaces/IStaticsCustody.sol";
import {LibCustody} from "../libraries/LibCustody.sol";

contract CustodyFacet is IStaticsCustody {
    function globalReservedByToken(address token) external view returns (uint256) {
        return LibCustody.globalReserved(token);
    }

    function reservedByAccount(bytes32 account, address token) external view returns (uint256) {
        return LibCustody.accountReserved(account, token);
    }

    function unreservedBalance(address token) external view returns (uint256) {
        return LibCustody.unreservedBalance(token);
    }

    function dollarCustodyAccount() external pure returns (bytes32) {
        return LibCustody.dollarAccount();
    }

    function basketCustodyAccount(uint256 basketId) external pure returns (bytes32) {
        return LibCustody.basketAccount(basketId);
    }

    function feeCustodyAccount() external pure returns (bytes32) {
        return LibCustody.feeAccount();
    }

    function stakingCustodyAccount() external pure returns (bytes32) {
        return LibCustody.stakingAccount();
    }
}
