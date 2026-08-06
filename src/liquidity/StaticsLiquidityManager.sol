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

    error OnlyStaticsDiamond(address caller);
    error CanonicalPoolAlreadyRegistered(uint256 basketId, address asset);
    error CanonicalPoolNotRegistered(uint256 basketId, address asset);
    error CanonicalPoolMismatch(uint256 basketId, address asset);
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
        movement = _executePosition(request, Actions.MINT_POSITION, 0, recipient);
        uint256 allocatedRefund0 = request.amount0Limit - movement.spent0 + movement.received0;
        uint256 allocatedRefund1 = request.amount1Limit - movement.spent1 + movement.received1;
        (, refund0) = _refundUser(token0, refundRecipient, allocatedRefund0);
        (, refund1) = _refundUser(token1, refundRecipient, allocatedRefund1);
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

    function increaseUserPosition(PositionRequest calldata request, uint256 tokenId, address refundRecipient)
        external
        nonReentrant
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1)
    {
        _enforceDiamond();
        if (refundRecipient == address(0)) revert InvalidRecipient();
        _validateRequest(request);
        address actualOwner = IERC721(positionManager).ownerOf(tokenId);
        if (actualOwner != staticsDiamond) {
            revert PositionOwnershipMismatch(tokenId, staticsDiamond, actualOwner);
        }
        PoolKey memory actualKey = _positionKey(request.basketId, request.asset, tokenId);
        if (keccak256(abi.encode(actualKey)) != keccak256(abi.encode(request.poolKey))) {
            revert CanonicalPoolMismatch(request.basketId, request.asset);
        }
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        movement = _executePosition(request, Actions.INCREASE_LIQUIDITY, tokenId, staticsDiamond);
        uint256 allocatedRefund0 = request.amount0Limit - movement.spent0 + movement.received0;
        uint256 allocatedRefund1 = request.amount1Limit - movement.spent1 + movement.received1;
        (, refund0) = _refundUser(token0, refundRecipient, allocatedRefund0);
        (, refund1) = _refundUser(token1, refundRecipient, allocatedRefund1);
        emit UserPositionIncreased(
            request.basketId,
            request.asset,
            tokenId,
            refundRecipient,
            request.liquidity,
            movement.spent0,
            movement.spent1,
            refund0,
            refund1
        );
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

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
