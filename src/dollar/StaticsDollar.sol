// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IStaticsDollar} from "./interfaces/IStaticsDollar.sol";

contract StaticsDollar is ERC20, ERC20Permit, IStaticsDollar {
    bytes32 internal constant TOKEN_KIND = keccak256("STATICS_DOLLAR_TOKEN_V1");

    address public immutable override pool;

    constructor(address pool_) ERC20("Statics Dollar", "etUSD") ERC20Permit("Statics Dollar") {
        if (pool_ == address(0)) revert ZeroAddress();
        pool = pool_;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function coreTokenKind() external pure override returns (bytes32) {
        return TOKEN_KIND;
    }

    function nonces(address owner) public view override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != pool) revert NotMinter(msg.sender);
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != pool) revert NotBurner(msg.sender);
        _burn(from, amount);
    }
}
