// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IUsdOracle} from "../../interfaces/IUsdOracle.sol";
import {LibCoreHealth} from "./LibCoreHealth.sol";
import {LibCoreStorage} from "./LibCoreStorage.sol";
import {LibSolvencyIndex} from "./LibSolvencyIndex.sol";

interface ICoreFeeReceiver {
    function onSeriesFee(uint256 seriesId, address token, uint256 amount, IStaticsDollarCoreTypes.FeeKind kind)
        external;
    function onPeggedProfileFee(
        uint256 profileId,
        address token,
        uint256 amount,
        IStaticsDollarCoreTypes.FeeKind kind
    ) external;
}

library LibCoreAccounting {
    using SafeERC20 for IERC20;
    using LibSolvencyIndex for LibSolvencyIndex.Tree;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PAUSE_MINTING = 1 << 0;
    uint256 internal constant PAUSE_ROLLOVER = 1 << 1;

    error BootstrapNotFinalized();
    error InvalidProfile(uint256 profileId);
    error InvalidSeries(uint256 seriesId);
    error ProfileOperationPaused(uint256 profileId, uint256 operation);
    error ProfileImpaired(uint256 profileId, uint256 seniorDeficitWad);
    error InvalidCollateralAmount(uint256 expectedAmount, uint256 actualAmount);
    error CustodyShortfall(address token, uint256 accounted, uint256 actual);
    error FeeRecipientCallbackFailed(address recipient);
    error NumericOverflow();

    event FeeCollected(
        address indexed payer, address indexed recipient, address indexed collateralToken, uint256 amount
    );

    function enforceBootstrapFinalized(LibCoreStorage.CS storage cs) internal view {
        if (!cs.bootstrapFinalized) revert BootstrapNotFinalized();
    }

    function profile(LibCoreStorage.CS storage cs, uint256 profileId)
        internal
        view
        returns (IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile)
    {
        storedProfile = cs.collateralProfiles[profileId];
        if (storedProfile.collateralToken == address(0)) revert InvalidProfile(profileId);
    }

    function series(LibCoreStorage.CS storage cs, uint256 seriesId)
        internal
        view
        returns (IStaticsDollarCoreTypes.RiskSeries storage storedSeries)
    {
        storedSeries = cs.riskSeries[seriesId];
        if (storedSeries.status == IStaticsDollarCoreTypes.SeriesStatus.None) revert InvalidSeries(seriesId);
    }

    function enforceOperationAvailable(LibCoreStorage.CS storage cs, uint256 profileId, uint256 operation)
        internal
        view
    {
        if ((cs.pausedProfileOperations[profileId] & operation) != 0) {
            revert ProfileOperationPaused(profileId, operation);
        }
    }

    function enforceHealthy(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile
    ) internal view {
        IStaticsDollarCoreTypes.ProfileSolvency memory solvency =
            LibCoreHealth.profileSolvency(cs, profileId, storedProfile);
        if (!solvency.healthy) revert ProfileImpaired(profileId, solvency.seniorDeficitWad);
    }

    function enforceProjectedCoverage(
        uint256 profileId,
        IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile,
        uint256 collateralAdded,
        uint256 seniorAdded,
        uint256 priceWad
    ) internal view {
        uint256 supporting = storedProfile.accountedCollateral + storedProfile.insuranceReserve + collateralAdded;
        uint256 value = LibCoreHealth.valueWad(toWad(supporting, storedProfile.decimals), priceWad);
        uint256 liabilities = storedProfile.seniorOutstanding + seniorAdded;
        if (value < liabilities) revert ProfileImpaired(profileId, liabilities - value);
    }

    function updateSeriesIndex(LibCoreStorage.CS storage cs, uint256 seriesId) internal {
        IStaticsDollarCoreTypes.RiskSeries storage storedSeries = cs.riskSeries[seriesId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        uint256 liability = storedSeries.seniorOutstanding + recovery.seniorRecoveryOutstanding;
        uint256 collateral = storedSeries.accountedCollateral + recovery.seniorRecoveryCollateral;
        uint8 decimals = cs.collateralProfiles[storedSeries.profileId].decimals;
        cs.solvencyIndex[storedSeries.profileId].update(bytes32(seriesId), liability, toWad(collateral, decimals));
    }

    function pullExact(address token, address from, uint256 amount) internal {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) revert InvalidCollateralAmount(amount, received);
    }

    function pushExact(address token, address receiver, uint256 amount) internal {
        if (amount == 0) return;
        uint256 senderBefore = IERC20(token).balanceOf(address(this));
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        IERC20(token).safeTransfer(receiver, amount);
        uint256 senderAfter = IERC20(token).balanceOf(address(this));
        uint256 receiverAfter = IERC20(token).balanceOf(receiver);
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) revert InvalidCollateralAmount(amount, received);
    }

    function collectSeriesFee(
        LibCoreStorage.CS storage cs,
        address payer,
        address token,
        uint256 amount,
        uint256 seriesId,
        IStaticsDollarCoreTypes.FeeKind kind
    ) internal {
        if (amount == 0) return;
        address recipient = cs.periphery;
        cs.cumulativeFeesPaid[payer][token] += amount;
        pushExact(token, recipient, amount);
        try ICoreFeeReceiver(recipient).onSeriesFee(seriesId, token, amount, kind) {}
        catch {
            revert FeeRecipientCallbackFailed(recipient);
        }
        emit FeeCollected(payer, recipient, token, amount);
    }

    function collectPeggedProfileFee(
        LibCoreStorage.CS storage cs,
        address payer,
        address token,
        uint256 amount,
        uint256 profileId,
        IStaticsDollarCoreTypes.FeeKind kind
    ) internal {
        if (amount == 0) return;
        address recipient = cs.periphery;
        cs.cumulativeFeesPaid[payer][token] += amount;
        pushExact(token, recipient, amount);
        try ICoreFeeReceiver(recipient).onPeggedProfileFee(profileId, token, amount, kind) {}
        catch {
            revert FeeRecipientCallbackFailed(recipient);
        }
        emit FeeCollected(payer, recipient, token, amount);
    }

    function enforceCustody(LibCoreStorage.CS storage cs, address token) internal view {
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 accounted = cs.accountedCollateralByToken[token];
        if (actual < accounted) revert CustodyShortfall(token, accounted, actual);
    }

    function insuranceContribution(
        IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile,
        uint256 net,
        uint256 priceWad,
        uint256 collateralPerPairWad
    ) internal view returns (uint256 amount) {
        if (storedProfile.insuranceTargetBps == 0 || storedProfile.insuranceFeeBps == 0) return 0;
        if (postDepositInsuranceTargetReached(storedProfile, net, 0, priceWad, collateralPerPairWad)) return 0;

        uint256 maximum = Math.mulDiv(net, storedProfile.insuranceFeeBps, BPS, Math.Rounding.Ceil);
        if (maximum > net) maximum = net;
        if (!postDepositInsuranceTargetReached(storedProfile, net, maximum, priceWad, collateralPerPairWad)) {
            return maximum;
        }

        uint256 low;
        uint256 high = maximum;
        while (low < high) {
            uint256 middle = low + (high - low) / 2;
            if (postDepositInsuranceTargetReached(storedProfile, net, middle, priceWad, collateralPerPairWad)) {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        return low;
    }

    function postDepositInsuranceTargetReached(
        IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile,
        uint256 net,
        uint256 contribution,
        uint256 priceWad,
        uint256 collateralPerPairWad
    ) internal view returns (bool) {
        uint256 pairCollateral = net - contribution;
        uint256 minted = Math.mulDiv(toWad(pairCollateral, storedProfile.decimals), WAD, collateralPerPairWad);
        uint256 target = insuranceTargetForSenior(storedProfile, storedProfile.seniorOutstanding + minted, priceWad);
        return storedProfile.insuranceReserve + contribution >= target;
    }

    function insuranceTarget(IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile, uint256 priceWad)
        internal
        view
        returns (uint256)
    {
        return insuranceTargetForSenior(storedProfile, storedProfile.seniorOutstanding, priceWad);
    }

    function insuranceTargetForSenior(
        IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile,
        uint256 seniorOutstanding,
        uint256 priceWad
    ) internal view returns (uint256) {
        if (storedProfile.insuranceTargetBps == 0 || seniorOutstanding == 0) return 0;
        uint256 targstaticsDollar = Math.mulDiv(seniorOutstanding, storedProfile.insuranceTargetBps, BPS);
        return fromWadCeil(Math.mulDiv(targstaticsDollar, WAD, priceWad, Math.Rounding.Ceil), storedProfile.decimals);
    }

    function seniorReserveCollateral(uint256 amount, uint256 priceWad, uint8 decimals) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return fromWadCeil(Math.mulDiv(amount, WAD, priceWad, Math.Rounding.Ceil), decimals);
    }

    function collateralRatioBps(uint8 decimals, uint256 collateral, uint256 senior, uint256 priceWad)
        internal
        pure
        returns (uint256)
    {
        if (senior == 0) return 0;
        return Math.mulDiv(Math.mulDiv(toWad(collateral, decimals), priceWad, WAD), BPS, senior);
    }

    function downsideTriggerPrice(IStaticsDollarCoreTypes.RiskSeries storage storedSeries)
        internal
        view
        returns (uint256)
    {
        return Math.mulDiv(storedSeries.startPriceWad, BPS, storedSeries.priceBandBps);
    }

    function upsideTriggerPrice(IStaticsDollarCoreTypes.RiskSeries storage storedSeries)
        internal
        view
        returns (uint256)
    {
        return Math.mulDiv(storedSeries.startPriceWad, storedSeries.priceBandBps, BPS);
    }

    function feeAmount(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (amount == 0 || bps == 0) return 0;
        return Math.mulDiv(amount, bps, BPS, Math.Rounding.Ceil);
    }

    function toWad(uint256 raw, uint8 decimals) internal pure returns (uint256 wad) {
        if (decimals == 18) return raw;
        uint256 scale = 10 ** (18 - decimals);
        if (raw > type(uint256).max / scale) revert NumericOverflow();
        return raw * scale;
    }

    function fromWadCeil(uint256 wad, uint8 decimals) internal pure returns (uint256) {
        return decimals == 18 ? wad : Math.mulDiv(wad, 1, 10 ** (18 - decimals), Math.Rounding.Ceil);
    }

    function readPriceWad(IStaticsDollarCoreTypes.StableCollateralProfile storage storedProfile)
        internal
        view
        returns (uint256)
    {
        return IUsdOracle(storedProfile.oracle).priceWad();
    }
}
