// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../script/DeployStaticsGenesis.s.sol";
import {DeployStaticsGenesisLocalFork} from "../../script/DeployStaticsGenesisLocalFork.s.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {DopplerLaunchTypes, IDopplerAirlock} from "../../src/genesis/doppler/DopplerLaunchTypes.sol";
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
    address public override owner;
    MockDeploymentInitializer public immutable initializer;
    uint256 public lastNumTokensToSell;
    bytes32 public lastTokenFactoryDataHash;
    uint256 public residual = 1 ether;

    constructor(address owner_, MockDeploymentInitializer initializer_) {
        owner = owner_;
        initializer = initializer_;
    }

    function setResidual(uint256 residual_) external {
        residual = residual_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function create(DopplerLaunchTypes.CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        MockDopplerToken token = new MockDopplerToken(address(this));
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
        initializer.configure(
            address(token), params.numeraire, poolData.fee, poolData.tickSpacing, poolData.beneficiaries
        );

        address treasury = abi.decode(params.governanceFactoryData, (address));
        token.transfer(params.poolInitializer, params.numTokensToSell - residual);
        token.transfer(treasury, token.balanceOf(address(this)));
        return (address(token), address(token), GOVERNANCE_DEAD, treasury, MIGRATION_DEAD);
    }
}

    contract DeployStaticsGenesisHarness is DeployStaticsGenesis {
        function requireApprovedProductionConfig(bytes32 currentHash) external pure {
            _requireApprovedProductionConfig(currentHash);
        }
    }

    contract DeployStaticsGenesisTest is Test {
        DeployStaticsGenesis private deployer;
        MockDopplerToken private weth;
        MockDeploymentInitializer private initializer;
        MockDeploymentAirlock private airlock;
        address private governance;
        address private treasury;

        function setUp() public {
            governance = makeAddr("governance");
            treasury = makeAddr("treasury");
            deployer = new DeployStaticsGenesis();
            weth = new MockDopplerToken(address(this));
            initializer = new MockDeploymentInitializer();
            airlock = new MockDeploymentAirlock(makeAddr("airlockOwner"), initializer);
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
                airlock.lastTokenFactoryDataHash(), keccak256(_expectedTokenFactoryData("ipfs://statics/token.json"))
            );
            assertEq(statics.balanceOf(address(initializer)), 799_999_999 ether);
            assertEq(genesis.balanceOf(address(vault)), 5_000);
            assertEq(genesis.balanceOf(address(vesting)), 555);
            assertEq(genesis.ownerOf(5_001), address(vesting));
            assertEq(genesis.ownerOf(5_555), address(vesting));
            assertEq(vault.circulatingGenesis(), 555);
            assertEq(vault.requiredBacking(), 99_900_000 ether);
            assertEq(vault.tokenBacking(), 99_900_000 ether);
            assertEq(statics.balanceOf(address(vault)), 99_900_001 ether);
            assertEq(statics.balanceOf(address(vesting)), 100_100_000 ether);
            assertEq(vesting.recipientAdmin(), governance);
            assertEq(vesting.withdrawalRecipient(), treasury);
            assertEq(vesting.bootstrapper(), address(0));
            assertEq(vesting.releasableStatics(), 0);
            assertEq(vesting.releasableGenesis(), 0);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolId(), deployment.poolId);
            assertEq(receiver.poolInitializer(), address(initializer));
            assertEq(initializer.getShares(deployment.poolId, address(receiver)), 0.95 ether);
            assertEq(initializer.getShares(deployment.poolId, airlock.owner()), 0.05 ether);
            assertEq(statics.balanceOf(deployment.genesisVault), 99_900_001 ether);
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

        function testRejectsExcessiveMulticurveResidual() public {
            airlock.setResidual(101 ether);
            StaticsGenesisDeploymentConfig memory config = _config();
            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.ExcessiveMulticurveResidual.selector, 101 ether, 100 ether)
            );
            deployer.deploy(config, address(deployer));
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

        function _config() private returns (StaticsGenesisDeploymentConfig memory config) {
            DeploymentModule tokenFactory = new DeploymentModule();
            DeploymentModule governanceFactory = new DeploymentModule();
            DeploymentModule noOpMigrator = new DeploymentModule();
            config = StaticsGenesisDeploymentConfig({
                governance: governance,
                treasury: treasury,
                numeraire: address(weth),
                integrator: address(0),
                modules: StaticsDopplerLaunchConfig.Modules({
                    airlock: address(airlock),
                    tokenFactory: address(tokenFactory),
                    governanceFactory: address(governanceFactory),
                    poolInitializer: address(initializer),
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

        function _expectedTokenFactoryData(string memory tokenURI) private pure returns (bytes memory) {
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
    }
