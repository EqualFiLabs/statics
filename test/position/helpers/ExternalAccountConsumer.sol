// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaticsExternalModules} from "../../../src/interfaces/IStaticsExternalModules.sol";

/// @dev Funded lifecycle fixture; each product implements its own accounting and emptiness checks.
contract ExternalAccountConsumer {
    using SafeERC20 for IERC20;
    bytes32 public constant MODULE = keccak256("test.external.account");
    IStaticsExternalModules public immutable core;
    IERC20 public immutable token;
    mapping(uint256 => uint256) public balance;
    mapping(uint256 => bool) public attached;

    constructor(address core_, IERC20 token_) {
        core = IStaticsExternalModules(core_);
        token = token_;
    }

    modifier owner(uint256 id) {
        require(IERC721(address(core)).ownerOf(id) == msg.sender, "owner");
        _;
    }

    function deposit(uint256 id, uint256 amount) external owner(id) {
        // Pull first to prove a failed attachment rolls custody back with the financial state.
        token.safeTransferFrom(msg.sender, address(this), amount);
        balance[id] += amount;
        if (!attached[id]) {
            core.attachExternalAccountLeg(id, MODULE, bytes32(id));
            attached[id] = true;
        }
    }

    function withdraw(uint256 id, uint256 amount) external owner(id) {
        balance[id] -= amount;
        token.safeTransfer(msg.sender, amount);
    }

    function cleanup(uint256 id) external owner(id) {
        require(balance[id] == 0, "occupied");
        attached[id] = false;
        core.detachExternalAccountLeg(id, MODULE, bytes32(id));
    }
}
