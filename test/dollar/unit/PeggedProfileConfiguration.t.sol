// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ConfigurePeggedProfile, PeggedProfileConfig} from "script/dollar/ConfigurePeggedProfile.s.sol";
import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {StaticsTimelock} from "src/governance/StaticsTimelock.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract PeggedProfileConfigurationTest is Test {
    ConfigurePeggedProfile internal ceremony;
    CoreBootstrapDeployment internal deployment;
    StaticsTimelock internal timelock;
    MockUSDC internal usdc;
    MockETHUSDOracle internal usdcOracle;
    PeggedProfileConfig internal config;
    address internal alice = makeAddr("alice");

    function setUp() public {
        ceremony = new ConfigurePeggedProfile();
        address[] memory proposers = new address[](1);
        proposers[0] = address(ceremony);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new StaticsTimelock(proposers, executors, address(0));

        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle wethOracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory bootstrap;
        bootstrap.owner = address(timelock);
        bootstrap.profileGuardian = makeAddr("profileGuardian");
        bootstrap.initialOracle = address(wethOracle);
        bootstrap.weth = address(weth);
        bootstrap.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(bootstrap);

        usdc = new MockUSDC();
        usdcOracle = new MockETHUSDOracle(1e18, 30 days);
        config = PeggedProfileConfig({
            collateralToken: address(usdc),
            oracle: address(usdcOracle),
            pegMinPriceWad: 0.995e18,
            pegMaxPriceWad: 1.005e18,
            mintFeeBps: 5,
            redemptionFeeBps: 7,
            debtCeiling: 10_000_000e18
        });
    }

    function test_OneTimelockBatchCreatesActivatesAndMints() public {
        bytes32 salt = keccak256("pegged profile");
        uint256 nextSeriesId = CoreViewFacet(deployment.core).nextSeriesId();
        (uint256 profileId, bytes32 operationId) = ceremony.schedule(deployment.core, config, salt);
        assertTrue(timelock.isOperationPending(operationId));

        vm.expectRevert();
        ceremony.execute(deployment.core, profileId, config, salt);

        vm.warp(block.timestamp + timelock.getMinDelay());
        usdcOracle.setUpdatedAt(block.timestamp);
        ceremony.execute(deployment.core, profileId, config, salt);

        IStaticsDollarCore core = IStaticsDollarCore(deployment.core);
        assertEq(uint256(core.collateralProfile(profileId).mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Active));
        assertEq(core.collateralProfile(profileId).activeSeriesId, 0);
        assertEq(CoreViewFacet(deployment.core).profileSeriesCount(profileId), 0);
        assertEq(CoreViewFacet(deployment.core).nextSeriesId(), nextSeriesId);

        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = core.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(deployment.core, preview.totalCollateralIn);
        uint256 collateralIn = core.mintPegged(profileId, 100e18, preview.totalCollateralIn, alice);
        vm.stopPrank();

        assertEq(collateralIn, preview.totalCollateralIn);
        assertEq(CoreViewFacet(deployment.core).nextSeriesId(), nextSeriesId);
    }

    function test_ScheduledBatchCannotExecuteWithConfigurationDrift() public {
        bytes32 salt = keccak256("bound profile");
        (uint256 profileId,) = ceremony.schedule(deployment.core, config, salt);
        vm.warp(block.timestamp + timelock.getMinDelay());
        usdcOracle.setUpdatedAt(block.timestamp);

        PeggedProfileConfig memory changed = config;
        changed.debtCeiling += 1;
        vm.expectRevert();
        ceremony.execute(deployment.core, profileId, changed, salt);

        ceremony.execute(deployment.core, profileId, config, salt);
        assertEq(IStaticsDollarCore(deployment.core).collateralProfile(profileId).debtCeiling, config.debtCeiling);
    }
}
