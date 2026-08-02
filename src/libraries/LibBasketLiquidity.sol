// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibCustody} from "./LibCustody.sol";

library LibBasketLiquidity {
    bytes32 internal constant LIQUIDITY_STORAGE_POSITION = keccak256("statics.storage.basket.liquidity.v1");

    struct PrimaryFeeTotals {
        uint256 holderAmount;
        uint256 liquidityAmount;
        uint256 protocolAmount;
    }

    struct CanonicalPool {
        PoolKey key;
        IStaticsBasketLiquidity.CanonicalPoolStatus status;
        uint40 initializedAt;
        uint40 activatedAt;
    }

    struct PoolAssociation {
        uint256 basketId;
        address asset;
        bool associated;
    }

    struct BasketLiquidityState {
        uint40 lastCompoundAt;
        uint40 nextCompoundAt;
        uint256 cumulativeSharesMinted;
    }

    struct LiquidityStorage {
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) liquidityReserve;
        mapping(uint256 basketId => mapping(address asset => PrimaryFeeTotals totals)) cumulativePrimaryFees;
        address poolManager;
        address hook;
        bool integrationInstalled;
        mapping(uint256 basketId => mapping(address asset => CanonicalPool pool)) canonicalPools;
        mapping(PoolId poolId => PoolAssociation association) poolAssociations;
        mapping(uint256 basketId => mapping(address asset => IStaticsBasketLiquidity.HookSettlementTotals totals))
            cumulativeHookSettlements;
        mapping(uint256 basketId => mapping(address revenueAsset => uint256 amount)) cumulativeHookRevenue;
        address manager;
        bool managerInstalled;
        mapping(uint256 basketId => mapping(address asset => bool synced)) managerPoolSynced;
        mapping(uint256 basketId => BasketLiquidityState state) basketLiquidityStates;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) cumulativeLiquidityAssetSent;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) cumulativeLiquidityAssetReceived;
        mapping(uint256 basketId => mapping(address asset => IStaticsBasketLiquidity.ProtocolLpFeeTotals totals))
            cumulativeProtocolLpFees;
        mapping(uint256 basketId => mapping(address asset => bool unwound)) liquidityUnwound;
    }

    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);

    function liquidityStorage() internal pure returns (LiquidityStorage storage ls) {
        bytes32 position = LIQUIDITY_STORAGE_POSITION;
        assembly ("memory-safe") {
            ls.slot := position
        }
    }

    function burnBasketTokensToRevenue(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256 shares
    ) internal returns (uint256[] memory revenueAmounts) {
        uint256 supply = IERC20(configured.token).totalSupply();
        uint256 tokenBalanceBefore = LibCustody.beginUnreservedDebit(configured.token, shares);
        StaticsBasketToken(configured.token).burn(address(this), shares);
        LibCustody.finishUnreservedDebit(configured.token, tokenBalanceBefore, shares);

        uint256 length = configured.assets.length;
        revenueAmounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address revenueAsset = configured.assets[i];
            uint256 amount = LibBasket.backingReduction(configured.bundleAmounts[i], supply, shares);
            uint256 available = bs.vaultBalances[basketId][revenueAsset];
            if (amount > available) revert InsufficientVaultBalance(revenueAsset, amount, available);
            bs.vaultBalances[basketId][revenueAsset] = available - amount;
            bs.protocolRevenue[basketId][revenueAsset] += amount;
            revenueAmounts[i] = amount;
        }
    }
}
