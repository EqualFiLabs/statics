// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLiquidityRewards} from "../libraries/LibLiquidityRewards.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract LiquidityRewardsFacet is IStaticsLiquidityRewards, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    error InvalidReceiver();
    error InvalidLiquidityAmount();
    error LiquidityActionPaused();
    error LiquidityManagerNotInstalled();
    error CanonicalPoolNotActive(uint256 basketId, address asset);
    error PoolNotCanonical(PoolId poolId);
    error PositionPoolMismatch(uint256 tokenId, PoolId expected, PoolId actual);
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

    function stakeLiquidityPosition(uint256 positionId, uint256 tokenId) external nonReentrant {
        _enforceLiquidityAvailable();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        IPositionManager positionManager = _positionManager();
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        IERC721 positionNft = IERC721(address(positionManager));
        address lpOwner = positionNft.ownerOf(tokenId);
        if (lpOwner != positionOwner) revert PositionOwnerMismatch(tokenId, positionOwner, lpOwner);

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        (LibBasketLiquidity.PoolAssociation storage association, LibBasketLiquidity.CanonicalPool storage pool) =
            _canonicalPool(poolId);
        LibBasket.enforceActive(LibBasket.basketStorage().baskets[association.basketId], association.basketId);
        if (pool.status != IStaticsBasketLiquidity.CanonicalPoolStatus.Active) {
            revert CanonicalPoolNotActive(association.basketId, association.asset);
        }
        if (info.hasSubscriber()) revert PositionHasSubscriber(tokenId);
        int24 expectedLower = TickMath.minUsableTick(key.tickSpacing);
        int24 expectedUpper = TickMath.maxUsableTick(key.tickSpacing);
        if (info.tickLower() != expectedLower || info.tickUpper() != expectedUpper) {
            revert PositionRangeNotFull(tokenId, info.tickLower(), info.tickUpper());
        }
        uint256 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert InvalidLiquidityAmount();

        positionNft.transferFrom(lpOwner, address(this), tokenId);
        if (positionNft.ownerOf(tokenId) != address(this)) {
            revert PositionOwnerMismatch(tokenId, address(this), positionNft.ownerOf(tokenId));
        }
        if (positionManager.getPositionLiquidity(tokenId) != liquidity) {
            revert PositionLiquidityMismatch(tokenId, liquidity, positionManager.getPositionLiquidity(tokenId));
        }
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        LibLiquidityRewards.cachePoolCurrencies(poolId, currency0, currency1);
        LibLiquidityRewards.LiquidityPosition storage position = LibLiquidityRewards.initializeRecord(
            tokenId, positionId, association.basketId, association.asset, poolId, currency0, currency1, liquidity
        );
        emit LiquidityPositionStaked(positionId, tokenId, poolId, liquidity, position.eligibleAtBlock);
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
        (LibBasketLiquidity.PoolAssociation storage association, LibBasketLiquidity.CanonicalPool storage pool) =
            _canonicalPool(position.poolId);
        LibBasket.enforceActive(LibBasket.basketStorage().baskets[association.basketId], association.basketId);
        if (pool.status != IStaticsBasketLiquidity.CanonicalPoolStatus.Active) {
            revert CanonicalPoolNotActive(association.basketId, association.asset);
        }
        LibLiquidityRewards.activateIfMatured(tokenId);
        (uint256 settled0, uint256 settled1) = LibLiquidityRewards.settle(tokenId);
        _emitSettled(position, tokenId, settled0, settled1);

        IPositionManager positionManager = _positionManager();
        uint256 beforeLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 recordedLiquidity = uint256(position.eligibleLiquidity) + uint256(position.pendingLiquidity);
        if (beforeLiquidity != recordedLiquidity) {
            revert PositionLiquidityMismatch(tokenId, recordedLiquidity, beforeLiquidity);
        }

        address managerAddress = LibBasketLiquidity.liquidityStorage().manager;
        uint256 funded0 = _fundManager(position.currency0, managerAddress, request.amount0Max);
        uint256 funded1 = _fundManager(position.currency1, managerAddress, request.amount1Max);
        IStaticsLiquidityManager.PositionRequest memory managerRequest = IStaticsLiquidityManager.PositionRequest({
            basketId: position.basketId,
            asset: position.asset,
            poolKey: pool.key,
            tickLower: TickMath.minUsableTick(pool.key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(pool.key.tickSpacing),
            liquidity: request.liquidityDelta,
            amount0Limit: funded0,
            amount1Limit: funded1,
            deadline: request.deadline
        });
        IStaticsLiquidityManager.PositionMovement memory movement;
        (movement, refund0, refund1) =
            IStaticsLiquidityManager(managerAddress).increaseUserPosition(managerRequest, tokenId, refundReceiver);
        spent0 = movement.spent0;
        spent1 = movement.spent1;
        if (spent0 + refund0 != funded0 + movement.received0) {
            revert IncompatibleLiquidityAsset(position.currency0, funded0 + movement.received0, spent0 + refund0);
        }
        if (spent1 + refund1 != funded1 + movement.received1) {
            revert IncompatibleLiquidityAsset(position.currency1, funded1 + movement.received1, spent1 + refund1);
        }
        uint256 afterLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 expectedLiquidity = beforeLiquidity + request.liquidityDelta;
        if (afterLiquidity != expectedLiquidity) {
            revert PositionLiquidityMismatch(tokenId, expectedLiquidity, afterLiquidity);
        }
        LibLiquidityRewards.addPending(tokenId, request.liquidityDelta);
        emit StakedLiquidityIncreased(
            positionId,
            tokenId,
            position.poolId,
            request.liquidityDelta,
            spent0,
            spent1,
            refund0,
            refund1,
            position.eligibleAtBlock
        );
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
        (LibBasketLiquidity.PoolAssociation storage association, LibBasketLiquidity.CanonicalPool storage pool) =
            _canonicalPool(poolId);
        address currency0 = Currency.unwrap(pool.key.currency0);
        address currency1 = Currency.unwrap(pool.key.currency1);
        if (asset != currency0 && asset != currency1) revert InvalidRewardAsset(poolId, asset);
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
                association.basketId,
                LibBasket.basketStorage().baskets[association.basketId],
                asset,
                basketStakerAmount
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
        LibBasketLiquidity.PoolAssociation storage association =
            LibBasketLiquidity.liquidityStorage().poolAssociations[poolId];
        if (!association.associated || _poolIsDecommissioned(poolId)) return false;
        return LibBasketRewards.canAccrue(association.basketId);
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

    function _canonicalPool(PoolId poolId)
        private
        view
        returns (LibBasketLiquidity.PoolAssociation storage association, LibBasketLiquidity.CanonicalPool storage pool)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        association = ls.poolAssociations[poolId];
        if (!association.associated) revert PoolNotCanonical(poolId);
        pool = ls.canonicalPools[association.basketId][association.asset];
        PoolId actual = pool.key.toId();
        if (PoolId.unwrap(actual) != PoolId.unwrap(poolId)) revert PositionPoolMismatch(0, poolId, actual);
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
