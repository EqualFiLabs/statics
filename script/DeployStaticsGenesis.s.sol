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
import {StaticsTreasuryVesting} from "../src/genesis/StaticsTreasuryVesting.sol";
import {DopplerLaunchTypes, IDopplerAirlock} from "../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";
import {LibStaticsTokenMetadata} from "../src/metadata/LibStaticsTokenMetadata.sol";
import {StaticsAvatarSVG} from "../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../src/tokens/StaticsGenesis.sol";
import {GenesisCreditConfig} from "../src/interfaces/IStaticsGenesisVault.sol";

struct StaticsGenesisDeploymentConfig {
    address governance;
    address treasury;
    address numeraire;
    address integrator;
    StaticsDopplerLaunchConfig.Modules modules;
    bytes32 salt;
    uint24 fee;
    uint16 genesisRewardShareBps;
    uint16 reserveShareBps;
    uint256 creditOriginationFee;
    uint256 creditExtensionFee;
    uint16 recoveryCallerShareBps;
    uint256 genesisEpochEnd;
    /// @dev Retained for lower-level config compatibility. Doppler launch calldata always uses canonical metadata.
    string tokenURI;
    string contractURI;
    string externalURLBase;
}

struct StaticsGenesisDeployment {
    address statics;
    address dopplerPoolInitializer;
    bytes32 poolId;
    address feeReceiver;
    address treasuryVesting;
    address activationRegistry;
    address genesis;
    address genesisVault;
    address genesisDistributor;
    address genesisRenderer;
    address avatarSVG;
}

/// @dev Internal grouping that keeps the launcher's live-local set within
/// legacy-codegen stack limits.
struct GenesisCollection {
    GenesisActivationRegistry registry;
    StaticsGenesisVault vault;
    StaticsAvatarSVG avatar;
    StaticsGenesisRenderer renderer;
    StaticsGenesis genesis;
}

/// @notice Fresh-deployment-only launcher for the standalone Doppler Genesis system.
contract DeployStaticsGenesis is Script, RobinhoodDeploymentConfig {
    using PoolIdLibrary for PoolKey;

    uint256 public constant STATICS_SUPPLY = 1_000_000_000 ether;
    uint256 public constant DOPPLER_INVENTORY = 800_000_000 ether;
    uint256 public constant PROTOCOL_ALLOCATION = 200_000_000 ether;
    uint256 public constant TREASURY_GENESIS_COUNT = 555;
    uint256 public constant TREASURY_GENESIS_FIRST_ID = 5_001;
    uint256 public constant TREASURY_GENESIS_LAST_ID = 5_555;
    uint256 public constant TREASURY_GENESIS_BACKING = 99_900_000 ether;
    uint256 public constant TREASURY_STATICS_VESTING_PRINCIPAL = 100_100_000 ether;
    uint256 public constant TREASURY_VESTING_DURATION = 60 days;
    uint256 public constant TREASURY_GENESIS_RELEASE_BATCH = 50;
    uint256 public constant GENESIS_BACKING = 180_000 ether;
    uint256 public constant GENESIS_MAX_SUPPLY = 5_555;
    uint256 public constant NATIVE_ACQUISITION_FEE = 0.003 ether;
    uint256 public constant GENESIS_CREDIT_MAX_PRINCIPAL = 171_000 ether;
    uint256 public constant GENESIS_CREDIT_RECOVERY_RESIDUAL = 9_000 ether;
    uint256 public constant GENESIS_CREDIT_TERM = 30 days;
    uint256 public constant GENESIS_CREDIT_RECOVERY_GRACE = 1 hours;
    uint16 public constant GENESIS_CREDIT_INITIAL_RESERVE_SHARE_BPS = 1_000;
    uint16 public constant GENESIS_CREDIT_INITIAL_TREASURY_SHARE_BPS = 9_000;
    uint96 public constant DOPPLER_OWNER_SHARE = 0.05 ether;
    uint96 public constant STATICS_FEE_SHARE = 0.95 ether;
    uint24 public constant MAX_DOPPLER_LP_FEE = 100_000;
    uint256 public constant MAX_MULTICURVE_RESIDUAL = 100 ether;
    bytes20 public constant DOPPLER_SOURCE_REVISION = hex"86a5200456b148c156d2eb81a893747dd601c3ca";
    /// @dev Remains zero until a follow-up economic-parameter decision ratifies the Robinhood launch.
    bytes32 public constant APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH = bytes32(0);
    int24 public constant TICK_SPACING = 100;
    int24 public constant FAR_TICK = 887_100;
    address public constant GOVERNANCE_DEAD = address(0xdead);
    address public constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

    error ZeroAddress();
    error InvalidModule(address module);
    error InvalidMetadataURI();
    error InvalidFee(uint256 fee);
    error InvalidRewardShare(uint256 shareBps);
    error InvalidReserveShare(uint256 shareBps);
    error InvalidRecoveryCallerShare(uint256 shareBps);
    error InvalidEpochEnd(uint256 epochEnd);
    error InvalidRobinhoodWeth(address expected, address actual);
    error InvalidRobinhoodWethCodeHash(bytes32 expected, bytes32 actual);
    error InvalidRobinhoodDependency(address expected, address actual);
    error InvalidRobinhoodDependencyCodeHash(address dependency, bytes32 expected, bytes32 actual);
    error ProductionLaunchConfigurationNotRatified(bytes32 currentHash, bytes32 approvedHash);
    error UnexpectedDopplerResult(address pool, address governance, address timelock, address migrationPool);
    error AllocationMismatch(uint256 totalSupply, uint256 treasuryBalance);
    error ExcessiveMulticurveResidual(uint256 residual, uint256 maximum);

    function run() external returns (StaticsGenesisDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 fee = vm.envUint("STATICS_DOPPLER_FEE");
        uint256 rewardShare = vm.envUint("STATICS_GENESIS_REWARD_SHARE_BPS");
        uint256 reserveShare = vm.envUint("STATICS_GENESIS_RESERVE_SHARE_BPS");
        uint256 recoveryCallerShare = vm.envUint("STATICS_GENESIS_RECOVERY_CALLER_SHARE_BPS");
        uint256 genesisEpochEnd = vm.envUint("STATICS_GENESIS_EPOCH_END");
        if (fee > type(uint24).max) revert InvalidFee(fee);
        if (rewardShare > type(uint16).max) revert InvalidRewardShare(rewardShare);
        if (reserveShare > type(uint16).max) revert InvalidReserveShare(reserveShare);
        if (recoveryCallerShare > type(uint16).max) revert InvalidRecoveryCallerShare(recoveryCallerShare);
        if (genesisEpochEnd <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd);
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: vm.envAddress("STATICS_GENESIS_GOVERNANCE"),
            treasury: vm.envAddress("STATICS_GENESIS_TREASURY"),
            numeraire: vm.envAddress("WETH_ADDRESS"),
            integrator: vm.envOr("STATICS_DOPPLER_INTEGRATOR", address(0)),
            modules: StaticsDopplerLaunchConfig.modules(block.chainid),
            salt: vm.envBytes32("STATICS_DOPPLER_SALT"),
            fee: uint24(fee),
            genesisRewardShareBps: uint16(rewardShare),
            reserveShareBps: uint16(reserveShare),
            creditOriginationFee: vm.envUint("STATICS_GENESIS_CREDIT_ORIGINATION_FEE"),
            creditExtensionFee: vm.envUint("STATICS_GENESIS_CREDIT_EXTENSION_FEE"),
            recoveryCallerShareBps: uint16(recoveryCallerShare),
            genesisEpochEnd: genesisEpochEnd,
            tokenURI: staticsTokenURI(),
            contractURI: vm.envString("STATICS_GENESIS_CONTRACT_URI"),
            externalURLBase: vm.envString("STATICS_GENESIS_EXTERNAL_URL_BASE")
        });
        if (block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) {
            bytes32 wethRuntimeCodeHash = _validateRobinhoodWeth(config.numeraire);
            StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes =
                _validateRobinhoodDopplerModules(config.modules);
            bytes32 currentHash = launchConfigHash(config, wethRuntimeCodeHash, moduleCodeHashes);
            if (
                APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH == bytes32(0)
                    || currentHash != APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH
            ) {
                revert ProductionLaunchConfigurationNotRatified(currentHash, APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH);
            }
        }

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

        (StaticsFeeReceiver receiver, StaticsTreasuryVesting treasuryVesting) =
            _deployLaunchReceivers(config, initialOwner);
        (address statics, bytes32 poolId) = _createDopplerMarket(config, receiver, treasuryVesting);
        receiver.bindMarket(statics, poolId);

        GenesisCollection memory collection =
            _deployGenesisCollection(statics, receiver, treasuryVesting, config, initialOwner);
        collection.registry.bindGenesisCollection(address(collection.genesis));
        treasuryVesting.finalizeBootstrap(statics, address(collection.vault), address(collection.genesis));

        // Bind the reserve vault and configure the reserve share before the first distributor is
        // accepted so nonzero reserveShareBps can never harvest around an unbound reserve vault.
        receiver.bindReserveVault(address(collection.vault));
        receiver.setReserveShareBps(config.reserveShareBps);

        GenesisLaunchDistributor distributor =
            _deployDistributor(receiver, collection.genesis, collection.registry, config, initialOwner);
        receiver.proposeDistributor(address(distributor));
        distributor.acceptFeeReceiverRole();
        collection.registry.proposeConsumer(address(distributor));
        distributor.acceptActivationConsumer();

        receiver.transferOwnership(config.governance);
        collection.registry.transferOwnership(config.governance);
        collection.vault.transferOwnership(config.governance);
        collection.genesis.transferOwnership(config.governance);
        distributor.transferOwnership(config.governance);

        deployment.statics = statics;
        deployment.dopplerPoolInitializer = config.modules.poolInitializer;
        deployment.poolId = poolId;
        deployment.feeReceiver = address(receiver);
        deployment.treasuryVesting = address(treasuryVesting);
        deployment.activationRegistry = address(collection.registry);
        deployment.genesis = address(collection.genesis);
        deployment.genesisVault = address(collection.vault);
        deployment.genesisDistributor = address(distributor);
        deployment.genesisRenderer = address(collection.renderer);
        deployment.avatarSVG = address(collection.avatar);
    }

    function _deployLaunchReceivers(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        private
        returns (StaticsFeeReceiver receiver, StaticsTreasuryVesting treasuryVesting)
    {
        receiver = new StaticsFeeReceiver(config.modules.poolInitializer, config.numeraire, initialOwner);
        treasuryVesting = new StaticsTreasuryVesting(initialOwner, config.governance, config.treasury);
    }

    function _deployGenesisCollection(
        address statics,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting,
        StaticsGenesisDeploymentConfig memory config,
        address initialOwner
    ) private returns (GenesisCollection memory collection) {
        collection.registry = new GenesisActivationRegistry(
            IERC20(statics), initialOwner, initialOwner, config.treasury
        );
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(receiver),
            treasury: config.treasury,
            originationFee: config.creditOriginationFee,
            extensionFee: config.creditExtensionFee,
            recoveryCallerShareBps: config.recoveryCallerShareBps
        });
        collection.vault = new StaticsGenesisVault(
            IERC20(statics), address(treasuryVesting), initialOwner, config.genesisEpochEnd, creditConfig
        );
        collection.avatar = new StaticsAvatarSVG();
        collection.renderer = new StaticsGenesisRenderer(collection.avatar);
        collection.genesis = new StaticsGenesis(
            address(collection.vault),
            address(treasuryVesting),
            address(collection.registry),
            collection.renderer,
            initialOwner,
            config.treasury,
            config.contractURI,
            config.externalURLBase
        );
    }

    function _deployDistributor(
        StaticsFeeReceiver receiver,
        StaticsGenesis genesis,
        GenesisActivationRegistry registry,
        StaticsGenesisDeploymentConfig memory config,
        address initialOwner
    ) private returns (GenesisLaunchDistributor distributor) {
        distributor = new GenesisLaunchDistributor(
            receiver, genesis, registry, config.treasury, initialOwner, config.genesisRewardShareBps
        );
    }

    /// @notice Canonical fully onchain URI used for every STATICS Doppler launch path.
    function staticsTokenURI() public pure returns (string memory) {
        return LibStaticsTokenMetadata.tokenURI();
    }

    /// @notice Six-curve Robinhood launch geometry pinned to the committed economics model.
    function defaultCurves() public pure returns (DopplerLaunchTypes.Curve[] memory curves) {
        curves = new DopplerLaunchTypes.Curve[](6);
        curves[0] =
            DopplerLaunchTypes.Curve({tickLower: -168_800, tickUpper: -153_800, numPositions: 11, shares: 0.025 ether});
        curves[1] =
            DopplerLaunchTypes.Curve({tickLower: -160_700, tickUpper: -139_900, numPositions: 11, shares: 0.075 ether});
        curves[2] =
            DopplerLaunchTypes.Curve({tickLower: -146_900, tickUpper: -123_800, numPositions: 11, shares: 0.125 ether});
        curves[3] =
            DopplerLaunchTypes.Curve({tickLower: -130_800, tickUpper: -100_800, numPositions: 11, shares: 0.2 ether});
        curves[4] =
            DopplerLaunchTypes.Curve({tickLower: -107_700, tickUpper: -77_800, numPositions: 11, shares: 0.425 ether});
        curves[5] =
            DopplerLaunchTypes.Curve({tickLower: -77_800, tickUpper: 887_200, numPositions: 1, shares: 0.15 ether});
    }

    function launchConfigHash(
        StaticsGenesisDeploymentConfig memory config,
        bytes32 wethRuntimeCodeHash,
        StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes
    ) public pure returns (bytes32) {
        bytes32 provenanceHash = keccak256(abi.encode(ROBINHOOD_MAINNET_CHAIN_ID, DOPPLER_SOURCE_REVISION));
        bytes32 fixedEconomicsHash = keccak256(
            abi.encode(
                STATICS_SUPPLY,
                DOPPLER_INVENTORY,
                PROTOCOL_ALLOCATION,
                _treasuryVestingHash(),
                NATIVE_ACQUISITION_FEE,
                GENESIS_CREDIT_MAX_PRINCIPAL,
                GENESIS_CREDIT_RECOVERY_RESIDUAL,
                GENESIS_CREDIT_TERM,
                GENESIS_CREDIT_RECOVERY_GRACE,
                GENESIS_CREDIT_INITIAL_RESERVE_SHARE_BPS,
                GENESIS_CREDIT_INITIAL_TREASURY_SHARE_BPS,
                DOPPLER_OWNER_SHARE,
                STATICS_FEE_SHARE
            )
        );
        bytes32 launchEconomicsHash = keccak256(
            abi.encode(
                config.fee,
                config.genesisRewardShareBps,
                config.reserveShareBps,
                config.creditOriginationFee,
                config.creditExtensionFee,
                config.recoveryCallerShareBps,
                config.genesisEpochEnd
            )
        );
        bytes32 authorityHash =
            keccak256(abi.encode(config.governance, config.treasury, config.integrator, config.salt));
        bytes32 dependencyHash =
            keccak256(abi.encode(config.numeraire, wethRuntimeCodeHash, config.modules, moduleCodeHashes));
        bytes32 marketHash = keccak256(
            abi.encode(
                TICK_SPACING, FAR_TICK, GOVERNANCE_DEAD, MIGRATION_DEAD, keccak256(_tokenFactoryData()), defaultCurves()
            )
        );
        bytes32 metadataHash = keccak256(
            abi.encode(
                keccak256(bytes("Statics")),
                keccak256(bytes("STATICS")),
                keccak256(bytes(LibStaticsTokenMetadata.tokenURI())),
                keccak256(bytes(config.contractURI)),
                keccak256(bytes(config.externalURLBase))
            )
        );
        return keccak256(
            abi.encode(
                provenanceHash,
                fixedEconomicsHash,
                launchEconomicsHash,
                authorityHash,
                dependencyHash,
                marketHash,
                metadataHash
            )
        );
    }

    function _treasuryVestingHash() private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TREASURY_GENESIS_COUNT,
                TREASURY_GENESIS_FIRST_ID,
                TREASURY_GENESIS_LAST_ID,
                GENESIS_BACKING,
                GENESIS_MAX_SUPPLY,
                TREASURY_GENESIS_BACKING,
                TREASURY_STATICS_VESTING_PRINCIPAL,
                TREASURY_VESTING_DURATION,
                TREASURY_GENESIS_RELEASE_BATCH
            )
        );
    }

    function _createDopplerMarket(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting
    ) private returns (address statics, bytes32 poolId) {
        IDopplerAirlock airlock = IDopplerAirlock(config.modules.airlock);
        DopplerLaunchTypes.CreateParams memory params = _dopplerCreateParams(config, receiver, treasuryVesting);

        statics = _launchThroughAirlock(airlock, params, treasuryVesting);
        _assertPostLaunchSupply(statics, treasuryVesting);
        poolId = _poolId(statics, config.numeraire, config.modules.poolInitializer, config.fee);
    }

    function _dopplerCreateParams(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting
    ) private view returns (DopplerLaunchTypes.CreateParams memory params) {
        DopplerLaunchTypes.BeneficiaryData[] memory poolBeneficiaries = new DopplerLaunchTypes.BeneficiaryData[](2);
        address dopplerOwner = IDopplerAirlock(config.modules.airlock).owner();
        DopplerLaunchTypes.BeneficiaryData memory ownerBeneficiary =
            DopplerLaunchTypes.BeneficiaryData({beneficiary: dopplerOwner, shares: DOPPLER_OWNER_SHARE});
        DopplerLaunchTypes.BeneficiaryData memory staticsBeneficiary =
            DopplerLaunchTypes.BeneficiaryData({beneficiary: address(receiver), shares: STATICS_FEE_SHARE});
        if (dopplerOwner < address(receiver)) {
            poolBeneficiaries[0] = ownerBeneficiary;
            poolBeneficiaries[1] = staticsBeneficiary;
        } else {
            poolBeneficiaries[0] = staticsBeneficiary;
            poolBeneficiaries[1] = ownerBeneficiary;
        }
        bytes memory poolData = abi.encode(
            DopplerLaunchTypes.PoolInitializerData({
                fee: config.fee,
                tickSpacing: TICK_SPACING,
                farTick: FAR_TICK,
                curves: defaultCurves(),
                beneficiaries: poolBeneficiaries,
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: bytes(""),
                graduationDopplerHookCalldata: bytes("")
            })
        );

        params = DopplerLaunchTypes.CreateParams({
            initialSupply: STATICS_SUPPLY,
            numTokensToSell: DOPPLER_INVENTORY,
            numeraire: config.numeraire,
            tokenFactory: config.modules.tokenFactory,
            tokenFactoryData: _tokenFactoryData(),
            governanceFactory: config.modules.governanceFactory,
            governanceFactoryData: abi.encode(address(treasuryVesting)),
            poolInitializer: config.modules.poolInitializer,
            poolInitializerData: poolData,
            liquidityMigrator: config.modules.noOpMigrator,
            liquidityMigratorData: bytes(""),
            integrator: config.integrator,
            salt: config.salt
        });
    }

    function _launchThroughAirlock(
        IDopplerAirlock airlock,
        DopplerLaunchTypes.CreateParams memory params,
        StaticsTreasuryVesting treasuryVesting
    ) private returns (address statics) {
        address pool;
        address governance;
        address timelock;
        address migrationPool;
        (statics, pool, governance, timelock, migrationPool) = airlock.create(params);
        if (
            pool != statics || governance != GOVERNANCE_DEAD || timelock != address(treasuryVesting)
                || migrationPool != MIGRATION_DEAD
        ) {
            revert UnexpectedDopplerResult(pool, governance, timelock, migrationPool);
        }
    }

    function _assertPostLaunchSupply(address statics, StaticsTreasuryVesting treasuryVesting) private view {
        uint256 totalSupply = IERC20(statics).totalSupply();
        uint256 vestingBalance = IERC20(statics).balanceOf(address(treasuryVesting));
        if (totalSupply != STATICS_SUPPLY || vestingBalance < PROTOCOL_ALLOCATION) {
            revert AllocationMismatch(totalSupply, vestingBalance);
        }
        uint256 residual = vestingBalance - PROTOCOL_ALLOCATION;
        if (residual > MAX_MULTICURVE_RESIDUAL) {
            revert ExcessiveMulticurveResidual(residual, MAX_MULTICURVE_RESIDUAL);
        }
    }

    function _tokenFactoryData() private pure returns (bytes memory) {
        return abi.encode(
            "Statics",
            "STATICS",
            new DopplerLaunchTypes.VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            LibStaticsTokenMetadata.tokenURI(),
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );
    }

    function _poolId(address statics, address numeraire, address initializer, uint24 fee)
        private
        pure
        returns (bytes32)
    {
        (address currency0, address currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
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
        if (block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) {
            _validateRobinhoodWeth(config.numeraire);
            _validateRobinhoodDopplerModules(config.modules);
        }
        _requireContract(config.modules.airlock);
        _requireContract(config.modules.tokenFactory);
        _requireContract(config.modules.governanceFactory);
        _requireContract(config.modules.poolInitializer);
        _requireContract(config.modules.noOpMigrator);
        if (bytes(config.contractURI).length == 0 || bytes(config.externalURLBase).length == 0) {
            revert InvalidMetadataURI();
        }
        if (config.fee == 0 || config.fee > MAX_DOPPLER_LP_FEE) revert InvalidFee(config.fee);
        if (config.genesisRewardShareBps > 10_000) revert InvalidRewardShare(config.genesisRewardShareBps);
        if (config.reserveShareBps > 10_000) revert InvalidReserveShare(config.reserveShareBps);
        if (config.recoveryCallerShareBps == 0 || config.recoveryCallerShareBps >= 10_000) {
            revert InvalidRecoveryCallerShare(config.recoveryCallerShareBps);
        }
        if (config.genesisEpochEnd <= block.timestamp) revert InvalidEpochEnd(config.genesisEpochEnd);
    }

    function _validateRobinhoodWeth(address configuredWeth) private view returns (bytes32 expectedCodeHash) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(ROBINHOOD_MAINNET_CHAIN_ID));
        address expectedWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        if (configuredWeth != expectedWeth) revert InvalidRobinhoodWeth(expectedWeth, configuredWeth);
        expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash");
        bytes32 actualCodeHash = configuredWeth.codehash;
        if (actualCodeHash != expectedCodeHash) revert InvalidRobinhoodWethCodeHash(expectedCodeHash, actualCodeHash);
    }

    function _validateRobinhoodDopplerModules(StaticsDopplerLaunchConfig.Modules memory modules)
        private
        view
        returns (StaticsDopplerLaunchConfig.RuntimeCodeHashes memory codeHashes)
    {
        string memory manifest = vm.readFile(_robinhoodManifestPath(ROBINHOOD_MAINNET_CHAIN_ID));
        codeHashes.airlock = _validateRobinhoodDependency(manifest, ".contracts.dopplerAirlock", modules.airlock);
        codeHashes.tokenFactory =
            _validateRobinhoodDependency(manifest, ".contracts.dopplerTokenFactory", modules.tokenFactory);
        codeHashes.governanceFactory =
            _validateRobinhoodDependency(manifest, ".contracts.dopplerGovernanceFactory", modules.governanceFactory);
        codeHashes.poolInitializer =
            _validateRobinhoodDependency(manifest, ".contracts.dopplerPoolInitializer", modules.poolInitializer);
        codeHashes.noOpMigrator =
            _validateRobinhoodDependency(manifest, ".contracts.dopplerNoOpMigrator", modules.noOpMigrator);
    }

    function _validateRobinhoodDependency(string memory manifest, string memory path, address configured)
        private
        view
        returns (bytes32 expectedCodeHash)
    {
        address expected = vm.parseJsonAddress(manifest, string.concat(path, ".address"));
        if (configured != expected) revert InvalidRobinhoodDependency(expected, configured);
        expectedCodeHash = vm.parseJsonBytes32(manifest, string.concat(path, ".runtimeCodeHash"));
        bytes32 actualCodeHash = configured.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidRobinhoodDependencyCodeHash(configured, expectedCodeHash, actualCodeHash);
        }
    }

    function _requireContract(address target) private view {
        if (target.code.length == 0) revert InvalidModule(target);
    }

    function _log(StaticsGenesisDeployment memory deployment) internal pure {
        console2.log("STATICS_TOKEN_ADDRESS", deployment.statics);
        console2.log("STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS", deployment.dopplerPoolInitializer);
        console2.log("STATICS_DOPPLER_POOL_ID");
        console2.logBytes32(deployment.poolId);
        console2.log("STATICS_FEE_RECEIVER_ADDRESS", deployment.feeReceiver);
        console2.log("STATICS_TREASURY_VESTING_ADDRESS", deployment.treasuryVesting);
        console2.log("STATICS_GENESIS_ACTIVATION_REGISTRY_ADDRESS", deployment.activationRegistry);
        console2.log("STATICS_GENESIS_NFT_ADDRESS", deployment.genesis);
        console2.log("STATICS_GENESIS_VAULT_ADDRESS", deployment.genesisVault);
        console2.log("STATICS_GENESIS_DISTRIBUTOR_ADDRESS", deployment.genesisDistributor);
        console2.log("STATICS_GENESIS_RENDERER_ADDRESS", deployment.genesisRenderer);
        console2.log("STATICS_GENESIS_AVATAR_SVG_ADDRESS", deployment.avatarSVG);
    }
}
