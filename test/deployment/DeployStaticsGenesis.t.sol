// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig,
    StaticsGenesisLaunchArtifact,
    StaticsGenesisLaunchCommitments,
    StaticsGenesisMarket
} from "../../script/DeployStaticsGenesis.s.sol";
import {DeployStaticsGenesisLocalFork} from "../../script/DeployStaticsGenesisLocalFork.s.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {
    DopplerLaunchTypes,
    IDopplerAirlock,
    IDopplerERC20V1,
    IDopplerERC20V1Factory
} from "../../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";

contract DeploymentModule {}

contract MockDeploymentInitializer {
    using PoolIdLibrary for PoolKey;

    PoolKey private poolKey;
    mapping(bytes32 poolId => mapping(address beneficiary => uint256 shares)) public getShares;

    function configure(
        address asset,
        address numeraire,
        uint24 fee,
        int24 tickSpacing,
        DopplerLaunchTypes.BeneficiaryData[] memory beneficiaries
    ) external {
        (address currency0, address currency1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            hooks: IHooks(address(this)),
            fee: fee,
            tickSpacing: tickSpacing
        });
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        for (uint256 i; i < beneficiaries.length; ++i) {
            getShares[poolId][beneficiaries[i].beneficiary] = beneficiaries[i].shares;
        }
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        return (
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            poolKey.fee,
            poolKey.tickSpacing,
            address(poolKey.hooks)
        );
    }

    function collectFees(bytes32) external pure returns (uint128, uint128) {}
}

contract MockDeploymentAirlock is IDopplerAirlock {
    address private constant GOVERNANCE_DEAD = address(0xdead);
    address private constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;

    struct AssetData {
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

    address public override owner;
    MockDeploymentInitializer public immutable initializer;
    uint256 public lastNumTokensToSell;
    bytes32 public lastTokenFactoryDataHash;
    uint256 public createCalls;
    address public lastCreateCaller;
    bytes32 public lastCreateCalldataHash;
    mapping(address asset => AssetData data) private assetData;

    constructor(address owner_, MockDeploymentInitializer initializer_) {
        owner = owner_;
        initializer = initializer_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function create(DopplerLaunchTypes.CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        ++createCalls;
        lastCreateCaller = msg.sender;
        lastCreateCalldataHash = keccak256(msg.data);
        asset = MockDeploymentTokenFactory(params.tokenFactory)
            .create(params.initialSupply, address(this), params.salt, params.tokenFactoryData);
        MockCloneableDopplerToken token = MockCloneableDopplerToken(asset);
        require(params.initialSupply == token.totalSupply(), "SUPPLY");
        require(params.numTokensToSell == 800_000_000 ether, "INVENTORY");
        lastNumTokensToSell = params.numTokensToSell;
        lastTokenFactoryDataHash = keccak256(params.tokenFactoryData);
        DopplerLaunchTypes.PoolInitializerData memory poolData =
            abi.decode(params.poolInitializerData, (DopplerLaunchTypes.PoolInitializerData));
        require(poolData.dopplerHook == address(0), "HOOK");
        require(poolData.onInitializationDopplerHookCalldata.length == 0, "HOOK_DATA");
        require(poolData.beneficiaries.length == 2, "BENEFICIARIES");
        require(poolData.beneficiaries[0].beneficiary < poolData.beneficiaries[1].beneficiary, "ORDER");
        initializer.configure(asset, params.numeraire, poolData.fee, poolData.tickSpacing, poolData.beneficiaries);

        timelock = abi.decode(params.governanceFactoryData, (address));
        token.transfer(params.poolInitializer, params.numTokensToSell);
        token.transfer(timelock, token.balanceOf(address(this)));
        pool = asset;
        governance = GOVERNANCE_DEAD;
        migrationPool = MIGRATION_DEAD;
        assetData[asset] = AssetData({
            numeraire: params.numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: params.liquidityMigrator,
            poolInitializer: params.poolInitializer,
            pool: pool,
            migrationPool: migrationPool,
            numTokensToSell: params.numTokensToSell,
            totalSupply: params.initialSupply,
            integrator: params.integrator == address(0) ? owner : params.integrator
        });
    }

    function setAssetPool(address asset, address pool) external {
        assetData[asset].pool = pool;
    }

    function getAssetData(address asset)
        external
        view
        returns (
            address numeraire,
            address timelock,
            address governance,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        )
    {
        AssetData memory data = assetData[asset];
        return (
            data.numeraire,
            data.timelock,
            data.governance,
            data.liquidityMigrator,
            data.poolInitializer,
            data.pool,
            data.migrationPool,
            data.numTokensToSell,
            data.totalSupply,
            data.integrator
        );
    }
}

    contract DeployStaticsGenesisHarness is DeployStaticsGenesis {
        function requireApprovedProductionConfig(bytes32 currentHash) external pure {
            _requireApprovedProductionConfig(currentHash);
        }

        function launchScriptCodeHash() public view override returns (bytes32) {
            return keccak256(
                vm.getDeployedCode("test/deployment/DeployStaticsGenesis.t.sol:DeployStaticsGenesisHarness")
            );
        }

        function buildArtifact(
            StaticsGenesisDeploymentConfig memory config,
            address deployer,
            StaticsFeeReceiver receiver,
            StaticsTreasuryVesting treasuryVesting,
            uint256 expectedLaunchNonce
        ) external view returns (StaticsGenesisLaunchArtifact memory artifact) {
            (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
                _dependencyCommitments(config);
            bytes32 currentHash = launchConfigHash(config, wethDependencyHash, moduleCodeHashes);
            StaticsGenesisLaunchCommitments memory commitments = StaticsGenesisLaunchCommitments({
                expectedLaunchNonce: expectedLaunchNonce,
                wethDependencyHash: wethDependencyHash,
                moduleCodeHashes: moduleCodeHashes,
                launchConfigHash: currentHash
            });
            artifact = _buildLaunchArtifact(config, deployer, receiver, treasuryVesting, commitments);
        }
    }

    contract DeployStaticsGenesisBroadcastHarness is DeployStaticsGenesis {
        error InvalidBroadcastProofRpc();

        function launchScriptCodeHash() public view override returns (bytes32) {
            return keccak256(
                vm.getDeployedCode("test/deployment/DeployStaticsGenesis.t.sol:DeployStaticsGenesisBroadcastHarness")
            );
        }

        function _beforeProductionEntryPoint() internal override {
            bytes memory nodeInfo = vm.rpc("anvil_nodeInfo", "[]");
            if (nodeInfo.length == 0) revert InvalidBroadcastProofRpc();
        }

        function _requireApprovedProductionConfig(bytes32) internal pure override {}
    }

    contract DeployStaticsGenesisTest is Test {
        DeployStaticsGenesisHarness private deployer;
        MockDopplerToken private weth;
        MockDeploymentInitializer private initializer;
        MockDeploymentAirlock private airlock;
        address private governance;
        address private treasury;

        function setUp() public {
            governance = makeAddr("governance");
            treasury = makeAddr("treasury");
            deployer = new DeployStaticsGenesisHarness();
            weth = new MockDopplerToken(address(this));
            initializer = new MockDeploymentInitializer();
            airlock = new MockDeploymentAirlock(makeAddr("airlockOwner"), initializer);
        }

        function testLaunchScriptRevisionBindsExactRuntime() public {
            DeployStaticsGenesisBroadcastHarness broadcastHarness = new DeployStaticsGenesisBroadcastHarness();
            DeployStaticsGenesisLocalFork localFork = new DeployStaticsGenesisLocalFork();

            assertEq(deployer.launchScriptCodeHash(), address(deployer).codehash);
            assertEq(broadcastHarness.launchScriptCodeHash(), address(broadcastHarness).codehash);
            assertEq(localFork.launchScriptCodeHash(), address(localFork).codehash);
            assertNotEq(deployer.launchScriptCodeHash(), broadcastHarness.launchScriptCodeHash());
            assertNotEq(deployer.launchScriptCodeHash(), localFork.launchScriptCodeHash());
        }

        function testLaunchArtifactRoundTripsWithoutLoss() public {
            StaticsGenesisDeploymentConfig memory config = _config();
            (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, address(deployer));
            StaticsGenesisLaunchArtifact memory artifact =
                deployer.buildArtifact(config, address(deployer), receiver, vesting, vm.getNonce(address(deployer)));
            string memory path = "artifacts/genesis-launch/unit-roundtrip.json";
            vm.createDir("artifacts/genesis-launch", true);

            deployer.writeLaunchArtifact(path, artifact);
            StaticsGenesisLaunchArtifact memory loaded = deployer.loadLaunchArtifact(path);

            assertEq(loaded.artifactHash, artifact.artifactHash);
            assertEq(keccak256(abi.encode(loaded)), keccak256(abi.encode(artifact)));
            assertEq(loaded.createCalldataHash, keccak256(loaded.createCalldata));
            deployer.validatePreparedLaunch(loaded);
        }

        function testPrepareCreatesOnlyPristineReceivers() public {
            uint256 startingNonce = vm.getNonce(address(deployer));
            (
                StaticsGenesisDeploymentConfig memory config,
                StaticsFeeReceiver receiver,
                StaticsTreasuryVesting vesting,
                StaticsGenesisLaunchArtifact memory artifact
            ) = _prepareArtifact();

            assertEq(address(receiver), vm.computeCreateAddress(address(deployer), startingNonce));
            assertEq(address(vesting), vm.computeCreateAddress(address(deployer), startingNonce + 1));
            assertEq(artifact.expectedLaunchNonce, startingNonce + 2);
            assertEq(vm.getNonce(address(deployer)), startingNonce + 2);
            assertEq(artifact.expectedStatics.code.length, 0);
            assertEq(airlock.createCalls(), 0);
            assertEq(receiver.poolInitializer(), config.modules.poolInitializer);
            assertEq(receiver.numeraire(), config.numeraire);
            assertEq(receiver.statics(), address(0));
            assertEq(receiver.owner(), address(deployer));
            assertEq(receiver.pendingOwner(), address(0));
            assertEq(vesting.bootstrapper(), address(deployer));
            assertEq(vesting.recipientAdmin(), governance);
            assertEq(vesting.withdrawalRecipient(), treasury);
            assertEq(vesting.vestingStart(), 0);
            deployer.validatePreparedLaunch(artifact);
        }

        function testLaunchCreatesExpectedLiveMarketWithoutFinalization() public {
            (
                StaticsGenesisDeploymentConfig memory config,
                StaticsFeeReceiver receiver,
                StaticsTreasuryVesting vesting,
                StaticsGenesisLaunchArtifact memory artifact
            ) = _prepareArtifact();

            StaticsGenesisMarket memory market = deployer.launch(artifact);

            assertEq(market.statics, artifact.expectedStatics);
            assertEq(market.pool, artifact.expectedStatics);
            assertEq(market.poolId, artifact.expectedPoolId);
            assertEq(market.governance, deployer.GOVERNANCE_DEAD());
            assertEq(market.timelock, address(vesting));
            assertEq(market.migrationPool, deployer.MIGRATION_DEAD());
            assertGt(artifact.expectedStatics.code.length, 0);
            assertEq(airlock.createCalls(), 1);
            assertEq(airlock.lastCreateCaller(), address(deployer));
            assertEq(airlock.lastCreateCalldataHash(), artifact.createCalldataHash);
            assertEq(receiver.statics(), address(0));
            assertEq(receiver.owner(), address(deployer));
            assertEq(vesting.vestingStart(), 0);
            assertEq(address(vesting.statics()), address(0));
            assertEq(config.modules.poolInitializer, address(initializer));
            deployer.validateLaunchedMarket(artifact);
        }

        function testFinalizeBeforeLaunchRevertsWithoutDeployment() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            uint256 nonceBefore = vm.getNonce(address(deployer));

            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.MarketNotLaunched.selector, artifact.expectedStatics)
            );
            deployer.finalize(artifact);

            assertEq(vm.getNonce(address(deployer)), nonceBefore);
            assertEq(airlock.createCalls(), 0);
        }

        function testFinalizeCompletesPreparedMarket() public {
            (
                StaticsGenesisDeploymentConfig memory config,
                StaticsFeeReceiver receiver,
                StaticsTreasuryVesting vesting,
                StaticsGenesisLaunchArtifact memory artifact
            ) = _prepareArtifact();
            deployer.launch(artifact);

            StaticsGenesisDeployment memory deployment = deployer.finalize(artifact);

            assertEq(deployment.statics, artifact.expectedStatics);
            assertEq(receiver.statics(), artifact.expectedStatics);
            assertEq(receiver.poolId(), artifact.expectedPoolId);
            assertEq(receiver.reserveVault(), deployment.genesisVault);
            assertEq(receiver.activeDistributor(), deployment.genesisDistributor);
            assertEq(vesting.bootstrapper(), address(0));
            assertEq(vesting.vestingStart(), block.timestamp);
            assertEq(address(vesting.statics()), artifact.expectedStatics);
            assertEq(address(vesting.genesisVault()), deployment.genesisVault);
            assertEq(address(vesting.genesis()), deployment.genesis);
            assertEq(
                GenesisActivationRegistry(deployment.activationRegistry).activeConsumer(), deployment.genesisDistributor
            );
            assertEq(StaticsGenesisVault(deployment.genesisVault).creditOriginationFee(), config.creditOriginationFee);
            assertEq(StaticsGenesisVault(deployment.genesisVault).creditExtensionFee(), config.creditExtensionFee);
            assertEq(
                StaticsGenesisVault(deployment.genesisVault).recoveryCallerShareBps(), config.recoveryCallerShareBps
            );
            assertEq(receiver.pendingOwner(), governance);
            assertEq(StaticsGenesis(deployment.genesis).pendingOwner(), governance);
        }

        function testPreparedValidationRejectsLiveReceiverDrift() public {
            (, StaticsFeeReceiver receiver,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            vm.prank(address(deployer));
            receiver.transferOwnership(makeAddr("unexpectedReceiverOwner"));
            vm.setNonce(address(deployer), uint64(artifact.expectedLaunchNonce));

            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.InvalidPreparedReceiver.selector, address(receiver))
            );
            deployer.validatePreparedLaunch(artifact);
        }

        function testPreparedValidationRejectsLiveVestingDrift() public {
            (,, StaticsTreasuryVesting vesting, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            vm.prank(governance);
            vesting.setWithdrawalRecipient(makeAddr("unexpectedVestingRecipient"));

            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.InvalidPreparedVesting.selector, address(vesting))
            );
            deployer.validatePreparedLaunch(artifact);
        }

        function testFinalizeRejectsMismatchedMarketWithoutNewDeployment() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            deployer.launch(artifact);
            airlock.setAssetPool(artifact.expectedStatics, makeAddr("unexpectedPool"));
            uint256 nonceBefore = vm.getNonce(address(deployer));

            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.UnexpectedLaunchState.selector, artifact.expectedStatics)
            );
            deployer.finalize(artifact);

            assertEq(vm.getNonce(address(deployer)), nonceBefore);
        }

        function testRunLaunchBroadcastsOnlyCanonicalAirlockCall() public {
            (address signer, uint256 privateKey) = makeAddrAndKey("launchSigner");
            StaticsGenesisDeploymentConfig memory config = _config();
            (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, signer);
            StaticsGenesisLaunchArtifact memory artifact =
                deployer.buildArtifact(config, signer, receiver, vesting, vm.getNonce(signer));
            string memory path = "artifacts/genesis-launch/run-launch-unit.json";
            vm.createDir("artifacts/genesis-launch", true);
            deployer.writeLaunchArtifact(path, artifact);
            vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
            vm.setEnv("STATICS_GENESIS_LAUNCH_ARTIFACT", path);

            vm.startStateDiffRecording();
            StaticsGenesisMarket memory market = deployer.runLaunch();
            VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

            uint256 signerAccesses;
            for (uint256 i; i < accesses.length; ++i) {
                VmSafe.AccountAccess memory access = accesses[i];
                if (access.accessor != signer || !_isStateChangingAccess(access.kind)) continue;
                ++signerAccesses;
                assertEq(uint256(access.kind), uint256(VmSafe.AccountAccessKind.Call));
                assertEq(access.account, config.modules.airlock);
                assertEq(access.value, 0);
                assertEq(keccak256(access.data), artifact.createCalldataHash);
            }
            assertEq(signerAccesses, 1);
            assertEq(market.statics, artifact.expectedStatics);
            assertEq(airlock.createCalls(), 1);
            assertEq(airlock.lastCreateCaller(), signer);
            assertEq(airlock.lastCreateCalldataHash(), artifact.createCalldataHash);
        }

        function testRunFinalizeRejectsNonceDriftBeforeBroadcast() public {
            (address signer, uint256 privateKey) = makeAddrAndKey("finalizeSigner");
            StaticsGenesisDeploymentConfig memory config = _config();
            (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, signer);
            StaticsGenesisLaunchArtifact memory artifact =
                deployer.buildArtifact(config, signer, receiver, vesting, vm.getNonce(signer));
            string memory path = "artifacts/genesis-launch/run-finalize-nonce.json";
            vm.createDir("artifacts/genesis-launch", true);
            deployer.writeLaunchArtifact(path, artifact);
            vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));
            vm.setEnv("STATICS_GENESIS_LAUNCH_ARTIFACT", path);
            deployer.runLaunch();
            uint64 driftedNonce = uint64(artifact.expectedLaunchNonce + 2);
            vm.setNonce(signer, driftedNonce);

            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployStaticsGenesis.UnexpectedDeployerNonce.selector,
                    artifact.expectedLaunchNonce + 1,
                    driftedNonce
                )
            );
            deployer.runFinalize();
        }

        function testLaunchArtifactRejectsIdentityAndNonceDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            artifact.artifactHash = bytes32(uint256(artifact.artifactHash) + 1);
            vm.expectPartialRevert(DeployStaticsGenesis.InvalidLaunchArtifactHash.selector);
            deployer.validatePreparedLaunch(artifact);

            artifact.chainId += 1;
            _expectPreparedFailure(artifact);
            artifact.chainId -= 1;

            address originalDeployer = artifact.deployer;
            artifact.deployer = makeAddr("differentPreparedDeployer");
            _expectPreparedFailure(artifact);
            artifact.deployer = originalDeployer;

            artifact.expectedLaunchNonce += 1;
            _expectPreparedFailure(artifact);
            artifact.expectedLaunchNonce -= 1;

            artifact.transactionValue = 1;
            _expectPreparedFailure(artifact);
            artifact.transactionValue = 0;

            artifact.launchScriptCodeHash = bytes32(uint256(artifact.launchScriptCodeHash) + 1);
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsEconomicDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            artifact.config.fee += 1;
            _expectPreparedFailure(artifact);
            artifact.config.fee -= 1;
            artifact.config.genesisRewardShareBps += 1;
            _expectPreparedFailure(artifact);
            artifact.config.genesisRewardShareBps -= 1;
            artifact.config.reserveShareBps += 1;
            _expectPreparedFailure(artifact);
            artifact.config.reserveShareBps -= 1;
            artifact.config.creditOriginationFee += 1;
            _expectPreparedFailure(artifact);
            artifact.config.creditOriginationFee -= 1;
            artifact.config.creditExtensionFee += 1;
            _expectPreparedFailure(artifact);
            artifact.config.creditExtensionFee -= 1;
            artifact.config.recoveryCallerShareBps += 1;
            _expectPreparedFailure(artifact);
            artifact.config.recoveryCallerShareBps -= 1;
            artifact.config.genesisEpochEnd += 1;
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsDependencyDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            artifact.wethDependencyHash = bytes32(uint256(artifact.wethDependencyHash) + 1);
            _expectPreparedFailure(artifact);
            artifact.wethDependencyHash = _localWethCommitment(artifact.config.numeraire);

            artifact.moduleCodeHashes.airlock = bytes32(uint256(artifact.moduleCodeHashes.airlock) + 1);
            _expectPreparedFailure(artifact);
            artifact.moduleCodeHashes.airlock = artifact.config.modules.airlock.codehash;
            artifact.moduleCodeHashes.tokenFactory = bytes32(uint256(artifact.moduleCodeHashes.tokenFactory) + 1);
            _expectPreparedFailure(artifact);
            artifact.moduleCodeHashes.tokenFactory = artifact.config.modules.tokenFactory.codehash;
            artifact.moduleCodeHashes.governanceFactory = bytes32(
                uint256(artifact.moduleCodeHashes.governanceFactory) + 1
            );
            _expectPreparedFailure(artifact);
            artifact.moduleCodeHashes.governanceFactory = artifact.config.modules.governanceFactory.codehash;
            artifact.moduleCodeHashes.poolInitializer = bytes32(uint256(artifact.moduleCodeHashes.poolInitializer) + 1);
            _expectPreparedFailure(artifact);
            artifact.moduleCodeHashes.poolInitializer = artifact.config.modules.poolInitializer.codehash;
            artifact.moduleCodeHashes.noOpMigrator = bytes32(uint256(artifact.moduleCodeHashes.noOpMigrator) + 1);
            _expectPreparedFailure(artifact);
            artifact.moduleCodeHashes.noOpMigrator = artifact.config.modules.noOpMigrator.codehash;
            artifact.tokenImplementationCodeHash = bytes32(uint256(artifact.tokenImplementationCodeHash) + 1);
            _expectPreparedFailure(artifact);
            artifact.tokenImplementationCodeHash = artifact.tokenImplementation.codehash;
            artifact.tokenImplementation = address(new MockCloneableDopplerToken());
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsEveryModuleAddressDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            StaticsDopplerLaunchConfig.Modules memory original = artifact.config.modules;

            artifact.config.modules.airlock =
                address(new MockDeploymentAirlock(makeAddr("driftAirlockOwner"), initializer));
            _expectPreparedFailure(artifact);
            artifact.config.modules.airlock = original.airlock;
            artifact.config.modules.tokenFactory = address(new MockDeploymentTokenFactory());
            _expectPreparedFailure(artifact);
            artifact.config.modules.tokenFactory = original.tokenFactory;
            artifact.config.modules.governanceFactory = original.noOpMigrator;
            _expectPreparedFailure(artifact);
            artifact.config.modules.governanceFactory = original.governanceFactory;
            artifact.config.modules.poolInitializer = address(new MockDeploymentInitializer());
            _expectPreparedFailure(artifact);
            artifact.config.modules.poolInitializer = original.poolInitializer;
            artifact.config.modules.noOpMigrator = original.governanceFactory;
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsRecipientAndAuthorityDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            address originalGovernance = artifact.config.governance;
            artifact.config.governance = makeAddr("artifactGovernanceDrift");
            _expectPreparedFailure(artifact);
            artifact.config.governance = originalGovernance;
            address originalTreasury = artifact.config.treasury;
            artifact.config.treasury = makeAddr("artifactTreasuryDrift");
            _expectPreparedFailure(artifact);
            artifact.config.treasury = originalTreasury;
            address originalReceiver = artifact.feeReceiver;
            artifact.feeReceiver = artifact.treasuryVesting;
            _expectPreparedFailure(artifact);
            artifact.feeReceiver = originalReceiver;
            address originalVesting = artifact.treasuryVesting;
            artifact.treasuryVesting = artifact.feeReceiver;
            _expectPreparedFailure(artifact);
            artifact.treasuryVesting = originalVesting;
            artifact.config.salt = bytes32(uint256(artifact.config.salt) + 1);
            _expectPreparedFailure(artifact);
            artifact.config.salt = bytes32(uint256(artifact.config.salt) - 1);
            artifact.dopplerOwner = makeAddr("artifactDopplerOwnerDrift");
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsBeneficiaryOrderAndCurveDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            artifact = _withBeneficiaryOrderDrift(artifact);
            _expectPreparedFailure(artifact);

            (,,, artifact) = _prepareArtifact();
            artifact = _withCurveDrift(artifact);
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsCanonicalPayloadDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            artifact.dopplerOwnerShare += 1;
            _expectPreparedFailure(artifact);
            artifact.dopplerOwnerShare -= 1;
            artifact.staticsFeeShare -= 1;
            _expectPreparedFailure(artifact);
            artifact.staticsFeeShare += 1;
            artifact.config.tokenURI = "ipfs://artifact-token-drift";
            _expectPreparedFailure(artifact);
            artifact.config.tokenURI = "ipfs://statics/token.json";
            artifact.config.contractURI = "ipfs://artifact-contract-drift";
            _expectPreparedFailure(artifact);
            artifact.config.contractURI = "ipfs://statics-genesis/contract.json";
            artifact.config.externalURLBase = "https://artifact-drift.invalid/";
            _expectPreparedFailure(artifact);
        }

        function testLaunchArtifactRejectsExpectedMarketAndRawPayloadDrift() public {
            (,,, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();

            artifact.expectedStatics = address(uint160(artifact.expectedStatics) + 1);
            _expectPreparedFailure(artifact);
            artifact.expectedStatics = address(uint160(artifact.expectedStatics) - 1);
            artifact.expectedPoolId = bytes32(uint256(artifact.expectedPoolId) + 1);
            _expectPreparedFailure(artifact);
            artifact.expectedPoolId = bytes32(uint256(artifact.expectedPoolId) - 1);
            artifact.marketCommitment = bytes32(uint256(artifact.marketCommitment) + 1);
            _expectPreparedFailure(artifact);
            artifact.marketCommitment = bytes32(uint256(artifact.marketCommitment) - 1);
            artifact.createParams = abi.encodePacked(artifact.createParams, bytes1(0));
            _expectPreparedFailure(artifact);

            (,,, artifact) = _prepareArtifact();
            artifact.createCalldata = abi.encodePacked(artifact.createCalldata, bytes1(0));
            _expectPreparedFailure(artifact);

            (,,, artifact) = _prepareArtifact();
            artifact.createCalldataHash = bytes32(uint256(artifact.createCalldataHash) + 1);
            _expectPreparedFailure(artifact);
        }

        function testPhasedDeploymentMatchesMonolithicState() public {
            StaticsGenesisDeployment memory monolithic = deployer.deploy(_config(), address(deployer));

            MockDeploymentInitializer phasedInitializer = new MockDeploymentInitializer();
            MockDeploymentAirlock phasedAirlock =
                new MockDeploymentAirlock(makeAddr("phasedAirlockOwner"), phasedInitializer);
            StaticsGenesisDeploymentConfig memory config = _configFor(phasedAirlock, phasedInitializer);
            (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, address(deployer));
            StaticsGenesisLaunchArtifact memory artifact =
                deployer.buildArtifact(config, address(deployer), receiver, vesting, vm.getNonce(address(deployer)));
            deployer.launch(artifact);
            StaticsGenesisDeployment memory phased = deployer.finalize(artifact);

            _assertEquivalentDeployments(monolithic, phased);
        }

        function testDeploysDopplerGenesisStackWithExactAllocations() public {
            StaticsGenesisDeployment memory deployment = deployer.deploy(_config(), address(deployer));
            IERC20 statics = IERC20(deployment.statics);
            StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
            StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
            StaticsTreasuryVesting vesting = StaticsTreasuryVesting(deployment.treasuryVesting);
            StaticsFeeReceiver receiver = StaticsFeeReceiver(payable(deployment.feeReceiver));
            GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
            GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

            assertEq(statics.totalSupply(), 1_000_000_000 ether);
            assertEq(statics.balanceOf(treasury), 0);
            assertEq(airlock.lastNumTokensToSell(), 800_000_000 ether);
            assertEq(
                airlock.lastTokenFactoryDataHash(),
                keccak256(_expectedTokenFactoryData("ipfs://statics/token.json", treasury))
            );
            assertEq(statics.balanceOf(address(initializer)), 800_000_000 ether);
            assertEq(statics.balanceOf(deployment.statics), 100_100_000 ether);
            assertEq(genesis.balanceOf(address(vault)), 5_000);
            assertEq(genesis.balanceOf(address(vesting)), 555);
            assertEq(genesis.ownerOf(5_001), address(vesting));
            assertEq(genesis.ownerOf(5_555), address(vesting));
            assertEq(vault.circulatingGenesis(), 555);
            assertEq(vault.requiredBacking(), 99_900_000 ether);
            assertEq(vault.tokenBacking(), 99_900_000 ether);
            assertEq(statics.balanceOf(address(vault)), 99_900_000 ether);
            assertEq(statics.balanceOf(address(vesting)), 0);
            assertEq(vesting.recipientAdmin(), governance);
            assertEq(vesting.withdrawalRecipient(), treasury);
            assertEq(vesting.bootstrapper(), address(0));
            assertEq(vesting.releasableGenesis(), 0);
            IDopplerERC20V1 nativeVesting = IDopplerERC20V1(deployment.statics);
            assertEq(nativeVesting.vestedTotalAmount(), 100_100_000 ether);
            assertEq(nativeVesting.vestingScheduleCount(), 1);
            (uint64 cliff, uint64 duration) = nativeVesting.vestingSchedules(0);
            assertEq(cliff, 0);
            assertEq(duration, 60 days);
            (uint256 totalAmount, uint256 releasedAmount) = nativeVesting.vestingOf(treasury, 0);
            assertEq(totalAmount, 100_100_000 ether);
            assertEq(releasedAmount, 0);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolId(), deployment.poolId);
            assertEq(receiver.poolInitializer(), address(initializer));
            assertEq(initializer.getShares(deployment.poolId, address(receiver)), 0.95 ether);
            assertEq(initializer.getShares(deployment.poolId, airlock.owner()), 0.05 ether);
            assertEq(statics.balanceOf(deployment.genesisVault), 99_900_000 ether);
            assertEq(receiver.activeDistributor(), address(distributor));
            assertEq(registry.activeConsumer(), address(distributor));
            assertEq(receiver.reserveVault(), address(vault));
            assertEq(receiver.reserveShareBps(), 5_000);
            assertEq(registry.treasury(), treasury);
            assertEq(vault.genesisEpochEnd(), block.timestamp + 7 days);
            assertTrue(vault.epochActive());
            assertEq(vault.reserveETH(), 0);
            assertEq(vault.creditOriginationFee(), 0.003 ether);
            assertEq(vault.creditExtensionFee(), 0.003 ether);
            assertEq(vault.recoveryCallerShareBps(), 2_000);
            assertEq(vault.creditServiceReserveShareBps(), 1_000);
            assertEq(vault.creditServiceTreasuryShareBps(), 9_000);
            assertEq(distributor.genesisRecoveryVault(), address(vault));
            assertEq(distributor.genesisRecoveryAsset(), address(statics));
            assertEq(receiver.pendingOwner(), governance);
            assertEq(registry.pendingOwner(), governance);
            assertEq(vault.pendingOwner(), governance);
            assertEq(genesis.pendingOwner(), governance);
            assertEq(distributor.pendingOwner(), governance);

            vm.startPrank(governance);
            receiver.acceptOwnership();
            registry.acceptOwnership();
            vault.acceptOwnership();
            genesis.acceptOwnership();
            distributor.acceptOwnership();
            vm.stopPrank();
            assertEq(receiver.owner(), governance);
            assertEq(registry.owner(), governance);
            assertEq(vault.owner(), governance);
            assertEq(genesis.owner(), governance);
            assertEq(distributor.owner(), governance);
            assertEq(receiver.pendingOwner(), address(0));
            assertEq(registry.pendingOwner(), address(0));
            assertEq(vault.pendingOwner(), address(0));
            assertEq(genesis.pendingOwner(), address(0));
            assertEq(distributor.pendingOwner(), address(0));
        }

        function testSixCurveLaunchGeometryMatchesEconomicModel() public view {
            DopplerLaunchTypes.Curve[] memory curves = deployer.defaultCurves();
            assertEq(curves.length, 6);

            assertEq(curves[0].tickLower, -168_800);
            assertEq(curves[0].tickUpper, -153_800);
            assertEq(curves[0].numPositions, 11);
            assertEq(curves[0].shares, 0.025 ether);

            assertEq(curves[1].tickLower, -160_700);
            assertEq(curves[1].tickUpper, -139_900);
            assertEq(curves[1].numPositions, 11);
            assertEq(curves[1].shares, 0.075 ether);

            assertEq(curves[2].tickLower, -146_900);
            assertEq(curves[2].tickUpper, -123_800);
            assertEq(curves[2].numPositions, 11);
            assertEq(curves[2].shares, 0.125 ether);

            assertEq(curves[3].tickLower, -130_800);
            assertEq(curves[3].tickUpper, -100_800);
            assertEq(curves[3].numPositions, 11);
            assertEq(curves[3].shares, 0.2 ether);

            assertEq(curves[4].tickLower, -107_700);
            assertEq(curves[4].tickUpper, -77_800);
            assertEq(curves[4].numPositions, 11);
            assertEq(curves[4].shares, 0.425 ether);

            assertEq(curves[5].tickLower, -77_800);
            assertEq(curves[5].tickUpper, 887_200);
            assertEq(curves[5].numPositions, 1);
            assertEq(curves[5].shares, 0.15 ether);

            uint256 totalShares;
            for (uint256 i; i < curves.length; ++i) {
                totalShares += curves[i].shares;
            }
            assertEq(totalShares, 1 ether);
            assertEq(curves[4].tickUpper, curves[5].tickLower);
            assertEq(deployer.FAR_TICK(), 887_100);
            assertEq(deployer.APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH(), bytes32(0));
            assertEq(deployer.GENESIS_CREDIT_MAX_PRINCIPAL(), 171_000 ether);
            assertEq(deployer.GENESIS_CREDIT_RECOVERY_RESIDUAL(), 9_000 ether);
            assertEq(deployer.GENESIS_CREDIT_TERM(), 30 days);
            assertEq(deployer.GENESIS_CREDIT_RECOVERY_GRACE(), 1 hours);
            assertEq(deployer.GENESIS_CREDIT_INITIAL_RESERVE_SHARE_BPS(), 1_000);
            assertEq(deployer.GENESIS_CREDIT_INITIAL_TREASURY_SHARE_BPS(), 9_000);
        }

        function testCanonicalGenesisCollectionMetadataMatchesApprovedPayload() public view {
            string memory expectedURI =
                "data:application/json;utf8,%7B%22name%22%3A%22STATICS%20Operators%22%2C%22symbol%22%3A%22STATOPS%22%2C%22description%22%3A%225%2C555%20deterministic%20onchain%20Genesis%20identities%20powering%20the%20STATICS%20protocol.%20Each%20STATICS%20Operator%20carries%20a%20180%2C000%20STATICS%20backing%20claim%2C%20evolving%20activation%20tiers%2C%20native%20artwork%2C%20and%20access%20to%20protocol%20reserve%20and%20reward%20flows.%22%2C%22external_link%22%3A%22https%3A%2F%2Fstaticsprotocol.com%22%7D";

            assertEq(deployer.staticsGenesisContractURI(), expectedURI);
            assertEq(deployer.staticsGenesisExternalURLBase(), "https://staticsprotocol.com/genesis/");
        }

        function testLaunchManifestHashBindsEconomicsAndAuthorities() public {
            StaticsGenesisDeploymentConfig memory config = _config();
            bytes32 canonicalWethHash = 0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353;
            StaticsDopplerLaunchConfig.RuntimeCodeHashes memory codeHashes = _codeHashes();
            bytes32 launchHash = deployer.launchConfigHash(config, canonicalWethHash, codeHashes);
            assertNotEq(launchHash, bytes32(0));
            assertNotEq(deployer.staticsImplementationHash(), bytes32(0));

            config.fee += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.fee -= 1;
            config.genesisRewardShareBps += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.genesisRewardShareBps -= 1;
            config.reserveShareBps += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.reserveShareBps -= 1;
            config.creditOriginationFee += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.creditOriginationFee -= 1;
            config.creditExtensionFee += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.creditExtensionFee -= 1;
            config.recoveryCallerShareBps += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.recoveryCallerShareBps -= 1;
            config.genesisEpochEnd += 1;
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.genesisEpochEnd -= 1;
            config.governance = address(uint160(config.governance) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.governance = governance;
            config.treasury = address(uint160(config.treasury) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.treasury = treasury;
            config.integrator = makeAddr("integrator");
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.integrator = address(0);
            config.salt = bytes32(uint256(config.salt) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.salt = keccak256("STATICS_DOPPLER_TEST");
            address originalDopplerOwner = airlock.owner();
            airlock.setOwner(makeAddr("rotatedAirlockOwner"));
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            airlock.setOwner(originalDopplerOwner);
        }

        function testZeroApprovedHashBlocksProductionRatification() public {
            DeployStaticsGenesisHarness harness = new DeployStaticsGenesisHarness();
            bytes32 currentHash = keccak256("unratified Robinhood launch");
            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployStaticsGenesis.ProductionLaunchConfigurationNotRatified.selector, currentHash, bytes32(0)
                )
            );
            harness.requireApprovedProductionConfig(currentHash);
        }

        function testLaunchManifestHashBindsDependenciesAndMetadata() public {
            StaticsGenesisDeploymentConfig memory config = _config();
            bytes32 canonicalWethHash = 0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353;
            StaticsDopplerLaunchConfig.RuntimeCodeHashes memory codeHashes = _codeHashes();
            StaticsDopplerLaunchConfig.Modules memory originalModules = config.modules;
            bytes32 launchHash = deployer.launchConfigHash(config, canonicalWethHash, codeHashes);

            config.numeraire = address(uint160(config.numeraire) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.numeraire = address(weth);
            config.modules.airlock = address(new MockDeploymentAirlock(makeAddr("differentAirlockOwner"), initializer));
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.modules.airlock = address(airlock);
            config.modules.tokenFactory = address(uint160(config.modules.tokenFactory) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.modules.tokenFactory = originalModules.tokenFactory;
            config.modules.governanceFactory = address(uint160(config.modules.governanceFactory) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.modules.governanceFactory = originalModules.governanceFactory;
            config.modules.poolInitializer = address(uint160(config.modules.poolInitializer) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.modules.poolInitializer = address(initializer);
            config.modules.noOpMigrator = address(uint160(config.modules.noOpMigrator) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.modules.noOpMigrator = originalModules.noOpMigrator;

            codeHashes.airlock = bytes32(uint256(codeHashes.airlock) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            codeHashes = _codeHashes();
            codeHashes.tokenFactory = bytes32(uint256(codeHashes.tokenFactory) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            codeHashes = _codeHashes();
            codeHashes.governanceFactory = bytes32(uint256(codeHashes.governanceFactory) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            codeHashes = _codeHashes();
            codeHashes.poolInitializer = bytes32(uint256(codeHashes.poolInitializer) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            codeHashes = _codeHashes();
            codeHashes.noOpMigrator = bytes32(uint256(codeHashes.noOpMigrator) + 1);
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            codeHashes = _codeHashes();
            assertNotEq(
                deployer.launchConfigHash(config, bytes32(uint256(canonicalWethHash) + 1), codeHashes), launchHash
            );
            config.tokenURI = "ipfs://different-token.json";
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.tokenURI = "ipfs://statics/token.json";
            config.contractURI = "ipfs://different-contract.json";
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
            config.contractURI = "ipfs://statics-genesis/contract.json";
            config.externalURLBase = "https://example.com/genesis/";
            assertNotEq(deployer.launchConfigHash(config, canonicalWethHash, codeHashes), launchHash);
        }

        function testFinalizeToleratesDonationWithoutIncreasingVaultBacking() public {
            uint256 surplus = 1_000_000 ether;
            (,, StaticsTreasuryVesting vesting, StaticsGenesisLaunchArtifact memory artifact) = _prepareArtifact();
            deployer.launch(artifact);
            vm.prank(address(initializer));
            IERC20(artifact.expectedStatics).transfer(address(vesting), surplus);

            StaticsGenesisDeployment memory deployment = deployer.finalize(artifact);
            IERC20 statics = IERC20(deployment.statics);

            assertEq(statics.balanceOf(deployment.genesisVault), 99_900_000 ether);
            assertEq(StaticsGenesisVault(deployment.genesisVault).tokenBacking(), 99_900_000 ether);
            assertEq(statics.balanceOf(deployment.treasuryVesting), surplus);

            vm.prank(governance);
            assertEq(vesting.sweepStaticsSurplus(), surplus);
            assertEq(statics.balanceOf(treasury), surplus);
        }

        function testNativeTreasuryVestingReleasesDirectlyToTreasury() public {
            StaticsGenesisDeployment memory deployment = deployer.deploy(_config(), address(deployer));
            IDopplerERC20V1 token = IDopplerERC20V1(deployment.statics);
            uint256 start = token.vestingStart();

            vm.warp(start + 30 days);
            token.releaseFor(treasury, 0, 0);

            assertEq(IERC20(deployment.statics).balanceOf(treasury), 50_050_000 ether);
            (, uint256 releasedAmount) = token.vestingOf(treasury, 0);
            assertEq(releasedAmount, 50_050_000 ether);
        }

        function testRejectsRenouncedDopplerOwner() public {
            airlock.setOwner(address(0));
            StaticsGenesisDeploymentConfig memory config = _config();
            vm.expectRevert(DeployStaticsGenesis.ZeroAddress.selector);
            deployer.deploy(config, address(deployer));
        }

        function testRejectsInvalidFeeAndMetadata() public {
            StaticsGenesisDeploymentConfig memory config = _config();
            config.fee = 0;
            vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidFee.selector, 0));
            deployer.deploy(config, address(deployer));

            config = _config();
            config.fee = 100_001;
            vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidFee.selector, 100_001));
            deployer.deploy(config, address(deployer));

            config = _config();
            config.genesisEpochEnd = block.timestamp;
            vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidEpochEnd.selector, block.timestamp));
            deployer.deploy(config, address(deployer));

            config = _config();
            config.recoveryCallerShareBps = 0;
            vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidRecoveryCallerShare.selector, 0));
            deployer.deploy(config, address(deployer));

            config = _config();
            config.recoveryCallerShareBps = 10_000;
            vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidRecoveryCallerShare.selector, 10_000));
            deployer.deploy(config, address(deployer));

            config = _config();
            config.tokenURI = "";
            vm.expectRevert(DeployStaticsGenesis.InvalidMetadataURI.selector);
            deployer.deploy(config, address(deployer));

            config = _config();
            config.contractURI = "";
            vm.expectRevert(DeployStaticsGenesis.InvalidMetadataURI.selector);
            deployer.deploy(config, address(deployer));
        }

        function testRejectsNoncanonicalRobinhoodWeth() public {
            vm.chainId(4_663);
            StaticsGenesisDeploymentConfig memory config = _config();
            string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");
            address canonicalWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployStaticsGenesis.InvalidRobinhoodWeth.selector, canonicalWeth, config.numeraire
                )
            );
            deployer.deploy(config, address(deployer));
        }

        function testRejectsRobinhoodWethCodeHashDrift() public {
            vm.chainId(4_663);
            string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");
            address canonicalWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
            bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash");
            vm.etch(canonicalWeth, hex"60006000fd");
            StaticsGenesisDeploymentConfig memory config = _config();
            config.numeraire = canonicalWeth;
            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployStaticsGenesis.InvalidRobinhoodWethCodeHash.selector, expectedCodeHash, canonicalWeth.codehash
                )
            );
            deployer.deploy(config, address(deployer));
        }

        function testLocalForkEntrypointRejectsWrongChainBeforeReadingSecrets() public {
            DeployStaticsGenesisLocalFork localForkDeployer = new DeployStaticsGenesisLocalFork();
            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesisLocalFork.InvalidLocalForkChain.selector, block.chainid)
            );
            localForkDeployer.runLocalFork();
        }

        function _withBeneficiaryOrderDrift(StaticsGenesisLaunchArtifact memory artifact)
            private
            view
            returns (StaticsGenesisLaunchArtifact memory)
        {
            DopplerLaunchTypes.CreateParams memory params =
                abi.decode(artifact.createParams, (DopplerLaunchTypes.CreateParams));
            DopplerLaunchTypes.PoolInitializerData memory poolData =
                abi.decode(params.poolInitializerData, (DopplerLaunchTypes.PoolInitializerData));
            DopplerLaunchTypes.BeneficiaryData memory first = poolData.beneficiaries[0];
            poolData.beneficiaries[0] = poolData.beneficiaries[1];
            poolData.beneficiaries[1] = first;
            params.poolInitializerData = abi.encode(poolData);
            return _withCommittedParams(artifact, params);
        }

        function _withCurveDrift(StaticsGenesisLaunchArtifact memory artifact)
            private
            view
            returns (StaticsGenesisLaunchArtifact memory)
        {
            DopplerLaunchTypes.CreateParams memory params =
                abi.decode(artifact.createParams, (DopplerLaunchTypes.CreateParams));
            DopplerLaunchTypes.PoolInitializerData memory poolData =
                abi.decode(params.poolInitializerData, (DopplerLaunchTypes.PoolInitializerData));
            poolData.curves[0].shares += 1;
            params.poolInitializerData = abi.encode(poolData);
            return _withCommittedParams(artifact, params);
        }

        function _withCommittedParams(
            StaticsGenesisLaunchArtifact memory artifact,
            DopplerLaunchTypes.CreateParams memory params
        ) private view returns (StaticsGenesisLaunchArtifact memory) {
            artifact.createParams = abi.encode(params);
            artifact.createCalldata = abi.encodeCall(IDopplerAirlock.create, (params));
            artifact.createCalldataHash = keccak256(artifact.createCalldata);
            artifact.marketCommitment = keccak256(abi.encode(params, artifact.expectedStatics, artifact.expectedPoolId));
            artifact.artifactHash = deployer.launchArtifactHash(artifact);
            return artifact;
        }

        function _expectPreparedFailure(StaticsGenesisLaunchArtifact memory artifact) private {
            artifact.artifactHash = deployer.launchArtifactHash(artifact);
            vm.expectRevert();
            deployer.validatePreparedLaunch(artifact);
        }

        function _localWethCommitment(address numeraire) private view returns (bytes32) {
            return keccak256(abi.encode(numeraire, numeraire.codehash));
        }

        function _isStateChangingAccess(VmSafe.AccountAccessKind kind) private pure returns (bool) {
            return kind == VmSafe.AccountAccessKind.Call || kind == VmSafe.AccountAccessKind.DelegateCall
                || kind == VmSafe.AccountAccessKind.CallCode || kind == VmSafe.AccountAccessKind.Create
                || kind == VmSafe.AccountAccessKind.SelfDestruct;
        }

        function _prepareArtifact()
            private
            returns (
                StaticsGenesisDeploymentConfig memory config,
                StaticsFeeReceiver receiver,
                StaticsTreasuryVesting vesting,
                StaticsGenesisLaunchArtifact memory artifact
            )
        {
            config = _config();
            (receiver, vesting) = deployer.prepare(config, address(deployer));
            artifact = deployer.buildArtifact(
                config, address(deployer), receiver, vesting, vm.getNonce(address(deployer))
            );
        }

        function _assertEquivalentDeployments(
            StaticsGenesisDeployment memory monolithic,
            StaticsGenesisDeployment memory phased
        ) private view {
            IERC20 monolithicStatics = IERC20(monolithic.statics);
            IERC20 phasedStatics = IERC20(phased.statics);
            StaticsGenesisVault monolithicVault = StaticsGenesisVault(monolithic.genesisVault);
            StaticsGenesisVault phasedVault = StaticsGenesisVault(phased.genesisVault);
            assertEq(monolithicStatics.totalSupply(), phasedStatics.totalSupply());
            assertEq(monolithicVault.tokenBacking(), phasedVault.tokenBacking());
            assertEq(monolithicStatics.balanceOf(monolithic.genesisVault), phasedStatics.balanceOf(phased.genesisVault));
            assertEq(
                monolithicStatics.balanceOf(monolithic.treasuryVesting), phasedStatics.balanceOf(phased.treasuryVesting)
            );
            assertEq(monolithicVault.creditOriginationFee(), phasedVault.creditOriginationFee());
            assertEq(monolithicVault.creditExtensionFee(), phasedVault.creditExtensionFee());
            assertEq(monolithicVault.recoveryCallerShareBps(), phasedVault.recoveryCallerShareBps());
            _assertEquivalentBindings(monolithic, phased);
        }

        function _assertEquivalentBindings(
            StaticsGenesisDeployment memory monolithic,
            StaticsGenesisDeployment memory phased
        ) private view {
            StaticsFeeReceiver monolithicReceiver = StaticsFeeReceiver(payable(monolithic.feeReceiver));
            StaticsFeeReceiver phasedReceiver = StaticsFeeReceiver(payable(phased.feeReceiver));
            StaticsGenesis monolithicGenesis = StaticsGenesis(monolithic.genesis);
            StaticsGenesis phasedGenesis = StaticsGenesis(phased.genesis);
            assertEq(monolithicReceiver.reserveShareBps(), phasedReceiver.reserveShareBps());
            assertEq(monolithicReceiver.statics(), monolithic.statics);
            assertEq(phasedReceiver.statics(), phased.statics);
            assertEq(monolithicReceiver.reserveVault(), monolithic.genesisVault);
            assertEq(phasedReceiver.reserveVault(), phased.genesisVault);
            assertEq(monolithicReceiver.activeDistributor(), monolithic.genesisDistributor);
            assertEq(phasedReceiver.activeDistributor(), phased.genesisDistributor);
            assertEq(monolithicGenesis.balanceOf(monolithic.genesisVault), phasedGenesis.balanceOf(phased.genesisVault));
            assertEq(
                monolithicGenesis.balanceOf(monolithic.treasuryVesting), phasedGenesis.balanceOf(phased.treasuryVesting)
            );
            assertEq(monolithicGenesis.pendingOwner(), phasedGenesis.pendingOwner());
        }

        function _config() private returns (StaticsGenesisDeploymentConfig memory config) {
            return _configFor(airlock, initializer);
        }

        function _configFor(MockDeploymentAirlock configuredAirlock, MockDeploymentInitializer configuredInitializer)
            private
            returns (StaticsGenesisDeploymentConfig memory config)
        {
            MockDeploymentTokenFactory tokenFactory = new MockDeploymentTokenFactory();
            DeploymentModule governanceFactory = new DeploymentModule();
            DeploymentModule noOpMigrator = new DeploymentModule();
            config = StaticsGenesisDeploymentConfig({
                governance: governance,
                treasury: treasury,
                numeraire: address(weth),
                integrator: address(0),
                modules: StaticsDopplerLaunchConfig.Modules({
                    airlock: address(configuredAirlock),
                    tokenFactory: address(tokenFactory),
                    governanceFactory: address(governanceFactory),
                    poolInitializer: address(configuredInitializer),
                    noOpMigrator: address(noOpMigrator)
                }),
                salt: keccak256("STATICS_DOPPLER_TEST"),
                fee: 30_000,
                genesisRewardShareBps: 5_000,
                reserveShareBps: 5_000,
                creditOriginationFee: 0.003 ether,
                creditExtensionFee: 0.003 ether,
                recoveryCallerShareBps: 2_000,
                genesisEpochEnd: block.timestamp + 7 days,
                tokenURI: "ipfs://statics/token.json",
                contractURI: "ipfs://statics-genesis/contract.json",
                externalURLBase: "https://statics.finance/genesis/"
            });
        }

        function _codeHashes() private pure returns (StaticsDopplerLaunchConfig.RuntimeCodeHashes memory codeHashes) {
            codeHashes = StaticsDopplerLaunchConfig.RuntimeCodeHashes({
                airlock: keccak256("airlock"),
                tokenFactory: keccak256("tokenFactory"),
                governanceFactory: keccak256("governanceFactory"),
                poolInitializer: keccak256("poolInitializer"),
                noOpMigrator: keccak256("noOpMigrator")
            });
        }

        function _expectedTokenFactoryData(string memory tokenURI, address beneficiary)
            private
            pure
            returns (bytes memory)
        {
            DopplerLaunchTypes.VestingSchedule[] memory schedules = new DopplerLaunchTypes.VestingSchedule[](1);
            schedules[0] = DopplerLaunchTypes.VestingSchedule({cliff: 0, duration: 60 days});
            address[] memory beneficiaries = new address[](1);
            beneficiaries[0] = beneficiary;
            uint256[] memory scheduleIds = new uint256[](1);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100_100_000 ether;
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
    }

    contract MockCloneableDopplerToken is ERC20 {
        struct VestingData {
            uint256 totalAmount;
            uint256 releasedAmount;
        }

        struct TokenFactoryData {
            DopplerLaunchTypes.VestingSchedule[] schedules;
            address[] beneficiaries;
            uint256[] scheduleIds;
            uint256[] amounts;
        }

        bool private initialized;
        uint256 public vestingStart;
        uint256 public vestedTotalAmount;
        DopplerLaunchTypes.VestingSchedule[] public vestingSchedules;
        mapping(address beneficiary => mapping(uint256 scheduleId => VestingData)) public vestingOf;
        mapping(address beneficiary => uint256 amount) public totalAllocatedOf;
        mapping(address beneficiary => uint256[] scheduleIds) private scheduleIdsOf;

        constructor() ERC20("Statics", "STATICS") {}

        function initialize(uint256 initialSupply, address recipient, bytes calldata tokenFactoryData) external {
            require(!initialized, "INITIALIZED");
            initialized = true;
            TokenFactoryData memory data = _decodeTokenFactoryData(tokenFactoryData);
            require(data.schedules.length == 1 && data.beneficiaries.length == 1, "VESTING_LENGTH");
            require(data.scheduleIds.length == 1 && data.amounts.length == 1, "ALLOCATION_LENGTH");
            require(data.scheduleIds[0] == 0, "SCHEDULE_ID");
            vestingStart = block.timestamp;
            vestingSchedules.push(data.schedules[0]);
            address beneficiary = data.beneficiaries[0];
            uint256 amount = data.amounts[0];
            vestingOf[beneficiary][0] = VestingData({totalAmount: amount, releasedAmount: 0});
            totalAllocatedOf[beneficiary] = amount;
            scheduleIdsOf[beneficiary].push(0);
            vestedTotalAmount = amount;
            _mint(address(this), amount);
            _mint(recipient, initialSupply - amount);
        }

        function _decodeTokenFactoryData(bytes calldata encoded) private pure returns (TokenFactoryData memory data) {
            (,, data.schedules, data.beneficiaries, data.scheduleIds, data.amounts,,,,,) = abi.decode(
                encoded,
                (
                    string,
                    string,
                    DopplerLaunchTypes.VestingSchedule[],
                    address[],
                    uint256[],
                    uint256[],
                    string,
                    uint256,
                    uint48,
                    address,
                    address[]
                )
            );
        }

        function vestingScheduleCount() external view returns (uint256) {
            return vestingSchedules.length;
        }

        function getScheduleIdsOf(address beneficiary) external view returns (uint256[] memory) {
            return scheduleIdsOf[beneficiary];
        }

        function releaseFor(address beneficiary, uint256 scheduleId, uint256 amount) external {
            require(scheduleId == 0, "SCHEDULE_ID");
            VestingData storage data = vestingOf[beneficiary][scheduleId];
            DopplerLaunchTypes.VestingSchedule memory schedule = vestingSchedules[scheduleId];
            uint256 elapsed = block.timestamp - vestingStart;
            uint256 vested =
                elapsed >= schedule.duration ? data.totalAmount : data.totalAmount * elapsed / schedule.duration;
            uint256 available = vested - data.releasedAmount;
            uint256 released = amount == 0 ? available : amount;
            require(released != 0 && released <= available, "RELEASE");
            data.releasedAmount += released;
            _transfer(address(this), beneficiary, released);
        }
    }

    contract MockDeploymentTokenFactory is IDopplerERC20V1Factory {
        bytes20 private constant CLONE_INIT_CODE_PREFIX = hex"602c3d8160093d39f33d3d3d3d363d3d37363d73";
        bytes13 private constant CLONE_INIT_CODE_SUFFIX = hex"5af43d3d93803e602a57fd5bf3";

        address public immutable override IMPLEMENTATION;

        constructor() {
            IMPLEMENTATION = address(new MockCloneableDopplerToken());
        }

        function create(uint256 initialSupply, address recipient, bytes32 salt, bytes calldata tokenFactoryData)
            external
            returns (address asset)
        {
            bytes memory initCode = abi.encodePacked(CLONE_INIT_CODE_PREFIX, IMPLEMENTATION, CLONE_INIT_CODE_SUFFIX);
            assembly {
                asset := create2(0, add(initCode, 0x20), mload(initCode), salt)
            }
            require(asset != address(0), "CREATE2");
            MockCloneableDopplerToken(asset).initialize(initialSupply, recipient, tokenFactoryData);
        }
    }
