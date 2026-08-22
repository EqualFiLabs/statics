// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskIncentives} from "../../interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibDiamond} from "../../../libraries/LibDiamond.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

/// @notice Lets a Statics Dollar holder exit at the series' immutable senior
/// collateral weight minus the pairing fee, without sourcing Risk Shares.
/// Supplied Risk Shares are consumed proportionally. Their owners receive the
/// complete junior residual plus the configured supplier share of the pairing
/// fee; profile insurance receives the rest of that fee.
contract PairingVaultFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PAUSE_PAIRING_FILLS = 1 << 2;
    bytes32 internal constant SOURCE_REDEMPTION = "REDEMPTION";
    bytes32 internal constant SOURCE_INCENTIVE = "INCENTIVE";

    struct RedeemPreview {
        uint256 staticsDollarRedeemed; // fill after capping to supplied Risk liquidity
        uint256 grossCollateral; // managed recombination output before the pairing fee
        uint256 collateralToRedeemer; // fixed senior allocation minus redemption fee
        uint256 collateralToRiskSuppliers; // junior residual + supplier share of the fee
        uint256 collateralToInsurance; // remainder of the fee
        uint256 seniorCollateralPerUnitWad;
    }

    struct ConsumedLiquidity {
        uint256 availableBefore;
        uint256 totalStored;
        uint64 epoch;
    }

    struct RedemptionRequest {
        uint256 seriesId;
        uint256 staticsDollarAmount;
        uint256 minStaticsDollarRedeemed;
        uint256 minCollateralPerStaticsDollarWad;
        address receiver;
        bool unwrapToETH;
    }

    struct RedemptionContext {
        IStaticsDollarCore core;
        IStaticsDollarCoreTypes.RiskSeries series;
        uint256 seriesId;
        uint8 collateralDecimals;
        address collateralToken;
        uint256 availableBefore;
        uint256 fill;
    }

    struct RedemptionDistribution {
        uint256 grossCollateral;
        uint256 toRedeemer;
        uint256 toRiskSuppliers;
        uint256 toInsurance;
    }

    event Redeemed(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        uint256 staticsDollarRedeemed,
        uint256 collateralToRedeemer,
        uint256 collateralToRiskSuppliers,
        uint256 collateralToInsurance
    );
    event RedemptionDeferred(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );
    event RedemptionParamsSet(uint16 redemptionFeeBps, uint16 supplierShareBps);

    error ZeroAmount();
    error ZeroAddress();
    error NoRiskLiquidity();
    error FillBelowMinimum(uint256 fill, uint256 minimum);
    error RateBelowMinimum(uint256 rateWad, uint256 minimumRateWad);
    error InvalidRedemptionParams(uint16 feeBps, uint16 supplierShareBps);
    error SeriesTransitionPending(uint256 seriesId);
    error NotWETHCollateral();
    error NativeTransferFailed(address receiver, uint256 amount);
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);
    error FixedAllocationExceedsGross(uint256 fixedSeniorCollateral, uint256 grossCollateral);
    error UnexpectedExitStatus(IStaticsDollarCoreTypes.ExitStatus status);
    error ProfileOperationPaused(uint256 profileId, uint256 operation);
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);

    // ---------------------------------------------------------------- redemption

    /// @param staticsDollarAmount requested redemption; fills partially against available
    ///        Risk liquidity (absolute output minimums are deliberately not used —
    ///        `minStaticsDollarRedeemed` owns fill-size protection, the rate param owns price
    ///        protection, so partial fills never spuriously revert).
    /// @param minCollateralPerStaticsDollarWad minimum collateral (WAD-normalized) per staticsDollar.
    function redeem(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 minStaticsDollarRedeemed,
        uint256 minCollateralPerStaticsDollarWad,
        uint256 deadline,
        address receiver
    )
        external
        nonReentrant
        returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 staticsDollarRedeemed, uint256 collateralOut)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        return _redeem(
            RedemptionRequest({
                seriesId: seriesId,
                staticsDollarAmount: staticsDollarAmount,
                minStaticsDollarRedeemed: minStaticsDollarRedeemed,
                minCollateralPerStaticsDollarWad: minCollateralPerStaticsDollarWad,
                receiver: receiver,
                unwrapToETH: false
            })
        );
    }

    /// @notice WETH-collateral convenience: identical flow, unwraps to native ETH.
    function redeemToETH(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 minStaticsDollarRedeemed,
        uint256 minCollateralPerStaticsDollarWad,
        uint256 deadline,
        address receiver
    )
        external
        nonReentrant
        returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 staticsDollarRedeemed, uint256 ethOut)
    {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        return _redeem(
            RedemptionRequest({
                seriesId: seriesId,
                staticsDollarAmount: staticsDollarAmount,
                minStaticsDollarRedeemed: minStaticsDollarRedeemed,
                minCollateralPerStaticsDollarWad: minCollateralPerStaticsDollarWad,
                receiver: receiver,
                unwrapToETH: true
            })
        );
    }

    function _redeem(RedemptionRequest memory request)
        internal
        returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 fill, uint256 collateralOut)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        RedemptionContext memory ctx = _prepareRedemption(ps, request);

        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = ctx.core.checkpointGlobalCollateralExit();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit RedemptionDeferred(msg.sender, request.receiver, request.seriesId, status, unhealthyBitmap);
            return (status, 0, 0);
        }
        fill = ctx.fill;

        ConsumedLiquidity memory consumed;
        RedemptionDistribution memory distribution;
        (consumed, distribution.grossCollateral) = _recombineForRedemption(ps, ctx, request);
        _applyRedemptionSplit(ps, ctx, request, distribution);
        _settleRedemptionShares(ps, ctx, consumed, distribution);
        collateralOut = distribution.toRedeemer;
        _payRedeemer(ctx, request, collateralOut);

        emit Redeemed(
            msg.sender,
            request.receiver,
            request.seriesId,
            fill,
            collateralOut,
            distribution.toRiskSuppliers,
            distribution.toInsurance
        );
        return (IStaticsDollarCoreTypes.ExitStatus.Available, fill, collateralOut);
    }

    function _prepareRedemption(LibPeriphery.PS storage ps, RedemptionRequest memory request)
        private
        view
        returns (RedemptionContext memory ctx)
    {
        if (request.staticsDollarAmount == 0) revert ZeroAmount();
        _requireActiveSeries(ps, request.seriesId);

        ctx.core = IStaticsDollarCore(ps.pool);
        ctx.seriesId = request.seriesId;
        ctx.series = ctx.core.riskSeries(request.seriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            ctx.core.collateralProfile(ctx.series.profileId);
        if (ctx.core.profileOperationPaused(ctx.series.profileId, PAUSE_PAIRING_FILLS)) {
            revert ProfileOperationPaused(ctx.series.profileId, PAUSE_PAIRING_FILLS);
        }
        ctx.collateralToken = ctx.series.collateralToken;
        ctx.collateralDecimals = profile.decimals;
        if (request.unwrapToETH && ctx.collateralToken != ps.weth) revert NotWETHCollateral();

        uint256 available = ps.series[request.seriesId].effectivePrincipal;
        if (available == 0) revert NoRiskLiquidity();
        ctx.availableBefore = available;
        ctx.fill = request.staticsDollarAmount > available ? available : request.staticsDollarAmount;
        if (ctx.fill < request.minStaticsDollarRedeemed) {
            revert FillBelowMinimum(ctx.fill, request.minStaticsDollarRedeemed);
        }
    }

    function _recombineForRedemption(
        LibPeriphery.PS storage ps,
        RedemptionContext memory ctx,
        RedemptionRequest memory request
    ) private returns (ConsumedLiquidity memory consumed, uint256 grossCollateral) {
        uint256 receivedStaticsDollar = LibCustody.pull(ps.staticsDollar, msg.sender, ctx.fill);
        if (receivedStaticsDollar < ctx.fill) {
            revert InsufficientTransferReceived(ps.staticsDollar, ctx.fill, receivedStaticsDollar);
        }

        // Consume the tier pro rata; the underlying 1155s stay here and are burned by
        // the recombination in the next step.
        LibPeriphery.SeriesBook storage book = ps.series[request.seriesId];
        consumed =
            ConsumedLiquidity({availableBefore: ctx.availableBefore, totalStored: book.totalStored, epoch: book.epoch});
        LibPeriphery.consume(ps, request.seriesId, ctx.fill);

        uint256 balanceBefore = IERC20(ctx.collateralToken).balanceOf(address(this));
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, ctx.fill);
        (IStaticsDollarCoreTypes.ExitStatus recombinationStatus,) =
            ctx.core.recombineManaged(request.seriesId, ctx.fill, ctx.fill, 0, address(this));
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, ctx.fill);
        if (recombinationStatus != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert UnexpectedExitStatus(recombinationStatus);
        }
        grossCollateral = IERC20(ctx.collateralToken).balanceOf(address(this)) - balanceBefore;
    }

    function _applyRedemptionSplit(
        LibPeriphery.PS storage ps,
        RedemptionContext memory ctx,
        RedemptionRequest memory request,
        RedemptionDistribution memory distribution
    ) private view {
        (
            distribution.toRedeemer, distribution.toRiskSuppliers, distribution.toInsurance,
        ) = _splitProceeds(ps, ctx.series, ctx.collateralDecimals, ctx.fill, distribution.grossCollateral);

        // Rate guard: collateral per staticsDollar, WAD-normalized.
        uint256 rateWad = Math.mulDiv(_toWad(ctx.collateralDecimals, distribution.toRedeemer), WAD, ctx.fill);
        if (rateWad < request.minCollateralPerStaticsDollarWad) {
            revert RateBelowMinimum(rateWad, request.minCollateralPerStaticsDollarWad);
        }
    }

    function _settleRedemptionShares(
        LibPeriphery.PS storage ps,
        RedemptionContext memory ctx,
        ConsumedLiquidity memory consumed,
        RedemptionDistribution memory distribution
    ) private {
        if (distribution.toRiskSuppliers != 0) {
            LibPeriphery.accrueRiskProceeds(
                ps,
                ctx.seriesId,
                consumed.epoch,
                consumed.totalStored,
                ctx.collateralToken,
                distribution.toRiskSuppliers,
                SOURCE_REDEMPTION
            );
        }
        _releaseRiskIncentives(ps, ctx.seriesId, consumed, ctx.fill, ctx.collateralToken);
        if (distribution.toInsurance != 0) {
            IERC20(ctx.collateralToken).forceApprove(ps.pool, distribution.toInsurance);
            uint256 collateralBefore = LibCustody.beginUnreservedDebit(ctx.collateralToken, distribution.toInsurance);
            ctx.core.topUpInsurance(ctx.series.profileId, distribution.toInsurance);
            LibCustody.finishUnreservedDebit(ctx.collateralToken, collateralBefore, distribution.toInsurance);
        }
    }

    function _payRedeemer(RedemptionContext memory ctx, RedemptionRequest memory request, uint256 collateralOut)
        private
    {
        if (request.unwrapToETH) {
            uint256 unreserved = LibCustody.unreservedBalance(ctx.collateralToken);
            if (collateralOut > unreserved) {
                revert LibCustody.InsufficientUnreserved(ctx.collateralToken, collateralOut, unreserved);
            }
            IWETH9(ctx.collateralToken).withdraw(collateralOut);
            (bool ok,) = payable(request.receiver).call{value: collateralOut}("");
            if (!ok) revert NativeTransferFailed(request.receiver, collateralOut);
        } else {
            LibCustody.pushUnreserved(ctx.collateralToken, request.receiver, collateralOut, collateralOut);
        }
    }

    function _releaseRiskIncentives(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        ConsumedLiquidity memory consumed,
        uint256 fill,
        address collateralToken
    ) private {
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        uint256 collateralAmount =
            LibPeriphery.proportionalRelease(book.collateralIncentiveReserve, fill, consumed.availableBefore);
        uint256 staticsDollarAmount =
            LibPeriphery.proportionalRelease(book.staticsDollarIncentiveReserve, fill, consumed.availableBefore);
        uint256 staticsAmount =
            LibPeriphery.proportionalRelease(book.staticsIncentiveReserve, fill, consumed.availableBefore);
        book.collateralIncentiveReserve -= collateralAmount;
        book.staticsDollarIncentiveReserve -= staticsDollarAmount;
        book.staticsIncentiveReserve -= staticsAmount;

        LibPeriphery.accrueReservedRiskIncentive(
            ps,
            seriesId,
            consumed.epoch,
            consumed.totalStored,
            collateralToken,
            collateralAmount,
            LibPeriphery.IncentiveKind.Collateral,
            SOURCE_INCENTIVE
        );
        LibPeriphery.accrueReservedRiskIncentive(
            ps,
            seriesId,
            consumed.epoch,
            consumed.totalStored,
            ps.staticsDollar,
            staticsDollarAmount,
            LibPeriphery.IncentiveKind.StaticsDollar,
            SOURCE_INCENTIVE
        );
        LibPeriphery.accrueReservedRiskIncentive(
            ps,
            seriesId,
            consumed.epoch,
            consumed.totalStored,
            ps.staticsToken,
            staticsAmount,
            LibPeriphery.IncentiveKind.Statics,
            SOURCE_INCENTIVE
        );
        if (collateralAmount != 0 || staticsDollarAmount != 0 || staticsAmount != 0) {
            emit IStaticsDollarRiskIncentives.RiskIncentivesReleased(
                seriesId, consumed.epoch, fill, collateralAmount, staticsDollarAmount, staticsAmount
            );
        }
    }

    function _splitProceeds(
        LibPeriphery.PS storage ps,
        IStaticsDollarCoreTypes.RiskSeries memory series,
        uint8 collateralDecimals,
        uint256 fill,
        uint256 grossCollateral
    )
        internal
        view
        returns (uint256 toRedeemer, uint256 toRiskSuppliers, uint256 toInsurance, uint256 seniorWeightWad)
    {
        seniorWeightWad = series.seniorCollateralPerUnitWad;
        uint256 fixedSeniorWad = Math.mulDiv(fill, seniorWeightWad, WAD);
        uint256 fixedSeniorCollateral = _fromWad(collateralDecimals, fixedSeniorWad);
        if (fixedSeniorCollateral > grossCollateral) {
            revert FixedAllocationExceedsGross(fixedSeniorCollateral, grossCollateral);
        }
        toRedeemer = Math.mulDiv(fixedSeniorCollateral, BPS - ps.redemptionFeeBps, BPS);

        uint256 proceeds = grossCollateral - toRedeemer;
        // Only the fee is split with insurance; the junior residual is the
        // suppliers' own capital and goes to them in full.
        uint256 feeCollateral = fixedSeniorCollateral - toRedeemer;
        toInsurance = Math.mulDiv(feeCollateral, BPS - ps.redemptionSupplierShareBps, BPS);
        toRiskSuppliers = proceeds - toInsurance;
    }

    // ---------------------------------------------------------------- preview

    function previewRedeem(uint256 seriesId, uint256 staticsDollarAmount)
        external
        view
        returns (RedeemPreview memory preview)
    {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireActiveSeries(ps, seriesId);
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory series = core.riskSeries(seriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);

        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        uint256 available = book.effectivePrincipal;
        if (available == 0) revert NoRiskLiquidity();
        preview.staticsDollarRedeemed = staticsDollarAmount > available ? available : staticsDollarAmount;

        IStaticsDollarCoreTypes.RedemptionPreview memory poolPreview =
            core.previewRecombine(seriesId, preview.staticsDollarRedeemed);
        // Pairing uses the Core's explicit managed selector, so gross includes
        // the ordinary recombination fee retained for this distribution path.
        preview.grossCollateral = poolPreview.collateralOut + poolPreview.feeAmount;

        (
            preview.collateralToRedeemer,
            preview.collateralToRiskSuppliers,
            preview.collateralToInsurance,
            preview.seniorCollateralPerUnitWad
        ) = _splitProceeds(ps, series, profile.decimals, preview.staticsDollarRedeemed, preview.grossCollateral);
    }

    // ---------------------------------------------------------------- config

    function setRedemptionParams(uint16 redemptionFeeBps, uint16 supplierShareBps) external {
        LibDiamond.enforceIsContractOwner();
        if (
            redemptionFeeBps > LibPeriphery.MAX_REDEMPTION_FEE_BPS || supplierShareBps > BPS
                || supplierShareBps < LibPeriphery.MIN_REDEMPTION_SUPPLIER_SHARE_BPS
        ) {
            revert InvalidRedemptionParams(redemptionFeeBps, supplierShareBps);
        }
        LibPeriphery.PS storage ps = LibPeriphery.s();
        ps.redemptionFeeBps = redemptionFeeBps;
        ps.redemptionSupplierShareBps = supplierShareBps;
        emit RedemptionParamsSet(redemptionFeeBps, supplierShareBps);
    }

    function redemptionParams() external view returns (uint16 redemptionFeeBps, uint16 supplierShareBps) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        return (ps.redemptionFeeBps, ps.redemptionSupplierShareBps);
    }

    function redeemableLiquidity(uint256 seriesId) external view returns (uint256 staticsDollarAmount) {
        LibPeriphery.SeriesBook storage book = LibPeriphery.s().series[seriesId];
        return book.effectivePrincipal;
    }

    // ---------------------------------------------------------------- internals

    function _requireActiveSeries(LibPeriphery.PS storage ps, uint256 seriesId) internal view {
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory series = core.riskSeries(seriesId);
        IStaticsDollarCoreTypes.ProfileMode mode = core.collateralProfile(series.profileId).mode;
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Active
                || (mode != IStaticsDollarCoreTypes.ProfileMode.Active
                    && mode != IStaticsDollarCoreTypes.ProfileMode.ReduceOnly)
        ) {
            revert SeriesTransitionPending(seriesId);
        }
    }

    function _toWad(uint8 decimals, uint256 rawAmount) internal pure returns (uint256) {
        if (decimals == 18) return rawAmount;
        return rawAmount * 10 ** (18 - decimals);
    }

    function _fromWad(uint8 decimals, uint256 wadAmount) internal pure returns (uint256) {
        if (decimals == 18) return wadAmount;
        return wadAmount / 10 ** (18 - decimals);
    }
}
