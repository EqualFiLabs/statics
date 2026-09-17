// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {
    ConfigureStaticsPhaseOneLiquidity,
    StaticsPhaseOneLiquidityConfig
} from "../../script/ConfigureStaticsPhaseOneLiquidity.s.sol";
import {DeployStaticsPhaseOne, StaticsPhaseOneDeployment} from "../../script/DeployStaticsPhaseOne.s.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PhaseOneCeremonyPoolManagerMock {}

contract PhaseOneUnexpectedFacet {
    function unexpectedSelector() external pure returns (bool) {
        return true;
    }
}

contract PhaseOneFakeTimelock {}

contract ConfigureStaticsPhaseOneLiquidityTest is Test {
    function testBatchContainsOnlyPhaseOneHookAndHarvesterCalls() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        address diamond = makeAddr("diamond");
        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: makeAddr("poolManager"),
            hook: makeAddr("hook"),
            permanentLiquidityHarvester: makeAddr("harvester"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: bytes32(0),
            hookCodeHash: bytes32(0)
        });

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, config);

        assertEq(targets.length, 2);
        assertEq(values.length, 2);
        assertEq(payloads.length, 2);
        assertEq(targets[0], diamond);
        assertEq(targets[1], diamond);
        assertEq(values[0], 0);
        assertEq(values[1], 0);
        assertEq(_selector(payloads[0]), IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector);
        assertEq(_selector(payloads[1]), IStaticsProtocolPools.setPermanentLiquidityHarvester.selector);
        assertEq(_addressArgument(payloads[0], 0), config.poolManager);
        assertEq(_addressArgument(payloads[0], 1), config.hook);
        assertEq(_addressArgument(payloads[1], 0), config.permanentLiquidityHarvester);
    }

    function testTimelockBatchInstallsOnlyPhaseOneLiquidityDependencies() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        address harvester = makeAddr("harvester");
        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: address(poolManager),
            hook: deployment.swapFeeHook,
            permanentLiquidityHarvester: harvester,
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            hookCodeHash: deployment.swapFeeHook.codehash
        });

        bytes32 salt = keccak256("install Phase 1 liquidity");
        (bytes32 operationId, uint256 delay) = _schedule(ceremony, deployment.diamond, config, salt, address(timelock));
        assertTrue(timelock.isOperationPending(operationId));

        vm.warp(block.timestamp + delay);
        ceremony.execute(deployment.diamond, config, salt);
        _assertInstalled(deployment, address(poolManager), harvester);
    }

    function testCeremonyRequiresExactHookCodeHash() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment,) = _deployPhaseOne(address(ceremony), address(poolManager));
        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: address(poolManager),
            hook: deployment.swapFeeHook,
            permanentLiquidityHarvester: makeAddr("harvester"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            hookCodeHash: bytes32(0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.InvalidCodeHash.selector,
                deployment.swapFeeHook,
                bytes32(0),
                deployment.swapFeeHook.codehash
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject missing hook hash"));
    }

    function testCeremonyRejectsDiamondOutsideExactPhaseOneManifest() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        PhaseOneUnexpectedFacet unexpectedFacet = new PhaseOneUnexpectedFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PhaseOneUnexpectedFacet.unexpectedSelector.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(unexpectedFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        vm.prank(address(timelock));
        IDiamondCut(deployment.diamond).diamondCut(cut, address(0), "");

        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: address(poolManager),
            hook: deployment.swapFeeHook,
            permanentLiquidityHarvester: makeAddr("harvester"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            hookCodeHash: deployment.swapFeeHook.codehash
        });

        vm.expectRevert(abi.encodeWithSelector(ConfigureStaticsPhaseOneLiquidity.UnexpectedFacetCount.selector, 14, 15));
        ceremony.prepare(deployment.diamond, config, keccak256("reject expanded manifest"));
    }

    function testCeremonyRejectsOwnerThatIsNotExactStaticsTimelock() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        PhaseOneFakeTimelock fakeTimelock = new PhaseOneFakeTimelock();
        vm.prank(address(timelock));
        IERC173(deployment.diamond).transferOwnership(address(fakeTimelock));

        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: address(poolManager),
            hook: deployment.swapFeeHook,
            permanentLiquidityHarvester: makeAddr("harvester"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            hookCodeHash: deployment.swapFeeHook.codehash
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.InvalidCodeHash.selector,
                address(fakeTimelock),
                keccak256(type(StaticsTimelock).runtimeCode),
                address(fakeTimelock).codehash
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject fake timelock"));
    }

    function _deployPhaseOne(address multisig, address poolManager)
        private
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        return deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: multisig,
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: poolManager, inputFeeBps: 25, outputFeeBps: 25, poolManagerCodeHash: poolManager.codehash
            })
        );
    }

    function _schedule(
        ConfigureStaticsPhaseOneLiquidity ceremony,
        address diamond,
        StaticsPhaseOneLiquidityConfig memory config,
        bytes32 salt,
        address expectedTimelock
    ) private returns (bytes32 operationId, uint256 delay) {
        (address target, uint256 value, bytes memory data, bytes32 id, uint256 requiredDelay) =
            ceremony.prepare(diamond, config, salt);
        assertEq(target, expectedTimelock);
        assertEq(value, 0);
        vm.prank(address(ceremony));
        (bool scheduled,) = target.call{value: value}(data);
        assertTrue(scheduled);
        return (id, requiredDelay);
    }

    function _assertInstalled(StaticsPhaseOneDeployment memory deployment, address poolManager, address harvester)
        private
        view
    {
        (address installedPoolManager, address installedHook, bool installed) =
            IStaticsBasketLiquidity(deployment.diamond).liquidityIntegration();
        assertTrue(installed);
        assertEq(installedPoolManager, poolManager);
        assertEq(installedHook, deployment.swapFeeHook);
        assertEq(IStaticsProtocolPools(deployment.diamond).permanentLiquidityHarvester(), harvester);
    }

    function _selector(bytes memory payload) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(payload, 0x20))
        }
    }

    function _addressArgument(bytes memory payload, uint256 index) private pure returns (address value) {
        assembly ("memory-safe") {
            value := mload(add(add(payload, 0x24), mul(index, 0x20)))
        }
    }
}
