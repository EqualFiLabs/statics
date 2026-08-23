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
    address public immutable override owner;
    MockDeploymentInitializer public immutable initializer;
    uint256 public lastNumTokensToSell;
    uint256 public residual = 1 ether;

    constructor(address owner_, MockDeploymentInitializer initializer_) {
        owner = owner_;
        initializer = initializer_;
    }

    function setResidual(uint256 residual_) external {
        residual = residual_;
    }

    function create(DopplerLaunchTypes.CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        MockDopplerToken token = new MockDopplerToken(address(this));
        require(params.initialSupply == token.totalSupply(), "SUPPLY");
        require(params.numTokensToSell == 800_000_000 ether, "INVENTORY");
        lastNumTokensToSell = params.numTokensToSell;
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
            StaticsFeeReceiver receiver = StaticsFeeReceiver(payable(deployment.feeReceiver));
            GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
            GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

            assertEq(statics.totalSupply(), 1_000_000_000 ether);
            assertEq(statics.balanceOf(treasury), 200_000_000 ether);
            assertEq(airlock.lastNumTokensToSell(), 800_000_000 ether);
            assertEq(statics.balanceOf(address(initializer)), 799_999_999 ether);
            assertEq(genesis.balanceOf(address(vault)), 5_555);
            assertEq(vault.requiredBacking(), 0);
            assertEq(vault.tokenBacking(), 0);
            assertEq(statics.balanceOf(address(vault)), 1 ether);
            assertEq(statics.balanceOf(deployment.allocationEscrow), 0);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolId(), deployment.poolId);
            assertEq(receiver.poolInitializer(), address(initializer));
            assertEq(initializer.getShares(deployment.poolId, address(receiver)), 0.95 ether);
            assertEq(initializer.getShares(deployment.poolId, airlock.owner()), 0.05 ether);
            assertEq(statics.balanceOf(deployment.genesisVault), 1 ether);
            assertEq(receiver.activeDistributor(), address(distributor));
            assertEq(registry.activeConsumer(), address(distributor));
            assertEq(receiver.reserveVault(), address(vault));
            assertEq(receiver.reserveShareBps(), 5_000);
            assertEq(registry.treasury(), treasury);
            assertEq(vault.genesisEpochEnd(), block.timestamp + 7 days);
            assertTrue(vault.epochActive());
            assertEq(vault.reserveETH(), 0);
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

        function testFourCurveFixtureUsesExactPlaceholderWeights() public view {
            DopplerLaunchTypes.Curve[] memory curves = deployer.defaultCurves();
            assertEq(curves.length, 4);
            assertEq(curves[0].shares, 0.5 ether);
            assertEq(curves[1].shares, 0.25 ether);
            assertEq(curves[2].shares, 0.24 ether);
            assertEq(curves[3].shares, 0.01 ether);
            assertEq(curves[0].numPositions, 11);
            assertEq(curves[3].tickLower, -84_100);
            assertEq(curves[3].tickUpper, -83_000);
            assertEq(deployer.APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH(), bytes32(0));
            uint256 epochEnd = block.timestamp + 7 days;
            address canonicalWeth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
            bytes32 canonicalWethHash = 0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353;
            bytes32 launchHash =
                deployer.launchConfigHash(30_000, 5_000, 5_000, epochEnd, canonicalWeth, canonicalWethHash);
            assertTrue(launchHash != bytes32(0));
            assertTrue(
                launchHash
                    != deployer.launchConfigHash(30_000, 5_000, 4_000, epochEnd, canonicalWeth, canonicalWethHash)
            );
            assertTrue(
                launchHash
                    != deployer.launchConfigHash(30_000, 5_000, 5_000, epochEnd + 1, canonicalWeth, canonicalWethHash)
            );
            assertTrue(
                launchHash
                    != deployer.launchConfigHash(
                        30_000, 5_000, 5_000, epochEnd, address(uint160(canonicalWeth) + 1), canonicalWethHash
                    )
            );
            assertTrue(
                launchHash
                    != deployer.launchConfigHash(
                        30_000, 5_000, 5_000, epochEnd, canonicalWeth, bytes32(uint256(canonicalWethHash) + 1)
                    )
            );
        }

        function testRejectsExcessiveMulticurveResidual() public {
            airlock.setResidual(101 ether);
            StaticsGenesisDeploymentConfig memory config = _config();
            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.ExcessiveMulticurveResidual.selector, 101 ether, 100 ether)
            );
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
                genesisEpochEnd: block.timestamp + 7 days,
                tokenURI: "ipfs://statics/token.json",
                contractURI: "ipfs://statics-genesis/contract.json",
                externalURLBase: "https://statics.finance/genesis/"
            });
        }
    }
