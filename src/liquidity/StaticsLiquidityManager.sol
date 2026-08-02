// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";

contract StaticsLiquidityManager is IStaticsLiquidityManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable staticsDiamond;
    address public immutable positionManager;
    address public immutable poolManager;
    address public immutable permit2;

    mapping(uint256 basketId => mapping(address asset => bytes32 keyHash)) public canonicalPoolHash;
    mapping(uint256 basketId => mapping(address token => uint256 amount)) public protocolInventory;
    mapping(address token => uint256 amount) public totalProtocolInventory;
    mapping(uint256 basketId => mapping(address asset => uint256 tokenId)) public protocolPositionId;

    error OnlyStaticsDiamond(address caller);
    error CanonicalPoolAlreadyRegistered(uint256 basketId, address asset);
    error CanonicalPoolNotRegistered(uint256 basketId, address asset);
    error CanonicalPoolMismatch(uint256 basketId, address asset);
    error InsufficientUnaccountedInventory(address token, uint256 requested, uint256 available);
    error InsufficientProtocolInventory(uint256 basketId, address token, uint256 requested, uint256 available);
    error InventoryInsolvent(address token, uint256 inventory, uint256 balance);
    error PositionAlreadyExists(uint256 basketId, address asset, uint256 tokenId);
    error PositionNotFound(uint256 basketId, address asset);
    error InvalidRecipient();
    error InvalidPositionParameters();
    error AmountExceedsPermit2(uint256 amount);
    error DeadlineExceedsPermit2(uint256 deadline);
    error ExcessiveTokenDebit(address token, uint256 spent, uint256 maximum);
    error PositionOwnershipMismatch(uint256 tokenId, address expectedOwner, address actualOwner);

    constructor(address diamond, address positionManager_, address poolManager_, address permit2_) {
        staticsDiamond = diamond;
        positionManager = positionManager_;
        poolManager = poolManager_;
        permit2 = permit2_;
    }

    function registerCanonicalPool(uint256 basketId, address asset, PoolKey calldata key) external {
        _enforceDiamond();
        if (canonicalPoolHash[basketId][asset] != bytes32(0)) {
            revert CanonicalPoolAlreadyRegistered(basketId, asset);
        }
        bytes32 keyHash = keccak256(abi.encode(key));
        canonicalPoolHash[basketId][asset] = keyHash;
        emit CanonicalPoolRegistered(basketId, asset, keyHash);
    }

    function creditProtocolInventory(uint256 basketId, address token, uint256 amount) external {
        _enforceDiamond();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 accounted = totalProtocolInventory[token];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (amount > available) revert InsufficientUnaccountedInventory(token, amount, available);
        protocolInventory[basketId][token] += amount;
        totalProtocolInventory[token] = accounted + amount;
        emit ProtocolInventoryCredited(basketId, token, amount);
    }

    function mintProtocolPosition(PositionRequest calldata request)
        external
        nonReentrant
        returns (PositionMovement memory movement)
    {
        _enforceDiamond();
        _validateRequest(request);
        uint256 existing = protocolPositionId[request.basketId][request.asset];
        if (existing != 0) revert PositionAlreadyExists(request.basketId, request.asset, existing);
        movement = _modifyPosition(request, Actions.MINT_POSITION, 0, address(this));
        protocolPositionId[request.basketId][request.asset] = movement.tokenId;
        emit ProtocolPositionMinted(
            request.basketId, request.asset, movement.tokenId, request.liquidity, movement.spent0, movement.spent1
        );
    }

    function increaseProtocolPosition(PositionRequest calldata request)
        external
        nonReentrant
        returns (PositionMovement memory movement)
    {
        _enforceDiamond();
        _validateRequest(request);
        uint256 tokenId = _position(request.basketId, request.asset);
        movement = _modifyPosition(request, Actions.INCREASE_LIQUIDITY, tokenId, address(this));
        emit ProtocolPositionIncreased(
            request.basketId,
            request.asset,
            tokenId,
            request.liquidity,
            movement.spent0,
            movement.received0,
            movement.spent1,
            movement.received1
        );
    }

    function collectProtocolPosition(uint256 basketId, address asset, uint256 deadline)
        external
        nonReentrant
        returns (PositionMovement memory movement)
    {
        _enforceDiamond();
        uint256 tokenId = _position(basketId, asset);
        PoolKey memory key = _positionKey(basketId, asset, tokenId);
        movement = _decrease(basketId, asset, key, tokenId, 0, 0, 0, deadline);
        emit ProtocolPositionCollected(basketId, asset, tokenId, movement.received0, movement.received1);
    }

    function removeProtocolLiquidity(
        uint256 basketId,
        address asset,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (PositionMovement memory movement) {
        _enforceDiamond();
        uint256 tokenId = _position(basketId, asset);
        PoolKey memory key = _positionKey(basketId, asset, tokenId);
        movement = _decrease(basketId, asset, key, tokenId, liquidity, amount0Min, amount1Min, deadline);
        emit ProtocolPositionReduced(basketId, asset, tokenId, liquidity, movement.received0, movement.received1);
    }

    function burnProtocolPosition(
        uint256 basketId,
        address asset,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (PositionMovement memory movement) {
        _enforceDiamond();
        uint256 tokenId = _position(basketId, asset);
        PoolKey memory key = _positionKey(basketId, asset, tokenId);
        movement = _burnPosition(basketId, key, tokenId, amount0Min, amount1Min, deadline);
        delete protocolPositionId[basketId][asset];
        emit ProtocolPositionBurned(basketId, asset, tokenId, movement.received0, movement.received1);
    }

    function returnProtocolInventory(uint256 basketId, address token, uint256 amount)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        _enforceDiamond();
        uint256 available = protocolInventory[basketId][token];
        if (amount > available) revert InsufficientProtocolInventory(basketId, token, amount, available);
        uint256 managerBefore = IERC20(token).balanceOf(address(this));
        uint256 diamondBefore = IERC20(token).balanceOf(staticsDiamond);
        IERC20(token).safeTransfer(staticsDiamond, amount);
        uint256 managerAfter = IERC20(token).balanceOf(address(this));
        uint256 diamondAfter = IERC20(token).balanceOf(staticsDiamond);
        spent = managerBefore > managerAfter ? managerBefore - managerAfter : 0;
        received = diamondAfter > diamondBefore ? diamondAfter - diamondBefore : 0;
        if (spent > amount) revert ExcessiveTokenDebit(token, spent, amount);
        protocolInventory[basketId][token] = available - spent;
        totalProtocolInventory[token] -= spent;
        _enforceSolvent(token);
        emit ProtocolInventoryReturned(basketId, token, spent, received);
    }

    function transferProtocolPosition(uint256 basketId, address asset, address receiver)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        _enforceDiamond();
        if (receiver == address(0)) revert InvalidRecipient();
        tokenId = _position(basketId, asset);
        delete protocolPositionId[basketId][asset];
        IERC721(positionManager).safeTransferFrom(address(this), receiver, tokenId);
        emit ProtocolPositionTransferred(basketId, asset, tokenId, receiver);
    }

    function mintUserPosition(PositionRequest calldata request, address recipient, address refundRecipient)
        external
        nonReentrant
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1)
    {
        _enforceDiamond();
        if (recipient == address(0) || refundRecipient == address(0)) revert InvalidRecipient();
        _validateRequest(request);
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        _enforceUnaccounted(token0, request.amount0Limit);
        _enforceUnaccounted(token1, request.amount1Limit);

        movement = _executePosition(request, Actions.MINT_POSITION, 0, recipient);
        uint256 allocatedRefund0 = request.amount0Limit - movement.spent0 + movement.received0;
        uint256 allocatedRefund1 = request.amount1Limit - movement.spent1 + movement.received1;
        (, refund0) = _refundUser(token0, refundRecipient, allocatedRefund0);
        (, refund1) = _refundUser(token1, refundRecipient, allocatedRefund1);
        _enforceSolvent(token0);
        _enforceSolvent(token1);
        emit UserPositionMinted(
            request.basketId,
            request.asset,
            movement.tokenId,
            recipient,
            refundRecipient,
            movement.spent0,
            movement.spent1,
            refund0,
            refund1
        );
    }

    function _modifyPosition(PositionRequest calldata request, uint256 action, uint256 tokenId, address recipient)
        private
        returns (PositionMovement memory movement)
    {
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        _enforceInventory(request.basketId, token0, request.amount0Limit);
        _enforceInventory(request.basketId, token1, request.amount1Limit);
        movement = _executePosition(request, action, tokenId, recipient);
        _applyInventoryMovement(request.basketId, token0, movement.spent0, movement.received0);
        _applyInventoryMovement(request.basketId, token1, movement.spent1, movement.received1);
    }

    function _executePosition(PositionRequest calldata request, uint256 action, uint256 tokenId, address recipient)
        private
        returns (PositionMovement memory movement)
    {
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        _approve(token0, request.amount0Limit, request.deadline);
        _approve(token1, request.amount1Limit, request.deadline);

        movement.tokenId = action == Actions.MINT_POSITION ? IPositionManager(positionManager).nextTokenId() : tokenId;
        bytes memory actionParams = action == Actions.MINT_POSITION
            ? abi.encode(
                request.poolKey,
                request.tickLower,
                request.tickUpper,
                request.liquidity,
                uint128(request.amount0Limit),
                uint128(request.amount1Limit),
                recipient,
                bytes("")
            )
            : abi.encode(
                tokenId, request.liquidity, uint128(request.amount0Limit), uint128(request.amount1Limit), bytes("")
            );
        IPositionManager(positionManager)
            .modifyLiquidities(_closePlan(action, actionParams, request.poolKey), request.deadline);
        _clearApproval(token0);
        _clearApproval(token1);
        (movement.spent0, movement.received0) = _movement(token0, balance0Before);
        (movement.spent1, movement.received1) = _movement(token1, balance1Before);
        if (movement.spent0 > request.amount0Limit) {
            revert ExcessiveTokenDebit(token0, movement.spent0, request.amount0Limit);
        }
        if (movement.spent1 > request.amount1Limit) {
            revert ExcessiveTokenDebit(token1, movement.spent1, request.amount1Limit);
        }
        address actualOwner = IERC721(positionManager).ownerOf(movement.tokenId);
        if (actualOwner != recipient) revert PositionOwnershipMismatch(movement.tokenId, recipient, actualOwner);
    }

    function _decrease(
        uint256 basketId,
        address asset,
        PoolKey memory key,
        uint256 tokenId,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) private returns (PositionMovement memory movement) {
        if (amount0Min > type(uint128).max || amount1Min > type(uint128).max) {
            revert InvalidPositionParameters();
        }
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        bytes memory params = abi.encode(tokenId, liquidity, uint128(amount0Min), uint128(amount1Min), bytes(""));
        IPositionManager(positionManager)
            .modifyLiquidities(_closePlan(Actions.DECREASE_LIQUIDITY, params, key), deadline);
        movement.tokenId = tokenId;
        (movement.spent0, movement.received0) = _movement(token0, balance0Before);
        (movement.spent1, movement.received1) = _movement(token1, balance1Before);
        _applyInventoryMovement(basketId, token0, movement.spent0, movement.received0);
        _applyInventoryMovement(basketId, token1, movement.spent1, movement.received1);
        _enforcePool(basketId, asset, key);
    }

    function _burnPosition(
        uint256 basketId,
        PoolKey memory key,
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) private returns (PositionMovement memory movement) {
        if (amount0Min > type(uint128).max || amount1Min > type(uint128).max) {
            revert InvalidPositionParameters();
        }
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        bytes memory params = abi.encode(tokenId, uint128(amount0Min), uint128(amount1Min), bytes(""));
        IPositionManager(positionManager).modifyLiquidities(_closePlan(Actions.BURN_POSITION, params, key), deadline);
        movement.tokenId = tokenId;
        (movement.spent0, movement.received0) = _movement(token0, balance0Before);
        (movement.spent1, movement.received1) = _movement(token1, balance1Before);
        _applyInventoryMovement(basketId, token0, movement.spent0, movement.received0);
        _applyInventoryMovement(basketId, token1, movement.spent1, movement.received1);
    }

    function _positionKey(uint256 basketId, address asset, uint256 tokenId) private view returns (PoolKey memory key) {
        (key,) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        _enforcePool(basketId, asset, key);
    }

    function _closePlan(uint256 action, bytes memory actionParams, PoolKey memory key)
        private
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(action)), bytes1(uint8(Actions.CLOSE_CURRENCY)), bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = actionParams;
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        return abi.encode(actions, params);
    }

    function _approve(address token, uint256 amount, uint256 deadline) private {
        if (amount > type(uint160).max || amount > type(uint128).max) revert AmountExceedsPermit2(amount);
        if (deadline > type(uint48).max) revert DeadlineExceedsPermit2(deadline);
        IERC20(token).forceApprove(permit2, amount);
        IAllowanceTransfer(permit2).approve(token, positionManager, uint160(amount), uint48(deadline));
    }

    function _clearApproval(address token) private {
        IAllowanceTransfer(permit2).approve(token, positionManager, 0, 0);
        IERC20(token).forceApprove(permit2, 0);
    }

    function _movement(address token, uint256 balanceBefore) private view returns (uint256 spent, uint256 received) {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceBefore > balanceAfter) spent = balanceBefore - balanceAfter;
        else received = balanceAfter - balanceBefore;
    }

    function _applyInventoryMovement(uint256 basketId, address token, uint256 spent, uint256 received) private {
        uint256 available = protocolInventory[basketId][token];
        if (spent > available) revert InsufficientProtocolInventory(basketId, token, spent, available);
        protocolInventory[basketId][token] = available - spent + received;
        totalProtocolInventory[token] = totalProtocolInventory[token] - spent + received;
        _enforceSolvent(token);
    }

    function _refundUser(address token, address receiver, uint256 amount)
        private
        returns (uint256 spent, uint256 received)
    {
        if (amount == 0) return (0, 0);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        IERC20(token).safeTransfer(receiver, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 receiverAfter = IERC20(token).balanceOf(receiver);
        spent = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        received = receiverAfter > receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent > amount) revert ExcessiveTokenDebit(token, spent, amount);
    }

    function _validateRequest(PositionRequest calldata request) private view {
        _enforcePool(request.basketId, request.asset, request.poolKey);
        if (
            request.liquidity == 0 || request.tickLower >= request.tickUpper || request.deadline < block.timestamp
                || request.amount0Limit > type(uint128).max || request.amount1Limit > type(uint128).max
        ) revert InvalidPositionParameters();
    }

    function _enforcePool(uint256 basketId, address asset, PoolKey memory key) private view {
        bytes32 expected = canonicalPoolHash[basketId][asset];
        if (expected == bytes32(0)) revert CanonicalPoolNotRegistered(basketId, asset);
        if (expected != keccak256(abi.encode(key))) revert CanonicalPoolMismatch(basketId, asset);
    }

    function _position(uint256 basketId, address asset) private view returns (uint256 tokenId) {
        tokenId = protocolPositionId[basketId][asset];
        if (tokenId == 0) revert PositionNotFound(basketId, asset);
    }

    function _enforceInventory(uint256 basketId, address token, uint256 amount) private view {
        uint256 available = protocolInventory[basketId][token];
        if (amount > available) revert InsufficientProtocolInventory(basketId, token, amount, available);
    }

    function _enforceUnaccounted(address token, uint256 amount) private view {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 accounted = totalProtocolInventory[token];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (amount > available) revert InsufficientUnaccountedInventory(token, amount, available);
    }

    function _enforceSolvent(address token) private view {
        uint256 inventory = totalProtocolInventory[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (inventory > balance) revert InventoryInsolvent(token, inventory, balance);
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
