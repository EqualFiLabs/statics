// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreHealthFacet} from "src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {LibCoreStorage} from "src/dollar/core/libraries/LibCoreStorage.sol";
import {LibSolvencyIndex} from "src/dollar/core/libraries/LibSolvencyIndex.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract HealthCollateral is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(uint256 decimals_) ERC20("Health Collateral", "HC") {
        require(decimals_ <= type(uint8).max);
        tokenDecimals = uint8(decimals_);
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract CoreHealthHarness is CoreHealthFacet {
    using LibSolvencyIndex for LibSolvencyIndex.Tree;

    function configureProfile(uint256 profileId, address collateral, address oracle, uint256 decimals_) external {
        require(profileId > 0 && profileId < 256);
        require(decimals_ <= 18);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        profile.collateralToken = collateral;
        profile.oracle = oracle;
        profile.decimals = uint8(decimals_);
        profile.mode = IStaticsDollarCoreTypes.ProfileMode.Active;
        if (cs.nextProfileId <= profileId) cs.nextProfileId = profileId + 1;
    }

    function setAccounting(uint256 profileId, uint256 accounted, uint256 insurance, uint256 senior) external {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        profile.accountedCollateral = accounted;
        profile.insuranceReserve = insurance;
        profile.seniorOutstanding = senior;
        cs.accountedCollateralByToken[profile.collateralToken] = accounted + insurance;
        cs.totalSeniorOutstanding = senior;
    }

    function setSeriesBook(uint256 profileId, uint256 seriesId, uint256 liabilityWad, uint256 rawCollateral) external {
        uint8 decimals_ = LibCoreStorage.s().collateralProfiles[profileId].decimals;
        uint256 collateralWad = rawCollateral * 10 ** (18 - decimals_);
        LibCoreStorage.s().solvencyIndex[profileId].update(bytes32(seriesId), liabilityWad, collateralWad);
    }
}

contract CoreHealthTest is Test {
    function test_SeriesDeficitsCannotBeMaskedByAnotherSeriesSurplus() public {
        (CoreHealthHarness health, HealthCollateral collateral,) = _profile(18, 1e18);
        collateral.mint(address(health), 200e18);
        health.setAccounting(1, 200e18, 0, 200e18);
        health.setSeriesBook(1, 1, 100e18, 50e18);
        health.setSeriesBook(1, 2, 100e18, 150e18);

        IStaticsDollarCoreTypes.ProfileSolvency memory solvency = health.profileSolvency(1);
        assertEq(solvency.collateralValueWad, 200e18);
        assertEq(solvency.seniorLiabilitiesWad, 200e18);
        assertEq(solvency.seniorDeficitWad, 50e18);
        assertFalse(solvency.healthy);
    }

    function test_InsuranceOffsetsSeriesDeficitWithoutIgnoringCustody() public {
        (CoreHealthHarness health, HealthCollateral collateral,) = _profile(18, 1e18);
        collateral.mint(address(health), 250e18);
        health.setAccounting(1, 200e18, 50e18, 200e18);
        health.setSeriesBook(1, 1, 100e18, 50e18);
        health.setSeriesBook(1, 2, 100e18, 150e18);
        assertTrue(health.profileSolvency(1).healthy);

        collateral.burn(address(health), 75e18);
        IStaticsDollarCoreTypes.ProfileSolvency memory solvency = health.profileSolvency(1);
        assertEq(solvency.collateralValueWad, 175e18);
        assertEq(solvency.seniorDeficitWad, 75e18);
        assertFalse(solvency.healthy);
    }

    function test_DecimalNormalizationMatchesAcrossSupportedPrecisions() public {
        uint256[4] memory decimalCases = [uint256(0), uint256(6), uint256(8), uint256(18)];
        for (uint256 i; i < decimalCases.length; ++i) {
            uint256 decimals_ = decimalCases[i];
            uint256 unit = 10 ** decimals_;
            (CoreHealthHarness health, HealthCollateral collateral,) = _profile(decimals_, 1e18);
            collateral.mint(address(health), 100 * unit);
            health.setAccounting(1, 100 * unit, 0, 100e18);
            health.setSeriesBook(1, 1, 100e18, 100 * unit);
            assertTrue(health.profileSolvency(1).healthy);

            collateral.burn(address(health), unit);
            IStaticsDollarCoreTypes.ProfileSolvency memory solvency = health.profileSolvency(1);
            assertEq(solvency.collateralValueWad, 99e18);
            assertEq(solvency.seniorDeficitWad, 1e18);
        }
    }

    function test_UnavailableHealthLatchesAndRequiresRecoveryDelay() public {
        (CoreHealthHarness health, HealthCollateral collateral, MockETHUSDOracle oracle) = _profile(18, 1e18);
        collateral.mint(address(health), 100e18);
        health.setAccounting(1, 100e18, 0, 100e18);
        health.setSeriesBook(1, 1, 100e18, 100e18);

        oracle.setInvalidPrice(true);
        health.syncGlobalHealth();
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase, uint256 bitmap,,) = health.globalImpairment();
        assertEq(uint256(phase), uint256(IStaticsDollarCoreTypes.GlobalHealthPhase.Unavailable));
        assertEq(bitmap, uint256(1) << 1);

        oracle.setInvalidPrice(false);
        oracle.setUpdatedAt(block.timestamp);
        health.syncGlobalHealth();
        uint256 recoveryAvailableAt;
        (phase,,, recoveryAvailableAt) = health.globalImpairment();
        assertEq(uint256(phase), uint256(IStaticsDollarCoreTypes.GlobalHealthPhase.Recovering));
        assertEq(recoveryAvailableAt, block.timestamp + 48 hours);

        vm.warp(recoveryAvailableAt);
        oracle.setUpdatedAt(block.timestamp);
        (IStaticsDollarCoreTypes.ExitStatus status,,,) = health.checkpointGlobalCollateralExit();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        (phase,,,) = health.globalImpairment();
        assertEq(uint256(phase), uint256(IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy));
    }

    function test_ExtremeOracleValueSaturatesInsteadOfBrickingHealth() public {
        (CoreHealthHarness health, HealthCollateral collateral,) = _profile(18, type(uint256).max);
        collateral.mint(address(health), 2e18);
        health.setAccounting(1, 2e18, 0, 1e18);
        health.setSeriesBook(1, 1, 1e18, 2e18);

        IStaticsDollarCoreTypes.ProfileSolvency memory solvency = health.profileSolvency(1);
        assertEq(solvency.collateralValueWad, type(uint256).max);
        assertEq(solvency.seniorDeficitWad, 0);
        assertTrue(solvency.healthy);
    }

    function _profile(uint256 decimals_, uint256 priceWad)
        private
        returns (CoreHealthHarness health, HealthCollateral collateral, MockETHUSDOracle oracle)
    {
        health = new CoreHealthHarness();
        collateral = new HealthCollateral(decimals_);
        oracle = new MockETHUSDOracle(priceWad, type(uint256).max);
        health.configureProfile(1, address(collateral), address(oracle), decimals_);
    }
}
