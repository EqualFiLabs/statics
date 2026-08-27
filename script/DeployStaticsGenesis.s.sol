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
import {StaticsFeeReceiver, IDopplerFeeSource} from "../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../src/genesis/StaticsGenesisVault.sol";
import {StaticsTreasuryVesting} from "../src/genesis/StaticsTreasuryVesting.sol";
import {
    DopplerLaunchTypes,
    IDopplerAirlock,
    IDopplerERC20V1,
    IDopplerERC20V1Factory
} from "../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsLaunchCurves} from "../src/genesis/doppler/StaticsLaunchCurves.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";
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
    /// @dev ERC20 token metadata URI passed through to Doppler's token factory.
    string tokenURI;
    /// @dev ERC-7572 collection metadata URI for the Genesis NFT collection.
    string contractURI;
    string externalURLBase;
}

struct StaticsGenesisLaunchArtifact {
    uint256 schemaVersion;
    uint256 chainId;
    address deployer;
    address airlock;
    uint256 transactionValue;
    uint256 expectedLaunchNonce;
    StaticsGenesisDeploymentConfig config;
    address feeReceiver;
    address treasuryVesting;
    bytes32 feeReceiverRuntimeCodeHash;
    bytes32 treasuryVestingRuntimeCodeHash;
    bytes32 wethDependencyHash;
    StaticsDopplerLaunchConfig.RuntimeCodeHashes moduleCodeHashes;
    address dopplerOwner;
    uint96 dopplerOwnerShare;
    uint96 staticsFeeShare;
    bytes32 dopplerSourceRevision;
    bytes32 launchScriptCodeHash;
    bytes32 staticsImplementationHash;
    bytes32 launchConfigHash;
    bytes32 marketCommitment;
    address tokenImplementation;
    bytes32 tokenImplementationCodeHash;
    address expectedStatics;
    bytes32 expectedPoolId;
    bytes createParams;
    bytes createCalldata;
    bytes32 createCalldataHash;
    bytes32 artifactHash;
}

struct StaticsGenesisMarket {
    address statics;
    address pool;
    address governance;
    address timelock;
    address migrationPool;
    bytes32 poolId;
}

struct DopplerAssetData {
    address numeraire;
    address timelock;
    address governance;
    address liquidityMigrator;
    address poolInitializer;
    address pool;
    address migrationPool;
    uint256 numTokensToSell;
    uint256 totalSupply;
    address integrator;
}

struct StaticsGenesisLaunchCommitments {
    uint256 expectedLaunchNonce;
    bytes32 wethDependencyHash;
    StaticsDopplerLaunchConfig.RuntimeCodeHashes moduleCodeHashes;
    bytes32 launchConfigHash;
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

/// @dev Groups the Genesis collection contracts returned by the launcher.
struct GenesisCollection {
    GenesisActivationRegistry registry;
    StaticsGenesisVault vault;
    StaticsAvatarSVG avatar;
    StaticsGenesisRenderer renderer;
    StaticsGenesis genesis;
}

interface IProxyAdminOwner {
    function owner() external view returns (address);
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
    bytes20 public constant DOPPLER_SOURCE_REVISION = hex"86a5200456b148c156d2eb81a893747dd601c3ca";
    string public constant STATICS_TOKEN_URI = "ipfs://Qmb9a5F2iNCBc2kCveJaDY7rPw5ycZNt7W6tVDX9uuunFR";
    string public constant STATICS_GENESIS_CONTRACT_URI =
        "data:application/json;utf8,%7B%22name%22%3A%22STATICS%20Operators%22%2C%22symbol%22%3A%22STATOPS%22%2C%22description%22%3A%225%2C555%20deterministic%20onchain%20Genesis%20identities%20powering%20the%20STATICS%20protocol.%20Each%20STATICS%20Operator%20carries%20a%20180%2C000%20STATICS%20backing%20claim%2C%20evolving%20activation%20tiers%2C%20native%20artwork%2C%20and%20access%20to%20protocol%20reserve%20and%20reward%20flows.%22%2C%22external_link%22%3A%22https%3A%2F%2Fstaticsprotocol.com%22%7D";
    string public constant STATICS_GENESIS_EXTERNAL_URL_BASE = "https://staticsprotocol.com/genesis/";
    /// @dev Production execution remains disabled until this equals the ratified launch hash.
    bytes32 public constant APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH = bytes32(0);
    int24 public constant TICK_SPACING = 100;
    int24 public constant FAR_TICK = StaticsLaunchCurves.FAR_TICK;
    address public constant GOVERNANCE_DEAD = address(0xdead);
    address public constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    uint256 public constant LAUNCH_ARTIFACT_SCHEMA = 1;
    bytes20 private constant CLONE_INIT_CODE_PREFIX = hex"602c3d8160093d39f33d3d3d3d363d3d37363d73";
    bytes13 private constant CLONE_INIT_CODE_SUFFIX = hex"5af43d3d93803e602a57fd5bf3";

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
    error AllocationMismatch(uint256 totalSupply, uint256 bootstrapBalance);

    error InvalidLaunchArtifactSchema(uint256 expected, uint256 actual);
    error InvalidLaunchArtifactHash(bytes32 expected, bytes32 actual);
    error LaunchArtifactMismatch();
    error InvalidPreparedReceiver(address receiver);
    error InvalidPreparedVesting(address vesting);
    error UnexpectedDeployer(address expected, address actual);
    error UnexpectedDeployerNonce(uint256 expected, uint256 actual);
    error MarketAlreadyLaunched(address statics);
    error MarketNotLaunched(address statics);
    error UnexpectedLaunchState(address statics);
    error UnexpectedFinalizeState(address target);

    function runPrepare() external returns (bytes32 artifactHash) {
        _beforeProductionEntryPoint();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        string memory path = vm.envString("STATICS_GENESIS_LAUNCH_ARTIFACT");
        StaticsGenesisDeploymentConfig memory config = _loadDeploymentConfig();
        _validate(config, deployer);

        (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
            _dependencyCommitments(config);
        bytes32 currentHash = launchConfigHash(config, wethDependencyHash, moduleCodeHashes);
        if (block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) _requireApprovedProductionConfig(currentHash);

        uint256 startingNonce = vm.getNonce(deployer);
        vm.startBroadcast(privateKey);
        (StaticsFeeReceiver receiver, StaticsTreasuryVesting treasuryVesting) = _deployLaunchReceivers(config, deployer);
        vm.stopBroadcast();

        if (address(receiver) != vm.computeCreateAddress(deployer, startingNonce)) {
            revert InvalidPreparedReceiver(address(receiver));
        }
        if (address(treasuryVesting) != vm.computeCreateAddress(deployer, startingNonce + 1)) {
            revert InvalidPreparedVesting(address(treasuryVesting));
        }
        uint256 expectedLaunchNonce = startingNonce + 2;
        uint256 liveNonce = vm.getNonce(deployer);
        if (liveNonce != expectedLaunchNonce) revert UnexpectedDeployerNonce(expectedLaunchNonce, liveNonce);

        StaticsGenesisLaunchCommitments memory commitments = StaticsGenesisLaunchCommitments({
            expectedLaunchNonce: expectedLaunchNonce,
            wethDependencyHash: wethDependencyHash,
            moduleCodeHashes: moduleCodeHashes,
            launchConfigHash: currentHash
        });
        StaticsGenesisLaunchArtifact memory artifact =
            _buildLaunchArtifact(config, deployer, receiver, treasuryVesting, commitments);
        writeLaunchArtifact(path, artifact);
        artifactHash = artifact.artifactHash;
        console2.log("STATICS_GENESIS_LAUNCH_ARTIFACT", path);
        console2.log("STATICS_GENESIS_LAUNCH_ARTIFACT_HASH");
        console2.logBytes32(artifactHash);
    }

    function runLaunch() external returns (StaticsGenesisMarket memory market) {
        _beforeProductionEntryPoint();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        StaticsGenesisLaunchArtifact memory artifact =
            loadLaunchArtifact(vm.envString("STATICS_GENESIS_LAUNCH_ARTIFACT"));
        if (signer != artifact.deployer) revert UnexpectedDeployer(artifact.deployer, signer);
        uint256 liveNonce = vm.getNonce(signer);
        if (liveNonce != artifact.expectedLaunchNonce) {
            revert UnexpectedDeployerNonce(artifact.expectedLaunchNonce, liveNonce);
        }
        validatePreparedLaunch(artifact);
        DopplerLaunchTypes.CreateParams memory params =
            abi.decode(artifact.createParams, (DopplerLaunchTypes.CreateParams));

        vm.broadcast(privateKey);
        market = _executeLaunch(artifact, params);
    }

    function runFinalize() external returns (StaticsGenesisDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        StaticsGenesisLaunchArtifact memory artifact =
            loadLaunchArtifact(vm.envString("STATICS_GENESIS_LAUNCH_ARTIFACT"));
        if (signer != artifact.deployer) revert UnexpectedDeployer(artifact.deployer, signer);
        uint256 expectedNonce = artifact.expectedLaunchNonce + 1;
        uint256 liveNonce = vm.getNonce(signer);
        if (liveNonce != expectedNonce) revert UnexpectedDeployerNonce(expectedNonce, liveNonce);
        validateLaunchedMarket(artifact);

        vm.startBroadcast(privateKey);
        deployment = _finalizeGenesis(artifact, signer);
        vm.stopBroadcast();
        _assertFinalized(artifact, deployment);
        _log(deployment);
    }

    function prepare(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        public
        returns (StaticsFeeReceiver receiver, StaticsTreasuryVesting treasuryVesting)
    {
        _validate(config, initialOwner);
        return _deployLaunchReceivers(config, initialOwner);
    }

    function launch(StaticsGenesisLaunchArtifact memory artifact) public returns (StaticsGenesisMarket memory market) {
        _validatePreparedLaunch(artifact, false);
        DopplerLaunchTypes.CreateParams memory params =
            abi.decode(artifact.createParams, (DopplerLaunchTypes.CreateParams));
        market = _executeLaunch(artifact, params);
    }

    function finalize(StaticsGenesisLaunchArtifact memory artifact)
        public
        returns (StaticsGenesisDeployment memory deployment)
    {
        validateLaunchedMarket(artifact);
        deployment = _finalizeGenesis(artifact, artifact.deployer);
        _assertFinalized(artifact, deployment);
    }

    function deploy(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        public
        returns (StaticsGenesisDeployment memory deployment)
    {
        (StaticsFeeReceiver receiver, StaticsTreasuryVesting treasuryVesting) = prepare(config, initialOwner);
        (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
            _dependencyCommitments(config);
        bytes32 currentHash = launchConfigHash(config, wethDependencyHash, moduleCodeHashes);
        StaticsGenesisLaunchCommitments memory commitments = StaticsGenesisLaunchCommitments({
            expectedLaunchNonce: vm.getNonce(initialOwner),
            wethDependencyHash: wethDependencyHash,
            moduleCodeHashes: moduleCodeHashes,
            launchConfigHash: currentHash
        });
        StaticsGenesisLaunchArtifact memory artifact =
            _buildLaunchArtifact(config, initialOwner, receiver, treasuryVesting, commitments);
        launch(artifact);
        deployment = finalize(artifact);
    }

    function _finalizeGenesis(StaticsGenesisLaunchArtifact memory artifact, address initialOwner)
        private
        returns (StaticsGenesisDeployment memory deployment)
    {
        StaticsGenesisDeploymentConfig memory config = artifact.config;
        StaticsFeeReceiver receiver = StaticsFeeReceiver(payable(artifact.feeReceiver));
        StaticsTreasuryVesting treasuryVesting = StaticsTreasuryVesting(artifact.treasuryVesting);
        receiver.bindMarket(artifact.expectedStatics, artifact.expectedPoolId);

        GenesisCollection memory collection =
            _deployGenesisCollection(artifact.expectedStatics, receiver, treasuryVesting, config, initialOwner);
        collection.registry.bindGenesisCollection(address(collection.genesis));
        treasuryVesting.finalizeBootstrap(
            artifact.expectedStatics, address(collection.vault), address(collection.genesis)
        );

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

        deployment.statics = artifact.expectedStatics;
        deployment.dopplerPoolInitializer = config.modules.poolInitializer;
        deployment.poolId = artifact.expectedPoolId;
        deployment.feeReceiver = artifact.feeReceiver;
        deployment.treasuryVesting = artifact.treasuryVesting;
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

    function _loadDeploymentConfig() private view returns (StaticsGenesisDeploymentConfig memory config) {
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
        config = StaticsGenesisDeploymentConfig({
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
            contractURI: staticsGenesisContractURI(),
            externalURLBase: staticsGenesisExternalURLBase()
        });
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

    /// @notice Canonical IPFS metadata URI used for the production STATICS Doppler launch.
    function staticsTokenURI() public pure returns (string memory) {
        return STATICS_TOKEN_URI;
    }

    /// @notice Canonical onchain ERC-7572 collection metadata for Statics Operators.
    function staticsGenesisContractURI() public pure returns (string memory) {
        return STATICS_GENESIS_CONTRACT_URI;
    }

    /// @notice Canonical token-page base; the Genesis token ID is appended directly.
    function staticsGenesisExternalURLBase() public pure returns (string memory) {
        return STATICS_GENESIS_EXTERNAL_URL_BASE;
    }

    /// @notice Six-curve Robinhood launch geometry pinned to the committed economics model.
    function defaultCurves() public pure returns (DopplerLaunchTypes.Curve[] memory curves) {
        return StaticsLaunchCurves.defaultCurves();
    }

    /// @notice Commitment to every Statics contract created by this launcher.
    /// @dev Creation code binds compiler output and constructor logic; constructor values are
    ///      committed separately by `launchConfigHash`.
    function staticsImplementationHash() public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(type(StaticsFeeReceiver).creationCode),
                keccak256(type(StaticsTreasuryVesting).creationCode),
                keccak256(type(GenesisActivationRegistry).creationCode),
                keccak256(type(StaticsGenesisVault).creationCode),
                keccak256(type(StaticsAvatarSVG).creationCode),
                keccak256(type(StaticsGenesisRenderer).creationCode),
                keccak256(type(StaticsGenesis).creationCode),
                keccak256(type(GenesisLaunchDistributor).creationCode)
            )
        );
    }

    function launchScriptCodeHash() public view virtual returns (bytes32) {
        return keccak256(vm.getDeployedCode("script/DeployStaticsGenesis.s.sol:DeployStaticsGenesis"));
    }

    function launchArtifactHash(StaticsGenesisLaunchArtifact memory artifact) public pure returns (bytes32 hash) {
        bytes32 storedHash = artifact.artifactHash;
        artifact.artifactHash = bytes32(0);
        hash = keccak256(abi.encode(artifact));
        artifact.artifactHash = storedHash;
    }

    function expectedStaticsAddress(StaticsGenesisDeploymentConfig memory config)
        public
        view
        returns (address expectedStatics, address implementation)
    {
        implementation = IDopplerERC20V1Factory(config.modules.tokenFactory).IMPLEMENTATION();
        if (implementation == address(0) || implementation.code.length == 0) {
            revert InvalidModule(implementation);
        }
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(CLONE_INIT_CODE_PREFIX, implementation, CLONE_INIT_CODE_SUFFIX));
        expectedStatics = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), config.modules.tokenFactory, config.salt, initCodeHash))
                )
            )
        );
    }

    function _dependencyCommitments(StaticsGenesisDeploymentConfig memory config)
        internal
        view
        returns (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes)
    {
        if (block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) {
            wethDependencyHash = _validateRobinhoodWeth(config.numeraire);
            moduleCodeHashes = _validateRobinhoodDopplerModules(config.modules);
        } else {
            wethDependencyHash = keccak256(abi.encode(config.numeraire, config.numeraire.codehash));
            moduleCodeHashes = StaticsDopplerLaunchConfig.RuntimeCodeHashes({
                airlock: config.modules.airlock.codehash,
                tokenFactory: config.modules.tokenFactory.codehash,
                governanceFactory: config.modules.governanceFactory.codehash,
                poolInitializer: config.modules.poolInitializer.codehash,
                noOpMigrator: config.modules.noOpMigrator.codehash
            });
        }
    }

    function _buildLaunchArtifact(
        StaticsGenesisDeploymentConfig memory config,
        address deployer,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting,
        StaticsGenesisLaunchCommitments memory commitments
    ) internal view returns (StaticsGenesisLaunchArtifact memory artifact) {
        _assertPreparedContracts(config, deployer, address(receiver), address(treasuryVesting));
        DopplerLaunchTypes.CreateParams memory params = _dopplerCreateParams(config, receiver, treasuryVesting);
        (address expectedStatics, address tokenImplementation) = expectedStaticsAddress(config);
        bytes32 expectedPoolId = _poolId(expectedStatics, config.numeraire, config.modules.poolInitializer, config.fee);
        bytes memory encodedParams = abi.encode(params);
        bytes memory createCalldata = abi.encodeCall(IDopplerAirlock.create, (params));

        artifact.schemaVersion = LAUNCH_ARTIFACT_SCHEMA;
        artifact.chainId = block.chainid;
        artifact.deployer = deployer;
        artifact.airlock = config.modules.airlock;
        artifact.transactionValue = 0;
        artifact.expectedLaunchNonce = commitments.expectedLaunchNonce;
        artifact.config = config;
        artifact.feeReceiver = address(receiver);
        artifact.treasuryVesting = address(treasuryVesting);
        artifact.feeReceiverRuntimeCodeHash = address(receiver).codehash;
        artifact.treasuryVestingRuntimeCodeHash = address(treasuryVesting).codehash;
        artifact.wethDependencyHash = commitments.wethDependencyHash;
        artifact.moduleCodeHashes = commitments.moduleCodeHashes;
        artifact.dopplerOwner = IDopplerAirlock(config.modules.airlock).owner();
        artifact.dopplerOwnerShare = DOPPLER_OWNER_SHARE;
        artifact.staticsFeeShare = STATICS_FEE_SHARE;
        artifact.dopplerSourceRevision = bytes32(DOPPLER_SOURCE_REVISION);
        artifact.launchScriptCodeHash = launchScriptCodeHash();
        artifact.staticsImplementationHash = staticsImplementationHash();
        artifact.launchConfigHash = commitments.launchConfigHash;
        artifact.tokenImplementation = tokenImplementation;
        artifact.tokenImplementationCodeHash = tokenImplementation.codehash;
        artifact.expectedStatics = expectedStatics;
        artifact.expectedPoolId = expectedPoolId;
        artifact.createParams = encodedParams;
        artifact.createCalldata = createCalldata;
        artifact.createCalldataHash = keccak256(createCalldata);
        artifact.marketCommitment = keccak256(abi.encode(params, expectedStatics, expectedPoolId));
        artifact.artifactHash = launchArtifactHash(artifact);
    }

    function launchConfigHash(
        StaticsGenesisDeploymentConfig memory config,
        bytes32 wethDependencyHash,
        StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes
    ) public view returns (bytes32) {
        return _launchConfigHash(
            config, wethDependencyHash, moduleCodeHashes, IDopplerAirlock(config.modules.airlock).owner()
        );
    }

    function _launchConfigHash(
        StaticsGenesisDeploymentConfig memory config,
        bytes32 wethDependencyHash,
        StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes,
        address dopplerOwner
    ) internal pure returns (bytes32) {
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
            keccak256(abi.encode(config.governance, config.treasury, config.integrator, dopplerOwner, config.salt));
        bytes32 dependencyHash =
            keccak256(abi.encode(config.numeraire, wethDependencyHash, config.modules, moduleCodeHashes));
        bytes32 marketHash = _marketHash(config.tokenURI, config.treasury);
        bytes32 metadataHash = keccak256(
            abi.encode(
                keccak256(bytes("Statics")),
                keccak256(bytes("STATICS")),
                keccak256(bytes(config.tokenURI)),
                keccak256(bytes(config.contractURI)),
                keccak256(bytes(config.externalURLBase))
            )
        );
        return keccak256(
            abi.encode(
                provenanceHash,
                staticsImplementationHash(),
                fixedEconomicsHash,
                launchEconomicsHash,
                authorityHash,
                dependencyHash,
                marketHash,
                metadataHash
            )
        );
    }

    function _marketHash(string memory tokenURI, address treasury) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TICK_SPACING,
                FAR_TICK,
                GOVERNANCE_DEAD,
                MIGRATION_DEAD,
                keccak256(_tokenFactoryData(tokenURI, treasury)),
                defaultCurves()
            )
        );
    }

    function writeLaunchArtifact(string memory path, StaticsGenesisLaunchArtifact memory artifact) public {
        artifact.artifactHash = launchArtifactHash(artifact);
        _assertArtifactIntegrity(artifact);
        string memory objectKey = "statics-genesis-launch";
        string memory json = vm.serializeUint(objectKey, "schemaVersion", artifact.schemaVersion);
        json = vm.serializeUint(objectKey, "chainId", artifact.chainId);
        json = vm.serializeAddress(objectKey, "deployer", artifact.deployer);
        json = vm.serializeAddress(objectKey, "airlock", artifact.airlock);
        json = vm.serializeUint(objectKey, "transactionValue", artifact.transactionValue);
        json = vm.serializeUint(objectKey, "expectedLaunchNonce", artifact.expectedLaunchNonce);
        json = vm.serializeAddress(objectKey, "governance", artifact.config.governance);
        json = vm.serializeAddress(objectKey, "treasury", artifact.config.treasury);
        json = vm.serializeAddress(objectKey, "numeraire", artifact.config.numeraire);
        json = vm.serializeAddress(objectKey, "integrator", artifact.config.integrator);
        json = vm.serializeAddress(objectKey, "moduleAirlock", artifact.config.modules.airlock);
        json = vm.serializeAddress(objectKey, "moduleTokenFactory", artifact.config.modules.tokenFactory);
        json = vm.serializeAddress(objectKey, "moduleGovernanceFactory", artifact.config.modules.governanceFactory);
        json = vm.serializeAddress(objectKey, "modulePoolInitializer", artifact.config.modules.poolInitializer);
        json = vm.serializeAddress(objectKey, "moduleNoOpMigrator", artifact.config.modules.noOpMigrator);
        json = vm.serializeBytes32(objectKey, "salt", artifact.config.salt);
        json = vm.serializeUint(objectKey, "fee", artifact.config.fee);
        json = vm.serializeUint(objectKey, "genesisRewardShareBps", artifact.config.genesisRewardShareBps);
        json = vm.serializeUint(objectKey, "reserveShareBps", artifact.config.reserveShareBps);
        json = vm.serializeUint(objectKey, "creditOriginationFee", artifact.config.creditOriginationFee);
        json = vm.serializeUint(objectKey, "creditExtensionFee", artifact.config.creditExtensionFee);
        json = vm.serializeUint(objectKey, "recoveryCallerShareBps", artifact.config.recoveryCallerShareBps);
        json = vm.serializeUint(objectKey, "genesisEpochEnd", artifact.config.genesisEpochEnd);
        json = vm.serializeString(objectKey, "tokenURI", artifact.config.tokenURI);
        json = vm.serializeString(objectKey, "contractURI", artifact.config.contractURI);
        json = vm.serializeString(objectKey, "externalURLBase", artifact.config.externalURLBase);
        json = vm.serializeAddress(objectKey, "feeReceiver", artifact.feeReceiver);
        json = vm.serializeAddress(objectKey, "treasuryVesting", artifact.treasuryVesting);
        json = vm.serializeBytes32(objectKey, "feeReceiverRuntimeCodeHash", artifact.feeReceiverRuntimeCodeHash);
        json = vm.serializeBytes32(objectKey, "treasuryVestingRuntimeCodeHash", artifact.treasuryVestingRuntimeCodeHash);
        json = vm.serializeBytes32(objectKey, "wethDependencyHash", artifact.wethDependencyHash);
        json = vm.serializeBytes32(objectKey, "moduleAirlockRuntimeCodeHash", artifact.moduleCodeHashes.airlock);
        json =
            vm.serializeBytes32(objectKey, "moduleTokenFactoryRuntimeCodeHash", artifact.moduleCodeHashes.tokenFactory);
        json = vm.serializeBytes32(
            objectKey, "moduleGovernanceFactoryRuntimeCodeHash", artifact.moduleCodeHashes.governanceFactory
        );
        json = vm.serializeBytes32(
            objectKey, "modulePoolInitializerRuntimeCodeHash", artifact.moduleCodeHashes.poolInitializer
        );
        json =
            vm.serializeBytes32(objectKey, "moduleNoOpMigratorRuntimeCodeHash", artifact.moduleCodeHashes.noOpMigrator);
        json = vm.serializeAddress(objectKey, "dopplerOwner", artifact.dopplerOwner);
        json = vm.serializeUint(objectKey, "dopplerOwnerShare", artifact.dopplerOwnerShare);
        json = vm.serializeUint(objectKey, "staticsFeeShare", artifact.staticsFeeShare);
        json = vm.serializeBytes32(objectKey, "dopplerSourceRevision", artifact.dopplerSourceRevision);
        json = vm.serializeBytes32(objectKey, "launchScriptCodeHash", artifact.launchScriptCodeHash);
        json = vm.serializeBytes32(objectKey, "staticsImplementationHash", artifact.staticsImplementationHash);
        json = vm.serializeBytes32(objectKey, "launchConfigHash", artifact.launchConfigHash);
        json = vm.serializeBytes32(objectKey, "marketCommitment", artifact.marketCommitment);
        json = vm.serializeAddress(objectKey, "tokenImplementation", artifact.tokenImplementation);
        json = vm.serializeBytes32(objectKey, "tokenImplementationCodeHash", artifact.tokenImplementationCodeHash);
        json = vm.serializeAddress(objectKey, "expectedStatics", artifact.expectedStatics);
        json = vm.serializeBytes32(objectKey, "expectedPoolId", artifact.expectedPoolId);
        json = vm.serializeBytes(objectKey, "createParams", artifact.createParams);
        json = vm.serializeBytes(objectKey, "createCalldata", artifact.createCalldata);
        json = vm.serializeBytes32(objectKey, "createCalldataHash", artifact.createCalldataHash);
        json = vm.serializeBytes32(objectKey, "artifactHash", artifact.artifactHash);
        vm.writeJson(json, path);
    }

    function loadLaunchArtifact(string memory path) public view returns (StaticsGenesisLaunchArtifact memory artifact) {
        string memory json = vm.readFile(path);
        artifact.schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        if (artifact.schemaVersion != LAUNCH_ARTIFACT_SCHEMA) {
            revert InvalidLaunchArtifactSchema(LAUNCH_ARTIFACT_SCHEMA, artifact.schemaVersion);
        }
        artifact.chainId = vm.parseJsonUint(json, ".chainId");
        artifact.deployer = vm.parseJsonAddress(json, ".deployer");
        artifact.airlock = vm.parseJsonAddress(json, ".airlock");
        artifact.transactionValue = vm.parseJsonUint(json, ".transactionValue");
        artifact.expectedLaunchNonce = vm.parseJsonUint(json, ".expectedLaunchNonce");
        artifact.config.governance = vm.parseJsonAddress(json, ".governance");
        artifact.config.treasury = vm.parseJsonAddress(json, ".treasury");
        artifact.config.numeraire = vm.parseJsonAddress(json, ".numeraire");
        artifact.config.integrator = vm.parseJsonAddress(json, ".integrator");
        artifact.config.modules = StaticsDopplerLaunchConfig.Modules({
            airlock: vm.parseJsonAddress(json, ".moduleAirlock"),
            tokenFactory: vm.parseJsonAddress(json, ".moduleTokenFactory"),
            governanceFactory: vm.parseJsonAddress(json, ".moduleGovernanceFactory"),
            poolInitializer: vm.parseJsonAddress(json, ".modulePoolInitializer"),
            noOpMigrator: vm.parseJsonAddress(json, ".moduleNoOpMigrator")
        });
        artifact.config.salt = vm.parseJsonBytes32(json, ".salt");
        artifact.config.fee = _artifactUint24(vm.parseJsonUint(json, ".fee"));
        artifact.config.genesisRewardShareBps = _artifactUint16(vm.parseJsonUint(json, ".genesisRewardShareBps"));
        artifact.config.reserveShareBps = _artifactUint16(vm.parseJsonUint(json, ".reserveShareBps"));
        artifact.config.creditOriginationFee = vm.parseJsonUint(json, ".creditOriginationFee");
        artifact.config.creditExtensionFee = vm.parseJsonUint(json, ".creditExtensionFee");
        artifact.config.recoveryCallerShareBps = _artifactUint16(vm.parseJsonUint(json, ".recoveryCallerShareBps"));
        artifact.config.genesisEpochEnd = vm.parseJsonUint(json, ".genesisEpochEnd");
        artifact.config.tokenURI = vm.parseJsonString(json, ".tokenURI");
        artifact.config.contractURI = vm.parseJsonString(json, ".contractURI");
        artifact.config.externalURLBase = vm.parseJsonString(json, ".externalURLBase");
        artifact.feeReceiver = vm.parseJsonAddress(json, ".feeReceiver");
        artifact.treasuryVesting = vm.parseJsonAddress(json, ".treasuryVesting");
        artifact.feeReceiverRuntimeCodeHash = vm.parseJsonBytes32(json, ".feeReceiverRuntimeCodeHash");
        artifact.treasuryVestingRuntimeCodeHash = vm.parseJsonBytes32(json, ".treasuryVestingRuntimeCodeHash");
        artifact.wethDependencyHash = vm.parseJsonBytes32(json, ".wethDependencyHash");
        artifact.moduleCodeHashes = StaticsDopplerLaunchConfig.RuntimeCodeHashes({
            airlock: vm.parseJsonBytes32(json, ".moduleAirlockRuntimeCodeHash"),
            tokenFactory: vm.parseJsonBytes32(json, ".moduleTokenFactoryRuntimeCodeHash"),
            governanceFactory: vm.parseJsonBytes32(json, ".moduleGovernanceFactoryRuntimeCodeHash"),
            poolInitializer: vm.parseJsonBytes32(json, ".modulePoolInitializerRuntimeCodeHash"),
            noOpMigrator: vm.parseJsonBytes32(json, ".moduleNoOpMigratorRuntimeCodeHash")
        });
        artifact.dopplerOwner = vm.parseJsonAddress(json, ".dopplerOwner");
        artifact.dopplerOwnerShare = _artifactUint96(vm.parseJsonUint(json, ".dopplerOwnerShare"));
        artifact.staticsFeeShare = _artifactUint96(vm.parseJsonUint(json, ".staticsFeeShare"));
        artifact.dopplerSourceRevision = vm.parseJsonBytes32(json, ".dopplerSourceRevision");
        artifact.launchScriptCodeHash = vm.parseJsonBytes32(json, ".launchScriptCodeHash");
        artifact.staticsImplementationHash = vm.parseJsonBytes32(json, ".staticsImplementationHash");
        artifact.launchConfigHash = vm.parseJsonBytes32(json, ".launchConfigHash");
        artifact.marketCommitment = vm.parseJsonBytes32(json, ".marketCommitment");
        artifact.tokenImplementation = vm.parseJsonAddress(json, ".tokenImplementation");
        artifact.tokenImplementationCodeHash = vm.parseJsonBytes32(json, ".tokenImplementationCodeHash");
        artifact.expectedStatics = vm.parseJsonAddress(json, ".expectedStatics");
        artifact.expectedPoolId = vm.parseJsonBytes32(json, ".expectedPoolId");
        artifact.createParams = vm.parseJsonBytes(json, ".createParams");
        artifact.createCalldata = vm.parseJsonBytes(json, ".createCalldata");
        artifact.createCalldataHash = vm.parseJsonBytes32(json, ".createCalldataHash");
        artifact.artifactHash = vm.parseJsonBytes32(json, ".artifactHash");
        _assertArtifactIntegrity(artifact);
    }

    function _artifactUint24(uint256 value) private pure returns (uint24 narrowed) {
        if (value > type(uint24).max) revert LaunchArtifactMismatch();
        narrowed = uint24(value);
    }

    function _artifactUint16(uint256 value) private pure returns (uint16 narrowed) {
        if (value > type(uint16).max) revert LaunchArtifactMismatch();
        narrowed = uint16(value);
    }

    function _artifactUint96(uint256 value) private pure returns (uint96 narrowed) {
        if (value > type(uint96).max) revert LaunchArtifactMismatch();
        narrowed = uint96(value);
    }

    function _assertArtifactIntegrity(StaticsGenesisLaunchArtifact memory artifact) private pure {
        if (artifact.schemaVersion != LAUNCH_ARTIFACT_SCHEMA) {
            revert InvalidLaunchArtifactSchema(LAUNCH_ARTIFACT_SCHEMA, artifact.schemaVersion);
        }
        if (
            bytes(artifact.config.tokenURI).length == 0 || bytes(artifact.config.contractURI).length == 0
                || bytes(artifact.config.externalURLBase).length == 0 || artifact.createParams.length == 0
                || artifact.createCalldata.length == 0
        ) revert LaunchArtifactMismatch();
        bytes32 expectedHash = launchArtifactHash(artifact);
        if (artifact.artifactHash != expectedHash) {
            revert InvalidLaunchArtifactHash(expectedHash, artifact.artifactHash);
        }
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

    function _beforeProductionEntryPoint() internal virtual {}

    function _requireApprovedProductionConfig(bytes32 currentHash) internal pure virtual {
        bytes32 approvedHash = APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH;
        if (approvedHash == bytes32(0) || currentHash != approvedHash) {
            revert ProductionLaunchConfigurationNotRatified(currentHash, approvedHash);
        }
    }

    function validatePreparedLaunch(StaticsGenesisLaunchArtifact memory artifact) public view {
        _validatePreparedLaunch(artifact, true);
    }

    function _validatePreparedLaunch(StaticsGenesisLaunchArtifact memory artifact, bool enforceProductionGate)
        private
        view
    {
        _validateArtifactBase(artifact);
        uint256 liveNonce = vm.getNonce(artifact.deployer);
        if (liveNonce != artifact.expectedLaunchNonce) {
            revert UnexpectedDeployerNonce(artifact.expectedLaunchNonce, liveNonce);
        }
        _validate(artifact.config, artifact.deployer);
        (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
            _dependencyCommitments(artifact.config);
        _assertDependencyCommitments(artifact, wethDependencyHash, moduleCodeHashes);
        if (IDopplerAirlock(artifact.airlock).owner() != artifact.dopplerOwner) {
            revert LaunchArtifactMismatch();
        }
        bytes32 currentHash =
            _launchConfigHash(artifact.config, wethDependencyHash, moduleCodeHashes, artifact.dopplerOwner);
        if (currentHash != artifact.launchConfigHash) revert LaunchArtifactMismatch();
        if (enforceProductionGate && block.chainid == ROBINHOOD_MAINNET_CHAIN_ID) {
            _requireApprovedProductionConfig(currentHash);
        }
        _assertCanonicalLaunch(artifact);
        _assertPreparedContracts(artifact.config, artifact.deployer, artifact.feeReceiver, artifact.treasuryVesting);
        if (artifact.expectedStatics.code.length != 0) {
            revert MarketAlreadyLaunched(artifact.expectedStatics);
        }
        if (!_assetDataIsEmpty(_assetData(artifact.airlock, artifact.expectedStatics))) {
            revert MarketAlreadyLaunched(artifact.expectedStatics);
        }
    }

    function validateLaunchedMarket(StaticsGenesisLaunchArtifact memory artifact) public view {
        _validateArtifactBase(artifact);
        _validateWithoutDopplerOwner(artifact.config, artifact.deployer);
        (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
            _dependencyCommitments(artifact.config);
        _assertDependencyCommitments(artifact, wethDependencyHash, moduleCodeHashes);
        if (
            _launchConfigHash(artifact.config, wethDependencyHash, moduleCodeHashes, artifact.dopplerOwner)
                != artifact.launchConfigHash
        ) revert LaunchArtifactMismatch();
        _assertCanonicalLaunch(artifact);
        _assertPreparedContracts(artifact.config, artifact.deployer, artifact.feeReceiver, artifact.treasuryVesting);
        if (artifact.expectedStatics.code.length == 0) revert MarketNotLaunched(artifact.expectedStatics);
        _assertLaunchedMarketState(artifact);
    }

    function _executeLaunch(StaticsGenesisLaunchArtifact memory artifact, DopplerLaunchTypes.CreateParams memory params)
        private
        returns (StaticsGenesisMarket memory market)
    {
        (market.statics, market.pool, market.governance, market.timelock, market.migrationPool) =
            IDopplerAirlock(artifact.config.modules.airlock).create(params);
        market.poolId = artifact.expectedPoolId;
        if (
            market.statics != artifact.expectedStatics || market.pool != artifact.expectedStatics
                || market.governance != GOVERNANCE_DEAD || market.timelock != artifact.treasuryVesting
                || market.migrationPool != MIGRATION_DEAD
        ) {
            revert UnexpectedDopplerResult(market.pool, market.governance, market.timelock, market.migrationPool);
        }
        _assertImmediatePostLaunchAllocations(artifact);
        _assertLaunchedMarketState(artifact);
    }

    function _dopplerCreateParams(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting
    ) private view returns (DopplerLaunchTypes.CreateParams memory params) {
        return _dopplerCreateParamsWithOwner(
            config, receiver, treasuryVesting, IDopplerAirlock(config.modules.airlock).owner()
        );
    }

    function _dopplerCreateParamsWithOwner(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting,
        address dopplerOwner
    ) private pure returns (DopplerLaunchTypes.CreateParams memory params) {
        DopplerLaunchTypes.BeneficiaryData[] memory poolBeneficiaries = new DopplerLaunchTypes.BeneficiaryData[](2);
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
            tokenFactoryData: _tokenFactoryData(config.tokenURI, config.treasury),
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

    function _validateArtifactBase(StaticsGenesisLaunchArtifact memory artifact) private view {
        _assertArtifactIntegrity(artifact);
        if (
            artifact.chainId != block.chainid || artifact.deployer == address(0) || artifact.airlock == address(0)
                || artifact.config.modules.airlock != artifact.airlock || artifact.transactionValue != 0
                || artifact.feeReceiver == address(0) || artifact.treasuryVesting == address(0)
                || artifact.expectedStatics == address(0) || artifact.expectedPoolId == bytes32(0)
                || artifact.tokenImplementation == address(0) || artifact.dopplerOwner == address(0)
        ) revert LaunchArtifactMismatch();
        if (
            artifact.launchScriptCodeHash != launchScriptCodeHash()
                || artifact.staticsImplementationHash != staticsImplementationHash()
                || artifact.dopplerSourceRevision != bytes32(DOPPLER_SOURCE_REVISION)
                || artifact.dopplerOwnerShare != DOPPLER_OWNER_SHARE || artifact.staticsFeeShare != STATICS_FEE_SHARE
                || artifact.createCalldataHash != keccak256(artifact.createCalldata)
                || artifact.launchConfigHash == bytes32(0) || artifact.marketCommitment == bytes32(0)
        ) revert LaunchArtifactMismatch();
        if (
            artifact.feeReceiver.codehash != artifact.feeReceiverRuntimeCodeHash
                || artifact.treasuryVesting.codehash != artifact.treasuryVestingRuntimeCodeHash
        ) revert LaunchArtifactMismatch();
    }

    function _assertDependencyCommitments(
        StaticsGenesisLaunchArtifact memory artifact,
        bytes32 wethDependencyHash,
        StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes
    ) private view {
        if (
            wethDependencyHash != artifact.wethDependencyHash
                || keccak256(abi.encode(moduleCodeHashes)) != keccak256(abi.encode(artifact.moduleCodeHashes))
        ) revert LaunchArtifactMismatch();
        address implementation = IDopplerERC20V1Factory(artifact.config.modules.tokenFactory).IMPLEMENTATION();
        if (
            implementation != artifact.tokenImplementation
                || implementation.codehash != artifact.tokenImplementationCodeHash
        ) revert LaunchArtifactMismatch();
    }

    function _assertCanonicalLaunch(StaticsGenesisLaunchArtifact memory artifact) private view {
        (address expectedStatics, address implementation) = expectedStaticsAddress(artifact.config);
        bytes32 expectedPoolId = _poolId(
            expectedStatics, artifact.config.numeraire, artifact.config.modules.poolInitializer, artifact.config.fee
        );
        if (
            expectedStatics != artifact.expectedStatics || implementation != artifact.tokenImplementation
                || expectedPoolId != artifact.expectedPoolId
        ) revert LaunchArtifactMismatch();

        DopplerLaunchTypes.CreateParams memory params = _dopplerCreateParamsWithOwner(
            artifact.config,
            StaticsFeeReceiver(payable(artifact.feeReceiver)),
            StaticsTreasuryVesting(artifact.treasuryVesting),
            artifact.dopplerOwner
        );
        bytes memory encodedParams = abi.encode(params);
        bytes memory createCalldata = abi.encodeCall(IDopplerAirlock.create, (params));
        if (
            keccak256(encodedParams) != keccak256(artifact.createParams)
                || keccak256(createCalldata) != keccak256(artifact.createCalldata)
                || keccak256(createCalldata) != artifact.createCalldataHash
                || keccak256(abi.encode(params, expectedStatics, expectedPoolId)) != artifact.marketCommitment
        ) revert LaunchArtifactMismatch();
    }

    function _assertPreparedContracts(
        StaticsGenesisDeploymentConfig memory config,
        address deployer,
        address receiverAddress,
        address vestingAddress
    ) private view {
        StaticsFeeReceiver receiver = StaticsFeeReceiver(payable(receiverAddress));
        if (
            receiver.poolInitializer() != config.modules.poolInitializer || receiver.numeraire() != config.numeraire
                || receiver.statics() != address(0) || receiver.poolId() != bytes32(0)
                || receiver.reserveVault() != address(0) || receiver.reserveShareBps() != 0
                || receiver.activeDistributor() != address(0) || receiver.pendingDistributor() != address(0)
                || receiver.owner() != deployer || receiver.pendingOwner() != address(0)
        ) revert InvalidPreparedReceiver(receiverAddress);

        StaticsTreasuryVesting vesting = StaticsTreasuryVesting(vestingAddress);
        if (
            vesting.bootstrapper() != deployer || vesting.recipientAdmin() != config.governance
                || vesting.withdrawalRecipient() != config.treasury || vesting.vestingStart() != 0
                || address(vesting.statics()) != address(0) || address(vesting.genesisVault()) != address(0)
                || address(vesting.genesis()) != address(0) || vesting.releasedGenesis() != 0
        ) revert InvalidPreparedVesting(vestingAddress);
    }

    function _assetData(address airlock, address statics) private view returns (DopplerAssetData memory data) {
        (bool success, bytes memory result) =
            airlock.staticcall(abi.encodeCall(IDopplerAirlock.getAssetData, (statics)));
        if (!success || result.length == 0) revert LaunchArtifactMismatch();
        data = abi.decode(result, (DopplerAssetData));
    }

    function _assetDataIsEmpty(DopplerAssetData memory data) private pure returns (bool) {
        return data.numeraire == address(0) && data.timelock == address(0) && data.governance == address(0)
            && data.liquidityMigrator == address(0) && data.poolInitializer == address(0) && data.pool == address(0)
            && data.migrationPool == address(0) && data.numTokensToSell == 0 && data.totalSupply == 0
            && data.integrator == address(0);
    }

    function _assertLaunchedMarketState(StaticsGenesisLaunchArtifact memory artifact) private view {
        DopplerAssetData memory data = _assetData(artifact.airlock, artifact.expectedStatics);
        if (
            data.numeraire != artifact.config.numeraire || data.timelock != artifact.treasuryVesting
                || data.governance != GOVERNANCE_DEAD || data.liquidityMigrator != artifact.config.modules.noOpMigrator
                || data.poolInitializer != artifact.config.modules.poolInitializer
                || data.pool != artifact.expectedStatics || data.migrationPool != MIGRATION_DEAD
                || data.numTokensToSell != DOPPLER_INVENTORY || data.totalSupply != STATICS_SUPPLY
                || data.integrator
                    != (artifact.config.integrator == address(0) ? artifact.dopplerOwner : artifact.config.integrator)
        ) revert UnexpectedLaunchState(artifact.expectedStatics);

        IDopplerFeeSource initializer = IDopplerFeeSource(artifact.config.modules.poolInitializer);
        (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) =
            initializer.getPoolKey(artifact.expectedPoolId);
        (address expectedCurrency0, address expectedCurrency1) = artifact.expectedStatics < artifact.config.numeraire
            ? (artifact.expectedStatics, artifact.config.numeraire)
            : (artifact.config.numeraire, artifact.expectedStatics);
        if (
            currency0 != expectedCurrency0 || currency1 != expectedCurrency1 || fee != artifact.config.fee
                || tickSpacing != TICK_SPACING || hooks != artifact.config.modules.poolInitializer
                || initializer.getShares(artifact.expectedPoolId, artifact.feeReceiver) != STATICS_FEE_SHARE
                || initializer.getShares(artifact.expectedPoolId, artifact.dopplerOwner) != DOPPLER_OWNER_SHARE
        ) revert UnexpectedLaunchState(artifact.expectedStatics);
        _assertDelayedPostLaunchAllocations(artifact);
    }

    function _assertFinalized(StaticsGenesisLaunchArtifact memory artifact, StaticsGenesisDeployment memory deployment)
        private
        view
    {
        if (
            deployment.statics != artifact.expectedStatics
                || deployment.dopplerPoolInitializer != artifact.config.modules.poolInitializer
                || deployment.poolId != artifact.expectedPoolId || deployment.feeReceiver != artifact.feeReceiver
                || deployment.treasuryVesting != artifact.treasuryVesting
        ) revert UnexpectedFinalizeState(artifact.expectedStatics);
        if (
            deployment.activationRegistry.code.length == 0 || deployment.genesis.code.length == 0
                || deployment.genesisVault.code.length == 0 || deployment.genesisDistributor.code.length == 0
                || deployment.genesisRenderer.code.length == 0 || deployment.avatarSVG.code.length == 0
        ) revert UnexpectedFinalizeState(deployment.genesis);

        IERC20 statics = IERC20(artifact.expectedStatics);
        StaticsFeeReceiver receiver = StaticsFeeReceiver(payable(artifact.feeReceiver));
        StaticsTreasuryVesting vesting = StaticsTreasuryVesting(artifact.treasuryVesting);
        GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
        StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
        StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
        GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

        if (statics.totalSupply() != STATICS_SUPPLY || statics.balanceOf(address(vault)) != TREASURY_GENESIS_BACKING) {
            revert UnexpectedFinalizeState(artifact.expectedStatics);
        }
        _assertNativeTreasuryVesting(artifact.expectedStatics, artifact.config.treasury, false);
        if (
            receiver.statics() != artifact.expectedStatics || receiver.poolId() != artifact.expectedPoolId
                || receiver.reserveVault() != address(vault)
                || receiver.reserveShareBps() != artifact.config.reserveShareBps
                || receiver.activeDistributor() != address(distributor) || receiver.pendingDistributor() != address(0)
                || !receiver.distributorActivated(address(distributor)) || receiver.owner() != artifact.deployer
                || receiver.pendingOwner() != artifact.config.governance
        ) revert UnexpectedFinalizeState(address(receiver));
        if (
            vesting.bootstrapper() != address(0) || vesting.recipientAdmin() != artifact.config.governance
                || vesting.withdrawalRecipient() != artifact.config.treasury || vesting.vestingStart() == 0
                || address(vesting.statics()) != artifact.expectedStatics
                || address(vesting.genesisVault()) != address(vault) || address(vesting.genesis()) != address(genesis)
        ) revert UnexpectedFinalizeState(address(vesting));
        if (
            address(registry.statics()) != artifact.expectedStatics || registry.treasury() != artifact.config.treasury
                || registry.bootstrapper() != address(0) || registry.genesisCollection() != address(genesis)
                || registry.activeConsumer() != address(distributor) || registry.pendingConsumer() != address(0)
                || registry.owner() != artifact.deployer || registry.pendingOwner() != artifact.config.governance
        ) revert UnexpectedFinalizeState(address(registry));
        if (
            address(vault.statics()) != artifact.expectedStatics || address(vault.feeReceiver()) != address(receiver)
                || vault.treasury() != artifact.config.treasury
                || vault.genesisEpochEnd() != artifact.config.genesisEpochEnd || vault.bootstrapper() != address(0)
                || address(vault.genesis()) != address(genesis) || !vault.finalized()
                || vault.tokenBacking() != TREASURY_GENESIS_BACKING
                || vault.creditOriginationFee() != artifact.config.creditOriginationFee
                || vault.creditExtensionFee() != artifact.config.creditExtensionFee
                || vault.recoveryCallerShareBps() != artifact.config.recoveryCallerShareBps
                || vault.creditServiceReserveShareBps() != GENESIS_CREDIT_INITIAL_RESERVE_SHARE_BPS
                || vault.creditServiceTreasuryShareBps() != GENESIS_CREDIT_INITIAL_TREASURY_SHARE_BPS
                || vault.owner() != artifact.deployer || vault.pendingOwner() != artifact.config.governance
        ) revert UnexpectedFinalizeState(address(vault));
        if (
            genesis.vault() != address(vault) || genesis.treasuryVesting() != address(vesting)
                || genesis.activationRegistry() != address(registry) || !genesis.launchFinalized()
                || genesis.mintedSupply() != GENESIS_MAX_SUPPLY || genesis.balanceOf(address(vault)) != 5_000
                || genesis.balanceOf(address(vesting)) != TREASURY_GENESIS_COUNT
                || genesis.ownerOf(TREASURY_GENESIS_FIRST_ID) != address(vesting)
                || genesis.ownerOf(TREASURY_GENESIS_LAST_ID) != address(vesting) || genesis.owner() != artifact.deployer
                || genesis.pendingOwner() != artifact.config.governance
        ) revert UnexpectedFinalizeState(address(genesis));
        if (
            address(distributor.feeReceiver()) != address(receiver)
                || address(distributor.genesis()) != address(genesis)
                || address(distributor.activationRegistry()) != address(registry)
                || distributor.statics() != artifact.expectedStatics
                || distributor.numeraire() != artifact.config.numeraire || distributor.vault() != address(vault)
                || distributor.treasury() != artifact.config.treasury
                || distributor.genesisRewardShareBps() != artifact.config.genesisRewardShareBps
                || distributor.owner() != artifact.deployer || distributor.pendingOwner() != artifact.config.governance
        ) revert UnexpectedFinalizeState(address(distributor));
    }

    function _assertImmediatePostLaunchAllocations(StaticsGenesisLaunchArtifact memory artifact) private view {
        IERC20 statics = IERC20(artifact.expectedStatics);
        uint256 bootstrapBalance = statics.balanceOf(artifact.treasuryVesting);
        if (
            statics.totalSupply() != STATICS_SUPPLY || bootstrapBalance != TREASURY_GENESIS_BACKING
                || statics.balanceOf(artifact.airlock) != 0
        ) revert AllocationMismatch(statics.totalSupply(), bootstrapBalance);
        _assertNativeTreasuryVesting(artifact.expectedStatics, artifact.config.treasury, true);
    }

    function _assertDelayedPostLaunchAllocations(StaticsGenesisLaunchArtifact memory artifact) private view {
        IERC20 statics = IERC20(artifact.expectedStatics);
        uint256 bootstrapBalance = statics.balanceOf(artifact.treasuryVesting);
        if (statics.totalSupply() != STATICS_SUPPLY || bootstrapBalance < TREASURY_GENESIS_BACKING) {
            revert AllocationMismatch(statics.totalSupply(), bootstrapBalance);
        }
        _assertNativeTreasuryVesting(artifact.expectedStatics, artifact.config.treasury, false);
    }

    function _assertNativeTreasuryVesting(address statics, address treasury, bool requireUnreleased) private view {
        IDopplerERC20V1 token = IDopplerERC20V1(statics);
        (uint64 cliff, uint64 duration) = token.vestingSchedules(0);
        (uint256 totalAmount, uint256 releasedAmount) = token.vestingOf(treasury, 0);
        uint256[] memory scheduleIds = token.getScheduleIdsOf(treasury);
        if (
            token.vestingStart() == 0 || token.vestedTotalAmount() != TREASURY_STATICS_VESTING_PRINCIPAL
                || token.vestingScheduleCount() != 1 || cliff != 0 || duration != TREASURY_VESTING_DURATION
                || token.totalAllocatedOf(treasury) != TREASURY_STATICS_VESTING_PRINCIPAL
                || totalAmount != TREASURY_STATICS_VESTING_PRINCIPAL || releasedAmount > totalAmount
                || scheduleIds.length != 1 || scheduleIds[0] != 0
                || IERC20(statics).balanceOf(statics) < totalAmount - releasedAmount
                || (requireUnreleased && (releasedAmount != 0 || IERC20(statics).balanceOf(statics) != totalAmount))
        ) revert UnexpectedLaunchState(statics);
    }

    function _tokenFactoryData(string memory tokenURI, address treasury) private pure returns (bytes memory) {
        DopplerLaunchTypes.VestingSchedule[] memory schedules = new DopplerLaunchTypes.VestingSchedule[](1);
        schedules[0] = DopplerLaunchTypes.VestingSchedule({cliff: 0, duration: uint64(TREASURY_VESTING_DURATION)});
        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = treasury;
        uint256[] memory scheduleIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = TREASURY_STATICS_VESTING_PRINCIPAL;
        return abi.encode(
            "Statics",
            "STATICS",
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            tokenURI,
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
        _validateWithoutDopplerOwner(config, initialOwner);
        if (IDopplerAirlock(config.modules.airlock).owner() == address(0)) revert ZeroAddress();
    }

    function _validateWithoutDopplerOwner(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        private
        view
    {
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
        if (
            bytes(config.tokenURI).length == 0 || bytes(config.contractURI).length == 0
                || bytes(config.externalURLBase).length == 0
        ) {
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

    function _validateRobinhoodWeth(address configuredWeth) private view returns (bytes32 wethDependencyHash) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(ROBINHOOD_MAINNET_CHAIN_ID));
        address expectedWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        if (configuredWeth != expectedWeth) revert InvalidRobinhoodWeth(expectedWeth, configuredWeth);
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash");
        bytes32 configuredCodeHash = configuredWeth.codehash;
        if (configuredCodeHash != expectedCodeHash) {
            revert InvalidRobinhoodWethCodeHash(expectedCodeHash, configuredCodeHash);
        }

        address implementation = address(uint160(uint256(vm.load(configuredWeth, ERC1967_IMPLEMENTATION_SLOT))));
        address expectedImplementation = vm.parseJsonAddress(manifest, ".contracts.weth.implementation.address");
        if (implementation != expectedImplementation) {
            revert InvalidRobinhoodDependency(expectedImplementation, implementation);
        }
        bytes32 expectedImplementationCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.implementation.runtimeCodeHash");
        _requireRobinhoodCodeHash(implementation, expectedImplementationCodeHash);

        bytes32 authorityHash = _validateRobinhoodWethAuthority(configuredWeth, manifest);
        wethDependencyHash = keccak256(
            abi.encode(expectedCodeHash, expectedImplementation, expectedImplementationCodeHash, authorityHash)
        );
    }

    function _validateRobinhoodWethAuthority(address configuredWeth, string memory manifest)
        private
        view
        returns (bytes32 authorityHash)
    {
        address proxyAdmin = address(uint160(uint256(vm.load(configuredWeth, ERC1967_ADMIN_SLOT))));
        address expectedProxyAdmin = vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.address");
        if (proxyAdmin != expectedProxyAdmin) revert InvalidRobinhoodDependency(expectedProxyAdmin, proxyAdmin);
        bytes32 expectedProxyAdminCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.runtimeCodeHash");
        _requireRobinhoodCodeHash(proxyAdmin, expectedProxyAdminCodeHash);

        bytes32 ownerHash = _validateRobinhoodProxyAdminOwner(proxyAdmin, manifest);
        authorityHash = keccak256(abi.encode(expectedProxyAdmin, expectedProxyAdminCodeHash, ownerHash));
    }

    function _validateRobinhoodProxyAdminOwner(address proxyAdmin, string memory manifest)
        private
        view
        returns (bytes32 ownerHash)
    {
        address proxyAdminOwner = IProxyAdminOwner(proxyAdmin).owner();
        address expectedProxyAdminOwner = vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.owner.address");
        if (proxyAdminOwner != expectedProxyAdminOwner) {
            revert InvalidRobinhoodDependency(expectedProxyAdminOwner, proxyAdminOwner);
        }
        bytes32 expectedProxyAdminOwnerCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.owner.runtimeCodeHash");
        _requireRobinhoodCodeHash(proxyAdminOwner, expectedProxyAdminOwnerCodeHash);

        address ownerImplementation = address(uint160(uint256(vm.load(proxyAdminOwner, ERC1967_IMPLEMENTATION_SLOT))));
        address expectedOwnerImplementation =
            vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.owner.implementation.address");
        if (ownerImplementation != expectedOwnerImplementation) {
            revert InvalidRobinhoodDependency(expectedOwnerImplementation, ownerImplementation);
        }
        bytes32 expectedOwnerImplementationCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.owner.implementation.runtimeCodeHash");
        _requireRobinhoodCodeHash(ownerImplementation, expectedOwnerImplementationCodeHash);

        address ownerProxyAdmin = address(uint160(uint256(vm.load(proxyAdminOwner, ERC1967_ADMIN_SLOT))));
        if (ownerProxyAdmin != proxyAdmin) revert InvalidRobinhoodDependency(proxyAdmin, ownerProxyAdmin);

        ownerHash = keccak256(
            abi.encode(
                expectedProxyAdminOwner,
                expectedProxyAdminOwnerCodeHash,
                expectedOwnerImplementation,
                expectedOwnerImplementationCodeHash
            )
        );
    }

    function _requireRobinhoodCodeHash(address dependency, bytes32 expectedCodeHash) private view {
        bytes32 actualCodeHash = dependency.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidRobinhoodDependencyCodeHash(dependency, expectedCodeHash, actualCodeHash);
        }
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
