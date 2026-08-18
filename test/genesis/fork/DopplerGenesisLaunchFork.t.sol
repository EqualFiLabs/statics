// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../../script/DeployStaticsGenesis.s.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsDopplerLaunchConfig} from "../../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../../mocks/MockDopplerToken.sol";

/// @notice Current-network integration proof against official Doppler deployments.
contract DopplerGenesisLaunchForkTest is Test {
    function testRobinhoodDopplerLaunchEncodingAndWiring() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 4_663);
        _deployAndAssert();
    }

    function testBaseSepoliaDopplerLaunchEncodingAndWiring() public {
        string memory rpcUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 84_532);
        _deployAndAssert();
    }

    function _deployAndAssert() private {
        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        _assertCode(modules.airlock);
        _assertCode(modules.tokenFactory);
        _assertCode(modules.governanceFactory);
        _assertCode(modules.poolInitializer);
        _assertCode(modules.noOpMigrator);
        _assertCode(modules.rehype);

        address governance = makeAddr("forkGovernance");
        address treasury = makeAddr("forkTreasury");
        MockDopplerToken weth = new MockDopplerToken(address(this));
        DeployStaticsGenesis deployer = new DeployStaticsGenesis();
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: governance,
            treasury: treasury,
            numeraire: address(weth),
            integrator: address(0),
            modules: modules,
            salt: keccak256(abi.encode("STATICS_DOPPLER_FORK", block.chainid, block.number)),
            startFee: 30_000,
            endFee: 5_000,
            feeDecayDuration: 3 days,
            genesisRewardShareBps: 5_000,
            tokenURI: "ipfs://statics/token.json",
            contractURI: "ipfs://statics-genesis/contract.json",
            externalURLBase: "https://statics.finance/genesis/"
        });

        StaticsGenesisDeployment memory deployment = deployer.deploy(config, address(deployer));
        IERC20 statics = IERC20(deployment.statics);
        StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
        StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
        StaticsFeeReceiver receiver = StaticsFeeReceiver(deployment.feeReceiver);
        GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
        GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

        assertEq(statics.totalSupply(), 1_000_000_000 ether);
        assertEq(statics.balanceOf(treasury), 200_000_000 ether);
        assertEq(genesis.balanceOf(address(vault)), 5_555);
        assertEq(vault.requiredBacking(), 0);
        assertEq(receiver.statics(), deployment.statics);
        assertEq(receiver.activeDistributor(), address(distributor));
        assertEq(registry.activeConsumer(), address(distributor));
        assertEq(receiver.pendingOwner(), governance);

        vm.deal(treasury, 1 ether);
        vm.startPrank(treasury);
        statics.approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: vault.nativeAcquisitionFee()}(1, treasury);
        distributor.registerGenesis(1);
        vm.stopPrank();
        assertEq(genesis.ownerOf(1), treasury);
        assertEq(vault.requiredBacking(), vault.GENESIS_PRICE());
    }

    function _assertCode(address target) private view {
        assertGt(target.code.length, 0, "missing official Doppler module");
    }
}
