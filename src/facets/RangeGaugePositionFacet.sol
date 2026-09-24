// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugePositionBase} from "./RangeGaugePositionBase.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice PNFT-authorized ingress for managed public Uniswap v4 positions.
contract RangeGaugePositionFacet is RangeGaugePositionBase {
    function provideLiquidity(uint256 positionId, IStaticsRangeGauge.ProvideLiquidityParams calldata params)
        external
        nonReentrant
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforcePublicGauge(params.poolId, true);
        _enforceNoLeg(positionId, params.poolId);
        address manager = _activeManager();
        InputBalances memory balances = _inputBalances(key, msg.sender);
        (uint256 amount0, uint256 amount1) =
            _fundManager(key, msg.sender, manager, params.amount0Maximum, params.amount1Maximum);
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = IStaticsLiquidityManager(manager)
            .mintManagedPosition(
                IStaticsLiquidityManager.PositionRequest({
                    poolKey: key,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidity: params.liquidity,
                    amount0Limit: amount0,
                    amount1Limit: amount1,
                    deadline: params.deadline
                }),
                msg.sender
            );
        IStaticsLiquidityManager.ManagedPositionState memory state = _verifiedState(
            manager, managed.tokenId, params.poolId, params.tickLower, params.tickUpper, params.liquidity
        );
        _synchronize(params.poolId, key);
        _storeNewLeg(positionId, params.poolId, manager, managed.tokenId, state);
        _enforceInputDebits(balances, msg.sender, params.amount0Maximum, params.amount1Maximum);
        movement = _inputMovement(managed);
        emit IStaticsRangeGauge.ManagedLiquidityProvided(
            positionId, params.poolId, managed.tokenId, manager, state.tickLower, state.tickUpper, state.liquidity
        );
    }

    function attachLiquidity(uint256 positionId, PoolId poolId, uint256 posmTokenId)
        external
        nonReentrant
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforcePublicGauge(poolId, true);
        _enforceNoLeg(positionId, poolId);
        address manager = _activeManager();
        address posm = IStaticsLiquidityManager(manager).positionManager();
        address posmOwner = IERC721(posm).ownerOf(posmTokenId);
        if (posmOwner != msg.sender) revert IStaticsRangeGauge.NotPosmOwner(posmTokenId, msg.sender, posmOwner);

        IStaticsLiquidityManager.ManagedPositionState memory attached =
            IStaticsLiquidityManager(manager).attachManagedPosition(msg.sender, poolId, posmTokenId);
        IStaticsLiquidityManager.ManagedPositionState memory state =
            _verifiedState(manager, posmTokenId, poolId, attached.tickLower, attached.tickUpper, attached.liquidity);
        _synchronize(poolId, key);
        _storeNewLeg(positionId, poolId, manager, posmTokenId, state);
        movement.posmTokenId = posmTokenId;
        movement.liquidity = state.liquidity;
        emit IStaticsRangeGauge.ManagedLiquidityAttached(
            positionId, poolId, posmTokenId, manager, state.tickLower, state.tickUpper, state.liquidity
        );
    }
}
