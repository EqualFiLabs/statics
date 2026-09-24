// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {CoreGovernanceFacet} from "../src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "../src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreInsuranceFacet} from "../src/dollar/core/facets/CoreInsuranceFacet.sol";
import {CoreMintFacet} from "../src/dollar/core/facets/CoreMintFacet.sol";
import {CoreReceiverFacet} from "../src/dollar/core/facets/CoreReceiverFacet.sol";
import {CoreRecoveryFacet} from "../src/dollar/core/facets/CoreRecoveryFacet.sol";
import {CoreTransitionFacet} from "../src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreViewFacet} from "../src/dollar/core/facets/CoreViewFacet.sol";
import {StaticsDollarCoreDiamond} from "../src/dollar/core/StaticsDollarCoreDiamond.sol";
import {IStaticsDollar} from "../src/dollar/interfaces/IStaticsDollar.sol";
import {IStaticsDollarGateway} from "../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {IStaticsDollarRiskShares} from "../src/dollar/interfaces/IStaticsDollarRiskShares.sol";
import {ChainlinkUsdOracle} from "../src/dollar/ChainlinkUsdOracle.sol";
import {FeeRouterFacet} from "../src/dollar/periphery/facets/FeeRouterFacet.sol";
import {PairingVaultFacet} from "../src/dollar/periphery/facets/PairingVaultFacet.sol";
import {SeriesMigrationFacet} from "../src/dollar/periphery/facets/SeriesMigrationFacet.sol";
import {StakingFacet} from "../src/dollar/periphery/facets/StakingFacet.sol";
import {StaticsDollarGatewayFacet} from "../src/dollar/periphery/facets/StaticsDollarGatewayFacet.sol";
import {LibPeriphery} from "../src/dollar/periphery/libraries/LibPeriphery.sol";
import {StaticsGenesisIntegrationInit} from "../src/diamond/StaticsGenesisIntegrationInit.sol";
import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {StaticsPhaseFourInit} from "../src/diamond/StaticsPhaseFourInit.sol";
import {StaticsPhaseThreeInit} from "../src/diamond/StaticsPhaseThreeInit.sol";
import {StaticsPhaseTwoInit} from "../src/diamond/StaticsPhaseTwoInit.sol";
import {BasketAdminFacet} from "../src/facets/BasketAdminFacet.sol";
import {BasketCollateralFacet} from "../src/facets/BasketCollateralFacet.sol";
import {BasketCreationFacet} from "../src/facets/BasketCreationFacet.sol";
import {BasketLiquidityFacet} from "../src/facets/BasketLiquidityFacet.sol";
import {BasketLiquidityLifecycleFacet} from "../src/facets/BasketLiquidityLifecycleFacet.sol";
import {BasketMintFacet} from "../src/facets/BasketMintFacet.sol";
import {BasketRedemptionFacet} from "../src/facets/BasketRedemptionFacet.sol";
import {BasketRewardsFacet} from "../src/facets/BasketRewardsFacet.sol";
import {BasketViewFacet} from "../src/facets/BasketViewFacet.sol";
import {BorrowLiquidityFacet} from "../src/facets/BorrowLiquidityFacet.sol";
import {CustodyFacet} from "../src/facets/CustodyFacet.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {FlashLoanFacet} from "../src/facets/FlashLoanFacet.sol";
import {GenesisNFTFacet} from "../src/facets/GenesisNFTFacet.sol";
import {GlobalRewardsFacet} from "../src/facets/GlobalRewardsFacet.sol";
import {GovernanceFacet} from "../src/facets/GovernanceFacet.sol";
import {LendingFacet} from "../src/facets/LendingFacet.sol";
import {MorphoAdminFacet} from "../src/facets/MorphoAdminFacet.sol";
import {MorphoFacet} from "../src/facets/MorphoFacet.sol";
import {MorphoRecoveryFacet} from "../src/facets/MorphoRecoveryFacet.sol";
import {MorphoSettlementFacet} from "../src/facets/MorphoSettlementFacet.sol";
import {MorphoViewFacet} from "../src/facets/MorphoViewFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {PositionPortfolioFacet} from "../src/facets/PositionPortfolioFacet.sol";
import {ProtocolPoolAdminFacet} from "../src/facets/ProtocolPoolAdminFacet.sol";
import {ProtocolPoolCreationFacet} from "../src/facets/ProtocolPoolCreationFacet.sol";
import {ProtocolPoolViewFacet} from "../src/facets/ProtocolPoolViewFacet.sol";
import {ProtocolRevenueFacet} from "../src/facets/ProtocolRevenueFacet.sol";
import {RewardPolicyFacet} from "../src/facets/RewardPolicyFacet.sol";
import {RangeGaugeFacet} from "../src/facets/RangeGaugeFacet.sol";
import {RangeGaugePositionFacet} from "../src/facets/RangeGaugePositionFacet.sol";
import {RangeGaugeLivenessFacet} from "../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugeViewFacet} from "../src/facets/RangeGaugeViewFacet.sol";
import {RangeGaugeCallbackFacet} from "../src/facets/RangeGaugeCallbackFacet.sol";
import {PermissionedPoolCreationFacet} from "../src/facets/PermissionedPoolCreationFacet.sol";
import {PermissionedPoolAdminFacet} from "../src/facets/PermissionedPoolAdminFacet.sol";
import {PermissionedPoolViewFacet} from "../src/facets/PermissionedPoolViewFacet.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGovernance} from "../src/interfaces/IStaticsGovernance.sol";
import {IStaticsPositionPortfolio} from "../src/interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsPermissionedPools} from "../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../src/interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IStaticsRewardPolicy} from "../src/interfaces/IStaticsRewardPolicy.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsPermanentLiquidityMath} from "../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsPermissionedSwapFeeHook} from "../src/liquidity/StaticsPermissionedSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";
import {PositionNFTFacet} from "../src/position/PositionNFTFacet.sol";
import {CoreBootstrapConfig, DeployCoreBootstrap} from "./dollar/DeployCoreBootstrap.s.sol";
import {StaticsProtocolParts, StaticsProtocolPlan} from "./libraries/StaticsProtocolPlan.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

interface IPhasePositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

interface IPhasePermissionedBindings is IPhasePositionManagerBindings {
    function permissionedHook() external view returns (address);
}

interface IPhasePermissionedPositionManagerBindings is IPhasePermissionedBindings {
    function positionClaims() external view returns (address);
}

interface IPhasePermissionedPositionClaimsBindings {
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function permissionedHook() external view returns (address);
}

interface IPhasePoolManagerBinding {
    function poolManager() external view returns (address);
}

struct PhaseTwoDeployment {
    StaticsProtocolParts parts;
    address initializer;
    address genesisInitializer;
}

struct PhaseThreeDeployment {
    StaticsProtocolParts parts;
    address initializer;
    address core;
    address staticsDollar;
    address staticsDollarRisk;
    address oracle;
    LibPeriphery.InitArgs dollarInit;
}

struct PhaseFourDeployment {
    StaticsProtocolParts parts;
    address initializer;
}

/// @notice Deploys every later-phase implementation and produces the exact timelock batches that
/// advance one Phase 1 Diamond through the complete current protocol surface.
contract DeployStaticsPhases is DeployCoreBootstrap, RobinhoodDeploymentConfig {
    bytes32 private constant PHASE_STORAGE_POSITION = keccak256("statics.storage.deployment.phases.v1");

    struct PhaseTwoConfig {
        address diamond;
        address poolManager;
        address positionManager;
        address permit2;
        address liquidityManager;
        address swapFeeHook;
        address permissionedSwapFeeHook;
        address permissionedRouter;
        address permissionedPositionManager;
        address permissionedQuoter;
        bytes32 poolManagerCodeHash;
        bytes32 positionManagerCodeHash;
        bytes32 permit2CodeHash;
        bytes32 liquidityManagerCodeHash;
        bytes32 swapFeeHookCodeHash;
        bytes32 permissionedSwapFeeHookCodeHash;
        bytes32 permissionedRouterCodeHash;
        bytes32 permissionedPositionManagerCodeHash;
        bytes32 permissionedPositionClaimsCodeHash;
        bytes32 permissionedQuoterCodeHash;
        uint256 creationFeeAmount;
        uint256 singleAssetFlashFeeBps;
    }

    struct PhaseThreeConfig {
        address diamond;
        CoreBootstrapConfig core;
        uint16 baseBps;
        uint16 insuranceBps;
        uint16 redemptionFeeBps;
        uint16 redemptionSupplierShareBps;
    }

    error InvalidDiamond(address diamond);
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidTimelock(address timelock);
    error InvalidContract(address target);
    error InvalidFacet(address facet, bytes32 expected, bytes32 actual);
    error InvalidFacetRoute(bytes4 selector, address expected, address actual);
    error InvalidSelectorManifest(uint256 phase, uint256 expectedCount, uint256 actualCount);
    error InvalidCoreSelectorManifest(uint256 expectedCount, uint256 actualCount);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidCoreBootstrap(address core);
    error InvalidDeploymentPhase(uint256 expected, uint256 actual);
    error InvalidLiquidityIntegration(address expected, address actual);
    error InvalidConfiguration();
    error ConfigurationValueOutOfRange(string field, uint256 value, uint256 maximum);

    function runPhaseTwo() external returns (PhaseTwoDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        _validateManifestChain(manifest);
        PhaseTwoConfig memory config = PhaseTwoConfig({
            diamond: vm.envAddress("STATICS_DIAMOND_ADDRESS"),
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            positionManager: vm.parseJsonAddress(manifest, ".contracts.positionManager.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            liquidityManager: vm.envAddress("STATICS_LIQUIDITY_MANAGER_ADDRESS"),
            swapFeeHook: vm.envAddress("STATICS_SWAP_FEE_HOOK_ADDRESS"),
            permissionedSwapFeeHook: vm.envAddress("STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS"),
            permissionedRouter: vm.envAddress("STATICS_PERMISSIONED_ROUTER_ADDRESS"),
            permissionedPositionManager: vm.envAddress("STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS"),
            permissionedQuoter: vm.parseJsonAddress(manifest, ".contracts.quoter.address"),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"),
            liquidityManagerCodeHash: vm.envBytes32("STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH"),
            swapFeeHookCodeHash: vm.envBytes32("STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH"),
            permissionedSwapFeeHookCodeHash: vm.envBytes32("STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH"),
            permissionedRouterCodeHash: vm.envBytes32("STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH"),
            permissionedPositionManagerCodeHash: vm.envBytes32(
                "STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH"
            ),
            permissionedPositionClaimsCodeHash: vm.envBytes32("STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH"),
            permissionedQuoterCodeHash: vm.parseJsonBytes32(manifest, ".contracts.quoter.runtimeCodeHash"),
            creationFeeAmount: vm.envUint("BASKET_CREATION_FEE_AMOUNT"),
            singleAssetFlashFeeBps: vm.envUint("STATICS_SINGLE_ASSET_FLASH_FEE_BPS")
        });
        vm.startBroadcast(privateKey);
        deployment = deployPhaseTwo(config);
        vm.stopBroadcast();
        _logPhaseTwo(config.diamond, deployment, config, vm.envBytes32("STATICS_PHASE_TWO_TIMELOCK_SALT"));
    }

    function runPhaseThree() external returns (PhaseThreeDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        _validateManifestChain(manifest);
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address sequencerUptimeFeed = vm.envAddress("SEQUENCER_UPTIME_FEED");
        address weth = vm.envAddress("WETH_ADDRESS");
        if (block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) {
            address expectedWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
            if (weth != expectedWeth) revert InvalidBinding(diamond, expectedWeth, weth);
            _validateContract(weth, vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash"));
        }
        PhaseThreeConfig memory config = PhaseThreeConfig({
            diamond: diamond,
            core: CoreBootstrapConfig({
                owner: IERC173(diamond).owner(),
                profileGuardian: vm.envAddress("GUARDIAN"),
                treasury: vm.envAddress("TREASURY"),
                stakingToken: vm.envAddress("STAKING_TOKEN"),
                creationFeeAmount: 0,
                positionCreationFeeAmount: 0,
                poolCreationFeeAmount: 0,
                singleAssetFlashFeeBps: 0,
                initialOracle: address(0),
                requiredSequencerUptimeFeed: sequencerUptimeFeed,
                minimumSequencerGracePeriod: vm.envUint("SEQUENCER_GRACE_PERIOD"),
                weth: weth,
                collateralRatioBps: vm.envUint("STATICS_DOLLAR_COLLATERAL_RATIO_BPS"),
                priceBandBps: vm.envUint("STATICS_DOLLAR_PRICE_BAND_BPS"),
                debtCeiling: vm.envUint("STATICS_DOLLAR_DEBT_CEILING"),
                riskUri: vm.envString("STATICS_DOLLAR_RISK_URI")
            }),
            baseBps: _envUint16("STATICS_DOLLAR_BASE_BPS"),
            insuranceBps: _envUint16("STATICS_DOLLAR_INSURANCE_BPS"),
            redemptionFeeBps: _envUint16("STATICS_DOLLAR_REDEMPTION_FEE_BPS"),
            redemptionSupplierShareBps: _envUint16("STATICS_DOLLAR_REDEMPTION_SUPPLIER_SHARE_BPS")
        });
        vm.startBroadcast(privateKey);
        address oracle = address(
            new ChainlinkUsdOracle(
                vm.envAddress("ETH_USD_FEED"),
                vm.envUint("STATICS_DOLLAR_ORACLE_MAX_STALENESS"),
                vm.envUint("STATICS_DOLLAR_ORACLE_MIN_PRICE_WAD"),
                vm.envUint("STATICS_DOLLAR_ORACLE_MAX_PRICE_WAD"),
                sequencerUptimeFeed,
                config.core.minimumSequencerGracePeriod
            )
        );
        config.core.initialOracle = oracle;
        deployment = deployPhaseThree(config, vm.addr(privateKey));
        vm.stopBroadcast();
        _logPhaseThree(diamond, deployment, vm.envBytes32("STATICS_PHASE_THREE_TIMELOCK_SALT"));
    }

    function runPhaseFour() external returns (PhaseFourDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        _validateManifestChain(vm.readFile(_robinhoodManifestPath(block.chainid)));
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        vm.startBroadcast(privateKey);
        deployment = deployPhaseFour(diamond);
        vm.stopBroadcast();
        _logPhaseFour(diamond, deployment, vm.envBytes32("STATICS_PHASE_FOUR_TIMELOCK_SALT"));
    }

    function deployPhaseTwo(PhaseTwoConfig memory config) public returns (PhaseTwoDeployment memory deployment) {
        _validatePhaseDiamond(config.diamond, 1);
        _validatePhaseTwoConfig(config);

        deployment.parts = _phaseTwoBaseParts(config.diamond);
        deployment.parts = _deployPhaseTwoProtocolParts(deployment.parts);
        deployment.initializer = address(new StaticsPhaseTwoInit());
        deployment.genesisInitializer = address(new StaticsGenesisIntegrationInit());
    }

    function _validatePhaseTwoConfig(PhaseTwoConfig memory config) private view {
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        _validateContract(config.liquidityManager, config.liquidityManagerCodeHash);
        _validateContract(config.swapFeeHook, config.swapFeeHookCodeHash);
        _validateContract(config.permissionedSwapFeeHook, config.permissionedSwapFeeHookCodeHash);
        _validateContract(config.permissionedRouter, config.permissionedRouterCodeHash);
        _validateContract(config.permissionedPositionManager, config.permissionedPositionManagerCodeHash);
        _validateContract(config.permissionedQuoter, config.permissionedQuoterCodeHash);
        if (config.singleAssetFlashFeeBps > 10_000) revert InvalidConfiguration();
        _validateInstalledPublicLiquidity(config);
        _validateInstalledPermissionedLiquidity(config);
        _validateHookBindings(config);
        _validateManagerAndCanonicalBindings(config);
        _validatePermissionedPeriphery(config);
    }

    function _validateInstalledPublicLiquidity(PhaseTwoConfig memory config) private view {
        (address installedPoolManager, address installedHook, bool installed) =
            IStaticsBasketLiquidity(config.diamond).liquidityIntegration();
        if (!installed || installedPoolManager != config.poolManager) {
            revert InvalidLiquidityIntegration(config.poolManager, installedPoolManager);
        }
        if (installedHook != config.swapFeeHook) {
            revert InvalidBinding(config.diamond, config.swapFeeHook, installedHook);
        }
        (address installedLiquidityManager, bool liquidityManagerInstalled) =
            IStaticsBasketLiquidity(config.diamond).liquidityManager();
        if (!liquidityManagerInstalled || installedLiquidityManager != config.liquidityManager) {
            revert InvalidLiquidityIntegration(config.liquidityManager, installedLiquidityManager);
        }
    }

    function _validateInstalledPermissionedLiquidity(PhaseTwoConfig memory config) private view {
        (
            address installedPermissionedHook,
            address installedPermissionedRouter,
            address installedPermissionedPositionManager,
            address installedPermissionedQuoter,
            bool permissionedInstalled
        ) = IStaticsBasketLiquidity(config.diamond).permissionedLiquidityIntegration();
        if (
            !permissionedInstalled || installedPermissionedHook != config.permissionedSwapFeeHook
                || installedPermissionedRouter != config.permissionedRouter
                || installedPermissionedPositionManager != config.permissionedPositionManager
                || installedPermissionedQuoter != config.permissionedQuoter
        ) revert InvalidLiquidityIntegration(config.permissionedSwapFeeHook, installedPermissionedHook);
    }

    function _validateHookBindings(PhaseTwoConfig memory config) private view {
        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(config.swapFeeHook));
        if (hook.staticsDiamond() != config.diamond) {
            revert InvalidBinding(config.swapFeeHook, config.diamond, hook.staticsDiamond());
        }
        if (address(hook.poolManager()) != config.poolManager) {
            revert InvalidBinding(config.swapFeeHook, config.poolManager, address(hook.poolManager()));
        }
        StaticsPermissionedSwapFeeHook permissionedHook = StaticsPermissionedSwapFeeHook(config.permissionedSwapFeeHook);
        if (permissionedHook.staticsDiamond() != config.diamond) {
            revert InvalidBinding(config.permissionedSwapFeeHook, config.diamond, permissionedHook.staticsDiamond());
        }
        if (address(permissionedHook.poolManager()) != config.poolManager) {
            revert InvalidBinding(
                config.permissionedSwapFeeHook, config.poolManager, address(permissionedHook.poolManager())
            );
        }
        if (
            !permissionedHook.trustedPeriphery(config.permissionedRouter)
                || !permissionedHook.trustedPeriphery(config.permissionedPositionManager)
                || !permissionedHook.trustedPeriphery(config.permissionedQuoter)
        ) revert InvalidConfiguration();
        _validateContract(
            address(hook.permanentLiquidityMath()), keccak256(type(StaticsPermanentLiquidityMath).runtimeCode)
        );
    }

    function _validateManagerAndCanonicalBindings(PhaseTwoConfig memory config) private view {
        StaticsLiquidityManager liquidityManager = StaticsLiquidityManager(config.liquidityManager);
        if (liquidityManager.staticsDiamond() != config.diamond) {
            revert InvalidBinding(config.liquidityManager, config.diamond, liquidityManager.staticsDiamond());
        }
        if (liquidityManager.poolManager() != config.poolManager) {
            revert InvalidBinding(config.liquidityManager, config.poolManager, liquidityManager.poolManager());
        }
        if (liquidityManager.positionManager() != config.positionManager) {
            revert InvalidBinding(config.liquidityManager, config.positionManager, liquidityManager.positionManager());
        }
        if (liquidityManager.permit2() != config.permit2) {
            revert InvalidBinding(config.liquidityManager, config.permit2, liquidityManager.permit2());
        }
        IPhasePositionManagerBindings positionManager = IPhasePositionManagerBindings(config.positionManager);
        if (positionManager.poolManager() != config.poolManager) {
            revert InvalidBinding(config.positionManager, config.poolManager, positionManager.poolManager());
        }
        if (positionManager.permit2() != config.permit2) {
            revert InvalidBinding(config.positionManager, config.permit2, positionManager.permit2());
        }
    }

    function deployPhaseThree(PhaseThreeConfig memory config) public returns (PhaseThreeDeployment memory deployment) {
        return deployPhaseThree(config, address(this));
    }

    function deployPhaseThree(PhaseThreeConfig memory config, address deploymentCreator)
        public
        returns (PhaseThreeDeployment memory deployment)
    {
        _validatePhaseDiamond(config.diamond, 2);
        address owner = IERC173(config.diamond).owner();
        if (
            config.core.owner != owner || config.core.treasury != IStaticsBasketAdmin(config.diamond).treasury()
                || config.core.stakingToken != IStaticsGlobalRewards(config.diamond).stakingToken()
                || uint256(config.baseBps) + uint256(config.insuranceBps) != 10_000 || config.redemptionFeeBps > 1_000
                || config.redemptionSupplierShareBps < 5_000 || config.redemptionSupplierShareBps > 10_000
                || config.core.weth == address(0)
        ) revert InvalidConfiguration();

        deployment.parts = _phaseThreeBaseParts(config.diamond);
        deployment.parts = _deployPhaseThreeProtocolParts(deployment.parts);
        deployment.initializer = address(new StaticsPhaseThreeInit());
        CoreBootstrapConfig memory coreConfig = _validatedConfig(config.core, deploymentCreator);
        (deployment.core, deployment.staticsDollar, deployment.staticsDollarRisk) =
            _deployCoreWithBootstrapAuthority(coreConfig, deploymentCreator, owner);
        deployment.oracle = coreConfig.initialOracle;
        deployment.dollarInit = LibPeriphery.InitArgs({
            pool: deployment.core,
            weth: coreConfig.weth,
            baseBps: config.baseBps,
            insuranceBps: config.insuranceBps,
            redemptionFeeBps: config.redemptionFeeBps,
            redemptionSupplierShareBps: config.redemptionSupplierShareBps
        });
    }

    function deployPhaseFour(address diamond) public returns (PhaseFourDeployment memory deployment) {
        _validatePhaseDiamond(diamond, 3);
        _validateDollarCore(diamond);
        deployment.parts = _phaseFourBaseParts(diamond);
        deployment.parts = _deployPhaseFourProtocolParts(deployment.parts);
        deployment.initializer = address(new StaticsPhaseFourInit());
    }

    function buildPhaseTwoBatch(address diamond, PhaseTwoDeployment memory deployment, PhaseTwoConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (
                StaticsProtocolPlan.phaseTwo(deployment.parts),
                deployment.initializer,
                abi.encodeCall(
                    StaticsPhaseTwoInit.initialize,
                    (StaticsPhaseTwoInit.InitArgs({
                            creationFeeAmount: config.creationFeeAmount,
                            singleAssetFlashFeeBps: config.singleAssetFlashFeeBps
                        }))
                )
            )
        );
    }

    function buildPhaseThreeBatch(address diamond, PhaseThreeDeployment memory deployment)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (
                StaticsProtocolPlan.phaseThree(deployment.parts),
                deployment.initializer,
                abi.encodeCall(StaticsPhaseThreeInit.initialize, (deployment.dollarInit))
            )
        );
        targets[1] = deployment.core;
        payloads[1] = abi.encodeCall(CoreGovernanceFacet.finalizeBootstrap, (diamond));
    }

    function buildPhaseFourBatch(address diamond, PhaseFourDeployment memory deployment)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (
                StaticsProtocolPlan.phaseFour(deployment.parts),
                deployment.initializer,
                abi.encodeCall(StaticsPhaseFourInit.initialize, ())
            )
        );
    }

    function buildTimelockCalldata(
        address diamond,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    ) public view returns (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall) {
        timelock = IERC173(diamond).owner();
        if (timelock.codehash != keccak256(type(StaticsTimelock).runtimeCode)) revert InvalidTimelock(timelock);
        TimelockController controller = TimelockController(payable(timelock));
        uint256 delay = controller.getMinDelay();
        operationId = controller.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        scheduleCall =
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, delay));
        executeCall = abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt));
    }

    function _phaseTwoBaseParts(address diamond) private view returns (StaticsProtocolParts memory parts) {
        parts.governance =
            _checkedFacet(diamond, IStaticsGovernance.guardian.selector, keccak256(type(GovernanceFacet).runtimeCode));
        parts.custody = _checkedFacet(
            diamond, IStaticsCustody.globalReservedByToken.selector, keccak256(type(CustodyFacet).runtimeCode)
        );
        parts.basketAdmin = _checkedFacet(
            diamond, IStaticsBasketAdmin.treasury.selector, keccak256(type(BasketAdminFacet).runtimeCode)
        );
        parts.basketLiquidity = _checkedFacet(
            diamond,
            IStaticsBasketLiquidity.liquidityIntegration.selector,
            keccak256(type(BasketLiquidityFacet).runtimeCode)
        );
        parts.protocolPoolAdmin = _checkedFacet(
            diamond,
            IStaticsProtocolPools.setGeneralFeeAllocation.selector,
            keccak256(type(ProtocolPoolAdminFacet).runtimeCode)
        );
        parts.protocolPoolView = _checkedFacet(
            diamond, IStaticsProtocolPools.protocolPool.selector, keccak256(type(ProtocolPoolViewFacet).runtimeCode)
        );
        parts.protocolRevenue = _checkedFacet(
            diamond,
            IStaticsProtocolRevenue.routeProtocolSwapFees.selector,
            keccak256(type(ProtocolRevenueFacet).runtimeCode)
        );
    }

    function _validatePermissionedPeriphery(PhaseTwoConfig memory config) private view {
        IPhasePermissionedBindings router = IPhasePermissionedBindings(config.permissionedRouter);
        if (router.poolManager() != config.poolManager) {
            revert InvalidBinding(config.permissionedRouter, config.poolManager, router.poolManager());
        }
        if (router.permit2() != config.permit2) {
            revert InvalidBinding(config.permissionedRouter, config.permit2, router.permit2());
        }
        if (router.permissionedHook() != config.permissionedSwapFeeHook) {
            revert InvalidBinding(config.permissionedRouter, config.permissionedSwapFeeHook, router.permissionedHook());
        }
        IPhasePermissionedPositionManagerBindings positionManager =
            IPhasePermissionedPositionManagerBindings(config.permissionedPositionManager);
        if (positionManager.poolManager() != config.poolManager) {
            revert InvalidBinding(config.permissionedPositionManager, config.poolManager, positionManager.poolManager());
        }
        if (positionManager.permit2() != config.permit2) {
            revert InvalidBinding(config.permissionedPositionManager, config.permit2, positionManager.permit2());
        }
        if (positionManager.permissionedHook() != config.permissionedSwapFeeHook) {
            revert InvalidBinding(
                config.permissionedPositionManager, config.permissionedSwapFeeHook, positionManager.permissionedHook()
            );
        }
        address claimsAddress = positionManager.positionClaims();
        _validateContract(claimsAddress, config.permissionedPositionClaimsCodeHash);
        IPhasePermissionedPositionClaimsBindings claims = IPhasePermissionedPositionClaimsBindings(claimsAddress);
        if (claims.poolManager() != config.poolManager) {
            revert InvalidBinding(claimsAddress, config.poolManager, claims.poolManager());
        }
        if (claims.positionManager() != config.permissionedPositionManager) {
            revert InvalidBinding(claimsAddress, config.permissionedPositionManager, claims.positionManager());
        }
        if (claims.permissionedHook() != config.permissionedSwapFeeHook) {
            revert InvalidBinding(claimsAddress, config.permissionedSwapFeeHook, claims.permissionedHook());
        }
        if (IPhasePoolManagerBinding(config.permissionedQuoter).poolManager() != config.poolManager) {
            revert InvalidBinding(
                config.permissionedQuoter,
                config.poolManager,
                IPhasePoolManagerBinding(config.permissionedQuoter).poolManager()
            );
        }
    }

    function _phaseThreeBaseParts(address diamond) private view returns (StaticsProtocolParts memory parts) {
        parts.custody = _checkedFacet(
            diamond, IStaticsCustody.globalReservedByToken.selector, keccak256(type(CustodyFacet).runtimeCode)
        );
        parts.positionPortfolio = _checkedFacet(
            diamond,
            IStaticsPositionPortfolio.positionPortfolioCounts.selector,
            keccak256(type(PositionPortfolioFacet).runtimeCode)
        );
    }

    function _phaseFourBaseParts(address diamond) private view returns (StaticsProtocolParts memory parts) {
        parts.positionPortfolio = _checkedFacet(
            diamond,
            IStaticsPositionPortfolio.positionPortfolioCounts.selector,
            keccak256(type(PositionPortfolioFacet).runtimeCode)
        );
    }

    function _validatePhaseDiamond(address diamond, uint8 expectedPhase) private view {
        if (diamond == address(0) || diamond.code.length == 0) revert InvalidDiamond(diamond);
        address timelock = IERC173(diamond).owner();
        bytes32 expectedTimelockHash = keccak256(type(StaticsTimelock).runtimeCode);
        if (timelock.codehash != expectedTimelockHash) revert InvalidTimelock(timelock);

        bytes4[] memory actual = _diamondSelectors(diamond);
        StaticsProtocolParts memory empty;
        bytes4[] memory expected = _cutSelectors(StaticsProtocolPlan.cumulative(empty, expectedPhase));
        _sort(actual);
        _sort(expected);
        if (actual.length != expected.length || keccak256(abi.encode(actual)) != keccak256(abi.encode(expected))) {
            revert InvalidSelectorManifest(expectedPhase, expected.length, actual.length);
        }
        _validatePhaseRuntimes(diamond, expectedPhase);
        uint256 actualPhase = uint256(vm.load(diamond, PHASE_STORAGE_POSITION)) & type(uint8).max;
        if (actualPhase != expectedPhase) revert InvalidDeploymentPhase(expectedPhase, actualPhase);
    }

    function _validatePhaseRuntimes(address diamond, uint8 phase) private view {
        _validatePhaseOneRuntimes(diamond);
        if (phase >= 2) _validatePhaseTwoRuntimes(diamond);
        if (phase >= 3) _validatePhaseThreeRuntimes(diamond);
    }

    function _validatePhaseOneRuntimes(address diamond) private view {
        _validateFacetSet(diamond, StaticsSelectors.diamondCut(), keccak256(type(DiamondCutFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.diamondLoupe(), keccak256(type(DiamondLoupeFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.ownership(), keccak256(type(OwnershipFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.phaseOneGovernance(), keccak256(type(GovernanceFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.position(), keccak256(type(PositionNFTFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.phaseOneCustody(), keccak256(type(CustodyFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneTreasuryAdmin(), keccak256(type(BasketAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneLiquidityIntegration(), keccak256(type(BasketLiquidityFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.globalRewards(), keccak256(type(GlobalRewardsFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.interfaceInit(), keccak256(type(StaticsInterfaceInit).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.protocolPoolCreation(), keccak256(type(ProtocolPoolCreationFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolPoolAdmin(), keccak256(type(ProtocolPoolAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolPoolView(), keccak256(type(ProtocolPoolViewFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseOneProtocolRevenue(), keccak256(type(ProtocolRevenueFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rewardPolicy(), keccak256(type(RewardPolicyFacet).runtimeCode));
        _validateFacetSet(
            diamond,
            StaticsSelectors.permissionedPoolCreation(),
            keccak256(type(PermissionedPoolCreationFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.permissionedPoolAdmin(), keccak256(type(PermissionedPoolAdminFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.permissionedPoolView(), keccak256(type(PermissionedPoolViewFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rangeGaugeActions(), keccak256(type(RangeGaugeFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugePositions(), keccak256(type(RangeGaugePositionFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugeLiveness(), keccak256(type(RangeGaugeLivenessFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.rangeGaugeViews(), keccak256(type(RangeGaugeViewFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.rangeGaugeCallback(), keccak256(type(RangeGaugeCallbackFacet).runtimeCode)
        );
    }

    function _validatePhaseTwoRuntimes(address diamond) private view {
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneGovernance(),
            StaticsSelectors.phaseTwoGovernance(),
            keccak256(type(GovernanceFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneCustody(),
            StaticsSelectors.phaseTwoCustody(),
            keccak256(type(CustodyFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneTreasuryAdmin(),
            StaticsSelectors.phaseTwoBasketAdmin(),
            keccak256(type(BasketAdminFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneLiquidityIntegration(),
            StaticsSelectors.phaseTwoBasketLiquidity(),
            keccak256(type(BasketLiquidityFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneProtocolPoolAdmin(),
            StaticsSelectors.phaseTwoProtocolPoolAdmin(),
            keccak256(type(ProtocolPoolAdminFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneProtocolPoolView(),
            StaticsSelectors.phaseTwoProtocolPoolView(),
            keccak256(type(ProtocolPoolViewFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseOneProtocolRevenue(),
            StaticsSelectors.phaseTwoProtocolRevenue(),
            keccak256(type(ProtocolRevenueFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.phaseTwoPositionPortfolio(), keccak256(type(PositionPortfolioFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.basketCreation(), keccak256(type(BasketCreationFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.basketMint(), keccak256(type(BasketMintFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.basketRedemption(), keccak256(type(BasketRedemptionFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.basketView(), keccak256(type(BasketViewFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.basketCollateral(), keccak256(type(BasketCollateralFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.basketRewards(), keccak256(type(BasketRewardsFacet).runtimeCode));
        _validateFacetSet(
            diamond,
            StaticsSelectors.basketLiquidityLifecycle(),
            keccak256(type(BasketLiquidityLifecycleFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.lending(), keccak256(type(LendingFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.flashLoan(), keccak256(type(FlashLoanFacet).runtimeCode));
        _validateFacetSet(diamond, StaticsSelectors.genesisNFT(), keccak256(type(GenesisNFTFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.borrowLiquidity(), keccak256(type(BorrowLiquidityFacet).runtimeCode)
        );
    }

    function _validatePhaseThreeRuntimes(address diamond) private view {
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseTwoCustody(),
            StaticsSelectors.phaseThreeCustody(),
            keccak256(type(CustodyFacet).runtimeCode)
        );
        _validateSharedFacetSet(
            diamond,
            StaticsSelectors.phaseTwoPositionPortfolio(),
            StaticsSelectors.phaseThreePositionPortfolio(),
            keccak256(type(PositionPortfolioFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.dollarStaking(), keccak256(type(StakingFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.dollarSeriesMigration(), keccak256(type(SeriesMigrationFacet).runtimeCode)
        );
        _validateFacetSet(diamond, StaticsSelectors.dollarFeeRouter(), keccak256(type(FeeRouterFacet).runtimeCode));
        _validateFacetSet(
            diamond, StaticsSelectors.dollarPairingVault(), keccak256(type(PairingVaultFacet).runtimeCode)
        );
        _validateFacetSet(
            diamond, StaticsSelectors.dollarGateway(), keccak256(type(StaticsDollarGatewayFacet).runtimeCode)
        );
    }

    function _validateDollarCore(address diamond) private view {
        address core = IStaticsDollarGateway(diamond).pool();
        if (core.codehash != keccak256(type(StaticsDollarCoreDiamond).runtimeCode)) revert InvalidContract(core);
        address timelock = IERC173(diamond).owner();
        address coreOwner = IERC173(core).owner();
        if (coreOwner != timelock) revert InvalidBinding(core, timelock, coreOwner);

        CoreParts memory empty;
        bytes4[] memory expected = _cutSelectors(_coreGenesis(empty));
        bytes4[] memory actual = _diamondSelectors(core);
        _sort(expected);
        _sort(actual);
        if (actual.length != expected.length || keccak256(abi.encode(actual)) != keccak256(abi.encode(expected))) {
            revert InvalidCoreSelectorManifest(expected.length, actual.length);
        }

        _validateFacetSet(core, _coreCutSelectors(), keccak256(type(DiamondCutFacet).runtimeCode));
        _validateFacetSet(core, _coreLoupeSelectors(), keccak256(type(DiamondLoupeFacet).runtimeCode));
        _validateFacetSet(core, _coreOwnershipSelectors(), keccak256(type(OwnershipFacet).runtimeCode));
        _validateFacetSet(core, _coreGovernanceSelectors(), keccak256(type(CoreGovernanceFacet).runtimeCode));
        _validateFacetSet(core, _coreHealthSelectors(), keccak256(type(CoreHealthFacet).runtimeCode));
        _validateFacetSet(core, _coreInsuranceSelectors(), keccak256(type(CoreInsuranceFacet).runtimeCode));
        _validateFacetSet(core, _coreMintSelectors(), keccak256(type(CoreMintFacet).runtimeCode));
        _validateFacetSet(core, _coreTransitionSelectors(), keccak256(type(CoreTransitionFacet).runtimeCode));
        _validateFacetSet(core, _coreRecoverySelectors(), keccak256(type(CoreRecoveryFacet).runtimeCode));
        _validateFacetSet(core, _coreReceiverSelectors(), keccak256(type(CoreReceiverFacet).runtimeCode));
        _validateFacetSet(core, _coreViewSelectors(), keccak256(type(CoreViewFacet).runtimeCode));

        CoreViewFacet viewFacet = CoreViewFacet(core);
        if (
            !viewFacet.initialized() || !viewFacet.bootstrapFinalized() || viewFacet.bootstrapAuthority() != address(0)
                || viewFacet.periphery() != diamond || viewFacet.positionNFT() != diamond
        ) revert InvalidCoreBootstrap(core);

        address staticsDollar = IStaticsDollarGateway(diamond).staticsDollar();
        address staticsDollarRisk = IStaticsDollarGateway(diamond).staticsDollarRisk();
        if (viewFacet.staticsDollar() != staticsDollar) {
            revert InvalidBinding(core, staticsDollar, viewFacet.staticsDollar());
        }
        if (viewFacet.staticsDollarRisk() != staticsDollarRisk) {
            revert InvalidBinding(core, staticsDollarRisk, viewFacet.staticsDollarRisk());
        }
        _contract(staticsDollar);
        _contract(staticsDollarRisk);
        if (IStaticsDollar(staticsDollar).pool() != core) {
            revert InvalidBinding(staticsDollar, core, IStaticsDollar(staticsDollar).pool());
        }
        if (IStaticsDollarRiskShares(staticsDollarRisk).pool() != core) {
            revert InvalidBinding(staticsDollarRisk, core, IStaticsDollarRiskShares(staticsDollarRisk).pool());
        }
    }

    function _validateFacetSet(address diamond, bytes4[] memory selectors, bytes32 expectedHash)
        private
        view
        returns (address facet)
    {
        facet = _checkedFacet(diamond, selectors[0], expectedHash);
        for (uint256 i = 1; i < selectors.length; ++i) {
            address actual = IDiamondLoupe(diamond).facetAddress(selectors[i]);
            if (actual != facet) revert InvalidFacetRoute(selectors[i], facet, actual);
        }
    }

    function _validateSharedFacetSet(
        address diamond,
        bytes4[] memory installed,
        bytes4[] memory deferred,
        bytes32 expectedHash
    ) private view {
        address facet = _validateFacetSet(diamond, installed, expectedHash);
        for (uint256 i; i < deferred.length; ++i) {
            address actual = IDiamondLoupe(diamond).facetAddress(deferred[i]);
            if (actual != facet) revert InvalidFacetRoute(deferred[i], facet, actual);
        }
    }

    function _checkedFacet(address diamond, bytes4 selector, bytes32 expectedHash)
        private
        view
        returns (address facet)
    {
        facet = IDiamondLoupe(diamond).facetAddress(selector);
        bytes32 actualHash = facet.codehash;
        if (facet == address(0) || actualHash != expectedHash) revert InvalidFacet(facet, expectedHash, actualHash);
    }

    function _diamondSelectors(address diamond) private view returns (bytes4[] memory selectors) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        uint256 count;
        for (uint256 i; i < facets.length; ++i) {
            count += loupe.facetFunctionSelectors(facets[i]).length;
        }
        selectors = new bytes4[](count);
        uint256 cursor;
        for (uint256 i; i < facets.length; ++i) {
            bytes4[] memory facetSelectors = loupe.facetFunctionSelectors(facets[i]);
            for (uint256 j; j < facetSelectors.length; ++j) {
                selectors[cursor++] = facetSelectors[j];
            }
        }
    }

    function _cutSelectors(IDiamondCut.FacetCut[] memory cut) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](StaticsProtocolPlan.selectorCount(cut));
        uint256 cursor;
        for (uint256 i; i < cut.length; ++i) {
            for (uint256 j; j < cut[i].functionSelectors.length; ++j) {
                selectors[cursor++] = cut[i].functionSelectors[j];
            }
        }
    }

    function _sort(bytes4[] memory selectors) private pure {
        for (uint256 i = 1; i < selectors.length; ++i) {
            bytes4 value = selectors[i];
            uint256 j = i;
            while (j != 0 && uint32(selectors[j - 1]) > uint32(value)) {
                selectors[j] = selectors[j - 1];
                --j;
            }
            selectors[j] = value;
        }
    }

    function _contract(address target) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidContract(target);
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidContract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash == bytes32(0) || actualHash != expectedHash) {
            revert InvalidCodeHash(target, expectedHash, actualHash);
        }
    }

    function _envUint16(string memory field) private view returns (uint16 result) {
        uint256 value = vm.envUint(field);
        if (value > type(uint16).max) revert ConfigurationValueOutOfRange(field, value, type(uint16).max);
        result = uint16(value);
    }

    function _validateManifestChain(string memory manifest) private view {
        uint256 expected = vm.parseJsonUint(manifest, ".chainId");
        if (block.chainid != expected) revert InvalidChain(expected, block.chainid);
    }

    function _logPhaseTwo(
        address diamond,
        PhaseTwoDeployment memory deployment,
        PhaseTwoConfig memory config,
        bytes32 salt
    ) private view {
        console2.log("STATICS_PHASE_TWO_INIT_ADDRESS", deployment.initializer);
        console2.log("STATICS_PHASE_TWO_INIT_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.initializer.codehash);
        console2.log("STATICS_GENESIS_INTEGRATION_INIT_ADDRESS", deployment.genesisInitializer);
        console2.log("STATICS_GENESIS_INTEGRATION_INIT_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.genesisInitializer.codehash);
        _logFacetCut(StaticsProtocolPlan.phaseTwo(deployment.parts));
        (,, bytes[] memory payloads) = buildPhaseTwoBatch(diamond, deployment, config);
        console2.log("STATICS_PHASE_TWO_DIAMOND_CUT_CALLDATA");
        console2.logBytes(payloads[0]);
        _logTimelockBatch(diamond, _phaseTwoTargets(diamond), payloads, salt);
    }

    function _logPhaseThree(address diamond, PhaseThreeDeployment memory deployment, bytes32 salt) private view {
        console2.log("STATICS_PHASE_THREE_INIT_ADDRESS", deployment.initializer);
        console2.log("STATICS_PHASE_THREE_INIT_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.initializer.codehash);
        console2.log("STATICS_DOLLAR_CORE_ADDRESS", deployment.core);
        console2.log("STATICS_DOLLAR_CORE_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.core.codehash);
        console2.log("STATICS_DOLLAR_TOKEN_ADDRESS", deployment.staticsDollar);
        console2.log("STATICS_DOLLAR_TOKEN_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.staticsDollar.codehash);
        console2.log("STATICS_DOLLAR_RISK_TOKEN_ADDRESS", deployment.staticsDollarRisk);
        console2.log("STATICS_DOLLAR_RISK_TOKEN_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.staticsDollarRisk.codehash);
        console2.log("STATICS_DOLLAR_ORACLE_ADDRESS", deployment.oracle);
        console2.log("STATICS_DOLLAR_ORACLE_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.oracle.codehash);
        _logFacetCut(StaticsProtocolPlan.phaseThree(deployment.parts));
        _logDiamondFacets(deployment.core);
        (,, bytes[] memory payloads) = buildPhaseThreeBatch(diamond, deployment);
        console2.log("STATICS_PHASE_THREE_DIAMOND_CUT_CALLDATA");
        console2.logBytes(payloads[0]);
        console2.log("STATICS_PHASE_THREE_CORE_FINALIZATION_CALLDATA");
        console2.logBytes(payloads[1]);
        address[] memory targets = new address[](2);
        targets[0] = diamond;
        targets[1] = deployment.core;
        _logTimelockBatch(diamond, targets, payloads, salt);
    }

    function _logPhaseFour(address diamond, PhaseFourDeployment memory deployment, bytes32 salt) private view {
        console2.log("STATICS_PHASE_FOUR_INIT_ADDRESS", deployment.initializer);
        console2.log("STATICS_PHASE_FOUR_INIT_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.initializer.codehash);
        _logFacetCut(StaticsProtocolPlan.phaseFour(deployment.parts));
        (,, bytes[] memory payloads) = buildPhaseFourBatch(diamond, deployment);
        console2.log("STATICS_PHASE_FOUR_DIAMOND_CUT_CALLDATA");
        console2.logBytes(payloads[0]);
        address[] memory targets = new address[](1);
        targets[0] = diamond;
        _logTimelockBatch(diamond, targets, payloads, salt);
    }

    function _phaseTwoTargets(address diamond) private pure returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = diamond;
    }

    function _logFacetCut(IDiamondCut.FacetCut[] memory cut) private view {
        for (uint256 i; i < cut.length; ++i) {
            console2.log("STATICS_PHASE_FACET_ADDRESS", cut[i].facetAddress);
            console2.log("STATICS_PHASE_FACET_RUNTIME_CODE_HASH");
            console2.logBytes32(cut[i].facetAddress.codehash);
            console2.log("STATICS_PHASE_FACET_SELECTOR_COUNT", cut[i].functionSelectors.length);
        }
    }

    function _logDiamondFacets(address diamond) private view {
        address[] memory facets = IDiamondLoupe(diamond).facetAddresses();
        for (uint256 i; i < facets.length; ++i) {
            console2.log("STATICS_DOLLAR_CORE_FACET_ADDRESS", facets[i]);
            console2.log("STATICS_DOLLAR_CORE_FACET_RUNTIME_CODE_HASH");
            console2.logBytes32(facets[i].codehash);
            console2.log(
                "STATICS_DOLLAR_CORE_FACET_SELECTOR_COUNT",
                IDiamondLoupe(diamond).facetFunctionSelectors(facets[i]).length
            );
        }
    }

    function _logTimelockBatch(address diamond, address[] memory targets, bytes[] memory payloads, bytes32 salt)
        private
        view
    {
        uint256[] memory values = new uint256[](targets.length);
        (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall) =
            buildTimelockCalldata(diamond, targets, values, payloads, salt);
        console2.log("STATICS_PHASE_TIMELOCK_ADDRESS", timelock);
        console2.log("STATICS_PHASE_TIMELOCK_OPERATION_ID");
        console2.logBytes32(operationId);
        console2.log("STATICS_PHASE_TIMELOCK_SCHEDULE_CALLDATA");
        console2.logBytes(scheduleCall);
        console2.log("STATICS_PHASE_TIMELOCK_EXECUTE_CALLDATA");
        console2.logBytes(executeCall);
    }
}
