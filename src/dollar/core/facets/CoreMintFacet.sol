// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarRiskShares} from "../../interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "../../interfaces/IStaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCoreHealth} from "../libraries/LibCoreHealth.sol";
import {LibCorePeggedRedemption} from "../libraries/LibCorePeggedRedemption.sol";
import {LibCoreRecovery} from "../libraries/LibCoreRecovery.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreMintFacet is ReentrancyGuard {
    uint256 internal constant WAD = 1e18;

    event InsuranceContributed(
        address indexed payer, uint256 indexed profileId, address indexed collateralToken, uint256 amount
    );
    event Deposited(
        address indexed caller,
        address indexed staticsDollarReceiver,
        address indexed shareReceiver,
        uint256 profileId,
        uint256 seriesId,
        uint256 collateralAmount,
        uint256 staticsDollarMinted,
        uint256 sharesMinted,
        uint256 priceWad,
        uint256 collateralPerPairWad
    );
    event PeggedMinted(
        address indexed caller,
        address indexed staticsDollarReceiver,
        uint256 indexed profileId,
        uint256 staticsDollarMinted,
        uint256 principalCollateral,
        uint256 feeAmount
    );
    event PeggedRedemptionDeferred(
        address indexed caller,
        address indexed receiver,
        uint256 indexed profileId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );
    event PeggedRedeemed(
        address indexed caller,
        address indexed receiver,
        uint256 indexed profileId,
        uint256 staticsDollarBurned,
        uint256 grossCollateral,
        uint256 feeAmount,
        uint256 collateralOut
    );
    event CollateralExitDeferred(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );
    event Recombined(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        uint256 staticsDollarBurned,
        uint256 sharesBurned,
        address collateralToken,
        uint256 collateralOut,
        uint256 collateralRatioBpsAfter
    );
    event SeriesClosed(uint256 indexed profileId, uint256 indexed seriesId);

    error ZeroAddress();
    error ZeroAmount();
    error OutputBelowMinimum(uint256 actual, uint256 minimum);
    error CollateralAboveMaximum(uint256 required, uint256 maximum);
    error InvalidProfileKind(
        uint256 profileId, IStaticsDollarCoreTypes.ProfileKind expected, IStaticsDollarCoreTypes.ProfileKind actual
    );
    error InvalidProfileMode(uint256 profileId, IStaticsDollarCoreTypes.ProfileMode mode);
    error SeriesNotActive(uint256 seriesId);
    error TransitionRequired(uint256 profileId, uint256 seriesId, uint256 currentPriceWad);
    error DepositTooSmall();
    error RedemptionTooSmall();
    error DebtCeilingExceeded(uint256 profileId, uint256 attemptedSeniorOutstanding, uint256 debtCeiling);
    error PegOutOfBounds(uint256 profileId, uint256 priceWad, uint256 minimumPriceWad, uint256 maximumPriceWad);
    error EmptyPool();
    error InvalidShareAmount(uint256 provided, uint256 required);
    error InvalidSeries(uint256 seriesId);
    error OnlyManagedPeriphery(address caller, address expected);

    struct RecombineContext {
        uint256 seriesId;
        uint256 staticsDollarAmount;
        uint256 shareAmount;
        address receiver;
        bool managed;
        uint256 gross;
        uint256 collateralOut;
        bool terminalEligible;
    }

    function depositCollateral(
        uint256 profileId,
        uint256 collateralAmount,
        uint256 minimumStaticsDollar,
        uint256 minimumShares,
        address staticsDollarReceiver,
        address shareReceiver
    ) external nonReentrant returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted) {
        if (staticsDollarReceiver == address(0) || shareReceiver == address(0)) revert ZeroAddress();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.DepositPreview memory preview = _previewDeposit(cs, profileId, collateralAmount);
        if (preview.staticsDollarMinted < minimumStaticsDollar) {
            revert OutputBelowMinimum(preview.staticsDollarMinted, minimumStaticsDollar);
        }
        if (preview.sharesMinted < minimumShares) revert OutputBelowMinimum(preview.sharesMinted, minimumShares);
        _recordDeposit(cs, profileId, preview, collateralAmount);
        _settleDeposit(cs, profileId, preview, staticsDollarReceiver, shareReceiver, collateralAmount);
        return (preview.seriesId, preview.staticsDollarMinted, preview.sharesMinted);
    }

    /// @dev Custody pull followed by all deposit accounting mutations and the
    /// post-accounting health checkpoint.
    function _recordDeposit(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        IStaticsDollarCoreTypes.DepositPreview memory preview,
        uint256 collateralAmount
    ) private {
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[preview.seriesId];

        LibCoreAccounting.pullExact(profile.collateralToken, msg.sender, collateralAmount);
        uint256 netCollateral = collateralAmount - preview.feeAmount;
        uint256 pairCollateral = netCollateral - preview.insuranceContribution;
        profile.accountedCollateral += pairCollateral;
        profile.insuranceReserve += preview.insuranceContribution;
        profile.seniorOutstanding += preview.staticsDollarMinted;
        series.accountedCollateral += pairCollateral;
        series.seniorOutstanding += preview.staticsDollarMinted;
        series.riskSharesOutstanding += preview.sharesMinted;
        cs.totalSeniorOutstanding += preview.staticsDollarMinted;
        cs.accountedCollateralByToken[profile.collateralToken] += netCollateral;
        LibCoreAccounting.updateSeriesIndex(cs, preview.seriesId);
        LibCoreAccounting.enforceHealthy(cs, profileId, profile);
    }

    /// @dev Fee collection, insurance acknowledgement, token minting, custody
    /// enforcement, and the deposit event.
    function _settleDeposit(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        IStaticsDollarCoreTypes.DepositPreview memory preview,
        address staticsDollarReceiver,
        address shareReceiver,
        uint256 collateralAmount
    ) private {
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        LibCoreAccounting.collectSeriesFee(
            cs,
            msg.sender,
            profile.collateralToken,
            preview.feeAmount,
            preview.seriesId,
            IStaticsDollarCoreTypes.FeeKind.Mint
        );
        if (preview.insuranceContribution != 0) {
            emit InsuranceContributed(msg.sender, profileId, profile.collateralToken, preview.insuranceContribution);
        }
        IStaticsDollar(cs.staticsDollar).mint(staticsDollarReceiver, preview.staticsDollarMinted);
        IStaticsDollarRiskShares(cs.staticsDollarRisk).mint(shareReceiver, preview.seriesId, preview.sharesMinted);
        LibCoreAccounting.enforceCustody(cs, profile.collateralToken);
        emit Deposited(
            msg.sender,
            staticsDollarReceiver,
            shareReceiver,
            profileId,
            preview.seriesId,
            collateralAmount,
            preview.staticsDollarMinted,
            preview.sharesMinted,
            preview.priceWad,
            preview.collateralPerPairWad
        );
    }

    function mintPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver
    ) external nonReentrant returns (uint256 collateralIn) {
        if (staticsDollarReceiver == address(0)) revert ZeroAddress();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview =
            _previewPeggedMint(cs, profileId, staticsDollarAmount);
        if (preview.totalCollateralIn > maximumCollateralIn) {
            revert CollateralAboveMaximum(preview.totalCollateralIn, maximumCollateralIn);
        }
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        LibCoreAccounting.pullExact(profile.collateralToken, msg.sender, preview.totalCollateralIn);

        profile.accountedCollateral += preview.principalCollateral;
        profile.seniorOutstanding += staticsDollarAmount;
        cs.totalSeniorOutstanding += staticsDollarAmount;
        cs.accountedCollateralByToken[profile.collateralToken] += preview.principalCollateral;
        LibCoreAccounting.enforceHealthy(cs, profileId, profile);

        LibCoreAccounting.collectPeggedProfileFee(
            cs, msg.sender, profile.collateralToken, preview.feeAmount, profileId, IStaticsDollarCoreTypes.FeeKind.Mint
        );
        IStaticsDollar(cs.staticsDollar).mint(staticsDollarReceiver, staticsDollarAmount);
        LibCoreAccounting.enforceCustody(cs, profile.collateralToken);
        emit PeggedMinted(
            msg.sender,
            staticsDollarReceiver,
            profileId,
            staticsDollarAmount,
            preview.principalCollateral,
            preview.feeAmount
        );
        return preview.totalCollateralIn;
    }

    function redeemPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        if (receiver == address(0)) revert ZeroAddress();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview =
            _previewPeggedRedemption(cs, profileId, staticsDollarAmount);

        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = LibCorePeggedRedemption.checkpoint(cs);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit PeggedRedemptionDeferred(msg.sender, receiver, profileId, status, unhealthyBitmap);
            return (status, 0);
        }
        if (preview.collateralOut < minimumCollateralOut) {
            revert OutputBelowMinimum(preview.collateralOut, minimumCollateralOut);
        }

        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        profile.accountedCollateral -= preview.grossCollateral;
        profile.seniorOutstanding -= staticsDollarAmount;
        cs.totalSeniorOutstanding -= staticsDollarAmount;
        cs.accountedCollateralByToken[profile.collateralToken] -= preview.grossCollateral;

        IStaticsDollar(cs.staticsDollar).burn(msg.sender, staticsDollarAmount);
        LibCoreAccounting.collectPeggedProfileFee(
            cs,
            msg.sender,
            profile.collateralToken,
            preview.feeAmount,
            profileId,
            IStaticsDollarCoreTypes.FeeKind.Redemption
        );
        LibCoreAccounting.pushExact(profile.collateralToken, receiver, preview.collateralOut);
        LibCoreAccounting.enforceCustody(cs, profile.collateralToken);
        emit PeggedRedeemed(
            msg.sender,
            receiver,
            profileId,
            staticsDollarAmount,
            preview.grossCollateral,
            preview.feeAmount,
            preview.collateralOut
        );
        return (IStaticsDollarCoreTypes.ExitStatus.Available, preview.collateralOut);
    }

    function recombine(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 shareAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        return _recombine(
            LibCoreStorage.s(), seriesId, staticsDollarAmount, shareAmount, minimumCollateralOut, receiver, false
        );
    }

    function recombineManaged(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 shareAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        if (msg.sender != cs.periphery) revert OnlyManagedPeriphery(msg.sender, cs.periphery);
        return _recombine(cs, seriesId, staticsDollarAmount, shareAmount, minimumCollateralOut, receiver, true);
    }

    function _recombine(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 shareAmount,
        uint256 minimumCollateralOut,
        address receiver,
        bool managed
    ) private returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) {
        if (receiver == address(0)) revert ZeroAddress();
        IStaticsDollarCoreTypes.RedemptionPreview memory preview = _previewRecombine(cs, seriesId, staticsDollarAmount);
        if (shareAmount != preview.sharesBurned) revert InvalidShareAmount(shareAmount, preview.sharesBurned);

        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = LibCoreHealth.checkpointGlobalHealth(cs, false);
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit CollateralExitDeferred(msg.sender, receiver, seriesId, status, unhealthyBitmap);
            return (status, 0);
        }

        RecombineContext memory ctx = RecombineContext({
            seriesId: seriesId,
            staticsDollarAmount: staticsDollarAmount,
            shareAmount: shareAmount,
            receiver: receiver,
            managed: managed,
            gross: 0,
            collateralOut: 0,
            terminalEligible: false
        });
        _applyRecombinationExit(cs, ctx, preview, minimumCollateralOut);
        _recordRecombination(cs, ctx);
        _settleRecombination(cs, ctx, preview);
        return (IStaticsDollarCoreTypes.ExitStatus.Available, ctx.collateralOut);
    }

    /// @dev Series-mode guard, expired-book consumption, and the output bound.
    function _applyRecombinationExit(
        LibCoreStorage.CS storage cs,
        RecombineContext memory ctx,
        IStaticsDollarCoreTypes.RedemptionPreview memory preview,
        uint256 minimumCollateralOut
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        if (profile.mode == IStaticsDollarCoreTypes.ProfileMode.Inactive) {
            revert InvalidProfileMode(series.profileId, profile.mode);
        }

        ctx.gross = preview.collateralOut + preview.feeAmount;
        ctx.terminalEligible = series.status == IStaticsDollarCoreTypes.SeriesStatus.Recoverable
            || series.status == IStaticsDollarCoreTypes.SeriesStatus.Retired;
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            LibCoreRecovery.consumeExpiredBook(cs.expiredRecoveryBook[ctx.seriesId], ctx.shareAmount, ctx.gross);
        }
        ctx.collateralOut = ctx.managed ? ctx.gross : preview.collateralOut;
        if (ctx.collateralOut < minimumCollateralOut) {
            revert OutputBelowMinimum(ctx.collateralOut, minimumCollateralOut);
        }
    }

    /// @dev Series, profile, and global accounting mutations.
    function _recordRecombination(LibCoreStorage.CS storage cs, RecombineContext memory ctx) private {
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        series.seniorOutstanding -= ctx.staticsDollarAmount;
        series.riskSharesOutstanding -= ctx.shareAmount;
        series.accountedCollateral -= ctx.gross;
        profile.seniorOutstanding -= ctx.staticsDollarAmount;
        profile.accountedCollateral -= ctx.gross;
        cs.totalSeniorOutstanding -= ctx.staticsDollarAmount;
        cs.accountedCollateralByToken[series.collateralToken] -= ctx.gross;
        LibCoreAccounting.updateSeriesIndex(cs, ctx.seriesId);
    }

    /// @dev Burns, fee collection, collateral payout, custody enforcement,
    /// terminal close, and the recombination event.
    function _settleRecombination(
        LibCoreStorage.CS storage cs,
        RecombineContext memory ctx,
        IStaticsDollarCoreTypes.RedemptionPreview memory preview
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[ctx.seriesId];
        IStaticsDollar(cs.staticsDollar).burn(msg.sender, ctx.staticsDollarAmount);
        IStaticsDollarRiskShares(cs.staticsDollarRisk).burn(msg.sender, ctx.seriesId, ctx.shareAmount);
        if (!ctx.managed) {
            LibCoreAccounting.collectSeriesFee(
                cs,
                msg.sender,
                series.collateralToken,
                preview.feeAmount,
                ctx.seriesId,
                IStaticsDollarCoreTypes.FeeKind.Redemption
            );
        }
        LibCoreAccounting.pushExact(series.collateralToken, ctx.receiver, ctx.collateralOut);
        LibCoreAccounting.enforceCustody(cs, series.collateralToken);
        if (ctx.terminalEligible && LibCoreRecovery.closeIfEmpty(cs, ctx.seriesId)) {
            emit SeriesClosed(series.profileId, ctx.seriesId);
        }

        emit Recombined(
            msg.sender,
            ctx.receiver,
            ctx.seriesId,
            ctx.staticsDollarAmount,
            ctx.shareAmount,
            series.collateralToken,
            ctx.collateralOut,
            preview.collateralRatioBpsAfter
        );
    }

    function previewDeposit(uint256 profileId, uint256 collateralAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.DepositPreview memory preview)
    {
        return _previewDeposit(LibCoreStorage.s(), profileId, collateralAmount);
    }

    function previewPeggedMint(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview)
    {
        return _previewPeggedMint(LibCoreStorage.s(), profileId, staticsDollarAmount);
    }

    function previewPeggedRedemption(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview)
    {
        return _previewPeggedRedemption(LibCoreStorage.s(), profileId, staticsDollarAmount);
    }

    function previewRecombine(uint256 seriesId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.RedemptionPreview memory preview)
    {
        return _previewRecombine(LibCoreStorage.s(), seriesId, staticsDollarAmount);
    }

    function requiredSharesForRecombine(uint256, uint256 staticsDollarAmount) external pure returns (uint256 shares) {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        return staticsDollarAmount;
    }

    function _previewDeposit(LibCoreStorage.CS storage cs, uint256 profileId, uint256 collateralAmount)
        private
        view
        returns (IStaticsDollarCoreTypes.DepositPreview memory preview)
    {
        if (collateralAmount == 0) revert ZeroAmount();
        LibCoreAccounting.enforceBootstrapFinalized(cs);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        LibCoreAccounting.enforceOperationAvailable(cs, profileId, LibCoreAccounting.PAUSE_MINTING);
        LibCoreAccounting.enforceHealthy(cs, profileId, profile);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Volatile) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Volatile, profile.kind);
        }
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active) {
            revert InvalidProfileMode(profileId, profile.mode);
        }
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[profile.activeSeriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
            revert SeriesNotActive(profile.activeSeriesId);
        }
        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        if (
            priceWad <= LibCoreAccounting.downsideTriggerPrice(series)
                || priceWad >= LibCoreAccounting.upsideTriggerPrice(series)
        ) revert TransitionRequired(profileId, profile.activeSeriesId, priceWad);

        preview.profileId = profileId;
        preview.seriesId = profile.activeSeriesId;
        preview.collateralIn = collateralAmount;
        preview.feeAmount = LibCoreAccounting.feeAmount(collateralAmount, profile.mintFeeBps);
        preview.priceWad = priceWad;
        preview.collateralPerPairWad = series.collateralPerPairWad;
        uint256 net = collateralAmount - preview.feeAmount;
        preview.insuranceContribution =
            LibCoreAccounting.insuranceContribution(profile, net, priceWad, series.collateralPerPairWad);
        uint256 pairCollateral = net - preview.insuranceContribution;
        preview.staticsDollarMinted =
            Math.mulDiv(LibCoreAccounting.toWad(pairCollateral, profile.decimals), WAD, series.collateralPerPairWad);
        if (preview.staticsDollarMinted == 0) revert DepositTooSmall();
        uint256 attemptedSenior = profile.seniorOutstanding + preview.staticsDollarMinted;
        if (attemptedSenior > profile.debtCeiling) {
            revert DebtCeilingExceeded(profileId, attemptedSenior, profile.debtCeiling);
        }
        preview.sharesMinted = preview.staticsDollarMinted;
        LibCoreAccounting.enforceProjectedCoverage(profileId, profile, net, preview.staticsDollarMinted, priceWad);
        preview.collateralRatioBpsAfter = LibCoreAccounting.collateralRatioBps(
            profile.decimals,
            series.accountedCollateral + pairCollateral,
            series.seniorOutstanding + preview.staticsDollarMinted,
            priceWad
        );
    }

    function _previewPeggedMint(LibCoreStorage.CS storage cs, uint256 profileId, uint256 staticsDollarAmount)
        private
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview)
    {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        LibCoreAccounting.enforceBootstrapFinalized(cs);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Pegged) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Pegged, profile.kind);
        }
        LibCoreAccounting.enforceOperationAvailable(cs, profileId, LibCoreAccounting.PAUSE_MINTING);
        LibCoreAccounting.enforceHealthy(cs, profileId, profile);
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active) {
            revert InvalidProfileMode(profileId, profile.mode);
        }
        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        if (priceWad < profile.pegMinPriceWad || priceWad > profile.pegMaxPriceWad) {
            revert PegOutOfBounds(profileId, priceWad, profile.pegMinPriceWad, profile.pegMaxPriceWad);
        }

        uint256 principal = LibCoreAccounting.fromWadCeil(staticsDollarAmount, profile.decimals);
        uint256 fee = LibCoreAccounting.feeAmount(principal, profile.mintFeeBps);
        uint256 attemptedSenior = profile.seniorOutstanding + staticsDollarAmount;
        if (attemptedSenior > profile.debtCeiling) {
            revert DebtCeilingExceeded(profileId, attemptedSenior, profile.debtCeiling);
        }
        LibCoreAccounting.enforceProjectedCoverage(profileId, profile, principal, staticsDollarAmount, priceWad);
        return IStaticsDollarCoreTypes.PeggedMintPreview({
            profileId: profileId,
            collateralToken: profile.collateralToken,
            staticsDollarMinted: staticsDollarAmount,
            principalCollateral: principal,
            feeAmount: fee,
            totalCollateralIn: principal + fee,
            priceWad: priceWad
        });
    }

    function _previewRecombine(LibCoreStorage.CS storage cs, uint256 seriesId, uint256 staticsDollarAmount)
        private
        view
        returns (IStaticsDollarCoreTypes.RedemptionPreview memory preview)
    {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        IStaticsDollarCoreTypes.RiskSeries storage series = LibCoreAccounting.series(cs, seriesId);
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Active
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Retired
        ) revert InvalidSeries(seriesId);
        if (
            series.seniorOutstanding == 0 || series.riskSharesOutstanding == 0
                || staticsDollarAmount > series.seniorOutstanding || staticsDollarAmount > series.riskSharesOutstanding
        ) revert EmptyPool();

        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        uint256 gross;
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            (gross,,) = LibCoreRecovery.expiredBookSlice(cs.expiredRecoveryBook[seriesId], staticsDollarAmount);
        } else {
            gross = staticsDollarAmount == series.seniorOutstanding
                ? series.accountedCollateral
                : Math.mulDiv(series.accountedCollateral, staticsDollarAmount, series.seniorOutstanding);
        }
        uint256 fee = LibCoreAccounting.feeAmount(gross, profile.redemptionFeeBps);
        uint256 net = gross - fee;
        if (gross == 0 || net == 0) revert RedemptionTooSmall();

        uint256 priceWad;
        uint256 ratioAfter;
        (bool priceAvailable, uint256 currentPrice) = LibCoreHealth.tryPrice(profile.oracle);
        if (priceAvailable) {
            priceWad = currentPrice;
            ratioAfter = LibCoreAccounting.collateralRatioBps(
                profile.decimals,
                series.accountedCollateral - gross,
                series.seniorOutstanding - staticsDollarAmount,
                currentPrice
            );
        }
        return IStaticsDollarCoreTypes.RedemptionPreview({
            profileId: series.profileId,
            seriesId: seriesId,
            collateralToken: series.collateralToken,
            staticsDollarBurned: staticsDollarAmount,
            sharesBurned: staticsDollarAmount,
            collateralOut: net,
            feeAmount: fee,
            priceWad: priceWad,
            collateralRatioBpsAfter: ratioAfter
        });
    }

    function _previewPeggedRedemption(LibCoreStorage.CS storage cs, uint256 profileId, uint256 staticsDollarAmount)
        private
        view
        returns (IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview)
    {
        if (staticsDollarAmount == 0) revert ZeroAmount();
        LibCoreAccounting.enforceBootstrapFinalized(cs);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Pegged) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Pegged, profile.kind);
        }
        if (
            profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active
                && profile.mode != IStaticsDollarCoreTypes.ProfileMode.ReduceOnly
                && profile.mode != IStaticsDollarCoreTypes.ProfileMode.Retired
        ) revert InvalidProfileMode(profileId, profile.mode);
        if (profile.seniorOutstanding == 0 || staticsDollarAmount > profile.seniorOutstanding) revert EmptyPool();

        uint256 gross = staticsDollarAmount == profile.seniorOutstanding
            ? profile.accountedCollateral
            : Math.mulDiv(profile.accountedCollateral, staticsDollarAmount, profile.seniorOutstanding);
        uint256 fee = LibCoreAccounting.feeAmount(gross, profile.redemptionFeeBps);
        uint256 net = gross - fee;
        if (gross == 0 || net == 0) revert RedemptionTooSmall();
        (, uint256 priceWad) = LibCoreHealth.tryPrice(profile.oracle);
        return IStaticsDollarCoreTypes.PeggedRedemptionPreview({
            profileId: profileId,
            collateralToken: profile.collateralToken,
            staticsDollarBurned: staticsDollarAmount,
            grossCollateral: gross,
            feeAmount: fee,
            collateralOut: net,
            priceWad: priceWad
        });
    }
}
