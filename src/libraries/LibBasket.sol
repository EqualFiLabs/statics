// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";

library LibBasket {
    bytes32 internal constant BASKET_STORAGE_POSITION = keccak256("statics.storage.basket");
    uint256 internal constant SHARE_SCALE = 1e18;
    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_FEE_BPS = BPS;
    uint8 internal constant MAX_ASSETS = 16;

    struct Basket {
        address token;
        address creator;
        IStaticsBasket.BasketStatus status;
        address[] assets;
        uint256[] bundleAmounts;
        IStaticsBasket.FeeTier[] mintFeeTiers;
        IStaticsBasket.FeeTier[] redemptionFeeTiers;
        uint16 flashFeeBps;
        uint16 originationFeeBps;
        uint16 extensionFeeBps;
        uint16 ltvBps;
        uint16 recoveryPenaltyBps;
        uint40 loanDuration;
    }

    struct BasketStorage {
        uint256 basketCount;
        mapping(uint256 basketId => Basket) baskets;
        mapping(address token => uint256 basketIdPlusOne) basketIds;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) vaultBalances;
        uint256 creationFeeAmount;
        address treasury;
    }

    error BasketNotActive(uint256 basketId, IStaticsBasket.BasketStatus status);

    function basketStorage() internal pure returns (BasketStorage storage bs) {
        bytes32 position = BASKET_STORAGE_POSITION;
        assembly ("memory-safe") {
            bs.slot := position
        }
    }

    function backingAtSupply(uint256 bundleAmount, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(bundleAmount, supply, SHARE_SCALE, Math.Rounding.Ceil);
    }

    function backingIncrease(uint256 bundleAmount, uint256 supply, uint256 shares) internal pure returns (uint256) {
        return backingAtSupply(bundleAmount, supply + shares) - backingAtSupply(bundleAmount, supply);
    }

    function backingReduction(uint256 bundleAmount, uint256 supply, uint256 shares) internal pure returns (uint256) {
        return backingAtSupply(bundleAmount, supply) - backingAtSupply(bundleAmount, supply - shares);
    }

    function convertFeeShares(uint256 bundleAmount, uint256 feeShares) internal pure returns (uint256 amount) {
        return Math.mulDiv(bundleAmount, feeShares, SHARE_SCALE, Math.Rounding.Ceil);
    }

    function selectFeeShares(IStaticsBasket.FeeTier[] storage tiers, uint256 actionShares)
        internal
        view
        returns (uint256 selected)
    {
        uint256 selectedThreshold;
        bool found;
        uint256 length = tiers.length;
        for (uint256 i; i < length; ++i) {
            IStaticsBasket.FeeTier storage tier = tiers[i];
            if (tier.minActionShares <= actionShares && (!found || tier.minActionShares >= selectedThreshold)) {
                selected = tier.feeShares;
                selectedThreshold = tier.minActionShares;
                found = true;
            }
        }
    }

    function enforceActive(Basket storage configured, uint256 basketId) internal view {
        if (configured.status != IStaticsBasket.BasketStatus.Active) {
            revert BasketNotActive(basketId, configured.status);
        }
    }
}
