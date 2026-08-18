// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {GenesisActivationRegistry} from "../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../src/genesis/StaticsGenesisVault.sol";
import {StaticsLaunchAllocationEscrow} from "../src/genesis/StaticsLaunchAllocationEscrow.sol";
import {
    DopplerLaunchTypes,
    IDopplerAirlock,
    IDopplerHookInitializerView
} from "../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsAvatarSVG} from "../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../src/tokens/StaticsGenesis.sol";

struct StaticsGenesisDeploymentConfig {
    address governance;
    address treasury;
    address numeraire;
    address integrator;
    StaticsDopplerLaunchConfig.Modules modules;
    bytes32 salt;
    uint24 startFee;
    uint24 endFee;
    uint32 feeDecayDuration;
    uint16 genesisRewardShareBps;
    string tokenURI;
    string contractURI;
    string externalURLBase;
}

struct StaticsGenesisDeployment {
    address statics;
    address dopplerPoolInitializer;
    address rehype;
    bytes32 poolId;
    address feeReceiver;
    address allocationEscrow;
    address activationRegistry;
    address genesis;
    address genesisVault;
    address genesisDistributor;
    address genesisRenderer;
    address avatarSVG;
}

/// @notice Fresh-deployment-only launcher for the standalone Doppler Genesis system.
contract DeployStaticsGenesis is Script {
    using PoolIdLibrary for PoolKey;

    uint256 public constant STATICS_SUPPLY = 1_000_000_000 ether;
    uint256 public constant DOPPLER_INVENTORY = 800_000_000 ether;
    uint256 public constant TREASURY_ALLOCATION = 200_000_000 ether;
    uint256 public constant BENEFICIARY_SHARE = 0.75 ether;
    uint256 public constant AUTO_LIQUIDITY_SHARE = 0.25 ether;
    uint8 public constant ROUTE_TO_BENEFICIARY_FEES = 1;
    int24 public constant TICK_SPACING = 100;
    int24 public constant FAR_TICK = -83_100;
    address public constant GOVERNANCE_DEAD = address(0xdead);
    address public constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

    error ZeroAddress();
    error InvalidModule(address module);
    error InvalidMetadataURI();
    error InvalidFeeSchedule(uint24 startFee, uint24 endFee, uint32 duration);
    error InvalidRewardShare(uint16 shareBps);
    error RehypeNotEnabled(address rehype);
    error UnexpectedDopplerResult(address pool, address governance, address timelock, address migrationPool);
    error AllocationMismatch(uint256 totalSupply, uint256 treasuryBalance);

    function run() external returns (StaticsGenesisDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: vm.envAddress("STATICS_GENESIS_GOVERNANCE"),
            treasury: vm.envAddress("STATICS_GENESIS_TREASURY"),
            numeraire: vm.envAddress("WETH_ADDRESS"),
            integrator: vm.envOr("STATICS_DOPPLER_INTEGRATOR", address(0)),
            modules: StaticsDopplerLaunchConfig.modules(block.chainid),
            salt: vm.envBytes32("STATICS_DOPPLER_SALT"),
            startFee: uint24(vm.envUint("STATICS_DOPPLER_START_FEE")),
            endFee: uint24(vm.envUint("STATICS_DOPPLER_END_FEE")),
            feeDecayDuration: uint32(vm.envUint("STATICS_DOPPLER_FEE_DECAY_SECONDS")),
            genesisRewardShareBps: uint16(vm.envUint("STATICS_GENESIS_REWARD_SHARE_BPS")),
            tokenURI: vm.envString("STATICS_TOKEN_URI"),
            contractURI: vm.envString("STATICS_GENESIS_CONTRACT_URI"),
            externalURLBase: vm.envString("STATICS_GENESIS_EXTERNAL_URL_BASE")
        });

        vm.startBroadcast(privateKey);
        deployment = deploy(config, deployer);
        vm.stopBroadcast();
        _log(deployment);
    }

    function deploy(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        public
        returns (StaticsGenesisDeployment memory deployment)
    {
        _validate(config, initialOwner);

        StaticsFeeReceiver receiver = new StaticsFeeReceiver(config.modules.rehype, config.numeraire, initialOwner);
        StaticsLaunchAllocationEscrow allocationEscrow =
            new StaticsLaunchAllocationEscrow(config.treasury, initialOwner);
        (address statics, bytes32 poolId) = _createDopplerMarket(config, receiver, allocationEscrow);
        receiver.bindMarket(statics, poolId);

        GenesisActivationRegistry registry = new GenesisActivationRegistry(IERC20(statics), initialOwner, initialOwner);
        StaticsGenesisVault vault =
            new StaticsGenesisVault(IERC20(statics), initialOwner, initialOwner, config.treasury);
        StaticsAvatarSVG avatar = new StaticsAvatarSVG();
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
        StaticsGenesis genesis = new StaticsGenesis(
            address(vault),
            address(registry),
            renderer,
            initialOwner,
            config.treasury,
            config.contractURI,
            config.externalURLBase
        );
        registry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));
        allocationEscrow.release(IERC20(statics), address(vault));
        if (IERC20(statics).balanceOf(config.treasury) != TREASURY_ALLOCATION) {
            revert AllocationMismatch(IERC20(statics).totalSupply(), IERC20(statics).balanceOf(config.treasury));
        }

        GenesisLaunchDistributor distributor = new GenesisLaunchDistributor(
            receiver, genesis, registry, config.treasury, initialOwner, config.genesisRewardShareBps
        );
        receiver.proposeDistributor(address(distributor));
        distributor.acceptFeeReceiverRole();
        registry.proposeConsumer(address(distributor));
        distributor.acceptActivationConsumer();

        receiver.transferOwnership(config.governance);
        registry.transferOwnership(config.governance);
        vault.transferOwnership(config.governance);
        genesis.transferOwnership(config.governance);
        distributor.transferOwnership(config.governance);

        deployment = StaticsGenesisDeployment({
            statics: statics,
            dopplerPoolInitializer: config.modules.poolInitializer,
            rehype: config.modules.rehype,
            poolId: poolId,
            feeReceiver: address(receiver),
            allocationEscrow: address(allocationEscrow),
            activationRegistry: address(registry),
            genesis: address(genesis),
            genesisVault: address(vault),
            genesisDistributor: address(distributor),
            genesisRenderer: address(renderer),
            avatarSVG: address(avatar)
        });
    }

    /// @notice Nonproduction four-curve fixture. Production ranges require a separate ratification.
    function defaultCurves() public pure returns (DopplerLaunchTypes.Curve[] memory curves) {
        curves = new DopplerLaunchTypes.Curve[](4);
        curves[0] =
            DopplerLaunchTypes.Curve({tickLower: -887_200, tickUpper: -142_200, numPositions: 11, shares: 0.5 ether});
        curves[1] =
            DopplerLaunchTypes.Curve({tickLower: -222_200, tickUpper: -116_300, numPositions: 11, shares: 0.25 ether});
        curves[2] =
            DopplerLaunchTypes.Curve({tickLower: -176_200, tickUpper: -84_100, numPositions: 11, shares: 0.24 ether});
        curves[3] =
            DopplerLaunchTypes.Curve({tickLower: -84_100, tickUpper: -83_000, numPositions: 11, shares: 0.01 ether});
    }

    function _createDopplerMarket(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsLaunchAllocationEscrow allocationEscrow
    ) private returns (address statics, bytes32 poolId) {
        IDopplerAirlock airlock = IDopplerAirlock(config.modules.airlock);
        if (
            IDopplerHookInitializerView(config.modules.poolInitializer).isDopplerHookEnabled(config.modules.rehype) & 1
                == 0
        ) {
            revert RehypeNotEnabled(config.modules.rehype);
        }

        DopplerLaunchTypes.BeneficiaryData[] memory poolBeneficiaries = new DopplerLaunchTypes.BeneficiaryData[](1);
        poolBeneficiaries[0] =
            DopplerLaunchTypes.BeneficiaryData({beneficiary: airlock.owner(), shares: uint96(DopplerLaunchTypes.WAD)});
        DopplerLaunchTypes.BeneficiaryData[] memory feeBeneficiaries = new DopplerLaunchTypes.BeneficiaryData[](1);
        feeBeneficiaries[0] = DopplerLaunchTypes.BeneficiaryData({
            beneficiary: address(receiver), shares: uint96(DopplerLaunchTypes.WAD)
        });

        DopplerLaunchTypes.FeeDistributionInfo memory distribution = DopplerLaunchTypes.FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: 0,
            assetFeesToBeneficiaryWad: BENEFICIARY_SHARE,
            assetFeesToLpWad: AUTO_LIQUIDITY_SHARE,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: 0,
            numeraireFeesToBeneficiaryWad: BENEFICIARY_SHARE,
            numeraireFeesToLpWad: AUTO_LIQUIDITY_SHARE
        });
        bytes memory rehypeData = abi.encode(
            DopplerLaunchTypes.RehypeInitData({
                numeraire: config.numeraire,
                buybackDst: address(receiver),
                startFee: config.startFee,
                endFee: config.endFee,
                durationSeconds: config.feeDecayDuration,
                startingTime: 0,
                feeRoutingMode: ROUTE_TO_BENEFICIARY_FEES,
                feeDistributionInfo: distribution,
                feeBeneficiaries: feeBeneficiaries
            })
        );
        bytes memory poolData = abi.encode(
            DopplerLaunchTypes.PoolInitializerData({
                fee: 0,
                tickSpacing: TICK_SPACING,
                farTick: FAR_TICK,
                curves: defaultCurves(),
                beneficiaries: poolBeneficiaries,
                dopplerHook: config.modules.rehype,
                onInitializationDopplerHookCalldata: rehypeData,
                graduationDopplerHookCalldata: bytes("")
            })
        );

        DopplerLaunchTypes.CreateParams memory params = DopplerLaunchTypes.CreateParams({
            initialSupply: STATICS_SUPPLY,
            numTokensToSell: DOPPLER_INVENTORY,
            numeraire: config.numeraire,
            tokenFactory: config.modules.tokenFactory,
            tokenFactoryData: _tokenFactoryData(config.tokenURI),
            governanceFactory: config.modules.governanceFactory,
            governanceFactoryData: abi.encode(address(allocationEscrow)),
            poolInitializer: config.modules.poolInitializer,
            poolInitializerData: poolData,
            liquidityMigrator: config.modules.noOpMigrator,
            liquidityMigratorData: bytes(""),
            integrator: config.integrator,
            salt: config.salt
        });

        address pool;
        address governance;
        address timelock;
        address migrationPool;
        (statics, pool, governance, timelock, migrationPool) = airlock.create(params);
        if (
            pool != statics || governance != GOVERNANCE_DEAD || timelock != address(allocationEscrow)
                || migrationPool != MIGRATION_DEAD
        ) {
            revert UnexpectedDopplerResult(pool, governance, timelock, migrationPool);
        }
        uint256 totalSupply = IERC20(statics).totalSupply();
        uint256 escrowBalance = IERC20(statics).balanceOf(address(allocationEscrow));
        if (totalSupply != STATICS_SUPPLY || escrowBalance < TREASURY_ALLOCATION) {
            revert AllocationMismatch(totalSupply, escrowBalance);
        }
        poolId = _poolId(statics, config.numeraire, config.modules.poolInitializer);
    }

    function _tokenFactoryData(string memory tokenURI) private pure returns (bytes memory) {
        return abi.encode(
            "Statics",
            "STATICS",
            new DopplerLaunchTypes.VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            tokenURI,
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );
    }

    function _poolId(address statics, address numeraire, address initializer) private pure returns (bytes32) {
        (address currency0, address currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: DopplerLaunchTypes.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(initializer)
        });
        return PoolId.unwrap(key.toId());
    }

    function _validate(StaticsGenesisDeploymentConfig memory config, address initialOwner) private view {
        if (
            initialOwner == address(0) || config.governance == address(0) || config.treasury == address(0)
                || config.numeraire == address(0)
        ) revert ZeroAddress();
        _requireContract(config.numeraire);
        _requireContract(config.modules.airlock);
        _requireContract(config.modules.tokenFactory);
        _requireContract(config.modules.governanceFactory);
        _requireContract(config.modules.poolInitializer);
        _requireContract(config.modules.noOpMigrator);
        _requireContract(config.modules.rehype);
        if (
            bytes(config.tokenURI).length == 0 || bytes(config.contractURI).length == 0
                || bytes(config.externalURLBase).length == 0
        ) {
            revert InvalidMetadataURI();
        }
        if (config.startFee < config.endFee || (config.startFee > config.endFee && config.feeDecayDuration == 0)) {
            revert InvalidFeeSchedule(config.startFee, config.endFee, config.feeDecayDuration);
        }
        if (config.genesisRewardShareBps > 10_000) revert InvalidRewardShare(config.genesisRewardShareBps);
    }

    function _requireContract(address target) private view {
        if (target.code.length == 0) revert InvalidModule(target);
    }

    function _log(StaticsGenesisDeployment memory deployment) private pure {
        console2.log("STATICS_TOKEN_ADDRESS", deployment.statics);
        console2.log("STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS", deployment.dopplerPoolInitializer);
        console2.log("STATICS_REHYPE_ADDRESS", deployment.rehype);
        console2.logBytes32(deployment.poolId);
        console2.log("STATICS_FEE_RECEIVER_ADDRESS", deployment.feeReceiver);
        console2.log("STATICS_LAUNCH_ALLOCATION_ESCROW_ADDRESS", deployment.allocationEscrow);
        console2.log("STATICS_GENESIS_ACTIVATION_REGISTRY_ADDRESS", deployment.activationRegistry);
        console2.log("STATICS_GENESIS_NFT_ADDRESS", deployment.genesis);
        console2.log("STATICS_GENESIS_VAULT_ADDRESS", deployment.genesisVault);
        console2.log("STATICS_GENESIS_DISTRIBUTOR_ADDRESS", deployment.genesisDistributor);
        console2.log("STATICS_GENESIS_RENDERER_ADDRESS", deployment.genesisRenderer);
        console2.log("STATICS_GENESIS_AVATAR_SVG_ADDRESS", deployment.avatarSVG);
    }
}
