// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarProductionConfig,
    StaticsDollarStackDeployment
} from "./dollar/DeployStaticsDollar.s.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

interface IPositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

contract DeployStatics is Script, RobinhoodDeploymentConfig {
    struct Config {
        address multisig;
        address guardian;
        address treasury;
        address stakingToken;
        uint256 creationFeeAmount;
    }

    struct V4Config {
        address poolManager;
        address positionManager;
        address permit2;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bytes32 poolManagerCodeHash;
        bytes32 positionManagerCodeHash;
        bytes32 permit2CodeHash;
    }

    error InvalidConfig();
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidV4Contract(address target);
    error InvalidV4CodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidV4Binding(address target, address expected, address actual);
    error InvalidHookFees(uint256 inputFeeBps, uint256 outputFeeBps);
    error HookAddressMismatch(address expected, address actual);

    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = Config({
            multisig: vm.envAddress("MULTISIG"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            creationFeeAmount: vm.envUint("BASKET_CREATION_FEE_AMOUNT")
        });
        StaticsDollarProductionConfig memory production = StaticsDollarProductionConfig({
            owner: address(0),
            profileGuardian: address(0),
            treasury: address(0),
            stakingToken: address(0),
            creationFeeAmount: 0,
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

        V4Config memory v4 = _loadRobinhoodV4Config();
        vm.startBroadcast(privateKey);
        (deployment, timelock) = deployProduction(config, production, v4, FOUNDRY_CREATE2_DEPLOYER);
        vm.stopBroadcast();
    }

    /// @notice Local full-stack deployment with repository WETH and oracle fixtures.
    function deploy(Config memory config)
        public
        returns (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock)
    {
        timelock = _deployTimelock(config);
        StaticsDollarLocalConfig memory local;
        local.owner = address(timelock);
        local.profileGuardian = config.guardian;
        local.treasury = config.treasury;
        local.stakingToken = config.stakingToken;
        local.creationFeeAmount = config.creationFeeAmount;
        local.deployMockWeth = true;
        local.deployMockOracle = true;
        local.mockOraclePriceWad = 2_500e18;
        local.mockOracleMaxStaleness = 30 days;
        local.collateralRatioBps = 15_000;
        local.priceBandBps = 15_000;
        local.debtCeiling = 1_000_000e18;
        local.riskUri = "ipfs://local-statics-dollar-risk/{id}.json";
        deployment = new DeployStaticsDollar().deployLocal(local);
    }

    /// @notice Local full-stack deployment bound to caller-supplied real v4 contracts.
    function deployWithLiquidity(Config memory config, V4Config memory v4)
        public
        returns (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock)
    {
        (deployment, timelock) = deploy(config);
        _deployLiquidityContracts(deployment, v4, address(this));
    }

    function deployProduction(Config memory config, StaticsDollarProductionConfig memory production)
        public
        returns (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock)
    {
        timelock = _deployTimelock(config);
        production.owner = address(timelock);
        production.profileGuardian = config.guardian;
        production.treasury = config.treasury;
        production.stakingToken = config.stakingToken;
        production.creationFeeAmount = config.creationFeeAmount;
        deployment = new DeployStaticsDollar().deployProduction(production);
    }

    function deployProduction(
        Config memory config,
        StaticsDollarProductionConfig memory production,
        V4Config memory v4,
        address create2Deployer
    ) public returns (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock) {
        (deployment, timelock) = deployProduction(config, production);
        _deployLiquidityContracts(deployment, v4, create2Deployer);
    }

    function _deployLiquidityContracts(
        StaticsDollarStackDeployment memory deployment,
        V4Config memory config,
        address create2Deployer
    ) private {
        _validateV4(config);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(config.poolManager), deployment.diamond, config.inputFeeBps, config.outputFeeBps
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        StaticsSwapFeeHook hook = new StaticsSwapFeeHook{salt: salt}(
            IPoolManager(config.poolManager), deployment.diamond, config.inputFeeBps, config.outputFeeBps
        );
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));
        StaticsLiquidityManager manager =
            new StaticsLiquidityManager(deployment.diamond, config.positionManager, config.poolManager, config.permit2);

        deployment.poolManager = config.poolManager;
        deployment.positionManager = config.positionManager;
        deployment.permit2 = config.permit2;
        deployment.swapFeeHook = address(hook);
        deployment.liquidityManager = address(manager);
    }

    function _validateV4(V4Config memory config) private view {
        if (
            config.inputFeeBps == 0 || config.outputFeeBps == 0
                || uint256(config.inputFeeBps) + uint256(config.outputFeeBps) > 200
        ) revert InvalidHookFees(config.inputFeeBps, config.outputFeeBps);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        address boundPoolManager = IPositionManagerBindings(config.positionManager).poolManager();
        if (boundPoolManager != config.poolManager) {
            revert InvalidV4Binding(config.positionManager, config.poolManager, boundPoolManager);
        }
        address boundPermit2 = IPositionManagerBindings(config.positionManager).permit2();
        if (boundPermit2 != config.permit2) {
            revert InvalidV4Binding(config.positionManager, config.permit2, boundPermit2);
        }
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidV4Contract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash != bytes32(0) && actualHash != expectedHash) {
            revert InvalidV4CodeHash(target, expectedHash, actualHash);
        }
    }

    function _loadRobinhoodV4Config() internal view returns (V4Config memory config) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        uint256 expectedChainId = vm.parseJsonUint(manifest, ".chainId");
        if (block.chainid != expectedChainId) revert InvalidChain(expectedChainId, block.chainid);
        uint256 inputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.inputFeeBps");
        uint256 outputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.outputFeeBps");
        if (inputFee > type(uint16).max || outputFee > type(uint16).max) {
            revert InvalidHookFees(inputFee, outputFee);
        }
        config = V4Config({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            positionManager: vm.parseJsonAddress(manifest, ".contracts.positionManager.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash")
        });
    }

    function _deployTimelock(Config memory config) private returns (StaticsTimelock timelock) {
        if (config.multisig == address(0) || config.guardian == address(0) || config.treasury == address(0)) {
            revert InvalidConfig();
        }
        address[] memory proposers = new address[](1);
        proposers[0] = config.multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new StaticsTimelock(proposers, executors, address(0));
    }
}
