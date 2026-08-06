// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "./LibPositionPortfolio.sol";

library LibBasketCollateral {
    bytes32 internal constant COLLATERAL_STORAGE_POSITION = keccak256("statics.storage.basket.collateral.v1");

    struct PositionBasketCollateral {
        uint256 depositedShares;
        uint256 lockedShares;
        uint256 lastDepositBlock;
    }

    struct CollateralStorage {
        mapping(uint256 positionId => mapping(uint256 basketId => PositionBasketCollateral position)) positions;
    }

    error InsufficientPositionShares(uint256 requested, uint256 available);
    error PositionSharesLocked(uint256 requested, uint256 unlocked);
    error InsufficientLockedShares(uint256 requested, uint256 locked);
    error BurnSharesExceedCollateral(uint256 burnShares, uint256 collateralShares);
    error PositionDepositTooRecent(uint256 positionId, uint256 basketId, uint256 withdrawableAfterBlock);

    function collateralStorage() internal pure returns (CollateralStorage storage cs) {
        bytes32 position = COLLATERAL_STORAGE_POSITION;
        assembly ("memory-safe") {
            cs.slot := position
        }
    }

    function increasePosition(uint256 positionId, uint256 basketId, uint256 shares) internal {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        bytes32 legKey = LibPosition.basketLegKey(basketId);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (!ps.activeLeg[positionId][legKey]) {
            LibPosition.activateLeg(positionId, LibPosition.BASKET_MODULE, bytes32(basketId));
        }
        // Position creation can attach the initial basket leg before collateral is recorded.
        LibPositionPortfolio.addBasket(positionId, basketId);
        position.depositedShares += shares;
        position.lastDepositBlock = block.number;
    }

    function decreasePosition(uint256 positionId, uint256 basketId, uint256 shares) internal {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        uint256 deposited = position.depositedShares;
        if (shares > deposited) revert InsufficientPositionShares(shares, deposited);
        uint256 unlocked = deposited - position.lockedShares;
        if (shares > unlocked) revert PositionSharesLocked(shares, unlocked);
        uint256 withdrawableAfterBlock = position.lastDepositBlock + 1;
        if (block.number < withdrawableAfterBlock) {
            revert PositionDepositTooRecent(positionId, basketId, withdrawableAfterBlock);
        }
        position.depositedShares = deposited - shares;
    }

    function lockForLoan(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        uint256 feeShares,
        uint256 collateralShares
    ) internal {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        uint256 deposited = position.depositedShares;
        uint256 unlocked = deposited - position.lockedShares;
        if (sharesIn > unlocked) revert PositionSharesLocked(sharesIn, unlocked);
        position.depositedShares = deposited - feeShares;
        position.lockedShares += collateralShares;
    }

    function unlockAfterRepay(uint256 positionId, uint256 basketId, uint256 collateralShares) internal {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        uint256 locked = position.lockedShares;
        if (collateralShares > locked) revert InsufficientLockedShares(collateralShares, locked);
        position.lockedShares = locked - collateralShares;
    }

    function releaseAfterRecovery(uint256 positionId, uint256 basketId, uint256 collateralShares, uint256 burnShares)
        internal
    {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        uint256 locked = position.lockedShares;
        if (collateralShares > locked) revert InsufficientLockedShares(collateralShares, locked);
        if (burnShares > collateralShares) revert BurnSharesExceedCollateral(burnShares, collateralShares);
        uint256 deposited = position.depositedShares;
        if (burnShares > deposited) revert InsufficientPositionShares(burnShares, deposited);
        position.lockedShares = locked - collateralShares;
        position.depositedShares = deposited - burnShares;
    }

    function deactivateIfEmpty(uint256 positionId, uint256 basketId) internal {
        PositionBasketCollateral storage position = collateralStorage().positions[positionId][basketId];
        if (position.depositedShares != 0 || position.lockedShares != 0) return;
        bytes32 key = LibPosition.basketLegKey(basketId);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.activeLeg[positionId][key]) {
            LibPosition.deactivateLeg(positionId, key);
            LibPositionPortfolio.removeBasket(positionId, basketId);
        }
    }
}
