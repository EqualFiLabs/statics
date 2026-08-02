// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ChainlinkUsdOracle} from "../../src/dollar/ChainlinkUsdOracle.sol";
import {CoreGovernanceFacet} from "../../src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCoreTypes} from "../../src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "../../src/dollar/mocks/CanonicalWETH9.sol";
import {LocalUSDG} from "../../src/dollar/mocks/LocalUSDG.sol";
import {MockETHUSDOracle} from "../../src/dollar/mocks/MockETHUSDOracle.sol";
import {CoreBootstrapConfig, CoreBootstrapDeployment, DeployCoreBootstrap} from "./DeployCoreBootstrap.s.sol";
import {console2} from "forge-std/console2.sol";

struct StaticsDollarProductionConfig {
    address owner;
    address profileGuardian;
    address treasury;
    address stakingToken;
    uint256 creationFeeAmount;
    address weth;
    address ethUsdFeed;
    address sequencerUptimeFeed;
    uint256 oracleMaxStaleness;
    uint256 oracleMinPriceWad;
    uint256 oracleMaxPriceWad;
    uint256 sequencerGracePeriod;
    uint256 collateralRatioBps;
    uint256 priceBandBps;
    uint256 debtCeiling;
    string riskUri;
}

struct StaticsDollarLocalConfig {
    address owner;
    address profileGuardian;
    address treasury;
    address stakingToken;
    uint256 creationFeeAmount;
    address weth;
    address oracle;
    bool deployMockWeth;
    bool deployMockOracle;
    uint256 mockOraclePriceWad;
    uint256 mockOracleMaxStaleness;
    uint256 collateralRatioBps;
    uint256 priceBandBps;
    uint256 debtCeiling;
    string riskUri;
}

struct StaticsDollarStackDeployment {
    address core;
    address pool;
    address staticsDollar;
    address staticsDollarRisk;
    address gateway;
    address weth;
    address oracle;
    address diamond;
    address positionNFT;
    address poolManager;
    address positionManager;
    address permit2;
    address swapFeeHook;
    address liquidityManager;
    address stateView;
    address usdg;
    address usdgOracle;
    uint256 usdgProfileId;
}

contract DeployStaticsDollar is DeployCoreBootstrap {
    uint256 internal constant MOCK_MARKER_GAS = 30_000;
    bytes32 internal constant OWNER_FIELD = "OWNER";
    bytes32 internal constant PROFILE_GUARDIAN_FIELD = "PROFILE_GUARDIAN";
    bytes32 internal constant TREASURY_FIELD = "TREASURY";
    bytes32 internal constant WETH_FIELD = "WETH";
    bytes32 internal constant ETH_USD_FEED_FIELD = "ETH_USD_FEED";
    bytes32 internal constant SEQUENCER_FEED_FIELD = "SEQUENCER_FEED";
    bytes32 internal constant ORACLE_STALENESS_FIELD = "ORACLE_STALENESS";
    bytes32 internal constant ORACLE_BOUNDS_FIELD = "ORACLE_BOUNDS";
    bytes32 internal constant SEQUENCER_GRACE_FIELD = "SEQUENCER_GRACE";
    bytes32 internal constant RISK_CONFIG_FIELD = "RISK_CONFIG";
    bytes32 internal constant DEBT_CEILING_FIELD = "DEBT_CEILING";
    bytes32 internal constant RISK_URI_FIELD = "RISK_URI";

    error MissingProductionInput(bytes32 field);
    error InvalidProductionInput(bytes32 field);
    error MockDependency(address dependency);
    error LocalDependencyMissing(bytes32 field);

    function run() external returns (StaticsDollarStackDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        StaticsDollarProductionConfig memory config = StaticsDollarProductionConfig({
            owner: vm.envAddress("STATICS_DOLLAR_OWNER"),
            profileGuardian: vm.envAddress("STATICS_DOLLAR_PROFILE_GUARDIAN"),
            treasury: vm.envAddress("STATICS_TREASURY"),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            creationFeeAmount: vm.envUint("BASKET_CREATION_FEE_AMOUNT"),
            weth: vm.envAddress("WETH_ADDRESS"),
            ethUsdFeed: vm.envAddress("ETH_USD_FEED"),
            sequencerUptimeFeed: vm.envAddress("SEQUENCER_UPTIME_FEED"),
            oracleMaxStaleness: vm.envUint("STATICS_DOLLAR_ORACLE_MAX_STALENESS"),
            oracleMinPriceWad: vm.envUint("STATICS_DOLLAR_ORACLE_MIN_PRICE_WAD"),
            oracleMaxPriceWad: vm.envUint("STATICS_DOLLAR_ORACLE_MAX_PRICE_WAD"),
            sequencerGracePeriod: vm.envUint("SEQUENCER_GRACE_PERIOD"),
            collateralRatioBps: vm.envUint("STATICS_DOLLAR_COLLATERAL_RATIO_BPS"),
            priceBandBps: vm.envUint("STATICS_DOLLAR_PRICE_BAND_BPS"),
            debtCeiling: vm.envUint("STATICS_DOLLAR_DEBT_CEILING"),
            riskUri: vm.envString("STATICS_DOLLAR_RISK_URI")
        });
        vm.startBroadcast(privateKey);
        deployment = _deployProduction(config, vm.addr(privateKey));
        vm.stopBroadcast();
    }

    /// @notice Deploys the complete stack with local mock dependencies for Anvil rehearsals.
    function runLocal() external returns (StaticsDollarStackDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        StaticsDollarLocalConfig memory config;
        config.owner = deployer;
        config.profileGuardian = deployer;
        config.treasury = deployer;
        config.creationFeeAmount = 1 ether;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.mockOracleMaxStaleness = 30 days;
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://local-statics-dollar-risk";

        vm.startBroadcast(privateKey);
        deployment = _deployLocal(config, deployer);
        deployment = deployLocalPeggedProfile(deployment, deployer);
        vm.stopBroadcast();

        _logLocalDeployment(deployment);
    }

    function _logLocalDeployment(StaticsDollarStackDeployment memory deployment) internal pure {
        console2.log("STATICS_DOLLAR_CORE_ADDRESS", deployment.core);
        console2.log("STATICS_DIAMOND_ADDRESS", deployment.diamond);
        console2.log("STATICS_DOLLAR_TOKEN_ADDRESS", deployment.staticsDollar);
        console2.log("STATICS_DOLLAR_RISK_TOKEN_ADDRESS", deployment.staticsDollarRisk);
        console2.log("STATICS_DOLLAR_GATEWAY_ADDRESS", deployment.gateway);
        console2.log("WETH_ADDRESS", deployment.weth);
        console2.log("STATICS_DOLLAR_ORACLE_ADDRESS", deployment.oracle);
        console2.log("STATICS_DOLLAR_POSITION_NFT_ADDRESS", deployment.positionNFT);
        if (deployment.usdg != address(0)) {
            console2.log("STATICS_DOLLAR_USDG_ADDRESS", deployment.usdg);
            console2.log("STATICS_DOLLAR_USDG_ORACLE_ADDRESS", deployment.usdgOracle);
            console2.log("STATICS_DOLLAR_USDG_PROFILE_ID", deployment.usdgProfileId);
        }
        if (deployment.swapFeeHook != address(0)) {
            console2.log("STATICS_POOL_MANAGER_ADDRESS", deployment.poolManager);
            console2.log("STATICS_POSITION_MANAGER_ADDRESS", deployment.positionManager);
            console2.log("STATICS_PERMIT2_ADDRESS", deployment.permit2);
            console2.log("STATICS_SWAP_FEE_HOOK_ADDRESS", deployment.swapFeeHook);
            console2.log("STATICS_LIQUIDITY_MANAGER_ADDRESS", deployment.liquidityManager);
            console2.log("STATICS_STATE_VIEW_ADDRESS", deployment.stateView);
        }
    }

    function deployProduction(StaticsDollarProductionConfig memory config)
        public
        returns (StaticsDollarStackDeployment memory deployment)
    {
        return _deployProduction(config, address(this));
    }

    function _deployProduction(StaticsDollarProductionConfig memory config, address deploymentCreator)
        internal
        returns (StaticsDollarStackDeployment memory deployment)
    {
        _validateProduction(config);
        ChainlinkUsdOracle oracle = new ChainlinkUsdOracle(
            config.ethUsdFeed,
            config.oracleMaxStaleness,
            config.oracleMinPriceWad,
            config.oracleMaxPriceWad,
            config.sequencerUptimeFeed,
            config.sequencerGracePeriod
        );
        return _deployStack(
            config.owner,
            config.profileGuardian,
            config.treasury,
            config.stakingToken,
            config.creationFeeAmount,
            config.weth,
            address(oracle),
            config.sequencerUptimeFeed,
            config.sequencerGracePeriod,
            config.collateralRatioBps,
            config.priceBandBps,
            config.debtCeiling,
            config.riskUri,
            deploymentCreator
        );
    }

    function deployLocal(StaticsDollarLocalConfig memory config)
        public
        returns (StaticsDollarStackDeployment memory deployment)
    {
        return _deployLocal(config, address(this));
    }

    /// @notice Adds a six-decimal USDG profile to a local stack for browser rehearsals.
    function deployLocalPeggedProfile(StaticsDollarStackDeployment memory deployment, address recipient)
        public
        returns (StaticsDollarStackDeployment memory)
    {
        LocalUSDG usdg = new LocalUSDG();
        MockETHUSDOracle oracle = new MockETHUSDOracle(1e18, 30 days);
        uint256 profileId = CoreGovernanceFacet(deployment.core)
            .createPeggedCollateralProfile(address(usdg), address(oracle), 0.995e18, 1.005e18, 5, 7, 10_000_000e18);
        CoreGovernanceFacet(deployment.core).setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
        usdg.mint(recipient, 10_000_000e6);
        deployment.usdg = address(usdg);
        deployment.usdgOracle = address(oracle);
        deployment.usdgProfileId = profileId;
        return deployment;
    }

    function _deployLocal(StaticsDollarLocalConfig memory config, address deploymentCreator)
        internal
        returns (StaticsDollarStackDeployment memory deployment)
    {
        if (config.owner == address(0)) config.owner = msg.sender;
        if (config.profileGuardian == address(0)) config.profileGuardian = config.owner;
        if (config.treasury == address(0)) config.treasury = config.owner;
        if (config.weth == address(0)) {
            if (!config.deployMockWeth) revert LocalDependencyMissing(WETH_FIELD);
            config.weth = address(new CanonicalWETH9());
        }
        if (config.stakingToken == address(0)) config.stakingToken = config.weth;
        if (config.oracle == address(0)) {
            if (!config.deployMockOracle) revert LocalDependencyMissing(ETH_USD_FEED_FIELD);
            uint256 price = config.mockOraclePriceWad == 0 ? 2_500e18 : config.mockOraclePriceWad;
            uint256 staleness = config.mockOracleMaxStaleness == 0 ? 30 days : config.mockOracleMaxStaleness;
            config.oracle = address(new MockETHUSDOracle(price, staleness));
        }
        return _deployStack(
            config.owner,
            config.profileGuardian,
            config.treasury,
            config.stakingToken,
            config.creationFeeAmount,
            config.weth,
            config.oracle,
            address(0),
            0,
            config.collateralRatioBps,
            config.priceBandBps,
            config.debtCeiling,
            config.riskUri,
            deploymentCreator
        );
    }

    function _deployStack(
        address owner,
        address profileGuardian,
        address treasury,
        address stakingToken,
        uint256 creationFeeAmount,
        address weth,
        address oracle,
        address sequencerUptimeFeed,
        uint256 sequencerGracePeriod,
        uint256 collateralRatioBps,
        uint256 priceBandBps,
        uint256 debtCeiling,
        string memory riskUri,
        address deploymentCreator
    ) private returns (StaticsDollarStackDeployment memory deployment) {
        CoreBootstrapConfig memory config = CoreBootstrapConfig({
            owner: owner,
            profileGuardian: profileGuardian,
            treasury: treasury,
            stakingToken: stakingToken,
            creationFeeAmount: creationFeeAmount,
            initialOracle: oracle,
            requiredSequencerUptimeFeed: sequencerUptimeFeed,
            minimumSequencerGracePeriod: sequencerGracePeriod,
            weth: weth,
            collateralRatioBps: collateralRatioBps,
            priceBandBps: priceBandBps,
            debtCeiling: debtCeiling,
            riskUri: riskUri
        });
        CoreBootstrapDeployment memory coreDeployment = deploy(config, deploymentCreator);
        deployment.core = coreDeployment.core;
        deployment.pool = coreDeployment.core;
        deployment.staticsDollar = coreDeployment.staticsDollar;
        deployment.staticsDollarRisk = coreDeployment.staticsDollarRisk;
        deployment.weth = weth;
        deployment.oracle = oracle;
        deployment.diamond = coreDeployment.diamond;
        deployment.positionNFT = coreDeployment.positionNFT;
        deployment.gateway = deployment.diamond;
    }

    function _validateProduction(StaticsDollarProductionConfig memory config) private view {
        _requireInput(config.owner, OWNER_FIELD);
        _requireInput(config.profileGuardian, PROFILE_GUARDIAN_FIELD);
        _requireInput(config.treasury, TREASURY_FIELD);
        _requireInput(config.weth, WETH_FIELD);
        _requireInput(config.ethUsdFeed, ETH_USD_FEED_FIELD);
        _requireInput(config.sequencerUptimeFeed, SEQUENCER_FEED_FIELD);
        if (config.oracleMaxStaleness == 0) revert MissingProductionInput(ORACLE_STALENESS_FIELD);
        if (config.oracleMinPriceWad == 0 || config.oracleMaxPriceWad <= config.oracleMinPriceWad) {
            revert InvalidProductionInput(ORACLE_BOUNDS_FIELD);
        }
        if (config.sequencerGracePeriod == 0) revert MissingProductionInput(SEQUENCER_GRACE_FIELD);
        if (config.collateralRatioBps == 0 || config.priceBandBps == 0) {
            revert MissingProductionInput(RISK_CONFIG_FIELD);
        }
        if (config.debtCeiling == 0) revert MissingProductionInput(DEBT_CEILING_FIELD);
        if (bytes(config.riskUri).length == 0) revert MissingProductionInput(RISK_URI_FIELD);
        if (config.weth.code.length == 0) revert InvalidProductionInput(WETH_FIELD);
        if (config.ethUsdFeed.code.length == 0) revert InvalidProductionInput(ETH_USD_FEED_FIELD);
        if (config.sequencerUptimeFeed.code.length == 0) revert InvalidProductionInput(SEQUENCER_FEED_FIELD);
        // This is an optional repository-mock marker, not a trusted interface.
        // Bound the probe because canonical WETH implementations may route an
        // unknown selector to a state-changing deposit fallback. Under STATICCALL
        // that exceptional halt otherwise consumes nearly all forwarded gas.
        (bool markerOk, bytes memory markerData) =
            config.weth.staticcall{gas: MOCK_MARKER_GAS}(abi.encodeWithSignature("isStaticsDollarLocalMock()"));
        if (markerOk && markerData.length >= 32 && abi.decode(markerData, (bool))) {
            revert MockDependency(config.weth);
        }
    }

    function _requireInput(address value, bytes32 field) private pure {
        if (value == address(0)) revert MissingProductionInput(field);
    }
}
