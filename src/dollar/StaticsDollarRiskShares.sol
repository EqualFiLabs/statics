// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {IStaticsDollarRiskShares} from "./interfaces/IStaticsDollarRiskShares.sol";

contract StaticsDollarRiskShares is ERC1155, IStaticsDollarRiskShares {
    bytes32 internal constant TOKEN_KIND = keccak256("STATICS_DOLLAR_RISK_V1");

    address public immutable override pool;
    string public constant override name = "Statics Dollar Risk Shares";
    string public constant override symbol = "ethLEV";

    constructor(address pool_, string memory uri_) ERC1155(uri_) {
        if (pool_ == address(0)) revert ZeroAddress();
        pool = pool_;
    }

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool(msg.sender);
        _;
    }

    function coreTokenKind() external pure override returns (bytes32) {
        return TOKEN_KIND;
    }

    function mint(address to, uint256 id, uint256 amount) external override onlyPool {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external override onlyPool {
        _burn(from, id, amount);
    }

    function batchMint(address to, uint256[] calldata ids, uint256[] calldata amounts) external override onlyPool {
        _mintBatch(to, ids, amounts, "");
    }

    function batchBurn(address from, uint256[] calldata ids, uint256[] calldata amounts) external override onlyPool {
        _burnBatch(from, ids, amounts);
    }
}
