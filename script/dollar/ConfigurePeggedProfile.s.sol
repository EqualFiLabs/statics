// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {CoreGovernanceFacet} from "../../src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreViewFacet} from "../../src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCore} from "../../src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "../../src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskShares} from "../../src/dollar/interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "../../src/dollar/interfaces/IStaticsDollar.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";

struct PeggedProfileConfig {
    address collateralToken;
    address oracle;
    uint256 pegMinPriceWad;
    uint256 pegMaxPriceWad;
    uint256 mintFeeBps;
    uint256 redemptionFeeBps;
    uint256 debtCeiling;
}

/// @notice Schedules and executes pegged-profile creation as one timelock batch.
contract ConfigurePeggedProfile is Script {
    error InvalidCore(address core);
    error InvalidCoreBinding(address expected, address actual);
    error InvalidTimelock(address timelock);
    error InvalidProfileState(uint256 profileId);

    function runSchedule() external returns (uint256 profileId, bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address core = vm.envAddress("STATICS_DOLLAR_CORE_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_DOLLAR_USDC_TIMELOCK_SALT");
        PeggedProfileConfig memory config = _loadConfig();

        vm.startBroadcast(privateKey);
        (profileId, operationId) = schedule(core, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address core = vm.envAddress("STATICS_DOLLAR_CORE_ADDRESS");
        uint256 profileId = vm.envUint("STATICS_DOLLAR_USDC_PROFILE_ID");
        bytes32 salt = vm.envBytes32("STATICS_DOLLAR_USDC_TIMELOCK_SALT");
        PeggedProfileConfig memory config = _loadConfig();

        vm.startBroadcast(privateKey);
        execute(core, profileId, config, salt);
        vm.stopBroadcast();
    }

    function schedule(address core, PeggedProfileConfig memory config, bytes32 salt)
        public
        returns (uint256 profileId, bytes32 operationId)
    {
        TimelockController timelock = _timelock(core);
        CoreViewFacet viewFacet = CoreViewFacet(core);
        profileId = viewFacet.nextProfileId();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch(core, profileId, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (!timelock.isOperationPending(operationId)) revert InvalidProfileState(profileId);
    }

    function execute(address core, uint256 profileId, PeggedProfileConfig memory config, bytes32 salt) public {
        TimelockController timelock = _timelock(core);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch(core, profileId, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            IStaticsDollarCore(core).collateralProfile(profileId);
        if (
            profile.kind != IStaticsDollarCoreTypes.ProfileKind.Pegged
                || profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active
                || profile.collateralToken != config.collateralToken || profile.oracle != config.oracle
                || profile.activeSeriesId != 0 || profile.redemptionFeeBps != config.redemptionFeeBps
                || profile.debtCeiling != config.debtCeiling || CoreViewFacet(core).profileSeriesCount(profileId) != 0
        ) revert InvalidProfileState(profileId);
    }

    function _batch(address core, uint256 profileId, PeggedProfileConfig memory config)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        targets[0] = core;
        targets[1] = core;
        values = new uint256[](2);
        payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(
            CoreGovernanceFacet.createPeggedCollateralProfile,
            (
                config.collateralToken,
                config.oracle,
                config.pegMinPriceWad,
                config.pegMaxPriceWad,
                config.mintFeeBps,
                config.redemptionFeeBps,
                config.debtCeiling
            )
        );
        payloads[1] =
            abi.encodeCall(CoreGovernanceFacet.setProfileMode, (profileId, IStaticsDollarCoreTypes.ProfileMode.Active));
    }

    function _timelock(address core) private view returns (TimelockController timelock) {
        _validateCore(core);
        address owner = IERC173(core).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));
    }

    function _validateCore(address core) private view {
        if (core.code.length == 0) revert InvalidCore(core);
        IStaticsDollarCore target = IStaticsDollarCore(core);
        if (!target.bootstrapFinalized()) revert InvalidCore(core);

        address staticsDollar = target.staticsDollar();
        address staticsDollarRisk = target.staticsDollarRisk();
        address periphery = target.periphery();
        address positionNFT = target.positionNFT();
        if (
            staticsDollar.code.length == 0 || staticsDollarRisk.code.length == 0 || periphery.code.length == 0
                || positionNFT.code.length == 0
        ) revert InvalidCore(core);
        if (IStaticsDollar(staticsDollar).pool() != core) {
            revert InvalidCoreBinding(core, IStaticsDollar(staticsDollar).pool());
        }
        if (IStaticsDollarRiskShares(staticsDollarRisk).pool() != core) {
            revert InvalidCoreBinding(core, IStaticsDollarRiskShares(staticsDollarRisk).pool());
        }
    }

    function _loadConfig() private view returns (PeggedProfileConfig memory config) {
        config = PeggedProfileConfig({
            collateralToken: vm.envAddress("STATICS_DOLLAR_USDC_TOKEN"),
            oracle: vm.envAddress("STATICS_DOLLAR_USDC_ORACLE"),
            pegMinPriceWad: vm.envUint("STATICS_DOLLAR_USDC_PEG_MIN_PRICE_WAD"),
            pegMaxPriceWad: vm.envUint("STATICS_DOLLAR_USDC_PEG_MAX_PRICE_WAD"),
            mintFeeBps: vm.envUint("STATICS_DOLLAR_USDC_MINT_FEE_BPS"),
            redemptionFeeBps: vm.envUint("STATICS_DOLLAR_USDC_REDEMPTION_FEE_BPS"),
            debtCeiling: vm.envUint("STATICS_DOLLAR_USDC_DEBT_CEILING")
        });
    }
}
