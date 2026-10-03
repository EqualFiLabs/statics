// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IVenueController} from "../interfaces/IVenueController.sol";

/// @notice Minimal creator-operated permission source shipped with Statics.
/// @dev Alternative controllers may use attestations, Merkle proofs, or external registries while
/// preserving the same read interface.
contract DefaultVenueController is IVenueController, IERC165 {
    uint256 public constant SWAP_ALLOWED = 1 << 0;
    uint256 public constant LIQUIDITY_ALLOWED = 1 << 1;
    uint256 public constant ALL_PERMISSIONS = SWAP_ALLOWED | LIQUIDITY_ALLOWED;

    address public override operator;
    address public pendingOperator;

    mapping(PoolId poolId => mapping(address account => uint256 flags)) private accountPermissions;
    mapping(address asset => TradingStatus status) private assetStatuses;
    mapping(PoolId poolId => TradingStatus status) private poolStatuses;

    error InvalidOperator(address operator);
    error OnlyOperator(address caller);
    error OnlyPendingOperator(address caller);
    error InvalidArrayLength();
    error InvalidPermissionFlags(uint256 flags);
    error InvalidAsset(address asset);

    event OperatorTransferStarted(address indexed currentOperator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event PermissionsSet(PoolId indexed poolId, address indexed account, uint256 flags);
    event AssetStatusSet(address indexed asset, TradingStatus status);
    event PoolStatusSet(PoolId indexed poolId, TradingStatus status);

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator(msg.sender);
        _;
    }

    constructor(address initialOperator) {
        if (initialOperator == address(0)) revert InvalidOperator(initialOperator);
        operator = initialOperator;
        emit OperatorTransferred(address(0), initialOperator);
    }

    function startOperatorTransfer(address nextOperator) external onlyOperator {
        if (nextOperator == address(0)) revert InvalidOperator(nextOperator);
        pendingOperator = nextOperator;
        emit OperatorTransferStarted(operator, nextOperator);
    }

    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert OnlyPendingOperator(msg.sender);
        address previous = operator;
        operator = msg.sender;
        pendingOperator = address(0);
        emit OperatorTransferred(previous, msg.sender);
    }

    function setPermissions(PoolId poolId, address[] calldata accounts, uint256[] calldata flags)
        external
        onlyOperator
    {
        uint256 length = accounts.length;
        if (length == 0 || length != flags.length) revert InvalidArrayLength();
        for (uint256 i; i < length; ++i) {
            if (accounts[i] == address(0)) revert InvalidOperator(accounts[i]);
            if (flags[i] & ~ALL_PERMISSIONS != 0) revert InvalidPermissionFlags(flags[i]);
            accountPermissions[poolId][accounts[i]] = flags[i];
            emit PermissionsSet(poolId, accounts[i], flags[i]);
        }
    }

    function setAssetStatus(address asset, TradingStatus status) external onlyOperator {
        if (asset == address(0)) revert InvalidAsset(asset);
        assetStatuses[asset] = status;
        emit AssetStatusSet(asset, status);
    }

    function setPoolStatus(PoolId poolId, TradingStatus status) external onlyOperator {
        poolStatuses[poolId] = status;
        emit PoolStatusSet(poolId, status);
    }

    function permissions(PoolId poolId, address account) external view returns (uint256 flags) {
        return accountPermissions[poolId][account];
    }

    function assetStatus(address asset) external view returns (TradingStatus status) {
        return assetStatuses[asset];
    }

    function poolStatus(PoolId poolId) external view returns (TradingStatus status) {
        return poolStatuses[poolId];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVenueController).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
