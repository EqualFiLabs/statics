// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibProtocolPools} from "./LibProtocolPools.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";
import {LibBasketManagerSettlement} from "./LibBasketManagerSettlement.sol";

/// @notice Custody-constrained protocol LP portfolio operations.
/// @dev Strategy selects explicit ranges and amounts. This library fixes every receiver to protocol
/// custody and classifies native PositionManager fees as Treasury revenue before principal moves.
library LibProtocolPol {
    error LiquidityManagerNotInstalled();
    error ProtocolPolNotActivated(PoolId poolId);
    error ProtocolPolPositionNotFound(uint256 positionId);
    error ProtocolPolPositionPoolMismatch(uint256 positionId, PoolId expected, PoolId actual);
    error ProtocolPolManagerTransferMismatch(address asset, uint256 expected, uint256 spent, uint256 received);
    error ProtocolPolManagerReturnMismatch(address asset, uint256 reported, uint256 observed);
    error ProtocolPolLiquidityMismatch(uint256 positionId, uint128 expected, uint128 actual);

    function isActivated(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind) internal view returns (bool) {
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) return true;
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.General) return false;
        return LibProtocolPools.protocolPoolStorage().polFunding[poolId].activated;
    }

    function open(IStaticsProtocolPools.ProtocolPolOpenParams memory params)
        internal
        returns (uint256 positionId, IStaticsLiquidityManager.ManagedPositionMovement memory movement)
    {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key,,) =
            LibProtocolPools.enforceRegistered(params.poolId);
        if (!isActivated(params.poolId, kind)) revert ProtocolPolNotActivated(params.poolId);

        address manager = _currentManager();
        LibBasketManagerSettlement.begin(key, manager, address(this));
        _fundManager(params.poolId, key, manager, params.amount0Maximum, params.amount1Maximum);
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        movement = IStaticsLiquidityManager(manager)
            .mintManagedPosition(
                IStaticsLiquidityManager.PositionRequest({
                    poolKey: key,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidity: params.liquidity,
                    amount0Limit: params.amount0Maximum,
                    amount1Limit: params.amount1Maximum,
                    deadline: params.deadline
                }),
                address(this)
            );
        LibBasketManagerSettlement.end();
        _reserveManagerReturns(params.poolId, key, before0, before1, movement.refund0, movement.refund1);
        _enforceInputAccounting(
            key.currency0, params.amount0Maximum, movement.spent0, movement.received0, movement.refund0
        );
        _enforceInputAccounting(
            key.currency1, params.amount1Maximum, movement.spent1, movement.received1, movement.refund1
        );

        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        positionId = ++ps.nextPolPositionId;
        ps.polPositions[positionId] = LibProtocolPools.ProtocolPolPosition({
            poolId: params.poolId,
            manager: manager,
            posmTokenId: movement.tokenId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: movement.liquidityAfter,
            active: true
        });
        ps.polPositionIds[params.poolId].push(positionId);
        ++ps.activePolPositionCount[params.poolId];
        LibRangeGauge.bindProtocolPol(movement.tokenId, positionId);
    }

    function increase(IStaticsProtocolPools.ProtocolPolLiquidityParams memory params)
        internal
        returns (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        )
    {
        (position,) = harvest(params.positionId, params.deadline);
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(position.poolId);
        LibBasketManagerSettlement.begin(key, position.manager, address(this));
        _fundManager(position.poolId, key, position.manager, params.amount0Limit, params.amount1Limit);
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        movement = IStaticsLiquidityManager(position.manager)
            .increaseManagedPosition(
                _request(
                    position.posmTokenId, params.liquidity, params.amount0Limit, params.amount1Limit, params.deadline
                )
            );
        LibBasketManagerSettlement.end();
        _reserveManagerReturns(position.poolId, key, before0, before1, movement.refund0, movement.refund1);
        _enforceInputAccounting(
            key.currency0, params.amount0Limit, movement.spent0, movement.received0, movement.refund0
        );
        _enforceInputAccounting(
            key.currency1, params.amount1Limit, movement.spent1, movement.received1, movement.refund1
        );
        position.liquidity = movement.liquidityAfter;
    }

    function harvest(uint256 positionId, uint256 deadline)
        internal
        returns (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        )
    {
        position = enforcePosition(positionId);
        LibRangeGauge.enforceProtocolPolBinding(position.posmTokenId, positionId);
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(position.poolId);
        LibBasketManagerSettlement.begin(key, position.manager, address(this));
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        movement = IStaticsLiquidityManager(position.manager)
            .collectManagedPositionFees(_request(position.posmTokenId, 0, 0, 0, deadline));
        LibBasketManagerSettlement.end();
        _accrueTreasuryReturn(key.currency0, before0, movement.received0);
        _accrueTreasuryReturn(key.currency1, before1, movement.received1);
    }

    function decrease(IStaticsProtocolPools.ProtocolPolLiquidityParams memory params)
        internal
        returns (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        )
    {
        (position,) = harvest(params.positionId, params.deadline);
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(position.poolId);
        LibBasketManagerSettlement.begin(key, position.manager, address(this));
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        movement = IStaticsLiquidityManager(position.manager)
            .decreaseManagedPosition(
                _request(
                    position.posmTokenId, params.liquidity, params.amount0Limit, params.amount1Limit, params.deadline
                )
            );
        LibBasketManagerSettlement.end();
        _reservePrincipalReturn(position.poolId, key.currency0, before0, movement.received0);
        _reservePrincipalReturn(position.poolId, key.currency1, before1, movement.received1);
        position.liquidity = movement.liquidityAfter;
    }

    function close(uint256 positionId, uint256 amount0Minimum, uint256 amount1Minimum, uint256 deadline)
        internal
        returns (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        )
    {
        (position,) = harvest(positionId, deadline);
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(position.poolId);
        LibBasketManagerSettlement.begin(key, position.manager, address(this));
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        movement = IStaticsLiquidityManager(position.manager)
            .exitManagedPosition(_request(position.posmTokenId, 0, amount0Minimum, amount1Minimum, deadline));
        LibBasketManagerSettlement.end();
        _reservePrincipalReturn(position.poolId, key.currency0, before0, movement.received0);
        _reservePrincipalReturn(position.poolId, key.currency1, before1, movement.received1);
        LibRangeGauge.unbindProtocolPol(position.posmTokenId, positionId);
        position.liquidity = 0;
        position.active = false;
        --LibProtocolPools.protocolPoolStorage().activePolPositionCount[position.poolId];
    }

    function enforcePosition(uint256 positionId)
        internal
        view
        returns (LibProtocolPools.ProtocolPolPosition storage position)
    {
        position = LibProtocolPools.protocolPoolStorage().polPositions[positionId];
        if (!position.active) revert ProtocolPolPositionNotFound(positionId);
    }

    function _fundManager(PoolId poolId, PoolKey memory key, address manager, uint256 amount0, uint256 amount1)
        private
    {
        _fundManagerToken(poolId, Currency.unwrap(key.currency0), manager, amount0);
        _fundManagerToken(poolId, Currency.unwrap(key.currency1), manager, amount1);
    }

    function _fundManagerToken(PoolId poolId, address asset, address manager, uint256 amount) private {
        if (amount == 0) return;
        (uint256 spent, uint256 received) = LibCustody.pushReserved(
            LibCustody.protocolPolAccount(PoolId.unwrap(poolId)), asset, manager, amount, amount
        );
        if (spent != amount || received != amount) {
            revert ProtocolPolManagerTransferMismatch(asset, amount, spent, received);
        }
    }

    function _reserveManagerReturns(
        PoolId poolId,
        PoolKey memory key,
        uint256 before0,
        uint256 before1,
        uint256 reported0,
        uint256 reported1
    ) private {
        _reservePrincipalReturn(poolId, key.currency0, before0, reported0);
        _reservePrincipalReturn(poolId, key.currency1, before1, reported1);
    }

    function _reservePrincipalReturn(PoolId poolId, Currency currency, uint256 beforeBalance, uint256 reported)
        private
    {
        address asset = Currency.unwrap(currency);
        uint256 afterBalance = IERC20(asset).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert ProtocolPolManagerReturnMismatch(asset, reported, observed);
        LibCustody.reserve(LibCustody.protocolPolAccount(PoolId.unwrap(poolId)), asset, observed);
    }

    function _accrueTreasuryReturn(Currency currency, uint256 beforeBalance, uint256 reported) private {
        address asset = Currency.unwrap(currency);
        uint256 afterBalance = IERC20(asset).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert ProtocolPolManagerReturnMismatch(asset, reported, observed);
        if (observed == 0) return;
        LibCustody.reserve(LibCustody.feeAccount(), asset, observed);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, observed);
    }

    function _enforceInputAccounting(
        Currency currency,
        uint256 supplied,
        uint256 spent,
        uint256 received,
        uint256 refunded
    ) private pure {
        if (spent + refunded != supplied + received) {
            revert ProtocolPolManagerTransferMismatch(Currency.unwrap(currency), supplied, spent, refunded);
        }
    }

    function _request(uint256 tokenId, uint128 liquidity, uint256 amount0Limit, uint256 amount1Limit, uint256 deadline)
        private
        view
        returns (IStaticsLiquidityManager.ManagedLiquidityRequest memory request)
    {
        request = IStaticsLiquidityManager.ManagedLiquidityRequest({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Limit: amount0Limit,
            amount1Limit: amount1Limit,
            deadline: deadline,
            receiver: address(this)
        });
    }

    function _currentManager() private view returns (address manager) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.managerInstalled || ls.manager.code.length == 0) revert LiquidityManagerNotInstalled();
        return ls.manager;
    }
}
