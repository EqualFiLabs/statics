// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorphoBlue} from "../interfaces/IMorphoBlue.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../libraries/LibGenesisRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibMorphoSync} from "../libraries/LibMorphoSync.sol";
import {StaticsMorphoAccount} from "../morpho/StaticsMorphoAccount.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract MorphoSettlementFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidAmount();
    error InvalidReceiver(address receiver);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 actual);
    error MorphoAccountNotDeployed(uint256 positionId);
    error MinimumRecoveryNotMet(address token, uint256 minimum, uint256 actual);
    error UnauthorizedPerformanceFeeRouter(address caller, address expected);
    error LiquidationSlippage(uint256 assetsSeized, uint256 minimum, uint256 assetsRepaid, uint256 maximum);

    struct LiquidationResult {
        uint256 assetsSeized;
        uint256 assetsRepaid;
        uint256 collateralReceived;
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
        LibMorpho.requireMarket(marketId_);
        LibMorpho.MorphoStorage storage ms = LibMorpho.requireInitialized();
        LibMorpho.enforceReceiver(ms, receiver);
        uint256 received = LibCustody.pull(ms.usdStx, msg.sender, maxRepayAssets);
        if (received != maxRepayAssets) revert IncompatibleTokenTransfer(ms.usdStx, maxRepayAssets, received);
        LiquidationResult memory result =
            _executeLiquidation(positionId, marketId_, seizedAssets, repaidShares, maxRepayAssets);
        assetsSeized = result.assetsSeized;
        assetsRepaid = result.assetsRepaid;
        if (assetsRepaid > maxRepayAssets || assetsSeized < minSeizedAssets) {
            revert LiquidationSlippage(assetsSeized, minSeizedAssets, assetsRepaid, maxRepayAssets);
        }
        if (maxRepayAssets > assetsRepaid) _pushExactUnreserved(ms.usdStx, msg.sender, maxRepayAssets - assetsRepaid);
        address collateralToken = LibMorpho.requireMarket(marketId_).params.collateralToken;
        if (result.collateralReceived != assetsSeized) {
            revert IncompatibleTokenTransfer(collateralToken, assetsSeized, result.collateralReceived);
        }
        _pushExactUnreserved(collateralToken, receiver, assetsSeized);
        LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
        emit IStaticsMorpho.MorphoLiquidatedAndSynchronized(
            positionId, marketId_, msg.sender, assetsSeized, assetsRepaid
        );
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

    function _pushExactUnreserved(address token, address receiver, uint256 amount) private {
        (uint256 spent, uint256 received) = LibCustody.pushUnreserved(token, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }

    function syncMorpho(uint256 positionId, bytes32 marketId_) external nonReentrant returns (uint256 trackedLoss) {
        return LibMorphoSync.syncOne(positionId, marketId_, msg.sender);
    }

    function syncMorphoForModule(uint256 positionId, address keeper) external {
        if (msg.sender != address(this)) revert LibPosition.InvalidModuleAuthority();
        LibMorphoSync.syncAll(positionId, keeper);
    }

    function claimMorphoSyncBounties(address[] calldata assets, address receiver)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        LibMorpho.MorphoStorage storage ms = LibMorpho.requireInitialized();
        LibMorpho.enforceReceiver(ms, receiver);
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 amount = ms.syncBounties[msg.sender][asset];
            if (amount == 0) continue;
            _pushExactReserved(asset, receiver, amount);
            delete ms.syncBounties[msg.sender][asset];
            ms.totalSyncBounties[asset] -= amount;
            amounts[i] = amount;
            emit IStaticsMorpho.MorphoSyncBountyClaimed(msg.sender, asset, receiver, amount);
        }
    }

    function recoverMorphoAccountToken(
        uint256 positionId,
        address token,
        uint256 amount,
        address receiver,
        uint256 minReceived
    ) external nonReentrant returns (uint256 received) {
        if (token == address(0) || amount == 0) revert InvalidAmount();
        LibMorpho.enforceRecoveryAuthorized(positionId, msg.sender);
        LibMorpho.MorphoStorage storage ms = LibMorpho.requireInitialized();
        LibMorpho.enforceReceiver(ms, receiver);
        address account = ms.accounts[positionId];
        if (account == address(0)) revert MorphoAccountNotDeployed(positionId);
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        if (LibRestrictedBasket.isRestricted(token)) {
            uint256 beforeBalance = IERC20(token).balanceOf(address(this));
            LibRestrictedBasket.authorizeProtocolTransfer(token, account, address(this), amount);
            StaticsMorphoAccount(account).sweepToken(token, address(this), amount);
            if (IERC20(token).balanceOf(address(this)) - beforeBalance != amount) revert InvalidAmount();
            LibCustody.pushUnreserved(token, receiver, amount, minReceived);
        } else {
            StaticsMorphoAccount(account).sweepToken(token, receiver, amount);
        }
        uint256 receiverAfter = IERC20(token).balanceOf(receiver);
        received = receiverAfter > receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received < minReceived) revert MinimumRecoveryNotMet(token, minReceived, received);
        emit IStaticsMorpho.MorphoAccountTokenRecovered(positionId, token, receiver, amount, received);
    }

    function routeMorphoPerformanceFee(uint256 realizedYield) external nonReentrant returns (uint256 feeAmount) {
        LibMorpho.MorphoStorage storage ms = LibMorpho.requireInitialized();
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

    function _pushExactReserved(address token, address receiver, uint256 amount) private {
        (uint256 spent, uint256 received) =
            LibCustody.pushReserved(LibCustody.feeAccount(), token, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }
}
