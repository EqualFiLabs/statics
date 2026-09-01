// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMorphoBlue, MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketCollateral} from "../libraries/LibBasketCollateral.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../libraries/LibGenesisRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibMorphoSync} from "../libraries/LibMorphoSync.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract MorphoFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InvalidReceiver(address receiver);
    error InsufficientAvailableCollateral(uint256 requested, uint256 available);
    error InsufficientTrackedCollateral(uint256 requested, uint256 tracked);
    error InsufficientUntrackedCollateral(uint256 requested, uint256 available);
    error BorrowSlippage(uint256 sharesBorrowed, uint256 maximum);
    error RepaySlippage(uint256 assetsRepaid, uint256 maximum);
    error LiquidationSlippage(uint256 assetsSeized, uint256 minimum, uint256 assetsRepaid, uint256 maximum);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 actual);
    error UnauthorizedPerformanceFeeRouter(address caller, address expected);

    struct LiquidationResult {
        uint256 assetsSeized;
        uint256 assetsRepaid;
        uint256 collateralReceived;
    }

    function deployMorphoCollateral(uint256 positionId, bytes32 marketId_, uint256 assets) external nonReentrant {
        if (assets == 0) revert InvalidAmount();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireActiveMarket(marketId_);
        LibMorpho.MorphoStorage storage ms = _storage();
        uint256 available;
        bytes32 custodyAccount;
        if (config.kind == IStaticsMorpho.CollateralKind.Basket) {
            LibBasketCollateral.PositionBasketCollateral storage collateral =
                LibBasketCollateral.collateralStorage().positions[positionId][config.basketId];
            available =
                collateral.depositedShares - collateral.lockedShares - ms.basketCollateral[positionId][config.basketId];
            custodyAccount = LibCustody.basketAccount(config.basketId);
            ms.basketCollateral[positionId][config.basketId] += assets;
        } else {
            uint256 balance = LibGlobalRewards.rewardStorage().positions[positionId].balance;
            available = balance - ms.staticsCollateral[positionId];
            custodyAccount = LibCustody.stakingAccount();
            ms.staticsCollateral[positionId] += assets;
        }
        if (assets > available) revert InsufficientAvailableCollateral(assets, available);
        address account = LibMorpho.ensureAccount(positionId);
        LibMorpho.trackMarket(positionId, marketId_);
        ms.positions[positionId].positions[marketId_].trackedCollateral += assets;
        LibCustody.release(custodyAccount, config.params.collateralToken, assets);
        IERC20(config.params.collateralToken).forceApprove(ms.morpho, assets);
        IMorphoBlue(ms.morpho).supplyCollateral(config.params, assets, account, "");
        IERC20(config.params.collateralToken).forceApprove(ms.morpho, 0);
        emit IStaticsMorpho.MorphoCollateralDeployed(positionId, marketId_, assets);
    }

    function recallMorphoCollateral(uint256 positionId, bytes32 marketId_, uint256 assets) external nonReentrant {
        if (assets == 0) revert InvalidAmount();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
        LibMorpho.MorphoStorage storage ms = _storage();
        LibMorpho.PositionMarket storage tracked = ms.positions[positionId].positions[marketId_];
        if (assets > tracked.trackedCollateral) {
            revert InsufficientTrackedCollateral(assets, tracked.trackedCollateral);
        }
        IMorphoBlue(ms.morpho)
            .withdrawCollateral(config.params, assets, LibMorpho.accountAddress(positionId), address(this));
        tracked.trackedCollateral -= assets;
        _decreaseSourceAllocation(ms, config, positionId, assets);
        LibCustody.reserve(_custodyAccount(config), config.params.collateralToken, assets);
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        LibMorpho.syncDebtObligation(positionId, marketId_, actual.borrowShares);
        LibMorpho.deactivateIfEmpty(positionId, marketId_, actual.borrowShares);
        emit IStaticsMorpho.MorphoCollateralRecalled(positionId, marketId_, assets);
    }

    function withdrawUntrackedMorphoCollateral(uint256 positionId, bytes32 marketId_, uint256 assets, address receiver)
        external
        nonReentrant
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver(receiver);
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
        LibMorpho.PositionMarket storage tracked = _storage().positions[positionId].positions[marketId_];
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        uint256 surplus = uint256(actual.collateral) - tracked.trackedCollateral;
        if (assets > surplus) revert InsufficientUntrackedCollateral(assets, surplus);
        IMorphoBlue(_storage().morpho)
            .withdrawCollateral(config.params, assets, LibMorpho.accountAddress(positionId), receiver);
        emit IStaticsMorpho.MorphoSurplusWithdrawn(positionId, marketId_, receiver, assets);
    }

    function borrowMorphoUsd(
        uint256 positionId,
        bytes32 marketId_,
        uint256 assets,
        uint256 maxBorrowShares,
        address receiver
    ) external nonReentrant returns (uint256 assetsBorrowed, uint256 sharesBorrowed) {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver(receiver);
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireActiveMarket(marketId_);
        address account = LibMorpho.ensureAccount(positionId);
        LibMorpho.trackMarket(positionId, marketId_);
        (assetsBorrowed, sharesBorrowed) =
            IMorphoBlue(_storage().morpho).borrow(config.params, assets, 0, account, receiver);
        if (sharesBorrowed > maxBorrowShares) revert BorrowSlippage(sharesBorrowed, maxBorrowShares);
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        LibMorpho.syncDebtObligation(positionId, marketId_, actual.borrowShares);
        emit IStaticsMorpho.MorphoBorrowed(positionId, marketId_, receiver, assetsBorrowed, sharesBorrowed);
    }

    function repayMorphoUsd(uint256 positionId, bytes32 marketId_, uint256 assets, uint256 shares, uint256 maxAssets)
        external
        nonReentrant
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        if ((assets == 0) == (shares == 0) || maxAssets == 0) revert InvalidAmount();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        LibMorpho.MorphoStorage storage ms = _storage();
        uint256 received = LibCustody.pull(ms.usdStx, msg.sender, maxAssets);
        if (received != maxAssets) revert IncompatibleTokenTransfer(ms.usdStx, maxAssets, received);
        IERC20(ms.usdStx).forceApprove(ms.morpho, maxAssets);
        (assetsRepaid, sharesRepaid) =
            IMorphoBlue(ms.morpho).repay(config.params, assets, shares, LibMorpho.accountAddress(positionId), "");
        IERC20(ms.usdStx).forceApprove(ms.morpho, 0);
        if (assetsRepaid > maxAssets) revert RepaySlippage(assetsRepaid, maxAssets);
        if (maxAssets > assetsRepaid) {
            LibCustody.pushUnreserved(ms.usdStx, msg.sender, maxAssets - assetsRepaid, maxAssets - assetsRepaid);
        }
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        LibMorpho.syncDebtObligation(positionId, marketId_, actual.borrowShares);
        LibMorpho.deactivateIfEmpty(positionId, marketId_, actual.borrowShares);
        emit IStaticsMorpho.MorphoRepaid(positionId, marketId_, assetsRepaid, sharesRepaid);
    }

    function syncMorpho(uint256 positionId, bytes32 marketId_) external nonReentrant returns (uint256 trackedLoss) {
        return LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
    }

    function syncMorphoForModule(uint256 positionId, address keeper) external {
        if (msg.sender != address(this)) revert LibPosition.InvalidModuleAuthority();
        LibMorphoSync.syncAll(positionId, keeper);
    }

    function liquidateMorphoAndSync(
        uint256 positionId,
        bytes32 marketId_,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 maxRepayAssets,
        uint256 minSeizedAssets,
        address receiver
    ) external nonReentrant returns (uint256 assetsSeized, uint256 assetsRepaid) {
        if ((seizedAssets == 0) == (repaidShares == 0) || maxRepayAssets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver(receiver);
        LibMorpho.requireMarket(marketId_);
        LibMorpho.MorphoStorage storage ms = _storage();
        uint256 received = LibCustody.pull(ms.usdStx, msg.sender, maxRepayAssets);
        if (received != maxRepayAssets) revert IncompatibleTokenTransfer(ms.usdStx, maxRepayAssets, received);
        LiquidationResult memory result =
            _executeLiquidation(positionId, marketId_, seizedAssets, repaidShares, maxRepayAssets);
        assetsSeized = result.assetsSeized;
        assetsRepaid = result.assetsRepaid;
        if (assetsRepaid > maxRepayAssets || assetsSeized < minSeizedAssets) {
            revert LiquidationSlippage(assetsSeized, minSeizedAssets, assetsRepaid, maxRepayAssets);
        }
        if (maxRepayAssets > assetsRepaid) {
            LibCustody.pushUnreserved(
                ms.usdStx, msg.sender, maxRepayAssets - assetsRepaid, maxRepayAssets - assetsRepaid
            );
        }
        address collateralToken = LibMorpho.requireMarket(marketId_).params.collateralToken;
        if (result.collateralReceived != assetsSeized) {
            revert IncompatibleTokenTransfer(collateralToken, assetsSeized, result.collateralReceived);
        }
        LibCustody.pushUnreserved(collateralToken, receiver, assetsSeized, assetsSeized);
        LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
        emit IStaticsMorpho.MorphoLiquidatedAndSynchronized(
            positionId, marketId_, msg.sender, assetsSeized, assetsRepaid
        );
    }

    function claimMorphoSyncBounties(address[] calldata assets, address receiver)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (receiver == address(0)) revert InvalidReceiver(receiver);
        LibMorpho.MorphoStorage storage ms = _storage();
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 amount = ms.syncBounties[msg.sender][asset];
            if (amount == 0) continue;
            delete ms.syncBounties[msg.sender][asset];
            ms.totalSyncBounties[asset] -= amount;
            LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
            amounts[i] = amount;
            emit IStaticsMorpho.MorphoSyncBountyClaimed(msg.sender, asset, receiver, amount);
        }
    }

    function routeMorphoPerformanceFee(uint256 realizedYield) external nonReentrant returns (uint256 feeAmount) {
        LibMorpho.MorphoStorage storage ms = _storage();
        address router = ms.performanceFeeRouter;
        if (router == address(0) || msg.sender != router) {
            revert UnauthorizedPerformanceFeeRouter(msg.sender, router);
        }
        uint256 operatorAmount;
        uint256 treasuryAmount;
        (feeAmount, operatorAmount, treasuryAmount) = _quotePerformanceFee(ms, realizedYield);
        if (feeAmount == 0) return 0;
        uint256 received =
            LibCustody.pullAndReserve(LibCustody.genesisRewardAccount(), ms.usdStx, msg.sender, feeAmount);
        if (received != feeAmount) revert IncompatibleTokenTransfer(ms.usdStx, feeAmount, received);
        LibGenesisIntegration.genesisStorage().accountedCustody[ms.usdStx] += feeAmount;
        LibGenesisRewards.allocateLenderPerformanceFee(ms.usdStx, feeAmount, operatorAmount);
        emit IStaticsMorpho.MorphoPerformanceFeeRouted(
            msg.sender, realizedYield, feeAmount, operatorAmount, treasuryAmount
        );
    }

    function _decreaseSourceAllocation(
        LibMorpho.MorphoStorage storage ms,
        LibMorpho.MarketConfig storage config,
        uint256 positionId,
        uint256 amount
    ) private {
        if (config.kind == IStaticsMorpho.CollateralKind.Basket) {
            ms.basketCollateral[positionId][config.basketId] -= amount;
        } else {
            ms.staticsCollateral[positionId] -= amount;
        }
    }

    function _executeLiquidation(
        uint256 positionId,
        bytes32 marketId_,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 maxRepayAssets
    ) private returns (LiquidationResult memory result) {
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        address collateralToken = config.params.collateralToken;
        uint256 beforeBalance = IERC20(collateralToken).balanceOf(address(this));
        IERC20(ms.usdStx).forceApprove(ms.morpho, maxRepayAssets);
        (result.assetsSeized, result.assetsRepaid) = IMorphoBlue(ms.morpho)
            .liquidate(config.params, LibMorpho.accountAddress(positionId), seizedAssets, repaidShares, "");
        IERC20(ms.usdStx).forceApprove(ms.morpho, 0);
        result.collateralReceived = IERC20(collateralToken).balanceOf(address(this)) - beforeBalance;
    }

    function _quotePerformanceFee(LibMorpho.MorphoStorage storage ms, uint256 realizedYield)
        private
        view
        returns (uint256 feeAmount, uint256 operatorAmount, uint256 treasuryAmount)
    {
        if (ms.performanceFeeRouter == address(0)) return (0, 0, 0);
        feeAmount = realizedYield * ms.performanceFeeBps / LibBasket.BPS;
        operatorAmount = feeAmount * ms.operatorShareBps / LibBasket.BPS;
        treasuryAmount = feeAmount - operatorAmount;
        if (LibGenesisIntegration.genesisStorage().totalWeight == 0) {
            treasuryAmount += operatorAmount;
            operatorAmount = 0;
        }
    }

    function _custodyAccount(LibMorpho.MarketConfig storage config) private view returns (bytes32) {
        if (config.kind == IStaticsMorpho.CollateralKind.Basket) {
            return LibCustody.basketAccount(config.basketId);
        }
        return LibCustody.stakingAccount();
    }

    function _storage() private view returns (LibMorpho.MorphoStorage storage ms) {
        ms = LibMorpho.morphoStorage();
        if (!ms.initialized) revert LibMorpho.MorphoNotInitialized();
    }
}
