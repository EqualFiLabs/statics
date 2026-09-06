// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMorphoBlue, MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibMorphoSync} from "../libraries/LibMorphoSync.sol";

/// @notice Recovers surplus Morpho collateral held for a PositionNFT.
contract MorphoRecoveryFacet is ReentrancyGuard {
    error InvalidAmount();
    error InvalidReceiver(address receiver);
    error InsufficientUntrackedCollateral(uint256 requested, uint256 available);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 actual);

    function withdrawUntrackedMorphoCollateral(uint256 positionId, bytes32 marketId_, uint256 assets, address receiver)
        external
        nonReentrant
    {
        if (assets == 0) revert InvalidAmount();
        bool closedPosition = LibMorpho.enforceRecoveryAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        LibMorpho.MorphoStorage storage ms = _storage();
        _enforceReceiver(ms, receiver);
        if (!closedPosition) LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
        LibMorpho.PositionMarket storage tracked = ms.positions[positionId].positions[marketId_];
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        uint256 surplus = uint256(actual.collateral) - tracked.trackedCollateral;
        if (assets > surplus) revert InsufficientUntrackedCollateral(assets, surplus);
        uint256 beforeBalance = IERC20(config.params.collateralToken).balanceOf(receiver);
        IMorphoBlue(ms.morpho).withdrawCollateral(config.params, assets, LibMorpho.accountAddress(positionId), receiver);
        uint256 received = IERC20(config.params.collateralToken).balanceOf(receiver) - beforeBalance;
        if (received != assets) revert IncompatibleTokenTransfer(config.params.collateralToken, assets, received);
        if (!closedPosition) {
            actual = LibMorpho.actualPosition(positionId, marketId_);
            LibMorpho.syncDebtObligation(positionId, marketId_, actual.borrowShares);
            LibMorpho.deactivateIfEmpty(positionId, marketId_, actual);
        }
        emit IStaticsMorpho.MorphoSurplusWithdrawn(positionId, marketId_, receiver, assets);
    }

    function _enforceReceiver(LibMorpho.MorphoStorage storage ms, address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || ms.isAccount[receiver]) {
            revert InvalidReceiver(receiver);
        }
    }

    function _storage() private view returns (LibMorpho.MorphoStorage storage ms) {
        ms = LibMorpho.morphoStorage();
        if (!ms.initialized) revert LibMorpho.MorphoNotInitialized();
    }
}
