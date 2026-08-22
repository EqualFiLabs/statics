// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLiquidityRewards} from "../libraries/LibLiquidityRewards.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

contract LiquidityRewardsFacet is IStaticsLiquidityRewards, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    error InvalidReceiver();
    error InvalidLiquidityAmount();
    error LiquidityActionPaused();
    error LiquidityManagerNotInstalled();
    error PositionRangeNotFull(uint256 tokenId, int24 tickLower, int24 tickUpper);
    error PositionHasSubscriber(uint256 tokenId);
    error PositionOwnerMismatch(uint256 tokenId, address expected, address actual);
    error PositionAssociationMismatch(uint256 tokenId, uint256 expectedPositionId, uint256 actualPositionId);
    error PositionLiquidityMismatch(uint256 tokenId, uint256 expected, uint256 actual);
    error IncompatibleLiquidityAsset(address asset, uint256 expected, uint256 actual);
    error InvalidRewardAsset(PoolId poolId, address asset);
    error OnlySwapFeeHook(address caller, address expected);
    error NoLiquidityRewards(uint256 tokenId);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error PoolDecommissioned(PoolId poolId);
    error GovernancePoolBasketReward(PoolId poolId, uint256 amount);

    struct IncreaseResult {
        IStaticsLiquidityManager.PositionMovement movement;
        uint256 funded0;
        uint256 funded1;
        uint256 refund0;
        uint256 refund1;
    }

    struct StakeVerification {
        PoolKey key;
        PoolId poolId;
        uint256 basketId;
        address basketAsset;
        uint256 liquidity;
        address lpOwner;
    }

    function stakeLiquidityPosition(uint256 positionId, uint256 tokenId) external nonReentrant {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        StakeVerification memory verified = _verifyStakeRequest(positionId, tokenId);
        _takePositionCustody(verified, tokenId);
        LibLiquidityRewards.LiquidityPosition storage position = _registerStakedPosition(verified, positionId, tokenId);
        emit LiquidityPositionStaked(positionId, tokenId, verified.poolId, verified.liquidity, position.eligibleAtBlock);
    }

    function _verifyStakeRequest(uint256 positionId, uint256 tokenId)
        private
        returns (StakeVerification memory verified)
    {
        IPositionManager positionManager = _positionManager();
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        IERC721 positionNft = IERC721(address(positionManager));
        verified.lpOwner = positionNft.ownerOf(tokenId);
        if (verified.lpOwner != positionOwner) revert PositionOwnerMismatch(tokenId, positionOwner, verified.lpOwner);

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        verified.poolId = key.toId();
        IStaticsProtocolPools.ProtocolPoolKind kind;
        (kind,, verified.basketId, verified.basketAsset) = LibProtocolPools.enforceRegistered(verified.poolId);
        if (_poolIsDecommissioned(verified.poolId)) revert PoolDecommissioned(verified.poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
            LibBasket.enforceActive(LibBasket.basketStorage().baskets[verified.basketId], verified.basketId);
        }
        if (info.hasSubscriber()) revert PositionHasSubscriber(tokenId);
        if (
            info.tickLower() != TickMath.minUsableTick(key.tickSpacing)
                || info.tickUpper() != TickMath.maxUsableTick(key.tickSpacing)
        ) {
            revert PositionRangeNotFull(tokenId, info.tickLower(), info.tickUpper());
        }
        verified.liquidity = positionManager.getPositionLiquidity(tokenId);
        if (verified.liquidity == 0) revert InvalidLiquidityAmount();
        verified.key = key;
    }

    function _takePositionCustody(StakeVerification memory verified, uint256 tokenId) private {
        IERC721 positionNft = IERC721(address(_positionManager()));
        positionNft.transferFrom(verified.lpOwner, address(this), tokenId);
        if (positionNft.ownerOf(tokenId) != address(this)) {
            revert PositionOwnerMismatch(tokenId, address(this), positionNft.ownerOf(tokenId));
        }
        uint256 observedLiquidity = _positionManager().getPositionLiquidity(tokenId);
        if (observedLiquidity != verified.liquidity) {
            revert PositionLiquidityMismatch(tokenId, verified.liquidity, observedLiquidity);
        }
    }

    function _registerStakedPosition(StakeVerification memory verified, uint256 positionId, uint256 tokenId)
        private
        returns (LibLiquidityRewards.LiquidityPosition storage position)
    {
        address currency0 = Currency.unwrap(verified.key.currency0);
        address currency1 = Currency.unwrap(verified.key.currency1);
        LibLiquidityRewards.cachePoolCurrencies(verified.poolId, currency0, currency1);
        return LibLiquidityRewards.initializeRecord(
            tokenId,
            positionId,
            verified.basketId,
            verified.basketAsset,
            verified.poolId,
            currency0,
            currency1,
            verified.liquidity
        );
    }

    function activateLiquidityPosition(uint256 tokenId) external nonReentrant {
        LibLiquidityRewards.LiquidityPosition storage position = _record(tokenId);
        if (_poolIsDecommissioned(position.poolId)) revert PoolDecommissioned(position.poolId);
        uint256 activated = LibLiquidityRewards.activate(tokenId);
        emit LiquidityPositionActivated(position.positionId, tokenId, position.poolId, activated);
    }

    function increaseStakedLiquidity(
        uint256 positionId,
        uint256 tokenId,
        IncreaseRequest calldata request,
        address refundReceiver
    ) external nonReentrant returns (uint256 spent0, uint256 spent1, uint256 refund0, uint256 refund1) {
        if (refundReceiver == address(0)) revert InvalidReceiver();
        if (request.liquidityDelta == 0) revert InvalidLiquidityAmount();
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibLiquidityRewards.LiquidityPosition storage position = _record(tokenId);
        if (position.positionId != positionId) {
            revert PositionAssociationMismatch(tokenId, position.positionId, positionId);
        }
        PoolKey memory key;
        {
            (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory registeredKey, uint256 basketId,) =
                LibProtocolPools.enforceRegistered(position.poolId);
            key = registeredKey;
            if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
                LibBasket.enforceActive(LibBasket.basketStorage().baskets[basketId], basketId);
            }
        }
        LibLiquidityRewards.activateIfMatured(tokenId);
        {
            (uint256 settled0, uint256 settled1) = LibLiquidityRewards.settle(tokenId);
            _emitSettled(position, tokenId, settled0, settled1);
        }

        uint256 beforeLiquidity = _verifyRecordedLiquidity(tokenId, position);
        IncreaseResult memory result = _increaseViaManager(position, tokenId, request, refundReceiver, key);
        _verifyProvision(position, tokenId, beforeLiquidity, request, result);
        LibLiquidityRewards.addPending(tokenId, request.liquidityDelta);
        emit StakedLiquidityIncreased(
            positionId,
            tokenId,
            position.poolId,
            request.liquidityDelta,
            result.movement.spent0,
            result.movement.spent1,
            result.refund0,
            result.refund1,
            position.eligibleAtBlock
        );
        spent0 = result.movement.spent0;
        spent1 = result.movement.spent1;
        refund0 = result.refund0;
        refund1 = result.refund1;
    }

    function _verifyRecordedLiquidity(uint256 tokenId, LibLiquidityRewards.LiquidityPosition storage position)
        private
        returns (uint256 recordedLiquidity)
    {
        uint256 actualLiquidity = _positionManager().getPositionLiquidity(tokenId);
        recordedLiquidity = uint256(position.eligibleLiquidity) + uint256(position.pendingLiquidity);
        if (actualLiquidity != recordedLiquidity) {
            revert PositionLiquidityMismatch(tokenId, recordedLiquidity, actualLiquidity);
        }
    }

    function _increaseViaManager(
        LibLiquidityRewards.LiquidityPosition storage position,
        uint256 tokenId,
        IncreaseRequest calldata request,
        address refundReceiver,
        PoolKey memory key
    ) private returns (IncreaseResult memory result) {
        address managerAddress = LibBasketLiquidity.liquidityStorage().manager;
        result.funded0 = _fundManager(position.currency0, managerAddress, request.amount0Max);
        result.funded1 = _fundManager(position.currency1, managerAddress, request.amount1Max);
        IStaticsLiquidityManager.PositionRequest memory managerRequest = IStaticsLiquidityManager.PositionRequest({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidity: request.liquidityDelta,
            amount0Limit: result.funded0,
            amount1Limit: result.funded1,
            deadline: request.deadline
        });
        (result.movement, result.refund0, result.refund1) =
            IStaticsLiquidityManager(managerAddress).increaseUserPosition(managerRequest, tokenId, refundReceiver);
    }

    function _verifyProvision(
        LibLiquidityRewards.LiquidityPosition storage position,
        uint256 tokenId,
        uint256 beforeLiquidity,
        IncreaseRequest calldata request,
        IncreaseResult memory result
    ) private {
        if (result.movement.spent0 + result.refund0 != result.funded0 + result.movement.received0) {
            revert IncompatibleLiquidityAsset(
                position.currency0, result.funded0 + result.movement.received0, result.movement.spent0 + result.refund0
            );
        }
        if (result.movement.spent1 + result.refund1 != result.funded1 + result.movement.received1) {
            revert IncompatibleLiquidityAsset(
                position.currency1, result.funded1 + result.movement.received1, result.movement.spent1 + result.refund1
            );
        }
        uint256 expectedLiquidity = beforeLiquidity + request.liquidityDelta;
        uint256 afterLiquidity = _positionManager().getPositionLiquidity(tokenId);
        if (afterLiquidity != expectedLiquidity) {
            revert PositionLiquidityMismatch(tokenId, expectedLiquidity, afterLiquidity);
        }
    }

    function unstakeLiquidityPosition(uint256 positionId, uint256 tokenId, address receiver) external nonReentrant {
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibLiquidityRewards.LiquidityPosition storage position = _record(tokenId);
        if (position.positionId != positionId) {
            revert PositionAssociationMismatch(tokenId, position.positionId, positionId);
        }
        IPositionManager positionManager = _positionManager();
        uint256 actualLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 recordedLiquidity = uint256(position.eligibleLiquidity) + uint256(position.pendingLiquidity);
        if (actualLiquidity != recordedLiquidity) {
            revert PositionLiquidityMismatch(tokenId, recordedLiquidity, actualLiquidity);
        }
        (uint256 settled0, uint256 settled1) = LibLiquidityRewards.settle(tokenId);
        _emitSettled(position, tokenId, settled0, settled1);
        PoolId poolId = position.poolId;
        LibLiquidityRewards.removeEligibility(tokenId);
        LibLiquidityRewards.finishEpoch(poolId);
        IERC721(address(positionManager)).safeTransferFrom(address(this), receiver, tokenId);
        emit LiquidityPositionUnstaked(positionId, tokenId, poolId, receiver);
        LibLiquidityRewards.clearIfEmpty(tokenId);
    }

    function claimLiquidityRewards(
        uint256 positionId,
        uint256 tokenId,
        address receiver,
        uint256 minAmount0,
        uint256 minAmount1
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibLiquidityRewards.LiquidityPosition storage position = _recordIncludingExited(tokenId);
        if (position.positionId != positionId) {
            revert PositionAssociationMismatch(tokenId, position.positionId, positionId);
        }
        (uint256 settled0, uint256 settled1) = LibLiquidityRewards.settle(tokenId);
        _emitSettled(position, tokenId, settled0, settled1);
        LibLiquidityRewards.PoolRewards storage pool = LibLiquidityRewards.rewardStorage().pools[position.poolId];
        uint256 owed0 = position.claimable0;
        uint256 owed1 = position.claimable1;
        if (owed0 == 0 && owed1 == 0) revert NoLiquidityRewards(tokenId);
        position.claimable0 = 0;
        position.claimable1 = 0;
        if (owed0 != 0) {
            pool.totalClaimable0 -= owed0;
            (, amount0) = LibCustody.pushReserved(LibCustody.feeAccount(), position.currency0, receiver, owed0, owed0);
            emit LiquidityRewardClaimed(positionId, tokenId, position.currency0, receiver, owed0);
        }
        if (owed1 != 0) {
            pool.totalClaimable1 -= owed1;
            (, amount1) = LibCustody.pushReserved(LibCustody.feeAccount(), position.currency1, receiver, owed1, owed1);
            emit LiquidityRewardClaimed(positionId, tokenId, position.currency1, receiver, owed1);
        }
        if (amount0 < minAmount0) revert MinimumOutputNotMet(position.currency0, amount0, minAmount0);
        if (amount1 < minAmount1) revert MinimumOutputNotMet(position.currency1, amount1, minAmount1);
        LibLiquidityRewards.clearIfEmpty(tokenId);
    }

    function routeCanonicalSwapFees(
        PoolId poolId,
        address asset,
        uint256 liquidityProviderAmount,
        uint256 basketStakerAmount,
        uint256 staticsStakerAmount,
        uint256 treasuryAmount
    ) external nonReentrant {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (msg.sender != ls.hook) revert OnlySwapFeeHook(msg.sender, ls.hook);
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId,) =
            LibProtocolPools.enforceRegistered(poolId);
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (asset != currency0 && asset != currency1) revert InvalidRewardAsset(poolId, asset);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.Governance && basketStakerAmount != 0) {
            revert GovernancePoolBasketReward(poolId, basketStakerAmount);
        }
        uint256 total = liquidityProviderAmount + basketStakerAmount + staticsStakerAmount + treasuryAmount;
        if (total == 0) return;
        uint256 received = LibCustody.pull(asset, msg.sender, total);
        if (received != total) revert IncompatibleLiquidityAsset(asset, total, received);
        LibCustody.reserve(LibCustody.feeAccount(), asset, total);
        if (liquidityProviderAmount != 0) {
            uint256 indexRay = LibLiquidityRewards.accrue(poolId, asset, liquidityProviderAmount);
            emit LiquidityRewardAccrued(poolId, asset, liquidityProviderAmount, indexRay);
        }
        if (basketStakerAmount != 0) {
            LibBasketRewards.accrueReserved(
                basketId, LibBasket.basketStorage().baskets[basketId], asset, basketStakerAmount
            );
        }
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, staticsStakerAmount);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, treasuryAmount);
    }

    function stakedLiquidityPosition(uint256 tokenId) external view returns (StakedLiquidityView memory view_) {
        LibLiquidityRewards.LiquidityPosition storage position = LibLiquidityRewards.rewardStorage().positions[tokenId];
        view_ = StakedLiquidityView({
            positionId: position.positionId,
            basketId: position.basketId,
            asset: position.asset,
            poolId: position.poolId,
            currency0: position.currency0,
            currency1: position.currency1,
            eligibleLiquidity: position.eligibleLiquidity,
            pendingLiquidity: position.pendingLiquidity,
            eligibleAtBlock: position.eligibleAtBlock,
            claimable0: position.claimable0,
            claimable1: position.claimable1,
            staked: position.staked
        });
    }

    function poolLiquidityRewards(PoolId poolId) external view returns (PoolLiquidityRewardView memory view_) {
        LibLiquidityRewards.PoolRewards storage pool = LibLiquidityRewards.rewardStorage().pools[poolId];
        view_ = PoolLiquidityRewardView({
            totalEligibleLiquidity: pool.totalEligibleLiquidity,
            index0Ray: pool.index0Ray,
            index1Ray: pool.index1Ray,
            indexRemainder0: pool.indexRemainder0,
            indexRemainder1: pool.indexRemainder1,
            indexed0: pool.indexed0,
            indexed1: pool.indexed1,
            crystallized0: pool.crystallized0,
            crystallized1: pool.crystallized1,
            totalClaimable0: pool.totalClaimable0,
            totalClaimable1: pool.totalClaimable1
        });
    }

    function pendingLiquidityRewards(uint256 positionId, uint256 tokenId)
        external
        view
        returns (address currency0, uint256 amount0, address currency1, uint256 amount1)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibLiquidityRewards.LiquidityPosition storage position = _recordIncludingExited(tokenId);
        if (position.positionId != positionId) {
            revert PositionAssociationMismatch(tokenId, position.positionId, positionId);
        }
        (amount0, amount1) = LibLiquidityRewards.pending(tokenId);
        return (position.currency0, amount0, position.currency1, amount1);
    }

    function canAccrueLiquidityRewards(PoolId poolId) external view returns (bool) {
        if (LibLiquidityRewards.rewardStorage().pools[poolId].totalEligibleLiquidity == 0) return false;
        return !_poolIsDecommissioned(poolId);
    }

    function canAccrueBasketRewards(PoolId poolId) external view returns (bool) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,, uint256 basketId,) = LibProtocolPools.resolve(poolId);
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical || _poolIsDecommissioned(poolId)) {
            return false;
        }
        return LibBasketRewards.canAccrue(basketId);
    }

    function _fundManager(address asset, address manager, uint256 amount) private returns (uint256 funded) {
        if (amount == 0) return 0;
        uint256 received = LibCustody.pull(asset, msg.sender, amount);
        if (received != amount) revert IncompatibleLiquidityAsset(asset, amount, received);
        (, funded) = LibCustody.pushUnreserved(asset, manager, amount, amount);
        if (funded != amount) revert IncompatibleLiquidityAsset(asset, amount, funded);
    }

    function _positionManager() private view returns (IPositionManager positionManager) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        positionManager = IPositionManager(IStaticsLiquidityManager(ls.manager).positionManager());
    }

    function _record(uint256 tokenId) private view returns (LibLiquidityRewards.LiquidityPosition storage position) {
        position = LibLiquidityRewards.rewardStorage().positions[tokenId];
        if (!position.staked) revert LibLiquidityRewards.InvalidLiquidityRecord(tokenId);
    }

    function _recordIncludingExited(uint256 tokenId)
        private
        view
        returns (LibLiquidityRewards.LiquidityPosition storage position)
    {
        position = LibLiquidityRewards.rewardStorage().positions[tokenId];
        if (position.positionId == 0) revert LibLiquidityRewards.InvalidLiquidityRecord(tokenId);
    }

    function _poolIsDecommissioned(PoolId poolId) private view returns (bool) {
        address hook = LibBasketLiquidity.liquidityStorage().hook;
        return hook != address(0) && IStaticsSwapFeeHook(hook).poolDecommissioned(poolId);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert LiquidityActionPaused();
        }
    }

    function _emitSettled(
        LibLiquidityRewards.LiquidityPosition storage position,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) private {
        if (amount0 != 0) {
            emit LiquidityRewardSettled(position.positionId, tokenId, position.currency0, amount0);
        }
        if (amount1 != 0) emit LiquidityRewardSettled(position.positionId, tokenId, position.currency1, amount1);
    }
}
