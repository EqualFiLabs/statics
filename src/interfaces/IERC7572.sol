// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice ERC-7572 contract-level metadata discovery.
interface IERC7572 is IERC165 {
    event ContractURIUpdated();

    function contractURI() external view returns (string memory);
}
