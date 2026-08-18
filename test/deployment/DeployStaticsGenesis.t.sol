// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../script/DeployStaticsGenesis.s.sol";
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
    function isDopplerHookEnabled(address) external pure returns (uint256) {
        return 1;
    }
}

contract MockDeploymentRehype {
    address public asset;
    address public numeraire;
    address public buybackDst;
    address public beneficiary;
    uint256 public beneficiaryShares;
    DopplerLaunchTypes.FeeDistributionInfo public distribution;

    function initialize(address asset_, DopplerLaunchTypes.RehypeInitData memory data) external {
        asset = asset_;
        numeraire = data.numeraire;
        buybackDst = data.buybackDst;
        beneficiary = data.feeBeneficiaries[0].beneficiary;
        beneficiaryShares = data.feeBeneficiaries[0].shares;
        distribution = data.feeDistributionInfo;
    }

    function getPoolInfo(bytes32) external view returns (address, address, address) {
        return (asset, numeraire, buybackDst);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? beneficiaryShares : 0;
    }

    function collectFees(address) external pure {}

    function setFeeDistribution(
        bytes32,
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 n0,
        uint256 n1,
        uint256 n2,
        uint256 n3
    ) external {
        distribution = DopplerLaunchTypes.FeeDistributionInfo(a0, a1, a2, a3, n0, n1, n2, n3);
    }
}

contract MockDeploymentAirlock is IDopplerAirlock {
    address private constant GOVERNANCE_DEAD = address(0xdead);
    address private constant MIGRATION_DEAD = 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD;
    address public immutable override owner;
    MockDeploymentRehype public immutable rehype;
    uint256 public lastNumTokensToSell;

    constructor(address owner_, MockDeploymentRehype rehype_) {
        owner = owner_;
        rehype = rehype_;
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
        DopplerLaunchTypes.RehypeInitData memory rehypeData =
            abi.decode(poolData.onInitializationDopplerHookCalldata, (DopplerLaunchTypes.RehypeInitData));
        rehype.initialize(address(token), rehypeData);

        address treasury = abi.decode(params.governanceFactoryData, (address));
        token.transfer(params.poolInitializer, params.numTokensToSell - 20 ether);
        token.transfer(treasury, token.balanceOf(address(this)));
        return (address(token), address(token), GOVERNANCE_DEAD, treasury, MIGRATION_DEAD);
    }
}

    contract DeployStaticsGenesisTest is Test {
        DeployStaticsGenesis private deployer;
        MockDopplerToken private weth;
        MockDeploymentRehype private rehype;
        MockDeploymentInitializer private initializer;
        MockDeploymentAirlock private airlock;
        address private governance;
        address private treasury;

        function setUp() public {
            governance = makeAddr("governance");
            treasury = makeAddr("treasury");
            deployer = new DeployStaticsGenesis();
            weth = new MockDopplerToken(address(this));
            rehype = new MockDeploymentRehype();
            initializer = new MockDeploymentInitializer();
            airlock = new MockDeploymentAirlock(makeAddr("airlockOwner"), rehype);
        }

        function testDeploysDopplerGenesisStackWithExactAllocations() public {
            StaticsGenesisDeployment memory deployment = deployer.deploy(_config(), address(deployer));
            IERC20 statics = IERC20(deployment.statics);
            StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
            StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
            StaticsFeeReceiver receiver = StaticsFeeReceiver(deployment.feeReceiver);
            GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
            GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

            assertEq(statics.totalSupply(), 1_000_000_000 ether);
            assertEq(statics.balanceOf(treasury), 200_000_000 ether);
            assertEq(airlock.lastNumTokensToSell(), 800_000_000 ether);
            assertEq(statics.balanceOf(address(initializer)), 799_999_980 ether);
            assertEq(genesis.balanceOf(address(vault)), 5_555);
            assertEq(vault.requiredBacking(), 0);
            assertEq(vault.tokenBacking(), 0);
            assertEq(statics.balanceOf(address(vault)), 20 ether);
            assertEq(statics.balanceOf(deployment.allocationEscrow), 0);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolId(), deployment.poolId);
            assertEq(receiver.activeDistributor(), address(distributor));
            assertEq(registry.activeConsumer(), address(distributor));
            assertEq(receiver.pendingOwner(), governance);
            assertEq(registry.pendingOwner(), governance);
            assertEq(vault.pendingOwner(), governance);
            assertEq(genesis.pendingOwner(), governance);
            assertEq(distributor.pendingOwner(), governance);

            (,, uint256 assetBeneficiary, uint256 assetLp,,, uint256 numeraireBeneficiary, uint256 numeraireLp) =
                rehype.distribution();
            assertEq(assetBeneficiary, 0.75 ether);
            assertEq(assetLp, 0.25 ether);
            assertEq(numeraireBeneficiary, 0.75 ether);
            assertEq(numeraireLp, 0.25 ether);
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
        }

        function testRejectsInvalidFeeScheduleAndMetadata() public {
            StaticsGenesisDeploymentConfig memory config = _config();
            config.startFee = 5_000;
            config.endFee = 10_000;
            vm.expectRevert(
                abi.encodeWithSelector(DeployStaticsGenesis.InvalidFeeSchedule.selector, 5_000, 10_000, 3 days)
            );
            deployer.deploy(config, address(deployer));

            config = _config();
            config.contractURI = "";
            vm.expectRevert(DeployStaticsGenesis.InvalidMetadataURI.selector);
            deployer.deploy(config, address(deployer));
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
                    noOpMigrator: address(noOpMigrator),
                    rehype: address(rehype)
                }),
                salt: keccak256("STATICS_DOPPLER_TEST"),
                startFee: 30_000,
                endFee: 5_000,
                feeDecayDuration: 3 days,
                genesisRewardShareBps: 5_000,
                tokenURI: "ipfs://statics/token.json",
                contractURI: "ipfs://statics-genesis/contract.json",
                externalURLBase: "https://statics.finance/genesis/"
            });
        }
    }
