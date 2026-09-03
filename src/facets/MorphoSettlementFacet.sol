// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../libraries/LibGenesisRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {StaticsMorphoAccount} from "../morpho/StaticsMorphoAccount.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract MorphoSettlementFacet is ReentrancyGuard {
    error InvalidAmount();
    error InvalidReceiver(address receiver);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 actual);
    error MorphoAccountNotDeployed(uint256 positionId);
    error MinimumRecoveryNotMet(address token, uint256 minimum, uint256 actual);
    error UnauthorizedPerformanceFeeRouter(address caller, address expected);

    function claimMorphoSyncBounties(address[] calldata assets, address receiver)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        LibMorpho.MorphoStorage storage ms = _storage();
        _enforceReceiver(ms, receiver);
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
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.MorphoStorage storage ms = _storage();
        _enforceReceiver(ms, receiver);
        address account = ms.accounts[positionId];
        if (account == address(0)) revert MorphoAccountNotDeployed(positionId);
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        StaticsMorphoAccount(account).sweepToken(token, receiver, amount);
        uint256 receiverAfter = IERC20(token).balanceOf(receiver);
        received = receiverAfter > receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received < minReceived) revert MinimumRecoveryNotMet(token, minReceived, received);
        emit IStaticsMorpho.MorphoAccountTokenRecovered(positionId, token, receiver, amount, received);
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

    function _enforceReceiver(LibMorpho.MorphoStorage storage ms, address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || ms.isAccount[receiver]) {
            revert InvalidReceiver(receiver);
        }
    }

    function _pushExactReserved(address token, address receiver, uint256 amount) private {
        (uint256 spent, uint256 received) =
            LibCustody.pushReserved(LibCustody.feeAccount(), token, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }

    function _storage() private view returns (LibMorpho.MorphoStorage storage ms) {
        ms = LibMorpho.morphoStorage();
        if (!ms.initialized) revert LibMorpho.MorphoNotInitialized();
    }
}
