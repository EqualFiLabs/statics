// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMulticall_v4} from "@uniswap/v4-periphery/src/interfaces/IMulticall_v4.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {DeployStaticsLaunchLiquidity} from "../../script/DeployStaticsLaunchLiquidity.s.sol";
import {PrepareStaticsLaunchPosition} from "../../script/PrepareStaticsLaunchPosition.s.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchBindingMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract LaunchDependencyMock {}

contract DeployStaticsLaunchLiquidityTest is Test {
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    address private governance = makeAddr("governance");
    address private feeReceiver = makeAddr("feeReceiver");
    address private positionOwner = makeAddr("positionOwner");
    address private outsider = makeAddr("outsider");
    DeployStaticsLaunchLiquidity private script;
    DeployStaticsLaunchLiquidity.Config private config;

    function setUp() public {
        LaunchDependencyMock manager = new LaunchDependencyMock();
        LaunchDependencyMock permit2 = new LaunchDependencyMock();
        LaunchBindingMock positionManager = new LaunchBindingMock(address(manager), address(permit2));
        MockERC20 statics = new MockERC20("STATICS", "STATICS", 18);
        MockERC20 pairedToken = new MockERC20("Stock", "STOCK", 18);
        bool staticsIsCurrency0 = address(statics) < address(pairedToken);
        script = new DeployStaticsLaunchLiquidity();
        config = DeployStaticsLaunchLiquidity.Config({
            chainId: block.chainid,
            poolManager: address(manager),
            positionManager: address(positionManager),
            permit2: address(permit2),
            statics: address(statics),
            pairedToken: address(pairedToken),
            governance: governance,
            feeReceiver: feeReceiver,
            positionOwner: positionOwner,
            nativeLpFee: 5_000,
            tickSpacing: 60,
            sqrtPriceX96: SQRT_PRICE_1_1,
            tickLower: staticsIsCurrency0 ? int24(60) : int24(-600),
            tickUpper: staticsIsCurrency0 ? int24(600) : int24(-60),
            liquidity: 1e18,
            amount0Max: staticsIsCurrency0 ? type(uint128).max : 0,
            amount1Max: staticsIsCurrency0 ? 0 : type(uint128).max,
            inputFeeBps: 25,
            outputFeeBps: 75,
            poolManagerCodeHash: address(manager).codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2).codehash,
            staticsCodeHash: address(statics).codehash,
            pairedTokenCodeHash: address(pairedToken).codehash
        });
    }

    function testDeploysGenericHookOwnedByDedicatedTimelock() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));

        assertEq(deployment.hook.owner(), address(deployment.timelock));
        assertEq(deployment.hook.feeReceiver(), feeReceiver);
        assertEq(deployment.hook.positionManager(), config.positionManager);
        assertEq(address(deployment.feeClaimRedeemer.poolManager()), config.poolManager);
        assertEq(deployment.key.fee, 5_000);
        assertEq(deployment.key.tickSpacing, 60);
        assertEq(uint160(address(deployment.hook)) & Hooks.ALL_HOOK_MASK, script.REQUIRED_HOOK_FLAGS());
        assertTrue(deployment.timelock.hasRole(deployment.timelock.PROPOSER_ROLE(), governance));
        assertTrue(deployment.timelock.hasRole(deployment.timelock.EXECUTOR_ROLE(), address(0)));
    }

    function testReceiverAndPoolFeesChangeOnlyThroughTimelock() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));
        StaticsLaunchLiquidityHook hook = deployment.hook;
        address replacement = makeAddr("replacement");

        _executeTimelock(deployment, script.registrationCalldata(config, deployment), keccak256("register launch pool"));

        vm.expectRevert();
        hook.setFeeReceiver(replacement);
        bytes memory receiverData = abi.encodeCall(StaticsLaunchLiquidityHook.setFeeReceiver, (replacement));
        _executeTimelock(deployment, receiverData, keccak256("replace launch fee receiver"));
        assertEq(hook.feeReceiver(), replacement);

        bytes memory feesData = abi.encodeCall(StaticsLaunchLiquidityHook.setHookFees, (deployment.poolId, 100, 200));
        _executeTimelock(deployment, feesData, keccak256("replace launch hook fees"));
        assertEq(hook.poolRegistration(deployment.poolId).inputFeeBps, 100);
        assertEq(hook.poolRegistration(deployment.poolId).outputFeeBps, 200);
    }

    function testRejectsPinnedDependencyHashMismatch() public {
        config.poolManagerCodeHash = bytes32(uint256(1));
        vm.expectRevert();
        script.deploy(config, address(script));
    }

    function testRejectsSingleSidedLimitsForWrongCurrency() public {
        (config.amount0Max, config.amount1Max) = (config.amount1Max, config.amount0Max);
        vm.expectRevert(DeployStaticsLaunchLiquidity.InvalidSingleSidedPosition.selector);
        script.deploy(config, address(script));
    }

    function testWritesStableDeploymentArtifactWithoutExpiringPositionCalldata() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));
        string memory path = "artifacts/launch-liquidity/test-deployment.json";
        vm.createDir("artifacts/launch-liquidity", true);
        script.writeArtifact(path, config, deployment, address(this));

        string memory artifact = vm.readFile(path);
        assertEq(vm.parseJsonAddress(artifact, ".hook"), address(deployment.hook));
        assertEq(vm.parseJsonAddress(artifact, ".timelock"), address(deployment.timelock));
        assertEq(vm.parseJsonAddress(artifact, ".feeClaimRedeemer"), address(deployment.feeClaimRedeemer));
        assertEq(vm.parseJsonAddress(artifact, ".pairedToken"), config.pairedToken);
        assertEq(vm.parseJsonAddress(artifact, ".positionOwner"), positionOwner);
        assertEq(vm.parseJsonUint(artifact, ".nativeLpFeePips"), 5_000);
        assertEq(vm.parseJsonUint(artifact, ".inputFeeBps"), 25);
        assertEq(vm.parseJsonUint(artifact, ".outputFeeBps"), 75);
        assertEq(vm.parseJsonUint(artifact, ".hookPermissionMask"), script.REQUIRED_HOOK_FLAGS());
        assertEq(vm.parseJsonBytes32(artifact, ".hookRuntimeCodeHash"), address(deployment.hook).codehash);
        bytes memory registration = vm.parseJsonBytes(artifact, ".registerPoolCalldata");
        assertEq(bytes4(registration), StaticsLaunchLiquidityHook.registerPool.selector);
        assertFalse(vm.keyExistsJson(artifact, ".positionDeadline"));
        assertFalse(vm.keyExistsJson(artifact, ".positionManagerMulticallCalldata"));
        vm.removeFile(path);
    }

    function testPreparesFreshInitializeFallbackAndActivationCalldata() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));
        string memory deploymentPath = "artifacts/launch-liquidity/test-deployment.json";
        string memory preparedPath = "artifacts/launch-liquidity/test-position.json";
        vm.createDir("artifacts/launch-liquidity", true);
        script.writeArtifact(deploymentPath, config, deployment, address(this));

        PrepareStaticsLaunchPosition prepare = new PrepareStaticsLaunchPosition();
        PrepareStaticsLaunchPosition.LaunchConfig memory launch = prepare.loadArtifact(deploymentPath);
        uint256 deadline = block.timestamp + 30 minutes;
        prepare.validate(launch, deadline);
        prepare.writeArtifact(preparedPath, deploymentPath, launch, deadline);

        string memory artifact = vm.readFile(preparedPath);
        assertEq(vm.parseJsonUint(artifact, ".positionDeadline"), deadline);
        assertEq(bytes4(vm.parseJsonBytes(artifact, ".initializeAndMintCalldata")), IMulticall_v4.multicall.selector);
        assertEq(bytes4(vm.parseJsonBytes(artifact, ".mintOnlyCalldata")), IPositionManager.modifyLiquidities.selector);
        assertEq(
            bytes4(vm.parseJsonBytes(artifact, ".activatePoolCalldata")),
            StaticsLaunchLiquidityHook.activatePool.selector
        );

        vm.removeFile(preparedPath);
        vm.removeFile(deploymentPath);
    }

    function testRejectsExpiredPreparedPositionDeadline() public {
        PrepareStaticsLaunchPosition prepare = new PrepareStaticsLaunchPosition();
        PrepareStaticsLaunchPosition.LaunchConfig memory launch;
        launch.chainId = block.chainid;
        vm.warp(100);
        vm.expectRevert(
            abi.encodeWithSelector(PrepareStaticsLaunchPosition.ExpiredDeadline.selector, uint256(99), uint256(100))
        );
        prepare.validate(launch, 99);
    }

    function testRejectsUnsafePositionOwnersAndExcessLiquidity() public {
        address[4] memory unsafeOwners = [config.poolManager, config.positionManager, address(1), address(2)];
        for (uint256 i; i < unsafeOwners.length; ++i) {
            config.positionOwner = unsafeOwners[i];
            vm.expectRevert(DeployStaticsLaunchLiquidity.InvalidConfig.selector);
            script.deploy(config, address(script));
        }

        config.positionOwner = positionOwner;
        config.liquidity = uint128(type(int128).max) + 1;
        vm.expectRevert(DeployStaticsLaunchLiquidity.InvalidConfig.selector);
        script.deploy(config, address(script));
    }

    function _executeTimelock(
        DeployStaticsLaunchLiquidity.Deployment memory deployment,
        bytes memory data,
        bytes32 salt
    ) private {
        uint256 delay = deployment.timelock.getMinDelay();
        vm.prank(governance);
        deployment.timelock.schedule(address(deployment.hook), 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(outsider);
        deployment.timelock.execute(address(deployment.hook), 0, data, bytes32(0), salt);
    }
}
