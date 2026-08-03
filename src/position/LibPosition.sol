// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";

library LibPosition {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.position.storage.v1");
    bytes32 internal constant DOLLAR_MODULE = keccak256("statics.position.module.dollar");
    bytes32 internal constant BASKET_MODULE = keccak256("statics.position.module.basket");
    bytes32 internal constant STAKING_MODULE = keccak256("statics.position.module.staking");
    bytes32 internal constant LIQUIDITY_MODULE = keccak256("statics.position.module.liquidity");

    /// @dev Fits in one storage word. Public reporting widens each integer to uint256.
    struct PackedPositionState {
        uint64 stateNonce;
        uint64 activeLegCount;
        uint64 unresolvedObligationCount;
        bool initializing;
    }

    struct PositionStorage {
        uint256 nextPositionId;
        bool initialized;
        // Reserved legacy slots. Fresh deployments use `state` below.
        mapping(uint256 positionId => uint256 count) activeLegCount;
        mapping(uint256 positionId => bool initializing) positionInitializing;
        mapping(uint256 positionId => mapping(bytes32 legKey => bool active)) activeLeg;
        uint256 creationFeeAmount;
        mapping(uint256 positionId => PackedPositionState value) state;
        address renderer;
    }

    error AlreadyInitialized();
    error NotInitialized();
    error NotPositionOwnerOrApproved(uint256 positionId, address caller);
    error InvalidModuleAuthority();
    error InvalidModuleType();
    error PositionLegAlreadyActive(uint256 positionId, bytes32 legKey);
    error PositionLegNotActive(uint256 positionId, bytes32 legKey);
    error NoUnresolvedPositionObligation(uint256 positionId);

    function positionStorage() internal pure returns (PositionStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            ps.slot := slot
        }
    }

    function initialize(uint256 creationFeeAmount, address renderer) internal {
        PositionStorage storage ps = positionStorage();
        if (ps.initialized) revert AlreadyInitialized();
        ps.nextPositionId = 1;
        ps.creationFeeAmount = creationFeeAmount;
        ps.renderer = renderer;
        ps.initialized = true;
    }

    function allocatePositionId() internal returns (uint256 positionId) {
        PositionStorage storage ps = positionStorage();
        if (!ps.initialized) revert NotInitialized();
        positionId = ps.nextPositionId++;
        PackedPositionState storage state = ps.state[positionId];
        state.stateNonce = 1;
        state.initializing = true;
    }

    function finishInitialization(uint256 positionId) internal {
        positionStorage().state[positionId].initializing = false;
    }

    function legKey(address moduleAuthority, bytes32 moduleType, bytes32 localPositionId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(moduleAuthority, moduleType, localPositionId));
    }

    function legKey(bytes32 moduleType, bytes32 localPositionId) internal view returns (bytes32) {
        return legKey(address(this), moduleType, localPositionId);
    }

    function dollarLegKey(uint256 seriesId) internal view returns (bytes32) {
        return legKey(DOLLAR_MODULE, bytes32(seriesId));
    }

    function dollarLegKey(address moduleAuthority, uint256 seriesId) internal pure returns (bytes32) {
        return legKey(moduleAuthority, DOLLAR_MODULE, bytes32(seriesId));
    }

    function basketLegKey(uint256 basketId) internal view returns (bytes32) {
        return legKey(BASKET_MODULE, bytes32(basketId));
    }

    function basketLegKey(address moduleAuthority, uint256 basketId) internal pure returns (bytes32) {
        return legKey(moduleAuthority, BASKET_MODULE, bytes32(basketId));
    }

    function stakingLegKey() internal view returns (bytes32) {
        return legKey(STAKING_MODULE, bytes32(uint256(1)));
    }

    function stakingLegKey(address moduleAuthority) internal pure returns (bytes32) {
        return legKey(moduleAuthority, STAKING_MODULE, bytes32(uint256(1)));
    }

    function liquidityLegKey() internal view returns (bytes32) {
        return legKey(LIQUIDITY_MODULE, bytes32(uint256(1)));
    }

    function liquidityLegKey(address moduleAuthority) internal pure returns (bytes32) {
        return legKey(moduleAuthority, LIQUIDITY_MODULE, bytes32(uint256(1)));
    }

    function activateLeg(uint256 positionId, bytes32 moduleType, bytes32 localPositionId)
        internal
        returns (bytes32 key)
    {
        address moduleAuthority = address(this);
        if (moduleAuthority == address(0)) revert InvalidModuleAuthority();
        if (moduleType == bytes32(0)) revert InvalidModuleType();
        IERC721(address(this)).ownerOf(positionId);
        key = legKey(moduleAuthority, moduleType, localPositionId);
        PositionStorage storage ps = positionStorage();
        if (ps.activeLeg[positionId][key]) revert PositionLegAlreadyActive(positionId, key);
        ps.activeLeg[positionId][key] = true;
        PackedPositionState storage state = ps.state[positionId];
        ++state.activeLegCount;
        uint256 nonce = ++state.stateNonce;
        emit IModularPositionNFT.PositionLegAttached(
            positionId, key, moduleAuthority, moduleType, localPositionId, nonce
        );
        emitStateChanged(positionId);
    }

    function deactivateLeg(uint256 positionId, bytes32 key) internal {
        PositionStorage storage ps = positionStorage();
        if (!ps.activeLeg[positionId][key]) revert PositionLegNotActive(positionId, key);
        delete ps.activeLeg[positionId][key];
        PackedPositionState storage state = ps.state[positionId];
        --state.activeLegCount;
        uint256 nonce = ++state.stateNonce;
        emit IModularPositionNFT.PositionLegDetached(positionId, key, nonce);
        emitStateChanged(positionId);
    }

    function incrementObligation(uint256 positionId) internal {
        PackedPositionState storage state = positionStorage().state[positionId];
        ++state.unresolvedObligationCount;
        ++state.stateNonce;
        emitStateChanged(positionId);
    }

    function decrementObligation(uint256 positionId) internal {
        PackedPositionState storage state = positionStorage().state[positionId];
        if (state.unresolvedObligationCount == 0) revert NoUnresolvedPositionObligation(positionId);
        --state.unresolvedObligationCount;
        ++state.stateNonce;
        emitStateChanged(positionId);
    }

    function incrementNonce(uint256 positionId) internal {
        ++positionStorage().state[positionId].stateNonce;
    }

    function emitStateChanged(uint256 positionId) internal {
        PackedPositionState storage state = positionStorage().state[positionId];
        emit IModularPositionNFT.PositionStateChanged(
            positionId, state.stateNonce, state.activeLegCount, state.unresolvedObligationCount
        );
    }

    function isAuthorized(uint256 positionId, address actor) internal view returns (bool) {
        IERC721 nft = IERC721(address(this));
        address owner = nft.ownerOf(positionId);
        return actor != address(0)
            && (actor == owner || nft.getApproved(positionId) == actor || nft.isApprovedForAll(owner, actor));
    }

    function enforceAuthorized(uint256 positionId, address actor) internal view {
        if (!isAuthorized(positionId, actor)) revert NotPositionOwnerOrApproved(positionId, actor);
    }
}
