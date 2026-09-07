// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Stateless helper that redeems PoolManager ERC-6909 fee claims for their underlying currency.
/// @dev A claim owner must first authorize this contract as an operator or grant a per-currency allowance.
contract StaticsLaunchFeeClaimRedeemer is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct Redemption {
        address owner;
        Currency currency;
        uint256 amount;
        address recipient;
    }

    error InvalidPoolManager(address manager);
    error InvalidRecipient(address recipient);
    error ZeroAmount();
    error UnauthorizedCallback(address sender);

    event ClaimsRedeemed(address indexed owner, Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0) || address(manager).code.length == 0) {
            revert InvalidPoolManager(address(manager));
        }
        poolManager = manager;
    }

    function redeem(Currency currency, uint256 amount, address recipient) external {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        poolManager.unlock(abi.encode(Redemption(msg.sender, currency, amount, recipient)));
        emit ClaimsRedeemed(msg.sender, currency, recipient, amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback(msg.sender);
        Redemption memory redemption = abi.decode(data, (Redemption));
        poolManager.burn(redemption.owner, redemption.currency.toId(), redemption.amount);
        poolManager.take(redemption.currency, redemption.recipient, redemption.amount);
        return bytes("");
    }
}
