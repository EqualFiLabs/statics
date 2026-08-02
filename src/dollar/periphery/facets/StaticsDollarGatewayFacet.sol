// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "../../interfaces/IStaticsDollarGateway.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";

contract StaticsDollarGatewayFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WETH_PROFILE_ID = 1;

    struct ResidualSnapshot {
        uint256 wethUnreserved;
        uint256 staticsDollarUnreserved;
        uint256 riskShareBalance;
        uint256 nativeBalance;
    }

    function depositETH(
        address staticsDollarReceiver,
        address shareReceiver,
        uint256 minStaticsDollar,
        uint256 minShares
    ) external payable nonReentrant returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted) {
        if (msg.value == 0) revert IStaticsDollarGateway.ZeroAmount();
        _requireReceiver(staticsDollarReceiver);
        _requireReceiver(shareReceiver);

        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.DepositPreview memory preview =
            _requireDepositMinimums(ps, msg.value, minStaticsDollar, minShares);
        ResidualSnapshot memory residuals = _residualSnapshot(ps, preview.seriesId, msg.value);

        IWETH9(ps.weth).deposit{value: msg.value}();
        IERC20(ps.weth).forceApprove(ps.pool, msg.value);
        uint256 wethBefore = LibCustody.beginUnreservedDebit(ps.weth, msg.value);
        (seriesId, staticsDollarMinted, sharesMinted) = IStaticsDollarCore(ps.pool)
            .depositCollateral(
                WETH_PROFILE_ID, msg.value, minStaticsDollar, minShares, staticsDollarReceiver, shareReceiver
            );
        LibCustody.finishUnreservedDebit(ps.weth, wethBefore, msg.value);
        IERC20(ps.weth).forceApprove(ps.pool, 0);
        _assertResidualBalancesRestored(ps, seriesId, residuals);

        emit IStaticsDollarGateway.ETHDeposited(
            msg.sender,
            staticsDollarReceiver,
            shareReceiver,
            WETH_PROFILE_ID,
            seriesId,
            msg.value,
            staticsDollarMinted,
            sharesMinted
        );
    }

    function depositWETH(
        uint256 wethAmount,
        address staticsDollarReceiver,
        address shareReceiver,
        uint256 minStaticsDollar,
        uint256 minShares
    ) external nonReentrant returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted) {
        if (wethAmount == 0) revert IStaticsDollarGateway.ZeroAmount();
        _requireReceiver(staticsDollarReceiver);
        _requireReceiver(shareReceiver);

        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.DepositPreview memory preview =
            _requireDepositMinimums(ps, wethAmount, minStaticsDollar, minShares);
        ResidualSnapshot memory residuals = _residualSnapshot(ps, preview.seriesId, 0);
        uint256 received = LibCustody.pull(ps.weth, msg.sender, wethAmount);
        if (received != wethAmount) {
            revert IStaticsDollarGateway.InsufficientTransferReceived(ps.weth, wethAmount, received);
        }
        IERC20(ps.weth).forceApprove(ps.pool, wethAmount);
        uint256 wethBefore = LibCustody.beginUnreservedDebit(ps.weth, wethAmount);
        (seriesId, staticsDollarMinted, sharesMinted) = IStaticsDollarCore(ps.pool)
            .depositCollateral(
                WETH_PROFILE_ID, wethAmount, minStaticsDollar, minShares, staticsDollarReceiver, shareReceiver
            );
        LibCustody.finishUnreservedDebit(ps.weth, wethBefore, wethAmount);
        IERC20(ps.weth).forceApprove(ps.pool, 0);
        _assertResidualBalancesRestored(ps, seriesId, residuals);

        emit IStaticsDollarGateway.WETHDeposited(
            msg.sender,
            staticsDollarReceiver,
            shareReceiver,
            WETH_PROFILE_ID,
            seriesId,
            wethAmount,
            staticsDollarMinted,
            sharesMinted
        );
    }

    function recombineToWETH(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minWETHOut
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RedemptionPreview memory preview;
        (status, preview) = _prepareRecombination(ps, seriesId, staticsDollarAmount, maxSharesIn, receiver, minWETHOut);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        wethOut =
            _executeRecombinationToWETH(ps, seriesId, staticsDollarAmount, preview.sharesBurned, receiver, minWETHOut);
    }

    function recombineToWETHWithPermit(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minWETHOut,
        IStaticsDollarGateway.PermitSignature calldata permitSignature
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RedemptionPreview memory preview;
        (status, preview) = _prepareRecombination(ps, seriesId, staticsDollarAmount, maxSharesIn, receiver, minWETHOut);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        _permitToken(ps.staticsDollar, staticsDollarAmount, permitSignature);
        wethOut =
            _executeRecombinationToWETH(ps, seriesId, staticsDollarAmount, preview.sharesBurned, receiver, minWETHOut);
    }

    function recombineToETH(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minETHOut
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RedemptionPreview memory preview;
        (status, preview) = _prepareRecombination(ps, seriesId, staticsDollarAmount, maxSharesIn, receiver, minETHOut);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        ethOut =
            _executeRecombinationToETH(ps, seriesId, staticsDollarAmount, preview.sharesBurned, receiver, minETHOut);
    }

    function recombineToETHWithPermit(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minETHOut,
        IStaticsDollarGateway.PermitSignature calldata permitSignature
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RedemptionPreview memory preview;
        (status, preview) = _prepareRecombination(ps, seriesId, staticsDollarAmount, maxSharesIn, receiver, minETHOut);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        _permitToken(ps.staticsDollar, staticsDollarAmount, permitSignature);
        ethOut =
            _executeRecombinationToETH(ps, seriesId, staticsDollarAmount, preview.sharesBurned, receiver, minETHOut);
    }

    function previewPeggedMint(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview)
    {
        return IStaticsDollarCore(LibPeriphery.s().pool).previewPeggedMint(profileId, staticsDollarAmount);
    }

    function mintPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver
    ) external nonReentrant returns (uint256 collateralIn) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview =
            _preparePeggedMint(ps, profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver);
        collateralIn =
            _executePeggedMint(ps, profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver, preview);
    }

    function mintPeggedWithPermit(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver,
        IStaticsDollarGateway.PermitSignature calldata permitSignature
    ) external nonReentrant returns (uint256 collateralIn) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview =
            _preparePeggedMint(ps, profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver);
        _permitToken(preview.collateralToken, preview.totalCollateralIn, permitSignature);
        collateralIn =
            _executePeggedMint(ps, profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver, preview);
    }

    function _executePeggedMint(
        LibPeriphery.PS storage ps,
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver,
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview
    ) private returns (uint256 collateralIn) {
        uint256 collateralUnreservedBefore = LibCustody.unreservedBalance(preview.collateralToken);
        uint256 staticsDollarUnreservedBefore = LibCustody.unreservedBalance(ps.staticsDollar);
        uint256 received = LibCustody.pull(preview.collateralToken, msg.sender, preview.totalCollateralIn);
        if (received != preview.totalCollateralIn) {
            revert IStaticsDollarGateway.InsufficientTransferReceived(
                preview.collateralToken, preview.totalCollateralIn, received
            );
        }
        IERC20(preview.collateralToken).forceApprove(ps.pool, preview.totalCollateralIn);
        uint256 collateralBefore = LibCustody.beginUnreservedDebit(preview.collateralToken, preview.totalCollateralIn);
        collateralIn = IStaticsDollarCore(ps.pool)
            .mintPegged(profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver);
        LibCustody.finishUnreservedDebit(preview.collateralToken, collateralBefore, preview.totalCollateralIn);
        IERC20(preview.collateralToken).forceApprove(ps.pool, 0);
        _assertPeggedResidualsRestored(
            ps, preview.collateralToken, collateralUnreservedBefore, staticsDollarUnreservedBefore
        );
        emit IStaticsDollarGateway.PeggedMintedThroughGateway(
            msg.sender, staticsDollarReceiver, profileId, preview.collateralToken, staticsDollarAmount, collateralIn
        );
    }

    function previewPeggedRedemption(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview)
    {
        return IStaticsDollarCore(LibPeriphery.s().pool).previewPeggedRedemption(profileId, staticsDollarAmount);
    }

    function redeemPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview;
        (status, preview) = _preparePeggedRedemption(ps, profileId, staticsDollarAmount, minimumCollateralOut, receiver);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        collateralOut =
            _executePeggedRedemption(ps, profileId, staticsDollarAmount, minimumCollateralOut, receiver, preview);
    }

    function redeemPeggedWithPermit(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver,
        IStaticsDollarGateway.PermitSignature calldata permitSignature
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview;
        (status, preview) = _preparePeggedRedemption(ps, profileId, staticsDollarAmount, minimumCollateralOut, receiver);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) return (status, 0);
        _permitToken(ps.staticsDollar, staticsDollarAmount, permitSignature);
        collateralOut =
            _executePeggedRedemption(ps, profileId, staticsDollarAmount, minimumCollateralOut, receiver, preview);
    }

    function _executePeggedRedemption(
        LibPeriphery.PS storage ps,
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver,
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview
    ) private returns (uint256 collateralOut) {
        uint256 collateralUnreservedBefore = LibCustody.unreservedBalance(preview.collateralToken);
        uint256 staticsDollarUnreservedBefore = LibCustody.unreservedBalance(ps.staticsDollar);
        uint256 received = LibCustody.pull(ps.staticsDollar, msg.sender, staticsDollarAmount);
        if (received != staticsDollarAmount) {
            revert IStaticsDollarGateway.InsufficientTransferReceived(ps.staticsDollar, staticsDollarAmount, received);
        }
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, staticsDollarAmount);
        IStaticsDollarCoreTypes.ExitStatus status;
        (status, collateralOut) =
            IStaticsDollarCore(ps.pool).redeemPegged(profileId, staticsDollarAmount, minimumCollateralOut, receiver);
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, staticsDollarAmount);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert IStaticsDollarGateway.UnexpectedExitStatus(status);
        }
        _assertPeggedResidualsRestored(
            ps, preview.collateralToken, collateralUnreservedBefore, staticsDollarUnreservedBefore
        );
        emit IStaticsDollarGateway.PeggedRedeemedThroughGateway(
            msg.sender, receiver, profileId, preview.collateralToken, staticsDollarAmount, collateralOut
        );
    }

    function peggedRedemptionStatus()
        external
        view
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        )
    {
        return IStaticsDollarCore(LibPeriphery.s().pool).peggedRedemptionStatus();
    }

    function weth() external view returns (address) {
        return LibPeriphery.s().weth;
    }

    function wethProfileId() external pure returns (uint256) {
        return WETH_PROFILE_ID;
    }

    function _requireDepositMinimums(
        LibPeriphery.PS storage ps,
        uint256 wethAmount,
        uint256 minStaticsDollar,
        uint256 minShares
    ) private view returns (IStaticsDollarCoreTypes.DepositPreview memory preview) {
        preview = IStaticsDollarCore(ps.pool).previewDeposit(WETH_PROFILE_ID, wethAmount);
        _requireMinimum(preview.staticsDollarMinted, minStaticsDollar);
        _requireMinimum(preview.sharesMinted, minShares);
    }

    function _requireRecombinationBounds(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        uint256 minOut
    ) private view returns (IStaticsDollarCoreTypes.RedemptionPreview memory preview) {
        preview = IStaticsDollarCore(ps.pool).previewRecombine(seriesId, staticsDollarAmount);
        if (preview.profileId != WETH_PROFILE_ID) {
            revert IStaticsDollarGateway.UnexpectedCollateralProfile(WETH_PROFILE_ID, preview.profileId);
        }
        if (preview.sharesBurned > maxSharesIn) {
            revert IStaticsDollarGateway.SharesAboveMaximum(preview.sharesBurned, maxSharesIn);
        }
        _requireMinimum(preview.collateralOut, minOut);
    }

    function _prepareRecombination(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minOut
    )
        private
        returns (IStaticsDollarCoreTypes.ExitStatus status, IStaticsDollarCoreTypes.RedemptionPreview memory preview)
    {
        _requireReceiver(receiver);
        preview = _requireRecombinationBounds(ps, seriesId, staticsDollarAmount, maxSharesIn, minOut);
        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = IStaticsDollarCore(ps.pool).checkpointGlobalCollateralExit();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit IStaticsDollarGateway.RecombinationDeferred(msg.sender, receiver, seriesId, status, unhealthyBitmap);
        }
    }

    function _permitToken(address token, uint256 amount, IStaticsDollarGateway.PermitSignature calldata permitSignature)
        private
    {
        try IERC20Permit(token)
            .permit(
                msg.sender,
                address(this),
                amount,
                permitSignature.deadline,
                permitSignature.v,
                permitSignature.r,
                permitSignature.s
            ) {}
            catch {}
    }

    function _preparePeggedMint(
        LibPeriphery.PS storage ps,
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver
    ) private view returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview) {
        _requireReceiver(staticsDollarReceiver);
        preview = IStaticsDollarCore(ps.pool).previewPeggedMint(profileId, staticsDollarAmount);
        if (preview.totalCollateralIn > maximumCollateralIn) {
            revert IStaticsDollarGateway.CollateralAboveMaximum(preview.totalCollateralIn, maximumCollateralIn);
        }
    }

    function _preparePeggedRedemption(
        LibPeriphery.PS storage ps,
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    )
        private
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview
        )
    {
        _requireReceiver(receiver);
        preview = IStaticsDollarCore(ps.pool).previewPeggedRedemption(profileId, staticsDollarAmount);
        _requireMinimum(preview.collateralOut, minimumCollateralOut);
        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = IStaticsDollarCore(ps.pool).checkpointPeggedRedemption();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit IStaticsDollarGateway.PeggedRedemptionDeferred(
                msg.sender, receiver, profileId, status, unhealthyBitmap
            );
        }
    }

    function _executeRecombinationToWETH(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 sharesBurned,
        address receiver,
        uint256 minWETHOut
    ) private returns (uint256 wethOut) {
        ResidualSnapshot memory residuals = _residualSnapshot(ps, seriesId, 0);
        _pullRecombinationTokens(ps, seriesId, staticsDollarAmount, sharesBurned);
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, staticsDollarAmount);
        IStaticsDollarCoreTypes.ExitStatus status;
        (status, wethOut) =
            IStaticsDollarCore(ps.pool).recombine(seriesId, staticsDollarAmount, sharesBurned, minWETHOut, receiver);
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, staticsDollarAmount);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert IStaticsDollarGateway.UnexpectedExitStatus(status);
        }
        _requireMinimum(wethOut, minWETHOut);
        _assertResidualBalancesRestored(ps, seriesId, residuals);
        emit IStaticsDollarGateway.RecombinedToWETH(
            msg.sender, receiver, seriesId, staticsDollarAmount, sharesBurned, wethOut
        );
    }

    function _executeRecombinationToETH(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 sharesBurned,
        address receiver,
        uint256 minETHOut
    ) private returns (uint256 ethOut) {
        ResidualSnapshot memory residuals = _residualSnapshot(ps, seriesId, 0);
        _pullRecombinationTokens(ps, seriesId, staticsDollarAmount, sharesBurned);
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, staticsDollarAmount);
        IStaticsDollarCoreTypes.ExitStatus status;
        (status, ethOut) = IStaticsDollarCore(ps.pool)
            .recombine(seriesId, staticsDollarAmount, sharesBurned, minETHOut, address(this));
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, staticsDollarAmount);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert IStaticsDollarGateway.UnexpectedExitStatus(status);
        }
        _requireMinimum(ethOut, minETHOut);

        uint256 wethBefore = LibCustody.beginUnreservedDebit(ps.weth, ethOut);
        IWETH9(ps.weth).withdraw(ethOut);
        LibCustody.finishUnreservedDebit(ps.weth, wethBefore, ethOut);
        (bool ok,) = payable(receiver).call{value: ethOut}("");
        if (!ok) revert IStaticsDollarGateway.NativeTransferFailed(receiver, ethOut);
        _assertResidualBalancesRestored(ps, seriesId, residuals);
        emit IStaticsDollarGateway.RecombinedToETH(
            msg.sender, receiver, seriesId, staticsDollarAmount, sharesBurned, ethOut
        );
    }

    function _pullRecombinationTokens(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 sharesBurned
    ) private {
        uint256 received = LibCustody.pull(ps.staticsDollar, msg.sender, staticsDollarAmount);
        if (received != staticsDollarAmount) {
            revert IStaticsDollarGateway.InsufficientTransferReceived(ps.staticsDollar, staticsDollarAmount, received);
        }
        if (ps.expectedRiskIngress.active) revert IStaticsDollarGateway.UnexpectedRiskIngressState();
        ps.expectedRiskIngress = LibPeriphery.ExpectedRiskIngress({
            operator: address(this), from: msg.sender, seriesId: seriesId, amount: sharesBurned, active: true
        });
        IERC1155(ps.staticsDollarRisk).safeTransferFrom(msg.sender, address(this), seriesId, sharesBurned, "");
        if (ps.expectedRiskIngress.active) revert IStaticsDollarGateway.UnexpectedRiskIngressState();
    }

    function _requireMinimum(uint256 actual, uint256 minimum) private pure {
        if (actual < minimum) revert IStaticsDollarGateway.OutputBelowMinimum(actual, minimum);
    }

    function _requireReceiver(address receiver) private pure {
        if (receiver == address(0)) revert IStaticsDollarGateway.ZeroAddress();
    }

    function _residualSnapshot(LibPeriphery.PS storage ps, uint256 seriesId, uint256 nativeIn)
        private
        view
        returns (ResidualSnapshot memory snapshot)
    {
        snapshot = ResidualSnapshot({
            wethUnreserved: LibCustody.unreservedBalance(ps.weth),
            staticsDollarUnreserved: LibCustody.unreservedBalance(ps.staticsDollar),
            riskShareBalance: IERC1155(ps.staticsDollarRisk).balanceOf(address(this), seriesId),
            nativeBalance: address(this).balance - nativeIn
        });
    }

    function _assertResidualBalancesRestored(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        ResidualSnapshot memory snapshot
    ) private view {
        uint256 balance = LibCustody.unreservedBalance(ps.weth);
        if (balance != snapshot.wethUnreserved) {
            revert IStaticsDollarGateway.ResidualGatewayBalance(ps.weth, snapshot.wethUnreserved, balance);
        }
        balance = LibCustody.unreservedBalance(ps.staticsDollar);
        if (balance != snapshot.staticsDollarUnreserved) {
            revert IStaticsDollarGateway.ResidualGatewayBalance(
                ps.staticsDollar, snapshot.staticsDollarUnreserved, balance
            );
        }
        balance = IERC1155(ps.staticsDollarRisk).balanceOf(address(this), seriesId);
        if (balance != snapshot.riskShareBalance) {
            revert IStaticsDollarGateway.ResidualGatewayERC1155Balance(
                ps.staticsDollarRisk, seriesId, snapshot.riskShareBalance, balance
            );
        }
        balance = address(this).balance;
        if (balance != snapshot.nativeBalance) {
            revert IStaticsDollarGateway.ResidualGatewayNativeBalance(snapshot.nativeBalance, balance);
        }
        uint256 allowance = IERC20(ps.weth).allowance(address(this), ps.pool);
        if (allowance != 0) revert IStaticsDollarGateway.ResidualGatewayApproval(ps.weth, ps.pool, allowance);
    }

    function _assertPeggedResidualsRestored(
        LibPeriphery.PS storage ps,
        address collateralToken,
        uint256 collateralUnreserved,
        uint256 staticsDollarUnreserved
    ) private view {
        uint256 balance = LibCustody.unreservedBalance(collateralToken);
        if (balance != collateralUnreserved) {
            revert IStaticsDollarGateway.ResidualGatewayBalance(collateralToken, collateralUnreserved, balance);
        }
        balance = LibCustody.unreservedBalance(ps.staticsDollar);
        if (balance != staticsDollarUnreserved) {
            revert IStaticsDollarGateway.ResidualGatewayBalance(ps.staticsDollar, staticsDollarUnreserved, balance);
        }
        uint256 allowance = IERC20(collateralToken).allowance(address(this), ps.pool);
        if (allowance != 0) {
            revert IStaticsDollarGateway.ResidualGatewayApproval(collateralToken, ps.pool, allowance);
        }
    }
}
