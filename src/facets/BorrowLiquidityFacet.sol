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
        return _borrowAndProvide(positionId, basketId, sharesIn, pools, lpRecipient, lpRecipient, false);
    }

    function borrowAndStakeLiquidity(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools
    ) external nonReentrant returns (uint256 loanId, uint256[] memory v4TokenIds) {
        address beneficiary = IERC721(address(this)).ownerOf(positionId);
        return _borrowAndProvide(positionId, basketId, sharesIn, pools, address(this), beneficiary, true);
    }

    function _borrowAndProvide(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools,
        address nftRecipient,
        address refundRecipient,
        bool stakePositions
    ) private returns (uint256 loanId, uint256[] memory v4TokenIds) {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }

        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
        uint256 assetCount = configured.assets.length;
        if (pools.length != assetCount) revert InvalidPoolCount(pools.length, assetCount);
        LibBasketLiquidity.LiquidityStorage storage liquidityStorage = LibBasketLiquidity.liquidityStorage();
        if (!liquidityStorage.managerInstalled) revert LiquidityManagerNotInstalled();

        (PreparedPool[] memory prepared, uint256[] memory poolAssetAmounts, uint256 basketShares) =
            _preparePools(liquidityStorage, configured, basketId, pools, stakePositions);
        uint256[] memory principals;
        (loanId, principals) =
            LibLoanOrigination.originate(positionId, basketId, sharesIn, msg.sender, refundRecipient, address(0));

        uint256[] memory mintInputs =
            LibBasketMint.quote(configured, basketShares, IERC20(configured.token).totalSupply());
        for (uint256 i; i < assetCount; ++i) {
            uint256 required = mintInputs[i] + poolAssetAmounts[i];
            if (required > principals[i]) {
                revert InsufficientPrincipal(configured.assets[i], required, principals[i]);
            }
        }
        LibBasketMint.mintFromRetainedPrincipal(basketId, basketShares, msg.sender, address(this));

        v4TokenIds = _provideLiquidity(
            liquidityStorage.manager,
            configured.token,
            basketId,
            loanId,
            positionId,
            prepared,
            nftRecipient,
            refundRecipient,
            stakePositions
        );
        _refundPrincipals(configured, basketId, principals, mintInputs, poolAssetAmounts, refundRecipient);
        if (stakePositions) {
            emit BorrowedLiquidityStaked(
                loanId, positionId, basketId, msg.sender, refundRecipient, sharesIn, basketShares, v4TokenIds
            );
        } else {
            emit BorrowedLiquidityProvided(
                loanId, positionId, basketId, msg.sender, refundRecipient, sharesIn, basketShares, v4TokenIds
            );
        }
    }

    function _preparePools(
        LibBasketLiquidity.LiquidityStorage storage ls,
        LibBasket.Basket storage configured,
        uint256 basketId,
        LiquidityParams[] calldata pools,
        bool requireFullRange
    ) private view returns (PreparedPool[] memory prepared, uint256[] memory poolAssetAmounts, uint256 basketShares) {
        uint256 length = pools.length;
        prepared = new PreparedPool[](length);
        poolAssetAmounts = new uint256[](length);
        bool[] memory seen = new bool[](length);
        IPoolManager poolManager = IPoolManager(ls.poolManager);

        for (uint256 i; i < length; ++i) {
            LiquidityParams calldata supplied = pools[i];
            uint256 assetIndex = _assetIndex(configured, basketId, supplied.asset);
            if (seen[assetIndex]) revert DuplicatePoolAsset(supplied.asset);
            seen[assetIndex] = true;
            LibBasketLiquidity.CanonicalPool storage stored = ls.canonicalPools[basketId][supplied.asset];
            _validateRange(supplied, stored.key.tickSpacing, requireFullRange);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(stored.key.toId());
            (uint256 amount0, uint256 amount1) = LibBasketLiquidityMath.rangeAmounts(
                sqrtPriceX96, supplied.tickLower, supplied.tickUpper, uint128(supplied.liquidity)
            );
            address currency0 = Currency.unwrap(stored.key.currency0);
            address currency1 = Currency.unwrap(stored.key.currency1);
            if (amount0 > supplied.amount0Max) revert AmountCapExceeded(currency0, amount0, supplied.amount0Max);
            if (amount1 > supplied.amount1Max) revert AmountCapExceeded(currency1, amount1, supplied.amount1Max);
            bool basketIsCurrency0 = currency0 == configured.token;
            uint256 basketAmount = basketIsCurrency0 ? amount0 : amount1;
            uint256 assetAmount = basketIsCurrency0 ? amount1 : amount0;
            if (basketAmount == 0 || assetAmount == 0) revert InvalidLiquidityParameters(supplied.asset);

            prepared[i] = PreparedPool({
                asset: supplied.asset,
                key: stored.key,
                tickLower: supplied.tickLower,
                tickUpper: supplied.tickUpper,
                liquidity: supplied.liquidity,
                basketAmount: basketAmount,
                assetAmount: assetAmount,
                deadline: supplied.deadline
            });
            poolAssetAmounts[assetIndex] = assetAmount;
            basketShares += basketAmount;
        }
    }

    function _provideLiquidity(
        address managerAddress,
        address basketToken,
        uint256 basketId,
        uint256 loanId,
        uint256 positionId,
        PreparedPool[] memory prepared,
        address nftRecipient,
        address refundRecipient,
        bool stakePositions
    ) private returns (uint256[] memory tokenIds) {
        IStaticsLiquidityManager manager = IStaticsLiquidityManager(managerAddress);
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        uint256 length = prepared.length;
        tokenIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            PreparedPool memory plan = prepared[i];
            (, uint256 basketReceived) =
                LibCustody.pushUnreserved(basketToken, managerAddress, plan.basketAmount, plan.basketAmount);
            (, uint256 assetReceived) =
                LibCustody.pushReserved(custodyAccount, plan.asset, managerAddress, plan.assetAmount, plan.assetAmount);
            bool basketIsCurrency0 = Currency.unwrap(plan.key.currency0) == basketToken;
            IStaticsLiquidityManager.PositionRequest memory request = IStaticsLiquidityManager.PositionRequest({
                basketId: basketId,
                asset: plan.asset,
                poolKey: plan.key,
                tickLower: plan.tickLower,
                tickUpper: plan.tickUpper,
                liquidity: plan.liquidity,
                amount0Limit: basketIsCurrency0 ? basketReceived : assetReceived,
                amount1Limit: basketIsCurrency0 ? assetReceived : basketReceived,
                deadline: plan.deadline
            });
            (IStaticsLiquidityManager.PositionMovement memory movement, uint256 refund0, uint256 refund1) =
                manager.mintUserPosition(request, nftRecipient, refundRecipient);
            tokenIds[i] = movement.tokenId;
            if (stakePositions) {
                _initializeLiquidityReward(manager, positionId, basketId, plan, movement.tokenId);
            }
            emit BorrowedLiquidityPositionMinted(
                loanId,
                basketId,
                plan.asset,
                movement.tokenId,
                nftRecipient,
                plan.liquidity,
                movement.spent0,
                movement.spent1,
                refund0,
                refund1
            );
        }
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
