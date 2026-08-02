// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IUsdOracle} from "../../interfaces/IUsdOracle.sol";
import {ICoreBootstrapWiring} from "../interfaces/ICoreBootstrapWiring.sol";
import {LibCore} from "../libraries/LibCore.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCorePeggedRedemption} from "../libraries/LibCorePeggedRedemption.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreGovernanceFacet is ReentrancyGuard {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_PROFILE_ID = 255;
    uint256 internal constant MAX_FEE_BPS = BPS;
    uint256 internal constant PAUSE_MINTING = 1 << 0;
    uint256 internal constant PAUSE_ROLLOVER = 1 << 1;
    uint256 internal constant PAUSE_PAIRING_FILLS = 1 << 2;
    uint256 internal constant ALL_OPERATION_PAUSES = PAUSE_MINTING | PAUSE_ROLLOVER | PAUSE_PAIRING_FILLS;

    struct ProfileRiskConfig {
        uint256 collateralRatioBps;
        uint256 priceBandBps;
        uint256 mintFeeBps;
        uint256 redemptionFeeBps;
        uint256 insuranceTargetBps;
        uint256 insuranceFeeBps;
        uint256 pegMinPriceWad;
        uint256 pegMaxPriceWad;
        uint256 debtCeiling;
    }

    event CoreBootstrapFinalized(address indexed staticsDiamond);
    event VolatileCollateralProfileCreated(
        uint256 indexed profileId,
        address indexed collateralToken,
        address indexed oracle,
        uint8 decimals,
        uint256 activeSeriesId
    );
    event PeggedCollateralProfileCreated(
        uint256 indexed profileId, address indexed collateralToken, address indexed oracle, uint8 decimals
    );
    event SeriesOpened(uint256 indexed profileId, uint256 indexed seriesId, uint256 priceWad);
    event ProfileRiskConfigurationSet(uint256 indexed profileId, uint256 debtCeiling);
    event DebtCeilingReduced(uint256 indexed profileId, uint256 previousCeiling, uint256 newCeiling);
    event ProfileModeChanged(
        uint256 indexed profileId,
        IStaticsDollarCoreTypes.ProfileMode previousMode,
        IStaticsDollarCoreTypes.ProfileMode newMode,
        address indexed caller
    );
    event ProfileOperationsPaused(uint256 indexed profileId, uint256 operations, address indexed caller);
    event ProfileOperationsResumed(uint256 indexed profileId, uint256 operations, address indexed caller);
    event ProfileOracleActivated(uint256 indexed profileId, address indexed previousOracle, address indexed newOracle);
    event SeriesTransitionCancelledForOracle(
        uint256 indexed profileId, uint256 indexed seriesId, address indexed replacementOracle
    );
    event ProfilePermanentlyRetired(uint256 indexed profileId, uint256 indexed seriesId, uint256 insuranceAllocated);
    event PeggedProfilePermanentlyRetired(uint256 indexed profileId);
    event ManagedRecoveryHolderSet(address indexed holder, bool managed);

    error ZeroAddress();
    error BootstrapAlreadyFinalized();
    error InvalidPeripheryWiring(address component, bytes4 selector, address expected, address actual);
    error BootstrapNotFinalized();
    error InvalidProfile(uint256 profileId);
    error TooManyProfiles(uint256 profileId);
    error InvalidCollateralRatio(uint256 collateralRatioBps);
    error InvalidPriceBand(uint256 priceBandBps);
    error InvalidFeeBps(uint256 feeBps);
    error InvalidInsuranceBps(uint256 bps);
    error InvalidDebtCeiling(uint256 debtCeiling, uint256 seniorOutstanding);
    error InvalidPegBounds(uint256 minimumPriceWad, uint256 maximumPriceWad);
    error InvalidCollateralDecimals(uint8 decimals);
    error CollateralTokenAlreadyAssigned(address collateralToken, uint256 profileId);
    error InvalidProfileMode(uint256 profileId, IStaticsDollarCoreTypes.ProfileMode mode);
    error SeriesTransitionPending(uint256 profileId, uint256 seriesId);
    error InvalidOperationMask(uint256 operations);

    function finalizeBootstrap(address staticsDiamond) external nonReentrant {
        LibCoreStorage.enforceBootstrapAuthority();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        if (cs.bootstrapFinalized) revert BootstrapAlreadyFinalized();
        if (staticsDiamond == address(0)) revert ZeroAddress();
        LibCore.requireContract(staticsDiamond);
        _requireWiring(
            staticsDiamond,
            ICoreBootstrapWiring.pool.selector,
            address(this),
            ICoreBootstrapWiring(staticsDiamond).pool()
        );
        _requireWiring(
            staticsDiamond,
            ICoreBootstrapWiring.staticsDollar.selector,
            cs.staticsDollar,
            ICoreBootstrapWiring(staticsDiamond).staticsDollar()
        );
        _requireWiring(
            staticsDiamond,
            ICoreBootstrapWiring.staticsDollarRisk.selector,
            cs.staticsDollarRisk,
            ICoreBootstrapWiring(staticsDiamond).staticsDollarRisk()
        );
        cs.periphery = staticsDiamond;
        cs.managedRecoveryHolder[staticsDiamond] = true;
        cs.bootstrapFinalized = true;
        cs.bootstrapAuthority = address(0);
        emit CoreBootstrapFinalized(staticsDiamond);
        emit ManagedRecoveryHolderSet(staticsDiamond, true);
    }

    function setManagedRecoveryHolder(address holder, bool managed) external {
        LibCoreStorage.enforceProtocolOwner();
        LibCoreStorage.s().managedRecoveryHolder[holder] = managed;
        emit ManagedRecoveryHolderSet(holder, managed);
    }

    function createCollateralProfile(
        address collateralToken,
        address oracle,
        uint256 collateralRatioBps,
        uint256 priceBandBps,
        uint256 mintFeeBps,
        uint256 redemptionFeeBps,
        uint256 debtCeiling
    ) external returns (uint256 profileId, uint256 seriesId) {
        LibCoreStorage.enforceProtocolOwner();
        _enforceBootstrapFinalized();
        _validateVolatileConfig(
            collateralToken, oracle, collateralRatioBps, priceBandBps, mintFeeBps, redemptionFeeBps, debtCeiling
        );
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        profileId = cs.nextProfileId++;
        if (profileId > MAX_PROFILE_ID) revert TooManyProfiles(profileId);
        seriesId = cs.nextSeriesId++;
        uint8 decimals = IERC20Metadata(collateralToken).decimals();
        cs.collateralProfiles[profileId] = IStaticsDollarCoreTypes.StableCollateralProfile({
            collateralToken: collateralToken,
            oracle: oracle,
            decimals: decimals,
            collateralRatioBps: uint16(collateralRatioBps),
            priceBandBps: uint16(priceBandBps),
            mintFeeBps: uint16(mintFeeBps),
            redemptionFeeBps: uint16(redemptionFeeBps),
            insuranceTargetBps: 0,
            insuranceFeeBps: 0,
            kind: IStaticsDollarCoreTypes.ProfileKind.Volatile,
            mode: IStaticsDollarCoreTypes.ProfileMode.Inactive,
            pegMinPriceWad: 0,
            pegMaxPriceWad: 0,
            activeSeriesId: seriesId,
            accountedCollateral: 0,
            insuranceReserve: 0,
            seniorOutstanding: 0,
            debtCeiling: debtCeiling
        });
        cs.profileIdByCollateralToken[collateralToken] = profileId;
        cs.profileOracleRevision[profileId] = 1;
        uint256 priceWad = IUsdOracle(oracle).priceWad();
        _openSeries(cs, profileId, seriesId, collateralToken, priceWad, collateralRatioBps, priceBandBps);
        emit VolatileCollateralProfileCreated(profileId, collateralToken, oracle, decimals, seriesId);
    }

    function createPeggedCollateralProfile(
        address collateralToken,
        address oracle,
        uint256 pegMinPriceWad,
        uint256 pegMaxPriceWad,
        uint256 mintFeeBps,
        uint256 redemptionFeeBps,
        uint256 debtCeiling
    ) external returns (uint256 profileId) {
        LibCoreStorage.enforceProtocolOwner();
        _enforceBootstrapFinalized();
        _validatePeggedConfig(
            collateralToken,
            oracle,
            pegMinPriceWad,
            pegMaxPriceWad,
            mintFeeBps,
            redemptionFeeBps,
            debtCeiling
        );
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        profileId = cs.nextProfileId++;
        if (profileId > MAX_PROFILE_ID) revert TooManyProfiles(profileId);
        uint8 decimals = IERC20Metadata(collateralToken).decimals();
        cs.collateralProfiles[profileId] = IStaticsDollarCoreTypes.StableCollateralProfile({
            collateralToken: collateralToken,
            oracle: oracle,
            decimals: decimals,
            collateralRatioBps: uint16(BPS),
            priceBandBps: uint16(BPS),
            mintFeeBps: uint16(mintFeeBps),
            redemptionFeeBps: uint16(redemptionFeeBps),
            insuranceTargetBps: 0,
            insuranceFeeBps: 0,
            kind: IStaticsDollarCoreTypes.ProfileKind.Pegged,
            mode: IStaticsDollarCoreTypes.ProfileMode.Inactive,
            pegMinPriceWad: pegMinPriceWad,
            pegMaxPriceWad: pegMaxPriceWad,
            activeSeriesId: 0,
            accountedCollateral: 0,
            insuranceReserve: 0,
            seniorOutstanding: 0,
            debtCeiling: debtCeiling
        });
        cs.profileIdByCollateralToken[collateralToken] = profileId;
        cs.profileOracleRevision[profileId] = 1;
        emit PeggedCollateralProfileCreated(profileId, collateralToken, oracle, decimals);
    }

    function setProfileRiskConfig(uint256 profileId, ProfileRiskConfig calldata config) external {
        LibCoreStorage.enforceProtocolOwner();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = _profile(profileId);
        _validateRiskConfig(profile, config);
        profile.collateralRatioBps = uint16(config.collateralRatioBps);
        profile.priceBandBps = uint16(config.priceBandBps);
        profile.mintFeeBps = uint16(config.mintFeeBps);
        profile.redemptionFeeBps = uint16(config.redemptionFeeBps);
        profile.insuranceTargetBps = uint16(config.insuranceTargetBps);
        profile.insuranceFeeBps = uint16(config.insuranceFeeBps);
        profile.pegMinPriceWad = config.pegMinPriceWad;
        profile.pegMaxPriceWad = config.pegMaxPriceWad;
        profile.debtCeiling = config.debtCeiling;
        emit ProfileRiskConfigurationSet(profileId, config.debtCeiling);
    }

    function reduceDebtCeiling(uint256 profileId, uint256 newDebtCeiling) external {
        LibCoreStorage.enforceGuardianOrOwner();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = _profile(profileId);
        if (newDebtCeiling < profile.seniorOutstanding || newDebtCeiling >= profile.debtCeiling) {
            revert InvalidDebtCeiling(newDebtCeiling, profile.seniorOutstanding);
        }
        uint256 previous = profile.debtCeiling;
        profile.debtCeiling = newDebtCeiling;
        emit DebtCeilingReduced(profileId, previous, newDebtCeiling);
    }

    function enterReduceOnly(uint256 profileId) external {
        LibCoreStorage.enforceGuardianOrOwner();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = _profile(profileId);
        if (profile.mode == IStaticsDollarCoreTypes.ProfileMode.Retired) {
            revert InvalidProfileMode(profileId, profile.mode);
        }
        IStaticsDollarCoreTypes.ProfileMode previous = profile.mode;
        profile.mode = IStaticsDollarCoreTypes.ProfileMode.ReduceOnly;
        emit ProfileModeChanged(profileId, previous, profile.mode, msg.sender);
    }

    function setProfileMode(uint256 profileId, IStaticsDollarCoreTypes.ProfileMode mode) external {
        LibCoreStorage.enforceProtocolOwner();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = _profile(profileId);
        if (mode != IStaticsDollarCoreTypes.ProfileMode.Active && mode != IStaticsDollarCoreTypes.ProfileMode.Retired) {
            revert InvalidProfileMode(profileId, mode);
        }
        if (profile.mode == IStaticsDollarCoreTypes.ProfileMode.Retired || profile.mode == mode) {
            revert InvalidProfileMode(profileId, mode);
        }
        if (
            mode == IStaticsDollarCoreTypes.ProfileMode.Retired
                && profile.mode != IStaticsDollarCoreTypes.ProfileMode.ReduceOnly
        ) revert InvalidProfileMode(profileId, mode);
        IStaticsDollarCoreTypes.ProfileMode previous = profile.mode;
        if (mode == IStaticsDollarCoreTypes.ProfileMode.Retired) {
            _retireProfile(cs, profileId, profile);
        } else {
            profile.mode = mode;
        }
        emit ProfileModeChanged(profileId, previous, mode, msg.sender);
    }

    function pauseProfileOperations(uint256 profileId, uint256 operations) external {
        LibCoreStorage.enforceGuardianOrOwner();
        _profile(profileId);
        _validateOperations(operations);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        cs.pausedProfileOperations[profileId] |= operations;
        emit ProfileOperationsPaused(profileId, operations, msg.sender);
    }

    function resumeProfileOperations(uint256 profileId, uint256 operations) external {
        LibCoreStorage.enforceProtocolOwner();
        _profile(profileId);
        _validateOperations(operations);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        if ((cs.pausedProfileOperations[profileId] & operations) != operations) {
            revert InvalidOperationMask(operations);
        }
        cs.pausedProfileOperations[profileId] &= ~operations;
        emit ProfileOperationsResumed(profileId, operations, msg.sender);
    }

    function setProfileOracle(uint256 profileId, address oracle) external {
        LibCoreStorage.enforceProtocolOwner();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = _profile(profileId);
        LibCore.validateOracle(oracle, cs.requiredSequencerUptimeFeed, cs.minimumSequencerGracePeriod);
        address previous = profile.oracle;
        uint256 activeSeriesId = profile.activeSeriesId;
        if (
            profile.kind == IStaticsDollarCoreTypes.ProfileKind.Volatile
                && cs.riskSeries[activeSeriesId].status == IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending
        ) {
            IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[activeSeriesId];
            LibCorePeggedRedemption.resolveDownside(cs, activeSeriesId);
            recovery.kind = IStaticsDollarCoreTypes.TransitionKind.None;
            recovery.startedAt = 0;
            recovery.endsAt = 0;
            cs.riskSeries[activeSeriesId].status = IStaticsDollarCoreTypes.SeriesStatus.Active;
            delete cs.transitionSnapshot[activeSeriesId];
            emit SeriesTransitionCancelledForOracle(profileId, activeSeriesId, oracle);
        }
        profile.oracle = oracle;
        cs.profileOracleRevision[profileId]++;
        emit ProfileOracleActivated(profileId, previous, oracle);
    }

    function _openSeries(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        uint256 seriesId,
        address collateralToken,
        uint256 priceWad,
        uint256 ratioBps,
        uint256 bandBps
    ) private {
        uint256 collateralPerPairWad = Math.mulDiv(Math.mulDiv(WAD, ratioBps, BPS), WAD, priceWad);
        uint256 seniorCollateralPerUnitWad = Math.mulDiv(WAD, WAD, priceWad);
        cs.riskSeries[seriesId] = IStaticsDollarCoreTypes.RiskSeries({
            profileId: profileId,
            collateralToken: collateralToken,
            seniorOutstanding: 0,
            riskSharesOutstanding: 0,
            accountedCollateral: 0,
            startPriceWad: priceWad,
            collateralPerPairWad: collateralPerPairWad,
            seniorCollateralPerUnitWad: seniorCollateralPerUnitWad,
            juniorCollateralPerUnitWad: collateralPerPairWad - seniorCollateralPerUnitWad,
            collateralRatioBps: ratioBps,
            priceBandBps: bandBps,
            startedAt: block.timestamp,
            retiredAt: 0,
            successorSeriesId: 0,
            status: IStaticsDollarCoreTypes.SeriesStatus.Active
        });
        cs.profileSeries[profileId].push(seriesId);
        emit SeriesOpened(profileId, seriesId, priceWad);
    }

    function _retireProfile(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile
    ) private {
        if (profile.kind == IStaticsDollarCoreTypes.ProfileKind.Pegged) {
            profile.mode = IStaticsDollarCoreTypes.ProfileMode.Retired;
            emit PeggedProfilePermanentlyRetired(profileId);
            return;
        }
        uint256 seriesId = profile.activeSeriesId;
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) {
            revert SeriesTransitionPending(profileId, seriesId);
        }
        uint256 allocated;
        if (profile.insuranceReserve != 0 && series.seniorOutstanding != 0) {
            allocated = profile.insuranceReserve;
            profile.insuranceReserve = 0;
            profile.accountedCollateral += allocated;
            series.accountedCollateral += allocated;
            LibCoreAccounting.updateSeriesIndex(cs, seriesId);
        }
        series.status = series.seniorOutstanding == 0 && series.riskSharesOutstanding == 0
            && series.accountedCollateral == 0
            ? IStaticsDollarCoreTypes.SeriesStatus.Closed
            : IStaticsDollarCoreTypes.SeriesStatus.Retired;
        series.retiredAt = block.timestamp;
        series.successorSeriesId = 0;
        profile.mode = IStaticsDollarCoreTypes.ProfileMode.Retired;
        emit ProfilePermanentlyRetired(profileId, seriesId, allocated);
    }

    function _validateVolatileConfig(
        address collateralToken,
        address oracle,
        uint256 ratioBps,
        uint256 bandBps,
        uint256 mintFeeBps,
        uint256 redemptionFeeBps,
        uint256 debtCeiling
    ) private view {
        LibCore.requireContract(collateralToken);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        _validateCollateralAvailable(cs, collateralToken);
        LibCore.validateOracle(oracle, cs.requiredSequencerUptimeFeed, cs.minimumSequencerGracePeriod);
        if (ratioBps <= BPS || ratioBps > 30_000) revert InvalidCollateralRatio(ratioBps);
        if (bandBps <= BPS || bandBps > 30_000 || bandBps > ratioBps) revert InvalidPriceBand(bandBps);
        _validateFee(mintFeeBps);
        _validateFee(redemptionFeeBps);
        if (debtCeiling == 0) revert InvalidDebtCeiling(debtCeiling, 0);
        uint8 decimals = IERC20Metadata(collateralToken).decimals();
        if (decimals > 18) revert InvalidCollateralDecimals(decimals);
    }

    function _validatePeggedConfig(
        address collateralToken,
        address oracle,
        uint256 pegMinPriceWad,
        uint256 pegMaxPriceWad,
        uint256 mintFeeBps,
        uint256 redemptionFeeBps,
        uint256 debtCeiling
    ) private view {
        LibCore.requireContract(collateralToken);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        _validateCollateralAvailable(cs, collateralToken);
        LibCore.validateOracle(oracle, cs.requiredSequencerUptimeFeed, cs.minimumSequencerGracePeriod);
        if (pegMinPriceWad == 0 || pegMinPriceWad >= WAD || pegMaxPriceWad <= WAD || pegMinPriceWad >= pegMaxPriceWad) {
            revert InvalidPegBounds(pegMinPriceWad, pegMaxPriceWad);
        }
        _validateFee(mintFeeBps);
        _validateFee(redemptionFeeBps);
        if (debtCeiling == 0) revert InvalidDebtCeiling(debtCeiling, 0);
        uint8 decimals = IERC20Metadata(collateralToken).decimals();
        if (decimals > 18) revert InvalidCollateralDecimals(decimals);
    }

    function _validateRiskConfig(
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile,
        ProfileRiskConfig calldata config
    ) private view {
        if (config.debtCeiling < profile.seniorOutstanding || config.debtCeiling == 0) {
            revert InvalidDebtCeiling(config.debtCeiling, profile.seniorOutstanding);
        }
        _validateFee(config.mintFeeBps);
        _validateFee(config.redemptionFeeBps);
        if (config.insuranceTargetBps > BPS) revert InvalidInsuranceBps(config.insuranceTargetBps);
        if (config.insuranceFeeBps > BPS) revert InvalidInsuranceBps(config.insuranceFeeBps);
        if (profile.kind == IStaticsDollarCoreTypes.ProfileKind.Volatile) {
            if (config.collateralRatioBps <= BPS || config.collateralRatioBps > 30_000) {
                revert InvalidCollateralRatio(config.collateralRatioBps);
            }
            if (
                config.priceBandBps <= BPS || config.priceBandBps > 30_000
                    || config.priceBandBps > config.collateralRatioBps
            ) revert InvalidPriceBand(config.priceBandBps);
            if (
                config.pegMinPriceWad != 0 || config.pegMaxPriceWad != 0
            ) revert InvalidPegBounds(config.pegMinPriceWad, config.pegMaxPriceWad);
        } else {
            if (
                config.collateralRatioBps != BPS || config.priceBandBps != BPS || config.insuranceTargetBps != 0
                    || config.insuranceFeeBps != 0
            ) revert InvalidCollateralRatio(config.collateralRatioBps);
            if (
                config.pegMinPriceWad == 0 || config.pegMinPriceWad >= WAD || config.pegMaxPriceWad <= WAD
                    || config.pegMinPriceWad >= config.pegMaxPriceWad
            ) revert InvalidPegBounds(config.pegMinPriceWad, config.pegMaxPriceWad);
        }
    }

    function _profile(uint256 profileId)
        private
        view
        returns (IStaticsDollarCoreTypes.StableCollateralProfile storage profile)
    {
        profile = LibCoreStorage.s().collateralProfiles[profileId];
        if (profile.collateralToken == address(0)) revert InvalidProfile(profileId);
    }

    function _enforceBootstrapFinalized() private view {
        if (!LibCoreStorage.s().bootstrapFinalized) revert BootstrapNotFinalized();
    }

    function _validateFee(uint256 feeBps) private pure {
        if (feeBps > MAX_FEE_BPS) revert InvalidFeeBps(feeBps);
    }

    function _validateOperations(uint256 operations) private pure {
        if (operations == 0 || (operations & ~ALL_OPERATION_PAUSES) != 0) revert InvalidOperationMask(operations);
    }

    function _validateCollateralAvailable(LibCoreStorage.CS storage cs, address collateralToken) private view {
        uint256 assignedProfileId = cs.profileIdByCollateralToken[collateralToken];
        if (assignedProfileId != 0) revert CollateralTokenAlreadyAssigned(collateralToken, assignedProfileId);
    }

    function _requireWiring(address component, bytes4 selector, address expected, address actual) private pure {
        if (actual != expected) revert InvalidPeripheryWiring(component, selector, expected, actual);
    }
}
