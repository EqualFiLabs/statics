// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {PoolManager} from "@v4-core/PoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {Airlock, ModuleState} from "src/Airlock.sol";
import {DopplerHookInitializer} from "src/initializers/DopplerHookInitializer.sol";
import {DopplerERC20V1Factory} from "src/tokens/DopplerERC20V1Factory.sol";
import {
    DeployGenesisTestnetDoppler,
    GenesisTestnetDopplerDeployment
} from "../script/DeployGenesisTestnetDoppler.s.sol";

contract GenesisTestnetDopplerDeploymentTest is Test {
    DeployGenesisTestnetDoppler private deployer;
    PoolManager private poolManager;
    address private feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        deployer = new DeployGenesisTestnetDoppler();
        poolManager = new PoolManager(address(this));
    }

    function testDeploysAndConfiguresTheMinimalGenesisModules() public {
        GenesisTestnetDopplerDeployment memory deployment =
            deployer.deploy(address(deployer), feeRecipient, address(poolManager), address(deployer));

        Airlock airlock = Airlock(payable(deployment.airlock));
        assertEq(airlock.owner(), feeRecipient);
        assertEq(uint256(airlock.getModuleState(deployment.tokenFactory)), uint256(ModuleState.TokenFactory));
        assertEq(uint256(airlock.getModuleState(deployment.governanceFactory)), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(deployment.poolInitializer)), uint256(ModuleState.PoolInitializer));
        assertEq(uint256(airlock.getModuleState(deployment.noOpMigrator)), uint256(ModuleState.LiquidityMigrator));
        assertEq(DopplerERC20V1Factory(deployment.tokenFactory).IMPLEMENTATION(), deployment.tokenImplementation);
        assertGt(deployment.tokenImplementation.code.length, 0);

        DopplerHookInitializer initializer = DopplerHookInitializer(payable(deployment.poolInitializer));
        assertEq(address(initializer.airlock()), deployment.airlock);
        assertEq(address(initializer.poolManager()), address(poolManager));
        assertEq(uint160(deployment.poolInitializer) & Hooks.ALL_HOOK_MASK, deployer.REQUIRED_HOOK_FLAGS());
    }

    function testRejectsZeroFeeRecipient() public {
        vm.expectRevert(DeployGenesisTestnetDoppler.ZeroAddress.selector);
        deployer.deploy(address(deployer), address(0), address(poolManager), address(deployer));
    }

    function testRunRejectsNonTestnetBeforeReadingSecrets() public {
        vm.expectRevert(abi.encodeWithSelector(DeployGenesisTestnetDoppler.UnsupportedChain.selector, block.chainid));
        deployer.run();
    }
}
