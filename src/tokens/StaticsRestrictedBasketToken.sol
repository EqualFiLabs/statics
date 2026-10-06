// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IStaticsRestrictedBasketToken} from "../interfaces/IStaticsRestrictedBasketToken.sol";
import {StaticsBasketToken} from "./StaticsBasketToken.sol";

/// @notice V2 token. V1 BasketToken bytecode and deployed transfer semantics are unchanged.
/// @dev Budgets constrain actual ERC-20 movement, not internally netted PoolManager operations.
contract StaticsRestrictedBasketToken is StaticsBasketToken, IStaticsRestrictedBasketToken {
    using TransientSlot for *;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant TRANSFER_DOMAIN = keccak256("statics.basket.protocol.transfer.v1");
    bytes32 private constant INBOUND_SLOT = keccak256("statics.basket.pool.inbound.v1");
    bytes32 private constant OUTBOUND_SLOT = keccak256("statics.basket.pool.outbound.v1");
    bytes32 private constant MORPHO_SLOT = keccak256("statics.basket.morpho.ingress.v1");

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;
    address public morpho;

    error InvalidSettlementAuthority(address authority);
    error TransferNotAuthorized(address from, address to, uint256 amount);
    error AuthorizationAlreadyPending(address from, address to, uint256 amount);
    error PoolManagerLocked();
    error SettlementBudgetExceeded(bool inbound, uint256 requested, uint256 available);
    error MorphoAlreadyConfigured(address morpho);

    event MorphoConfigured(address indexed morpho);

    constructor(string memory name, string memory symbol, address protocol_, uint256 basketId_, IPoolManager manager)
        StaticsBasketToken(name, symbol, protocol_, basketId_)
    {
        if (protocol_ == address(0) || address(manager) == address(0) || address(manager) == protocol_) {
            revert InvalidSettlementAuthority(address(manager));
        }
        poolManager = manager;
    }

    modifier onlyProtocol() {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        _;
    }

    /// @dev No wildcard endpoints or amounts. Consumption happens before the balance update.
    function authorizeProtocolTransfer(address from, address to, uint256 amount) external onlyProtocol {
        if (
            from == address(0) || to == address(0) || (from != protocol && to != protocol)
                || from == address(poolManager) || to == address(poolManager)
                || (morpho != address(0) && (from == morpho || to == morpho))
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

    /// @dev Set once when the protocol binds a tracked market; outbound liquidation has no Diamond callback.
    function configureMorpho(address morpho_) external onlyProtocol {
        if (morpho != address(0)) revert MorphoAlreadyConfigured(morpho);
        if (morpho_ == address(0) || morpho_ == protocol || morpho_ == address(poolManager) || morpho_.code.length == 0)
        {
            revert InvalidSettlementAuthority(morpho_);
        }
        morpho = morpho_;
        emit MorphoConfigured(morpho_);
    }

    /// @dev Ingress is always pulled by configured Morpho from Diamond custody, never a user/account directly.
    function authorizeMorphoIngress(uint256 amount) external onlyProtocol {
        if (morpho == address(0)) revert InvalidSettlementAuthority(address(0));
        bytes32 slot = keccak256(abi.encode(MORPHO_SLOT, amount));
        if (slot.asBoolean().tload()) revert AuthorizationAlreadyPending(protocol, morpho, amount);
        slot.asBoolean().tstore(true);
    }

    function settlementBudgets() external view returns (uint256 inbound, uint256 outbound) {
        return (INBOUND_SLOT.asUint256().tload(), OUTBOUND_SLOT.asUint256().tload());
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Only inherited protocol-only mint/burn entrypoints can reach these cases.
        if (from != address(0) && to != address(0)) {
            if (from == address(poolManager) || to == address(poolManager)) {
                if (!poolManager.isUnlocked()) revert PoolManagerLocked();
                if (from == to) revert TransferNotAuthorized(from, to, amount);
                bool inbound = to == address(poolManager);
                bytes32 slot = inbound ? INBOUND_SLOT : OUTBOUND_SLOT;
                uint256 available = slot.asUint256().tload();
                if (amount > available) revert SettlementBudgetExceeded(inbound, amount, available);
                slot.asUint256().tstore(available - amount);
            } else if (morpho != address(0) && from == morpho && msg.sender == morpho) {
                // Direct Morpho recall/liquidation must remain independent of Diamond dispatch.
            } else if (morpho != address(0) && to == morpho && from == protocol && msg.sender == morpho) {
                _consume(keccak256(abi.encode(MORPHO_SLOT, amount)), from, to, amount);
            } else {
                _consume(_transferSlot(from, to, amount), from, to, amount);
            }
        }
        super._update(from, to, amount);
    }

    function _consume(bytes32 slot, address from, address to, uint256 amount) private {
        if (!slot.asBoolean().tload()) revert TransferNotAuthorized(from, to, amount);
        slot.asBoolean().tstore(false);
    }

    function _transferSlot(address from, address to, uint256 amount) private pure returns (bytes32) {
        return keccak256(abi.encode(TRANSFER_DOMAIN, from, to, amount));
    }
}
