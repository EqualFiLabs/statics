// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";

interface IRangeGaugeBindingView {
    function posmBinding(uint256 posmTokenId) external view returns (bytes32 binding);
}

contract StaticsLiquidityManager is IStaticsLiquidityManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    address public immutable staticsDiamond;
    address public immutable positionManager;
    address public immutable poolManager;
    address public immutable permit2;

    error OnlyStaticsDiamond(address caller);
    error InvalidBinding(address target);
    error ProtocolPoolNotRegistered(bytes32 poolId);
    error ProtocolPoolMismatch(bytes32 poolId);
    error ProtocolPoolDecommissioned(bytes32 poolId);
    error PublicProtocolPoolRequired(bytes32 poolId);
    error InvalidRecipient();
    error InvalidPositionParameters();
    error AmountExceedsPermit2(uint256 amount);
    error DeadlineExceedsPermit2(uint256 deadline);
    error ExcessiveTokenDebit(address token, uint256 spent, uint256 maximum);
    error InexactTokenDebit(address token, uint256 expected, uint256 actual);
    error InsufficientTokenOutput(address token, uint256 minimum, uint256 actual);
    error UnexpectedTokenDebit(address token, uint256 beforeBalance, uint256 afterBalance);
    error PositionOwnershipMismatch(uint256 tokenId, address expectedOwner, address actualOwner);
    error PositionPoolMismatch(uint256 tokenId, bytes32 expectedPoolId, bytes32 actualPoolId);
    error PositionRangeMismatch(uint256 tokenId);
    error PositionLiquidityMismatch(uint256 tokenId, uint128 expected, uint128 actual);
    error PositionSubscriberNotCleared(uint256 tokenId, address subscriber);
    error PositionStillExists(uint256 tokenId);
    error BoundPositionRecovery(uint256 tokenId, bytes32 binding);

    constructor(address diamond, address positionManager_, address poolManager_, address permit2_) {
        if (
            diamond == address(0) || positionManager_ == address(0) || poolManager_ == address(0)
                || permit2_ == address(0)
        ) revert InvalidBinding(address(0));
        staticsDiamond = diamond;
        positionManager = positionManager_;
        poolManager = poolManager_;
        permit2 = permit2_;
    }

    function mintUserPosition(PositionRequest calldata request, address recipient, address refundRecipient)
        external
        nonReentrant
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1)
    {
        _enforceDiamond();
        _validateReceiver(recipient);
        _validateReceiver(refundRecipient);
        _validateMintRequest(request);
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        movement = _executeMint(request, recipient);
        (, refund0) = _refundUser(token0, refundRecipient, request.amount0Limit - movement.spent0 + movement.received0);
        (, refund1) = _refundUser(token1, refundRecipient, request.amount1Limit - movement.spent1 + movement.received1);
        emit UserPositionMinted(
            PoolId.unwrap(request.poolKey.toId()),
            movement.tokenId,
            recipient,
            refundRecipient,
            movement.spent0,
            movement.spent1,
            refund0,
            refund1
        );
    }

    function mintManagedPosition(PositionRequest calldata request, address refundRecipient)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateReceiver(refundRecipient);
        _validateMintRequest(request);
        PositionMovement memory minted = _executeMint(request, address(this));
        ManagedPositionState memory state = _managedState(minted.tokenId, true);
        _enforceExpectedPosition(
            minted.tokenId, state, request.poolKey, request.tickLower, request.tickUpper, request.liquidity
        );

        movement.tokenId = minted.tokenId;
        movement.liquidityAfter = state.liquidity;
        movement.spent0 = minted.spent0;
        movement.spent1 = minted.spent1;
        movement.received0 = minted.received0;
        movement.received1 = minted.received1;
        (, movement.refund0) = _refundUser(
            Currency.unwrap(request.poolKey.currency0),
            refundRecipient,
            request.amount0Limit - minted.spent0 + minted.received0
        );
        (, movement.refund1) = _refundUser(
            Currency.unwrap(request.poolKey.currency1),
            refundRecipient,
            request.amount1Limit - minted.spent1 + minted.received1
        );
        emit ManagedPositionMinted(PoolId.unwrap(state.poolId), minted.tokenId, state.liquidity);
    }

    function attachManagedPosition(address owner, PoolId expectedPoolId, uint256 tokenId)
        external
        nonReentrant
        returns (ManagedPositionState memory state)
    {
        _enforceDiamond();
        if (owner == address(0) || owner == address(this) || owner == staticsDiamond) revert InvalidRecipient();
        ManagedPositionState memory beforeState = _readPosition(tokenId);
        if (beforeState.owner != owner) revert PositionOwnershipMismatch(tokenId, owner, beforeState.owner);
        if (PoolId.unwrap(beforeState.poolId) != PoolId.unwrap(expectedPoolId)) {
            revert PositionPoolMismatch(tokenId, PoolId.unwrap(expectedPoolId), PoolId.unwrap(beforeState.poolId));
        }
        _enforcePublicPool(beforeState.poolKey, true);
        if (beforeState.liquidity == 0) revert InvalidPositionParameters();

        IERC721(positionManager).transferFrom(owner, address(this), tokenId);
        state = _readPosition(tokenId);
        if (state.owner != address(this)) revert PositionOwnershipMismatch(tokenId, address(this), state.owner);
        if (state.subscriber != address(0)) revert PositionSubscriberNotCleared(tokenId, state.subscriber);
        _enforceSamePosition(tokenId, beforeState, state);
        emit ManagedPositionAttached(PoolId.unwrap(state.poolId), tokenId, owner);
    }

    function inspectManagedPosition(uint256 tokenId) external view returns (ManagedPositionState memory state) {
        _enforceDiamond();
        state = _managedState(tokenId, false);
    }

    function increaseManagedPosition(ManagedLiquidityRequest calldata request)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateInputRequest(request);
        ManagedPositionState memory beforeState = _managedState(request.tokenId, true);
        address token0 = Currency.unwrap(beforeState.poolKey.currency0);
        address token1 = Currency.unwrap(beforeState.poolKey.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        _approve(token0, request.amount0Limit, request.deadline);
        _approve(token1, request.amount1Limit, request.deadline);
        IPositionManager(positionManager)
            .modifyLiquidities(
                _closePlan(
                    Actions.INCREASE_LIQUIDITY,
                    abi.encode(
                        request.tokenId,
                        uint256(request.liquidity),
                        uint128(request.amount0Limit),
                        uint128(request.amount1Limit),
                        bytes("")
                    ),
                    beforeState.poolKey
                ),
                request.deadline
            );
        _clearApproval(token0);
        _clearApproval(token1);

        (movement.spent0, movement.received0) = _movement(token0, balance0Before);
        (movement.spent1, movement.received1) = _movement(token1, balance1Before);
        _enforceMaximum(token0, movement.spent0, request.amount0Limit);
        _enforceMaximum(token1, movement.spent1, request.amount1Limit);
        (, movement.refund0) =
            _refundUser(token0, request.receiver, request.amount0Limit - movement.spent0 + movement.received0);
        (, movement.refund1) =
            _refundUser(token1, request.receiver, request.amount1Limit - movement.spent1 + movement.received1);

        ManagedPositionState memory afterState = _managedState(request.tokenId, true);
        _enforceSamePosition(request.tokenId, beforeState, afterState);
        uint128 expectedLiquidity = beforeState.liquidity + request.liquidity;
        if (afterState.liquidity != expectedLiquidity) {
            revert PositionLiquidityMismatch(request.tokenId, expectedLiquidity, afterState.liquidity);
        }
        movement.tokenId = request.tokenId;
        movement.liquidityBefore = beforeState.liquidity;
        movement.liquidityAfter = afterState.liquidity;
        emit ManagedPositionLiquidityChanged(
            PoolId.unwrap(afterState.poolId), request.tokenId, beforeState.liquidity, afterState.liquidity
        );
    }

    function decreaseManagedPosition(ManagedLiquidityRequest calldata request)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateOutputRequest(request, true);
        ManagedPositionState memory beforeState = _managedState(request.tokenId, false);
        if (request.liquidity > beforeState.liquidity) revert InvalidPositionParameters();
        movement = _executeOutputChange(beforeState, request, Actions.DECREASE_LIQUIDITY, request.liquidity, true);
        ManagedPositionState memory afterState = _managedState(request.tokenId, false);
        _enforceSamePosition(request.tokenId, beforeState, afterState);
        uint128 expectedLiquidity = beforeState.liquidity - request.liquidity;
        if (afterState.liquidity != expectedLiquidity) {
            revert PositionLiquidityMismatch(request.tokenId, expectedLiquidity, afterState.liquidity);
        }
        movement.liquidityAfter = afterState.liquidity;
        emit ManagedPositionLiquidityChanged(
            PoolId.unwrap(afterState.poolId), request.tokenId, beforeState.liquidity, afterState.liquidity
        );
    }

    function collectManagedPositionFees(ManagedLiquidityRequest calldata request)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateOutputRequest(request, false);
        ManagedPositionState memory beforeState = _managedState(request.tokenId, false);
        movement = _executeOutputChange(beforeState, request, Actions.DECREASE_LIQUIDITY, 0, false);
        ManagedPositionState memory afterState = _managedState(request.tokenId, false);
        _enforceSamePosition(request.tokenId, beforeState, afterState);
        if (afterState.liquidity != beforeState.liquidity) {
            revert PositionLiquidityMismatch(request.tokenId, beforeState.liquidity, afterState.liquidity);
        }
        movement.liquidityAfter = afterState.liquidity;
        emit ManagedPositionFeesCollected(
            PoolId.unwrap(afterState.poolId), request.tokenId, request.receiver, movement.received0, movement.received1
        );
    }

    function burnManagedPosition(ManagedLiquidityRequest calldata request)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateOutputRequest(request, false);
        ManagedPositionState memory beforeState = _managedState(request.tokenId, false);
        if (beforeState.liquidity != 0) {
            revert PositionLiquidityMismatch(request.tokenId, 0, beforeState.liquidity);
        }
        movement = _executeBurn(beforeState, request, false);
        emit ManagedPositionBurned(
            PoolId.unwrap(beforeState.poolId), request.tokenId, request.receiver, movement.received0, movement.received1
        );
    }

    function exitManagedPosition(ManagedLiquidityRequest calldata request)
        external
        nonReentrant
        returns (ManagedPositionMovement memory movement)
    {
        _enforceDiamond();
        _validateOutputRequest(request, false);
        ManagedPositionState memory beforeState = _managedState(request.tokenId, false);
        movement = _executeBurn(beforeState, request, true);
        emit ManagedPositionExited(
            PoolId.unwrap(beforeState.poolId), request.tokenId, request.receiver, movement.received0, movement.received1
        );
    }

    function recoverUnboundPosition(uint256 tokenId, address receiver) external nonReentrant {
        _enforceDiamond();
        _validateReceiver(receiver);
        bytes32 binding = IRangeGaugeBindingView(staticsDiamond).posmBinding(tokenId);
        if (binding != bytes32(0)) revert BoundPositionRecovery(tokenId, binding);
        address actualOwner = IERC721(positionManager).ownerOf(tokenId);
        if (actualOwner != address(this)) {
            revert PositionOwnershipMismatch(tokenId, address(this), actualOwner);
        }
        IERC721(positionManager).transferFrom(address(this), receiver, tokenId);
        actualOwner = IERC721(positionManager).ownerOf(tokenId);
        if (actualOwner != receiver) revert PositionOwnershipMismatch(tokenId, receiver, actualOwner);
        emit UnboundPositionRecovered(tokenId, receiver);
    }

    function _executeMint(PositionRequest calldata request, address recipient)
        private
        returns (PositionMovement memory movement)
    {
        address token0 = Currency.unwrap(request.poolKey.currency0);
        address token1 = Currency.unwrap(request.poolKey.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        _approve(token0, request.amount0Limit, request.deadline);
        _approve(token1, request.amount1Limit, request.deadline);

        movement.tokenId = IPositionManager(positionManager).nextTokenId();
        bytes memory actionParams = abi.encode(
            request.poolKey,
            request.tickLower,
            request.tickUpper,
            request.liquidity,
            uint128(request.amount0Limit),
            uint128(request.amount1Limit),
            recipient,
            bytes("")
        );
        IPositionManager(positionManager)
            .modifyLiquidities(_closePlan(Actions.MINT_POSITION, actionParams, request.poolKey), request.deadline);
        _clearApproval(token0);
        _clearApproval(token1);
        (movement.spent0, movement.received0) = _movement(token0, balance0Before);
        (movement.spent1, movement.received1) = _movement(token1, balance1Before);
        _enforceMaximum(token0, movement.spent0, request.amount0Limit);
        _enforceMaximum(token1, movement.spent1, request.amount1Limit);
        address actualOwner = IERC721(positionManager).ownerOf(movement.tokenId);
        if (actualOwner != recipient) revert PositionOwnershipMismatch(movement.tokenId, recipient, actualOwner);
    }

    function _executeOutputChange(
        ManagedPositionState memory beforeState,
        ManagedLiquidityRequest calldata request,
        uint256 action,
        uint128 liquidity,
        bool usePrincipalMinimums
    ) private returns (ManagedPositionMovement memory movement) {
        uint128 amount0Min = usePrincipalMinimums ? uint128(request.amount0Limit) : 0;
        uint128 amount1Min = usePrincipalMinimums ? uint128(request.amount1Limit) : 0;
        movement = _executeOutputPlan(
            beforeState,
            request,
            action,
            abi.encode(request.tokenId, uint256(liquidity), amount0Min, amount1Min, bytes(""))
        );
    }

    function _executeBurn(
        ManagedPositionState memory beforeState,
        ManagedLiquidityRequest calldata request,
        bool usePrincipalMinimums
    ) private returns (ManagedPositionMovement memory movement) {
        uint128 amount0Min = usePrincipalMinimums ? uint128(request.amount0Limit) : 0;
        uint128 amount1Min = usePrincipalMinimums ? uint128(request.amount1Limit) : 0;
        movement = _executeOutputPlan(
            beforeState, request, Actions.BURN_POSITION, abi.encode(request.tokenId, amount0Min, amount1Min, bytes(""))
        );
        _enforcePositionDestroyed(request.tokenId);
    }

    function _executeOutputPlan(
        ManagedPositionState memory beforeState,
        ManagedLiquidityRequest calldata request,
        uint256 action,
        bytes memory actionParams
    ) private returns (ManagedPositionMovement memory movement) {
        address token0 = Currency.unwrap(beforeState.poolKey.currency0);
        address token1 = Currency.unwrap(beforeState.poolKey.currency1);
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        IPositionManager(positionManager)
            .modifyLiquidities(_closePlan(action, actionParams, beforeState.poolKey), request.deadline);
        uint256 gross0 = _positiveMovement(token0, balance0Before);
        uint256 gross1 = _positiveMovement(token1, balance1Before);
        movement.received0 = _deliverOutput(token0, request.receiver, gross0, request.amount0Limit);
        movement.received1 = _deliverOutput(token1, request.receiver, gross1, request.amount1Limit);
        _enforceBaseline(token0, balance0Before);
        _enforceBaseline(token1, balance1Before);
        movement.tokenId = request.tokenId;
        movement.liquidityBefore = beforeState.liquidity;
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

    function _positiveMovement(address token, uint256 balanceBefore) private view returns (uint256 received) {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert UnexpectedTokenDebit(token, balanceBefore, balanceAfter);
        received = balanceAfter - balanceBefore;
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
        if (spent != amount) revert InexactTokenDebit(token, amount, spent);
    }

    function _deliverOutput(address token, address receiver, uint256 amount, uint256 minimum)
        private
        returns (uint256 received)
    {
        (, received) = _refundUser(token, receiver, amount);
        if (received < minimum) revert InsufficientTokenOutput(token, minimum, received);
    }

    function _enforceBaseline(address token, uint256 expected) private view {
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual != expected) revert InexactTokenDebit(token, expected, actual);
    }

    function _validateMintRequest(PositionRequest calldata request) private view {
        _enforcePublicPool(request.poolKey, true);
        if (
            request.liquidity == 0 || request.liquidity > type(uint128).max || request.tickLower >= request.tickUpper
                || request.deadline < block.timestamp || request.amount0Limit > type(uint128).max
                || request.amount1Limit > type(uint128).max
        ) revert InvalidPositionParameters();
    }

    function _validateInputRequest(ManagedLiquidityRequest calldata request) private view {
        _validateReceiver(request.receiver);
        if (
            request.liquidity == 0 || request.deadline < block.timestamp || request.amount0Limit > type(uint128).max
                || request.amount1Limit > type(uint128).max
        ) revert InvalidPositionParameters();
    }

    function _validateOutputRequest(ManagedLiquidityRequest calldata request, bool requireLiquidity) private view {
        _validateManagedOutputReceiver(request.receiver);
        if (
            request.deadline < block.timestamp || request.amount0Limit > type(uint128).max
                || request.amount1Limit > type(uint128).max || (requireLiquidity && request.liquidity == 0)
                || (!requireLiquidity && request.liquidity != 0)
        ) revert InvalidPositionParameters();
    }

    function _validateReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == staticsDiamond) {
            revert InvalidRecipient();
        }
    }

    function _validateManagedOutputReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidRecipient();
    }

    function _managedState(uint256 tokenId, bool active) private view returns (ManagedPositionState memory state) {
        state = _readPosition(tokenId);
        if (state.owner != address(this)) {
            revert PositionOwnershipMismatch(tokenId, address(this), state.owner);
        }
        if (state.subscriber != address(0)) revert PositionSubscriberNotCleared(tokenId, state.subscriber);
        _enforcePublicPool(state.poolKey, active);
    }

    function _readPosition(uint256 tokenId) private view returns (ManagedPositionState memory state) {
        (PoolKey memory key, PositionInfo info) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        state = ManagedPositionState({
            poolId: key.toId(),
            poolKey: key,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: IPositionManager(positionManager).getPositionLiquidity(tokenId),
            owner: IERC721(positionManager).ownerOf(tokenId),
            subscriber: address(IPositionManager(positionManager).subscriber(tokenId))
        });
    }

    function _enforcePublicPool(PoolKey memory key, bool active) private view {
        PoolId poolId = key.toId();
        bytes32 rawPoolId = PoolId.unwrap(poolId);
        IStaticsProtocolPools.ProtocolPoolView memory registered =
            IStaticsProtocolPools(staticsDiamond).protocolPool(poolId);
        if (registered.kind == IStaticsProtocolPools.ProtocolPoolKind.None) {
            revert ProtocolPoolNotRegistered(rawPoolId);
        }
        if (
            registered.kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
                && registered.kind != IStaticsProtocolPools.ProtocolPoolKind.General
        ) revert PublicProtocolPoolRequired(rawPoolId);
        if (keccak256(abi.encode(registered.key)) != keccak256(abi.encode(key))) {
            revert ProtocolPoolMismatch(rawPoolId);
        }
        if (active && registered.decommissioned) revert ProtocolPoolDecommissioned(rawPoolId);
    }

    function _enforceExpectedPosition(
        uint256 tokenId,
        ManagedPositionState memory state,
        PoolKey calldata expectedKey,
        int24 expectedLower,
        int24 expectedUpper,
        uint256 expectedLiquidity
    ) private pure {
        if (keccak256(abi.encode(state.poolKey)) != keccak256(abi.encode(expectedKey))) {
            revert PositionPoolMismatch(tokenId, PoolId.unwrap(expectedKey.toId()), PoolId.unwrap(state.poolId));
        }
        if (state.tickLower != expectedLower || state.tickUpper != expectedUpper) {
            revert PositionRangeMismatch(tokenId);
        }
        uint128 narrowedExpected = uint128(expectedLiquidity);
        if (state.liquidity != narrowedExpected) {
            revert PositionLiquidityMismatch(tokenId, narrowedExpected, state.liquidity);
        }
    }

    function _enforceSamePosition(
        uint256 tokenId,
        ManagedPositionState memory beforeState,
        ManagedPositionState memory afterState
    ) private pure {
        if (
            PoolId.unwrap(beforeState.poolId) != PoolId.unwrap(afterState.poolId)
                || keccak256(abi.encode(beforeState.poolKey)) != keccak256(abi.encode(afterState.poolKey))
        ) {
            revert PositionPoolMismatch(tokenId, PoolId.unwrap(beforeState.poolId), PoolId.unwrap(afterState.poolId));
        }
        if (beforeState.tickLower != afterState.tickLower || beforeState.tickUpper != afterState.tickUpper) {
            revert PositionRangeMismatch(tokenId);
        }
    }

    function _enforcePositionDestroyed(uint256 tokenId) private view {
        (bool exists,) = positionManager.staticcall(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (exists) revert PositionStillExists(tokenId);
    }

    function _enforceMaximum(address token, uint256 spent, uint256 maximum) private pure {
        if (spent > maximum) revert ExcessiveTokenDebit(token, spent, maximum);
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
