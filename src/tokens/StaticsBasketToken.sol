// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IStaticsBasketToken} from "../interfaces/IStaticsBasketToken.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Basket shares with governed distributor transfers and exact protocol settlement.
/// @dev Budgets constrain actual ERC-20 movement, not internally netted PoolManager operations.
contract StaticsBasketToken is ERC20, ERC20Permit, IStaticsBasketToken {
    using TransientSlot for *;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant TRANSFER_DOMAIN = keccak256("statics.basket.protocol.transfer");
    bytes32 private constant INBOUND_SLOT = keccak256("statics.basket.pool.inbound");
    bytes32 private constant OUTBOUND_SLOT = keccak256("statics.basket.pool.outbound");
    bytes32 private constant CLAIM_DOMAIN = keccak256("statics.basket.pool.claim");

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable protocol;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable basketId;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    error OnlyProtocol(address caller);
    error InvalidSettlementAuthority(address authority);
    error TransferNotAuthorized(address from, address to, uint256 amount);
    error AuthorizationAlreadyPending(address from, address to, uint256 amount);
    error PoolManagerLocked();
    error SettlementBudgetExceeded(bool inbound, uint256 requested, uint256 available);

    constructor(string memory name, string memory symbol, address protocol_, uint256 basketId_, IPoolManager manager)
        ERC20(name, symbol)
        ERC20Permit(name)
    {
        if (protocol_ == address(0) || address(manager) == address(0) || address(manager) == protocol_) {
            revert InvalidSettlementAuthority(address(manager));
        }
        protocol = protocol_;
        basketId = basketId_;
        poolManager = manager;
    }

    modifier onlyProtocol() {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        _;
    }

    function mint(address receiver, uint256 shares) external onlyProtocol {
        _mint(receiver, shares);
    }

    function burn(address owner, uint256 shares) external onlyProtocol {
        _burn(owner, shares);
    }

    /// @dev No wildcard endpoints or amounts. Consumption happens before the balance update.
    function authorizeProtocolTransfer(address from, address to, uint256 amount) external onlyProtocol {
        if (
            from == address(0) || to == address(0) || (from != protocol && to != protocol)
                || from == address(poolManager) || to == address(poolManager)
        ) revert TransferNotAuthorized(from, to, amount);
        bytes32 slot = _transferSlot(from, to, amount);
        if (slot.asBoolean().tload()) revert AuthorizationAlreadyPending(from, to, amount);
        slot.asBoolean().tstore(true);
    }

    /// @dev The Diamond authenticates the registered pool hook and final delta before granting.
    function authorizePoolSettlement(uint256 inbound, uint256 outbound) external onlyProtocol {
        if (!poolManager.isUnlocked()) revert PoolManagerLocked();
        INBOUND_SLOT.asUint256().tstore(INBOUND_SLOT.asUint256().tload() + inbound);
        OUTBOUND_SLOT.asUint256().tstore(OUTBOUND_SLOT.asUint256().tload() + outbound);
    }

    function authorizePoolClaim(address receiver, uint256 amount) external onlyProtocol {
        if (!poolManager.isUnlocked()) revert PoolManagerLocked();
        if (receiver == address(0) || receiver == address(poolManager)) {
            revert TransferNotAuthorized(address(poolManager), receiver, amount);
        }
        bytes32 slot = _claimSlot(receiver, amount);
        if (slot.asBoolean().tload()) revert AuthorizationAlreadyPending(address(poolManager), receiver, amount);
        slot.asBoolean().tstore(true);
    }

    function settlementBudgets() external view returns (uint256 inbound, uint256 outbound) {
        return (INBOUND_SLOT.asUint256().tload(), OUTBOUND_SLOT.asUint256().tload());
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Only the protocol mint/burn entrypoints can reach these cases.
        if (from != address(0) && to != address(0)) {
            if (from == address(poolManager) || to == address(poolManager)) {
                if (!poolManager.isUnlocked()) revert PoolManagerLocked();
                if (from == to) revert TransferNotAuthorized(from, to, amount);
                if (from == address(poolManager) && msg.sender != address(poolManager)) {
                    revert TransferNotAuthorized(from, to, amount);
                }
                bool inbound = to == address(poolManager);
                bytes32 claimSlot = _claimSlot(to, amount);
                if (!inbound && claimSlot.asBoolean().tload()) {
                    claimSlot.asBoolean().tstore(false);
                } else {
                    bytes32 slot = inbound ? INBOUND_SLOT : OUTBOUND_SLOT;
                    uint256 available = slot.asUint256().tload();
                    if (amount > available) revert SettlementBudgetExceeded(inbound, amount, available);
                    slot.asUint256().tstore(available - amount);
                }
            } else {
                bytes32 slot = _transferSlot(from, to, amount);
                if (slot.asBoolean().tload()) {
                    // Consume exact tickets even when a distributor could authorize the transfer.
                    slot.asBoolean().tstore(false);
                } else if (
                    IStaticsBasket(protocol).basketStatus(basketId) == IStaticsBasket.BasketStatus.Pending
                        || (!IStaticsBasketAdmin(protocol).isBasketDistributor(from)
                            && !IStaticsBasketAdmin(protocol).isBasketDistributor(to))
                ) {
                    revert TransferNotAuthorized(from, to, amount);
                }
            }
        }
        super._update(from, to, amount);
    }

    function _transferSlot(address from, address to, uint256 amount) private pure returns (bytes32) {
        return keccak256(abi.encode(TRANSFER_DOMAIN, from, to, amount));
    }

    function _claimSlot(address receiver, uint256 amount) private pure returns (bytes32) {
        return keccak256(abi.encode(CLAIM_DOMAIN, receiver, amount));
    }
}
