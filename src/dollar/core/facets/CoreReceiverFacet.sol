// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

/// @notice Core ERC-1155 receiver surface. Transition facets add expected-ingress
/// records before enabling any receipt; unsolicited transfers always fail closed.
contract CoreReceiverFacet {
    error UnexpectedRiskIngress(address operator, address from, uint256 id, uint256 amount);
    error UnexpectedRiskBatchIngress(address operator, address from);

    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata)
        external
        returns (bytes4)
    {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        LibCoreStorage.ExpectedRiskIngress memory expected = cs.expectedRiskIngress;
        if (
            msg.sender != cs.staticsDollarRisk || operator != address(this) || !expected.active || from != expected.from
                || id != expected.seriesId || amount != expected.amount
        ) revert UnexpectedRiskIngress(operator, from, id, amount);
        delete cs.expectedRiskIngress;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnexpectedRiskBatchIngress(operator, from);
    }
}
