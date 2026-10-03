// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugePositionBase} from "./RangeGaugePositionBase.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice PNFT-authorized mutation of existing managed public Uniswap v4 positions.
contract RangeGaugePositionManagementFacet is RangeGaugePositionBase {
    struct RebalanceResult {
        uint256 oldPosmTokenId;
        address newManager;
        IStaticsLiquidityManager.ManagedPositionMovement minted;
        IStaticsLiquidityManager.ManagedPositionState state;
    }

    function increaseLiquidity(
        uint256 positionId,
        PoolId poolId,
        IStaticsRangeGauge.IncreaseLiquidityParams calldata params
    ) external nonReentrant returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforcePublicGauge(poolId, true);
        LibRangeGauge.LpLeg storage leg = _leg(positionId, poolId);
        _synchronizeAndSettle(poolId, key, leg);
        InputBalances memory balances = _inputBalances(key, msg.sender);
        (uint256 amount0, uint256 amount1) =
            _fundManager(key, msg.sender, leg.manager, params.amount0Maximum, params.amount1Maximum);
        address receiver = IERC721(address(this)).ownerOf(positionId);
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = IStaticsLiquidityManager(leg.manager)
            .increaseManagedPosition(
                _managerRequest(leg.posmTokenId, params.liquidity, amount0, amount1, params.deadline, receiver)
            );
        uint128 expectedLiquidity = leg.liquidity + params.liquidity;
        _verifiedState(leg.manager, leg.posmTokenId, poolId, leg.tickLower, leg.tickUpper, expectedLiquidity);
        _replaceRange(poolId, key.tickSpacing, leg, leg.tickLower, leg.tickUpper, expectedLiquidity);
        _enforceInputDebits(balances, msg.sender, params.amount0Maximum, params.amount1Maximum);
        movement = _inputMovement(managed);
        emit IStaticsRangeGauge.ManagedLiquidityChanged(positionId, poolId, leg.posmTokenId, leg.liquidity);
    }

    function decreaseLiquidity(
        uint256 positionId,
        PoolId poolId,
        IStaticsRangeGauge.DecreaseLiquidityParams calldata params
    ) external nonReentrant returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforcePublicGauge(poolId, false);
        LibRangeGauge.LpLeg storage leg = _leg(positionId, poolId);
        if (params.liquidity == 0 || params.liquidity >= leg.liquidity) {
            revert IStaticsRangeGauge.InvalidPositionState(positionId, poolId);
        }
        _synchronizeAndSettle(poolId, key, leg);
        address receiver = IERC721(address(this)).ownerOf(positionId);
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = IStaticsLiquidityManager(leg.manager)
            .decreaseManagedPosition(
                _managerRequest(
                    leg.posmTokenId,
                    params.liquidity,
                    params.amount0Minimum,
                    params.amount1Minimum,
                    params.deadline,
                    receiver
                )
            );
        uint128 expectedLiquidity = leg.liquidity - params.liquidity;
        _verifiedState(leg.manager, leg.posmTokenId, poolId, leg.tickLower, leg.tickUpper, expectedLiquidity);
        _replaceRange(poolId, key.tickSpacing, leg, leg.tickLower, leg.tickUpper, expectedLiquidity);
        movement = _outputMovement(managed);
        emit IStaticsRangeGauge.ManagedLiquidityChanged(positionId, poolId, leg.posmTokenId, leg.liquidity);
    }

    function collectNativeFees(
        uint256 positionId,
        PoolId poolId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external nonReentrant returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        _enforcePublicGauge(poolId, false);
        LibRangeGauge.LpLeg storage leg = _leg(positionId, poolId);
        address receiver = IERC721(address(this)).ownerOf(positionId);
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = IStaticsLiquidityManager(leg.manager)
            .collectManagedPositionFees(
                _managerRequest(leg.posmTokenId, 0, amount0Minimum, amount1Minimum, deadline, receiver)
            );
        _verifiedState(leg.manager, leg.posmTokenId, poolId, leg.tickLower, leg.tickUpper, leg.liquidity);
        movement = _outputMovement(managed);
    }

    function rebalanceLiquidity(
        uint256 positionId,
        PoolId poolId,
        IStaticsRangeGauge.RebalanceLiquidityParams calldata params
    ) external nonReentrant returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        PoolKey memory key = _enforcePublicGauge(poolId, true);
        LibRangeGauge.LpLeg storage leg = _leg(positionId, poolId);
        _synchronizeAndSettle(poolId, key, leg);
        InputBalances memory balances = _inputBalances(key, msg.sender);
        RebalanceResult memory result = _executeRebalance(positionId, poolId, key, leg, params);
        _enforceInputDebits(balances, msg.sender, params.amount0Maximum, params.amount1Maximum);

        movement = _inputMovement(result.minted);
        emit IStaticsRangeGauge.ManagedLiquidityRebalanced(
            positionId,
            poolId,
            result.oldPosmTokenId,
            result.minted.tokenId,
            result.newManager,
            result.state.tickLower,
            result.state.tickUpper,
            result.state.liquidity
        );
    }

    function _executeRebalance(
        uint256 positionId,
        PoolId poolId,
        PoolKey memory key,
        LibRangeGauge.LpLeg storage leg,
        IStaticsRangeGauge.RebalanceLiquidityParams calldata params
    ) private returns (RebalanceResult memory result) {
        result.oldPosmTokenId = leg.posmTokenId;
        IStaticsLiquidityManager.ManagedPositionMovement memory exited = IStaticsLiquidityManager(leg.manager)
            .exitManagedPosition(
                _managerRequest(
                    result.oldPosmTokenId,
                    0,
                    params.amount0Minimum,
                    params.amount1Minimum,
                    params.deadline,
                    address(this)
                )
            );
        LibRangeGauge.unbindPosm(result.oldPosmTokenId, positionId, poolId);

        (result.newManager, result.minted, result.state) = _mintReplacement(positionId, poolId, key, params, exited);
        LibRangeGauge.replacePositionRange(
            poolId,
            leg.tickLower,
            leg.tickUpper,
            leg.liquidity,
            result.state.tickLower,
            result.state.tickUpper,
            result.state.liquidity,
            key.tickSpacing
        );
        leg.manager = result.newManager;
        leg.posmTokenId = result.minted.tokenId;
        leg.tickLower = result.state.tickLower;
        leg.tickUpper = result.state.tickUpper;
        leg.liquidity = result.state.liquidity;
        LibRangeGauge.checkpointLeg(poolId, leg);
        LibRangeGauge.bindPosm(result.minted.tokenId, positionId, poolId);
    }

    function _mintReplacement(
        uint256 positionId,
        PoolId poolId,
        PoolKey memory key,
        IStaticsRangeGauge.RebalanceLiquidityParams calldata params,
        IStaticsLiquidityManager.ManagedPositionMovement memory exited
    )
        private
        returns (
            address newManager,
            IStaticsLiquidityManager.ManagedPositionMovement memory minted,
            IStaticsLiquidityManager.ManagedPositionState memory state
        )
    {
        newManager = _activeManager();
        (uint256 amount0, uint256 amount1) = _fundRebalance(
            key,
            msg.sender,
            newManager,
            exited.received0,
            exited.received1,
            params.amount0Maximum,
            params.amount1Maximum
        );
        minted = IStaticsLiquidityManager(newManager)
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
                IERC721(address(this)).ownerOf(positionId)
            );
        state = _verifiedState(newManager, minted.tokenId, poolId, params.tickLower, params.tickUpper, params.liquidity);
    }
}
