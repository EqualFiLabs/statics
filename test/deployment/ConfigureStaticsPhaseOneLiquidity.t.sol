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
import {IStaticsPermissionedPools} from "../../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../../src/interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PhaseOneCeremonyPoolManagerMock {}

contract PhaseOneCeremonyDependencyMock {}

contract PhaseOneCeremonyCanonicalPositionManagerMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract PhaseOneCeremonyClaimsMock {
    address public immutable poolManager;
    address public immutable permissionedHook;
    address public positionManager;

    constructor(address manager, address hook) {
        poolManager = manager;
        permissionedHook = hook;
    }

    function bindPositionManager(address manager) external {
        require(positionManager == address(0));
        positionManager = manager;
    }
}

contract PhaseOneCeremonyPeripheryMock {
    address public immutable poolManager;
    address public immutable permit2;
    address public immutable permissionedHook;
    address public immutable positionClaims;
    address public immutable WETH9;

    constructor(address manager, address permit, address hook, address claims, address weth) {
        poolManager = manager;
        permit2 = permit;
        permissionedHook = hook;
        positionClaims = claims;
        WETH9 = weth;
    }
}

contract PhaseOneCeremonyQuoterMock {
    address public immutable poolManager;

    constructor(address manager) {
        poolManager = manager;
    }
}

contract PhaseOneUnexpectedFacet {
    function unexpectedSelector() external pure returns (bool) {
        return true;
    }
}

contract PhaseOneFakeTimelock {}

contract ConfigureStaticsPhaseOneLiquidityTest is Test {
    function testBatchContainsOnlyPhaseOneLiquidityCalls() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        address diamond = makeAddr("diamond");
        StaticsPhaseOneLiquidityConfig memory config = StaticsPhaseOneLiquidityConfig({
            poolManager: makeAddr("poolManager"),
            positionManager: makeAddr("positionManager"),
            liquidityManager: makeAddr("liquidityManager"),
            hook: makeAddr("hook"),
            permissionedHook: makeAddr("permissionedHook"),
            permissionedRouter: makeAddr("permissionedRouter"),
            permissionedPositionManager: makeAddr("permissionedPositionManager"),
            permissionedQuoter: makeAddr("permissionedQuoter"),
            permit2: makeAddr("permit2"),
            weth: makeAddr("weth"),
            permanentLiquidityHarvester: makeAddr("harvester"),
            governanceSafe: makeAddr("governanceSafe"),
            guardian: makeAddr("guardian"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: bytes32(0),
            positionManagerCodeHash: bytes32(0),
            liquidityManagerCodeHash: bytes32(0),
            hookCodeHash: bytes32(0),
            permissionedHookCodeHash: bytes32(0),
            permissionedRouterCodeHash: bytes32(0),
            permissionedPositionManagerCodeHash: bytes32(0),
            permissionedPositionClaimsCodeHash: bytes32(0),
            permissionedQuoterCodeHash: bytes32(0),
            permit2CodeHash: bytes32(0),
            wethCodeHash: bytes32(0)
        });

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, config);

        assertEq(targets.length, 7);
        assertEq(values.length, 7);
        assertEq(payloads.length, 7);
        for (uint256 i; i < targets.length; ++i) {
            assertEq(targets[i], diamond);
            assertEq(values[i], 0);
        }
        assertEq(_selector(payloads[0]), IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector);
        assertEq(_selector(payloads[1]), IStaticsBasketLiquidity.installLiquidityManager.selector);
        assertEq(_selector(payloads[2]), IStaticsBasketLiquidity.installPermissionedPoolIntegration.selector);
        assertEq(_selector(payloads[3]), IStaticsPermissionedPools.setPermissionedTrustedPeriphery.selector);
        assertEq(_selector(payloads[4]), IStaticsPermissionedPools.setPermissionedTrustedPeriphery.selector);
        assertEq(_selector(payloads[5]), IStaticsPermissionedPools.setPermissionedTrustedPeriphery.selector);
        assertEq(_selector(payloads[6]), IStaticsProtocolPools.setPermanentLiquidityHarvester.selector);
        assertEq(_addressArgument(payloads[0], 0), config.poolManager);
        assertEq(_addressArgument(payloads[0], 1), config.hook);
        assertEq(_addressArgument(payloads[1], 0), config.liquidityManager);
        assertEq(_addressArgument(payloads[2], 0), config.permissionedHook);
        assertEq(_addressArgument(payloads[2], 1), config.permissionedRouter);
        assertEq(_addressArgument(payloads[2], 2), config.permissionedPositionManager);
        assertEq(_addressArgument(payloads[2], 3), config.permissionedQuoter);
        assertEq(_addressArgument(payloads[6], 0), config.permanentLiquidityHarvester);
    }

    function testTimelockBatchInstallsOnlyPhaseOneLiquidityDependencies() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        address harvester = makeAddr("harvester");
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), harvester, address(ceremony));

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
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));
        config.hookCodeHash = bytes32(0);

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

        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));

        vm.expectRevert(abi.encodeWithSelector(ConfigureStaticsPhaseOneLiquidity.UnexpectedFacetCount.selector, 26, 27));
        ceremony.prepare(deployment.diamond, config, keccak256("reject expanded manifest"));
    }

    function testCeremonyRejectsPositionManagerBoundToAnotherWeth() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment,) = _deployPhaseOne(address(ceremony), address(poolManager));
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));
        PhaseOneCeremonyDependencyMock wrongWeth = new PhaseOneCeremonyDependencyMock();
        config.weth = address(wrongWeth);
        config.wethCodeHash = address(wrongWeth).codehash;

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.InvalidBinding.selector,
                config.permissionedPositionManager,
                address(wrongWeth),
                deployment.weth
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject wrong position manager weth"));
    }

    function testCeremonyRejectsOwnerThatIsNotExactStaticsTimelock() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        PhaseOneFakeTimelock fakeTimelock = new PhaseOneFakeTimelock();
        vm.prank(address(timelock));
        IERC173(deployment.diamond).transferOwnership(address(fakeTimelock));

        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));

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

    function testCeremonyRejectsUnexpectedGovernanceSafe() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));
        config.governanceSafe = makeAddr("unexpected governance safe");

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.MissingTimelockRole.selector,
                timelock.PROPOSER_ROLE(),
                config.governanceSafe
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject unexpected governance safe"));
    }

    function testCeremonyRejectsUnexpectedGuardian() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));
        config.guardian = makeAddr("unexpected guardian");

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.MissingTimelockRole.selector,
                timelock.CANCELLER_ROLE(),
                config.guardian
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject unexpected guardian"));
    }

    function testCeremonyRejectsClosedTimelockExecution() public {
        ConfigureStaticsPhaseOneLiquidity ceremony = new ConfigureStaticsPhaseOneLiquidity();
        PhaseOneCeremonyPoolManagerMock poolManager = new PhaseOneCeremonyPoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployPhaseOne(address(ceremony), address(poolManager));
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        vm.prank(address(timelock));
        timelock.revokeRole(executorRole, address(0));
        StaticsPhaseOneLiquidityConfig memory config =
            _config(deployment, address(poolManager), makeAddr("harvester"), address(ceremony));

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsPhaseOneLiquidity.MissingTimelockRole.selector, executorRole, address(0)
            )
        );
        ceremony.prepare(deployment.diamond, config, keccak256("reject closed timelock execution"));
    }

    function _deployPhaseOne(address multisig, address poolManager)
        private
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        PhaseOneCeremonyDependencyMock permit2 = new PhaseOneCeremonyDependencyMock();
        PhaseOneCeremonyCanonicalPositionManagerMock positionManager =
            new PhaseOneCeremonyCanonicalPositionManagerMock(poolManager, address(permit2));
        return deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: multisig,
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: poolManager,
                positionManager: address(positionManager),
                permit2: address(permit2),
                inputFeeBps: 25,
                outputFeeBps: 25,
                poolManagerCodeHash: poolManager.codehash,
                positionManagerCodeHash: address(positionManager).codehash,
                permit2CodeHash: address(permit2).codehash
            })
        );
    }

    function _config(
        StaticsPhaseOneDeployment memory deployment,
        address poolManager,
        address harvester,
        address governanceSafe
    ) private returns (StaticsPhaseOneLiquidityConfig memory config) {
        StaticsLiquidityManager liquidityManager = StaticsLiquidityManager(deployment.liquidityManager);
        address permit2 = liquidityManager.permit2();
        address positionManagerAddress = liquidityManager.positionManager();
        PhaseOneCeremonyClaimsMock claims =
            new PhaseOneCeremonyClaimsMock(poolManager, deployment.permissionedSwapFeeHook);
        PhaseOneCeremonyPeripheryMock router = new PhaseOneCeremonyPeripheryMock(
            poolManager, permit2, deployment.permissionedSwapFeeHook, address(0), address(0)
        );
        PhaseOneCeremonyPeripheryMock positionManager = new PhaseOneCeremonyPeripheryMock(
            poolManager, permit2, deployment.permissionedSwapFeeHook, address(claims), deployment.weth
        );
        claims.bindPositionManager(address(positionManager));
        PhaseOneCeremonyQuoterMock quoter = new PhaseOneCeremonyQuoterMock(poolManager);
        config = StaticsPhaseOneLiquidityConfig({
            poolManager: poolManager,
            positionManager: positionManagerAddress,
            liquidityManager: deployment.liquidityManager,
            hook: deployment.swapFeeHook,
            permissionedHook: deployment.permissionedSwapFeeHook,
            permissionedRouter: address(router),
            permissionedPositionManager: address(positionManager),
            permissionedQuoter: address(quoter),
            permit2: permit2,
            weth: deployment.weth,
            permanentLiquidityHarvester: harvester,
            governanceSafe: governanceSafe,
            guardian: makeAddr("guardian"),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: poolManager.codehash,
            positionManagerCodeHash: positionManagerAddress.codehash,
            liquidityManagerCodeHash: deployment.liquidityManager.codehash,
            hookCodeHash: deployment.swapFeeHook.codehash,
            permissionedHookCodeHash: deployment.permissionedSwapFeeHook.codehash,
            permissionedRouterCodeHash: address(router).codehash,
            permissionedPositionManagerCodeHash: address(positionManager).codehash,
            permissionedPositionClaimsCodeHash: address(claims).codehash,
            permissionedQuoterCodeHash: address(quoter).codehash,
            permit2CodeHash: permit2.codehash,
            wethCodeHash: deployment.weth.codehash
        });
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
        (address manager, bool managerInstalled) = IStaticsBasketLiquidity(deployment.diamond).liquidityManager();
        assertTrue(managerInstalled);
        assertEq(manager, deployment.liquidityManager);
        (address hook, address router, address positionManager, address quoter, bool permissionedInstalled) =
            IStaticsBasketLiquidity(deployment.diamond).permissionedLiquidityIntegration();
        assertTrue(permissionedInstalled);
        assertEq(hook, deployment.permissionedSwapFeeHook);
        assertTrue(IStaticsPermissionedSwapFeeHook(hook).trustedPeriphery(router));
        assertTrue(IStaticsPermissionedSwapFeeHook(hook).trustedPeriphery(positionManager));
        assertTrue(IStaticsPermissionedSwapFeeHook(hook).trustedPeriphery(quoter));
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
