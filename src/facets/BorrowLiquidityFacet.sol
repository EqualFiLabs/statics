// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBorrowLiquidity} from "../interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketLiquidityMath} from "../libraries/LibBasketLiquidityMath.sol";
import {LibBasketMint} from "../libraries/LibBasketMint.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLoanOrigination} from "../libraries/LibLoanOrigination.sol";
import {LibLiquidityRewards} from "../libraries/LibLiquidityRewards.sol";

contract BorrowLiquidityFacet is IStaticsBorrowLiquidity, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct PreparedPool {
        address asset;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint256 basketAmount;
        uint256 assetAmount;
        uint256 deadline;
    }

    struct BorrowLiquidityRequest {
        uint256 positionId;
        uint256 basketId;
        uint256 sharesIn;
        address nftRecipient;
        address refundRecipient;
        bool stakePositions;
    }

    struct PreparedBorrow {
        PreparedPool[] pools;
        uint256[] assetAmounts;
        uint256 basketShares;
    }

    struct ProvisionContext {
        address manager;
        address basketToken;
        uint256 basketId;
        uint256 loanId;
        uint256 positionId;
        address nftRecipient;
        address refundRecipient;
        bool stakePositions;
        bytes32 custodyAccount;
    }

    error BasketNotFound(uint256 basketId);
    error InvalidRecipient();
    error InvalidPoolCount(uint256 provided, uint256 required);
    error DuplicatePoolAsset(address asset);
    error AssetNotInBasket(uint256 basketId, address asset);
    error LiquidityManagerNotInstalled();
    error InvalidLiquidityParameters(address asset);
    error AmountCapExceeded(address token, uint256 required, uint256 maximum);
    error InsufficientPrincipal(address asset, uint256 required, uint256 available);
    error PositionLiquidityMismatch(uint256 tokenId, uint256 expected, uint256 actual);
    error ActionPaused(uint256 action);

    function borrowAndProvideLiquidity(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools,
        address lpRecipient
    ) external nonReentrant returns (uint256 loanId, uint256[] memory v4TokenIds) {
        if (lpRecipient == address(0)) revert InvalidRecipient();
        BorrowLiquidityRequest memory request = BorrowLiquidityRequest({
            positionId: positionId,
            basketId: basketId,
            sharesIn: sharesIn,
            nftRecipient: lpRecipient,
            refundRecipient: lpRecipient,
            stakePositions: false
        });
        return _borrowAndProvide(request, pools);
    }

    function borrowAndStakeLiquidity(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools
    ) external nonReentrant returns (uint256 loanId, uint256[] memory v4TokenIds) {
        address beneficiary = IERC721(address(this)).ownerOf(positionId);
        BorrowLiquidityRequest memory request = BorrowLiquidityRequest({
            positionId: positionId,
            basketId: basketId,
            sharesIn: sharesIn,
            nftRecipient: address(this),
            refundRecipient: beneficiary,
            stakePositions: true
        });
        return _borrowAndProvide(request, pools);
    }

    function _borrowAndProvide(BorrowLiquidityRequest memory request, LiquidityParams[] calldata pools)
        private
        returns (uint256 loanId, uint256[] memory v4TokenIds)
    {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }

        LibBasket.Basket storage configured;
        LibBasketLiquidity.LiquidityStorage storage ls;
        {
            LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
            configured = bs.baskets[request.basketId];
            if (configured.token == address(0)) revert BasketNotFound(request.basketId);
            uint256 assetCount = configured.assets.length;
            if (pools.length != assetCount) revert InvalidPoolCount(pools.length, assetCount);
            ls = LibBasketLiquidity.liquidityStorage();
            if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        }

        PreparedBorrow memory prepared = _preparePools(ls, configured, request.basketId, pools, request.stakePositions);
        uint256[] memory principals;
        uint256[] memory mintInputs;
        {
            LibLoanOrigination.OriginationRequest memory origination = LibLoanOrigination.OriginationRequest({
                positionId: request.positionId,
                basketId: request.basketId,
                sharesIn: request.sharesIn,
                operator: msg.sender,
                eventReceiver: request.refundRecipient,
                principalReceiver: address(0)
            });
            (loanId, principals) = LibLoanOrigination.originate(origination);
            mintInputs = LibBasketMint.quote(configured, prepared.basketShares, IERC20(configured.token).totalSupply());
            _verifyPrincipalCoverage(configured, principals, mintInputs, prepared.assetAmounts);
        }
        LibBasketMint.mintFromRetainedPrincipal(request.basketId, prepared.basketShares, msg.sender, address(this));

        v4TokenIds = _provideLiquidity(_provisionContext(ls, configured, loanId, request), prepared.pools);
        _refundPrincipals(
            configured, request.basketId, principals, mintInputs, prepared.assetAmounts, request.refundRecipient
        );
        if (request.stakePositions) {
            emit BorrowedLiquidityStaked(
                loanId,
                request.positionId,
                request.basketId,
                msg.sender,
                request.refundRecipient,
                request.sharesIn,
                prepared.basketShares,
                v4TokenIds
            );
        } else {
            emit BorrowedLiquidityProvided(
                loanId,
                request.positionId,
                request.basketId,
                msg.sender,
                request.refundRecipient,
                request.sharesIn,
                prepared.basketShares,
                v4TokenIds
            );
        }
    }

    function _verifyPrincipalCoverage(
        LibBasket.Basket storage configured,
        uint256[] memory principals,
        uint256[] memory mintInputs,
        uint256[] memory poolAssetAmounts
    ) private view {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 required = mintInputs[i] + poolAssetAmounts[i];
            if (required > principals[i]) {
                revert InsufficientPrincipal(configured.assets[i], required, principals[i]);
            }
        }
    }

    function _provisionContext(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 loanId,
        BorrowLiquidityRequest memory request
    ) private view returns (ProvisionContext memory ctx) {
        ctx = ProvisionContext({
            manager: ls.manager,
            basketToken: configured.token,
            basketId: request.basketId,
            loanId: loanId,
            positionId: request.positionId,
            nftRecipient: request.nftRecipient,
            refundRecipient: request.refundRecipient,
            stakePositions: request.stakePositions,
            custodyAccount: LibCustody.basketAccount(request.basketId)
        });
    }

    function _preparePools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        LiquidityParams[] calldata pools,
        bool requireFullRange
    ) private view returns (PreparedBorrow memory result) {
        uint256 length = pools.length;
        result.pools = new PreparedPool[](length);
        result.assetAmounts = new uint256[](length);
        bool[] memory seen = new bool[](length);

        for (uint256 i; i < length; ++i) {
            LiquidityParams calldata supplied = pools[i];
            uint256 assetIndex = _assetIndex(configured, basketId, supplied.asset);
            if (seen[assetIndex]) revert DuplicatePoolAsset(supplied.asset);
            seen[assetIndex] = true;
            result.pools[i] = _preparePool(ls, configured, basketId, supplied, requireFullRange);
            result.assetAmounts[assetIndex] = result.pools[i].assetAmount;
            result.basketShares += result.pools[i].basketAmount;
        }
    }

    function _preparePool(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        LiquidityParams calldata supplied,
        bool requireFullRange
    ) private view returns (PreparedPool memory pool) {
        LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][supplied.asset];
        _validateRange(supplied, stored.key.tickSpacing, requireFullRange);
        pool.asset = supplied.asset;
        pool.key = stored.key;
        pool.tickLower = supplied.tickLower;
        pool.tickUpper = supplied.tickUpper;
        pool.liquidity = supplied.liquidity;
        pool.deadline = supplied.deadline;
        {
            (uint160 sqrtPriceX96,,,) = IPoolManager(ls.poolManager).getSlot0(stored.key.toId());
            (uint256 amount0, uint256 amount1) = LibBasketLiquidityMath.rangeAmounts(
                sqrtPriceX96, supplied.tickLower, supplied.tickUpper, uint128(supplied.liquidity)
            );
            if (amount0 > supplied.amount0Max) {
                revert AmountCapExceeded(Currency.unwrap(stored.key.currency0), amount0, supplied.amount0Max);
            }
            if (amount1 > supplied.amount1Max) {
                revert AmountCapExceeded(Currency.unwrap(stored.key.currency1), amount1, supplied.amount1Max);
            }
            bool basketIsCurrency0 = Currency.unwrap(stored.key.currency0) == configured.token;
            pool.basketAmount = basketIsCurrency0 ? amount0 : amount1;
            pool.assetAmount = basketIsCurrency0 ? amount1 : amount0;
        }
        if (pool.basketAmount == 0 || pool.assetAmount == 0) revert InvalidLiquidityParameters(supplied.asset);
    }

    function _provideLiquidity(ProvisionContext memory ctx, PreparedPool[] memory prepared)
        private
        returns (uint256[] memory tokenIds)
    {
        IStaticsLiquidityManager manager = IStaticsLiquidityManager(ctx.manager);
        uint256 length = prepared.length;
        tokenIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            tokenIds[i] = _mintLiquidityPosition(manager, ctx, prepared[i]);
        }
    }

    function _mintLiquidityPosition(
        IStaticsLiquidityManager manager,
        ProvisionContext memory ctx,
        PreparedPool memory plan
    ) private returns (uint256 tokenId) {
        (, uint256 basketReceived) = LibCustody.pushUnreserved(
            ctx.basketToken, ctx.manager, plan.basketAmount, plan.basketAmount
        );
        (, uint256 assetReceived) =
            LibCustody.pushReserved(ctx.custodyAccount, plan.asset, ctx.manager, plan.assetAmount, plan.assetAmount);
        bool basketIsCurrency0 = Currency.unwrap(plan.key.currency0) == ctx.basketToken;
        IStaticsLiquidityManager.PositionRequest memory request = IStaticsLiquidityManager.PositionRequest({
            poolKey: plan.key,
            tickLower: plan.tickLower,
            tickUpper: plan.tickUpper,
            liquidity: plan.liquidity,
            amount0Limit: basketIsCurrency0 ? basketReceived : assetReceived,
            amount1Limit: basketIsCurrency0 ? assetReceived : basketReceived,
            deadline: plan.deadline
        });
        (IStaticsLiquidityManager.PositionMovement memory movement, uint256 refund0, uint256 refund1) =
            manager.mintUserPosition(request, ctx.nftRecipient, ctx.refundRecipient);
        tokenId = movement.tokenId;
        if (ctx.stakePositions) {
            _initializeLiquidityReward(manager, ctx.positionId, ctx.basketId, plan, tokenId);
        }
        emit BorrowedLiquidityPositionMinted(
            ctx.loanId,
            ctx.basketId,
            plan.asset,
            movement.tokenId,
            ctx.nftRecipient,
            plan.liquidity,
            movement.spent0,
            movement.spent1,
            refund0,
            refund1
        );
    }

    function _initializeLiquidityReward(
        IStaticsLiquidityManager manager,
        uint256 positionId,
        uint256 basketId,
        PreparedPool memory plan,
        uint256 tokenId
    ) private {
        uint256 actualLiquidity = IPositionManager(manager.positionManager()).getPositionLiquidity(tokenId);
        if (actualLiquidity != plan.liquidity) {
            revert PositionLiquidityMismatch(tokenId, plan.liquidity, actualLiquidity);
        }
        PoolId poolId = plan.key.toId();
        address currency0 = Currency.unwrap(plan.key.currency0);
        address currency1 = Currency.unwrap(plan.key.currency1);
        LibLiquidityRewards.cachePoolCurrencies(poolId, currency0, currency1);
        LibLiquidityRewards.LiquidityPosition storage position = LibLiquidityRewards.initializeRecord(
            tokenId, positionId, basketId, plan.asset, poolId, currency0, currency1, actualLiquidity
        );
        emit IStaticsLiquidityRewards.LiquidityPositionStaked(
            positionId, tokenId, poolId, actualLiquidity, position.eligibleAtBlock
        );
    }

    function _refundPrincipals(
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256[] memory principals,
        uint256[] memory mintInputs,
        uint256[] memory poolAssetAmounts,
        address receiver
    ) private {
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 refund = principals[i] - mintInputs[i] - poolAssetAmounts[i];
            if (refund != 0) {
                LibCustody.pushReserved(custodyAccount, configured.assets[i], receiver, refund, refund);
            }
        }
    }

    function _assetIndex(LibBasket.Basket storage configured, uint256 basketId, address asset)
        private
        view
        returns (uint256 index)
    {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            if (configured.assets[i] == asset) return i;
        }
        revert AssetNotInBasket(basketId, asset);
    }

    function _validateRange(LiquidityParams calldata supplied, int24 tickSpacing, bool requireFullRange) private view {
        int24 minimumTick = TickMath.minUsableTick(tickSpacing);
        int24 maximumTick = TickMath.maxUsableTick(tickSpacing);
        if (
            supplied.liquidity == 0 || supplied.liquidity > type(uint128).max || supplied.deadline < block.timestamp
                || supplied.tickLower >= supplied.tickUpper || supplied.tickLower < minimumTick
                || supplied.tickUpper > maximumTick || supplied.tickLower % tickSpacing != 0
                || supplied.tickUpper % tickSpacing != 0
                || (requireFullRange && (supplied.tickLower != minimumTick || supplied.tickUpper != maximumTick))
        ) revert InvalidLiquidityParameters(supplied.asset);
    }
}
