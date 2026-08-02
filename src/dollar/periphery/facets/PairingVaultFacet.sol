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
            seriesId, staticsDollarAmount, minStaticsDollarRedeemed, minCollateralPerStaticsDollarWad, receiver, false
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
            seriesId, staticsDollarAmount, minStaticsDollarRedeemed, minCollateralPerStaticsDollarWad, receiver, true
        );
    }

    function _redeem(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 minStaticsDollarRedeemed,
        uint256 minCollateralPerStaticsDollarWad,
        address receiver,
        bool unwrapToETH
    ) internal returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 fill, uint256 collateralOut) {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireActiveSeries(ps, seriesId);

        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory series = core.riskSeries(seriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);
        if (core.profileOperationPaused(series.profileId, PAUSE_PAIRING_FILLS)) {
            revert ProfileOperationPaused(series.profileId, PAUSE_PAIRING_FILLS);
        }
        address collateralToken = series.collateralToken;
        if (unwrapToETH && collateralToken != ps.weth) revert NotWETHCollateral();

        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        uint256 available = book.effectivePrincipal;
        if (available == 0) revert NoRiskLiquidity();
        fill = staticsDollarAmount > available ? available : staticsDollarAmount;
        if (fill < minStaticsDollarRedeemed) revert FillBelowMinimum(fill, minStaticsDollarRedeemed);

        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = core.checkpointGlobalCollateralExit();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit RedemptionDeferred(msg.sender, receiver, seriesId, status, unhealthyBitmap);
            return (status, 0, 0);
        }

        uint256 receivedStaticsDollar = LibCustody.pull(ps.staticsDollar, msg.sender, fill);
        if (receivedStaticsDollar < fill) {
            revert InsufficientTransferReceived(ps.staticsDollar, fill, receivedStaticsDollar);
        }

        // Consume the tier pro rata; the underlying 1155s stay here and are burned by
        // the recombination in the next step.
        ConsumedLiquidity memory consumed =
            ConsumedLiquidity({availableBefore: available, totalStored: book.totalStored, epoch: book.epoch});
        LibPeriphery.consume(ps, seriesId, fill);

        uint256 balanceBefore = IERC20(collateralToken).balanceOf(address(this));
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, fill);
        (IStaticsDollarCoreTypes.ExitStatus recombinationStatus,) =
            core.recombineManaged(seriesId, fill, fill, 0, address(this));
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, fill);
        if (recombinationStatus != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert UnexpectedExitStatus(recombinationStatus);
        }
        uint256 grossCollateral = IERC20(collateralToken).balanceOf(address(this)) - balanceBefore;

        (uint256 toRedeemer, uint256 toRiskSuppliers, uint256 toInsurance,) =
            _splitProceeds(ps, series, profile.decimals, fill, grossCollateral);
        collateralOut = toRedeemer;

        // Rate guard: collateral per staticsDollar, WAD-normalized.
        uint256 rateWad = Math.mulDiv(_toWad(profile.decimals, collateralOut), WAD, fill);
        if (rateWad < minCollateralPerStaticsDollarWad) {
            revert RateBelowMinimum(rateWad, minCollateralPerStaticsDollarWad);
        }

        if (toRiskSuppliers != 0) {
            LibPeriphery.accrueRiskProceeds(
                ps, seriesId, consumed.epoch, consumed.totalStored, collateralToken, toRiskSuppliers, SOURCE_REDEMPTION
            );
        }
        _releaseRiskIncentives(ps, seriesId, consumed, fill, collateralToken);
        if (toInsurance != 0) {
            IERC20(collateralToken).forceApprove(ps.pool, toInsurance);
            uint256 collateralBefore = LibCustody.beginUnreservedDebit(collateralToken, toInsurance);
            core.topUpInsurance(series.profileId, toInsurance);
            LibCustody.finishUnreservedDebit(collateralToken, collateralBefore, toInsurance);
        }

        if (unwrapToETH) {
            uint256 unreserved = LibCustody.unreservedBalance(collateralToken);
            if (collateralOut > unreserved) {
                revert LibCustody.InsufficientUnreserved(collateralToken, collateralOut, unreserved);
            }
            IWETH9(collateralToken).withdraw(collateralOut);
            (bool ok,) = payable(receiver).call{value: collateralOut}("");
            if (!ok) revert NativeTransferFailed(receiver, collateralOut);
        } else {
            LibCustody.pushUnreserved(collateralToken, receiver, collateralOut, collateralOut);
        }

        emit Redeemed(msg.sender, receiver, seriesId, fill, collateralOut, toRiskSuppliers, toInsurance);
        return (IStaticsDollarCoreTypes.ExitStatus.Available, fill, collateralOut);
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
