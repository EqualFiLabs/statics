// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IStaticsDollar is IERC20, IERC20Permit {
    error NotMinter(address caller);
    error NotBurner(address caller);
    error ZeroAddress();

    function coreTokenKind() external pure returns (bytes32);

    function pool() external view returns (address);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}
