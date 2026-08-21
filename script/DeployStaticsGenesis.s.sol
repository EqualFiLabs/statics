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
import {DopplerLaunchTypes, IDopplerAirlock} from "../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {LibStaticsTokenMetadata} from "../src/metadata/LibStaticsTokenMetadata.sol";
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
    uint24 fee;
    uint16 genesisRewardShareBps;
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
    address allocationEscrow;
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
contract DeployStaticsGenesis is Script {
    using PoolIdLibrary for PoolKey;

    uint256 public constant STATICS_SUPPLY = 1_000_000_000 ether;
    uint256 public constant DOPPLER_INVENTORY = 800_000_000 ether;
    uint256 public constant TREASURY_ALLOCATION = 200_000_000 ether;
    uint96 public constant DOPPLER_OWNER_SHARE = 0.05 ether;
    uint96 public constant STATICS_FEE_SHARE = 0.95 ether;
    uint24 public constant MAX_DOPPLER_LP_FEE = 100_000;
    uint256 public constant MAX_MULTICURVE_RESIDUAL = 100 ether;
    /// @dev Remains zero until a follow-up economic-parameter decision ratifies the Robinhood launch.
    bytes32 public constant APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH = bytes32(0);
    int24 public constant TICK_SPACING = 100;
    int24 public constant FAR_TICK = -83_100;
    address public constant GOVERNANCE_DEAD = address(0xdead);
    address public constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

    error ZeroAddress();
    error InvalidModule(address module);
    error InvalidMetadataURI();
    error InvalidFee(uint256 fee);
    error InvalidRewardShare(uint256 shareBps);
    error ProductionLaunchConfigurationNotRatified(bytes32 currentHash, bytes32 approvedHash);
    error UnexpectedDopplerResult(address pool, address governance, address timelock, address migrationPool);
    error AllocationMismatch(uint256 totalSupply, uint256 treasuryBalance);
    error ExcessiveMulticurveResidual(uint256 residual, uint256 maximum);

    function run() external returns (StaticsGenesisDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 fee = vm.envUint("STATICS_DOPPLER_FEE");
        uint256 rewardShare = vm.envUint("STATICS_GENESIS_REWARD_SHARE_BPS");
        if (fee > type(uint24).max) revert InvalidFee(fee);
        if (rewardShare > type(uint16).max) revert InvalidRewardShare(rewardShare);
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: vm.envAddress("STATICS_GENESIS_GOVERNANCE"),
            treasury: vm.envAddress("STATICS_GENESIS_TREASURY"),
            numeraire: vm.envAddress("WETH_ADDRESS"),
            integrator: vm.envOr("STATICS_DOPPLER_INTEGRATOR", address(0)),
            modules: StaticsDopplerLaunchConfig.modules(block.chainid),
            salt: vm.envBytes32("STATICS_DOPPLER_SALT"),
            fee: uint24(fee),
            genesisRewardShareBps: uint16(rewardShare),
            tokenURI: staticsTokenURI(),
            contractURI: vm.envString("STATICS_GENESIS_CONTRACT_URI"),
            externalURLBase: vm.envString("STATICS_GENESIS_EXTERNAL_URL_BASE")
        });
        if (block.chainid == 4_663) {
            bytes32 currentHash = launchConfigHash(config.fee, config.genesisRewardShareBps);
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

        (StaticsFeeReceiver receiver, StaticsLaunchAllocationEscrow allocationEscrow) =
            _deployLaunchReceivers(config, initialOwner);
        (address statics, bytes32 poolId) = _createDopplerMarket(config, receiver, allocationEscrow);
        receiver.bindMarket(statics, poolId);

        GenesisCollection memory collection = _deployGenesisCollection(statics, config, initialOwner);
        collection.registry.bindGenesisCollection(address(collection.genesis));
        collection.vault.finalizeGenesisCollection(address(collection.genesis));
        allocationEscrow.release(IERC20(statics), address(collection.vault));
        if (IERC20(statics).balanceOf(config.treasury) != TREASURY_ALLOCATION) {
            revert AllocationMismatch(IERC20(statics).totalSupply(), IERC20(statics).balanceOf(config.treasury));
        }

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

        deployment = StaticsGenesisDeployment({
            statics: statics,
            dopplerPoolInitializer: config.modules.poolInitializer,
            poolId: poolId,
            feeReceiver: address(receiver),
            allocationEscrow: address(allocationEscrow),
            activationRegistry: address(collection.registry),
            genesis: address(collection.genesis),
            genesisVault: address(collection.vault),
            genesisDistributor: address(distributor),
            genesisRenderer: address(collection.renderer),
            avatarSVG: address(collection.avatar)
        });
    }

    function _deployLaunchReceivers(StaticsGenesisDeploymentConfig memory config, address initialOwner)
        private
        returns (StaticsFeeReceiver receiver, StaticsLaunchAllocationEscrow allocationEscrow)
    {
        receiver = new StaticsFeeReceiver(config.modules.poolInitializer, config.numeraire, initialOwner);
        allocationEscrow = new StaticsLaunchAllocationEscrow(config.treasury, initialOwner);
    }

    function _deployGenesisCollection(
        address statics,
        StaticsGenesisDeploymentConfig memory config,
        address initialOwner
    ) private returns (GenesisCollection memory collection) {
        collection.registry = new GenesisActivationRegistry(IERC20(statics), initialOwner, initialOwner);
        collection.vault = new StaticsGenesisVault(IERC20(statics), initialOwner, initialOwner, config.treasury);
        collection.avatar = new StaticsAvatarSVG();
        collection.renderer = new StaticsGenesisRenderer(collection.avatar);
        collection.genesis = new StaticsGenesis(
            address(collection.vault),
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

    function launchConfigHash(uint24 fee, uint16 genesisRewardShareBps) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STATICS_SUPPLY,
                DOPPLER_INVENTORY,
                TREASURY_ALLOCATION,
                DOPPLER_OWNER_SHARE,
                STATICS_FEE_SHARE,
                fee,
                genesisRewardShareBps,
                TICK_SPACING,
                FAR_TICK,
                keccak256(bytes(LibStaticsTokenMetadata.tokenURI())),
                defaultCurves()
            )
        );
    }

    function _createDopplerMarket(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsLaunchAllocationEscrow allocationEscrow
    ) private returns (address statics, bytes32 poolId) {
        IDopplerAirlock airlock = IDopplerAirlock(config.modules.airlock);
        DopplerLaunchTypes.CreateParams memory params = _dopplerCreateParams(config, receiver, allocationEscrow);

        statics = _launchThroughAirlock(airlock, params, allocationEscrow);
        _assertPostLaunchSupply(statics, allocationEscrow);
        poolId = _poolId(statics, config.numeraire, config.modules.poolInitializer, config.fee);
    }

    function _dopplerCreateParams(
        StaticsGenesisDeploymentConfig memory config,
        StaticsFeeReceiver receiver,
        StaticsLaunchAllocationEscrow allocationEscrow
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
            governanceFactoryData: abi.encode(address(allocationEscrow)),
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
        StaticsLaunchAllocationEscrow allocationEscrow
    ) private returns (address statics) {
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
    }

    function _assertPostLaunchSupply(address statics, StaticsLaunchAllocationEscrow allocationEscrow) private view {
        uint256 totalSupply = IERC20(statics).totalSupply();
        uint256 escrowBalance = IERC20(statics).balanceOf(address(allocationEscrow));
        if (totalSupply != STATICS_SUPPLY || escrowBalance < TREASURY_ALLOCATION) {
            revert AllocationMismatch(totalSupply, escrowBalance);
        }
        uint256 residual = escrowBalance - TREASURY_ALLOCATION;
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
        console2.log("STATICS_LAUNCH_ALLOCATION_ESCROW_ADDRESS", deployment.allocationEscrow);
        console2.log("STATICS_GENESIS_ACTIVATION_REGISTRY_ADDRESS", deployment.activationRegistry);
        console2.log("STATICS_GENESIS_NFT_ADDRESS", deployment.genesis);
        console2.log("STATICS_GENESIS_VAULT_ADDRESS", deployment.genesisVault);
        console2.log("STATICS_GENESIS_DISTRIBUTOR_ADDRESS", deployment.genesisDistributor);
        console2.log("STATICS_GENESIS_RENDERER_ADDRESS", deployment.genesisRenderer);
        console2.log("STATICS_GENESIS_AVATAR_SVG_ADDRESS", deployment.avatarSVG);
    }
}
