// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PrepareStaticsPoolLaunch} from "../../script/PrepareStaticsPoolLaunch.s.sol";
import {PrepareStaticsPositionActions} from "../../script/PrepareStaticsPositionActions.s.sol";
import {PrepareStaticsPositionMint} from "../../script/PrepareStaticsPositionMint.s.sol";
import {LaunchLiquidityScript} from "../../script/libraries/LaunchLiquidityScript.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract PrepareStaticsLiquidityOperationsTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IAllowanceTransfer private permit2;
    PositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;
    PrepareStaticsPoolLaunch private prepareLaunch;
    PrepareStaticsPositionActions private prepareActions;
    PrepareStaticsPositionMint private prepareMint;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(24 hours, proposers, executors, address(0));
        bytes memory args = abi.encode(manager, positionManager, address(timelock), makeAddr("feeReceiver"));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        hook = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(manager),
            IPositionManager(address(positionManager)),
            address(timelock),
            makeAddr("feeReceiver")
        );
        assertEq(address(hook), expectedHook);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        prepareLaunch = new PrepareStaticsPoolLaunch();
        prepareActions = new PrepareStaticsPositionActions();
        prepareMint = new PrepareStaticsPositionMint();
    }

    function testPreparedStaticsOnlyLaunchUsesOnlyStatics() public {
        PrepareStaticsPoolLaunch.PoolLaunchConfig memory config =
            _launchConfig(LaunchLiquidityScript.FundingMode.StaticsOnly, 3_000, 60, 600, 100 ether, 0);
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = _executeLaunch(config);

        assertEq(positionManager.ownerOf(tokenId), address(this));
        assertLt(currency0.balanceOfSelf(), balance0Before);
        assertEq(currency1.balanceOfSelf(), balance1Before);
    }

    function testPreparedPairedTokenOnlyLaunchUsesOnlyPairedToken() public {
        PrepareStaticsPoolLaunch.PoolLaunchConfig memory config =
            _launchConfig(LaunchLiquidityScript.FundingMode.PairedTokenOnly, 3_000, -600, -60, 0, 100 ether);
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        _executeLaunch(config);

        assertEq(currency0.balanceOfSelf(), balance0Before);
        assertLt(currency1.balanceOfSelf(), balance1Before);
    }

    function testPreparedTwoSidedLaunchUsesBothAssets() public {
        PrepareStaticsPoolLaunch.PoolLaunchConfig memory config =
            _launchConfig(LaunchLiquidityScript.FundingMode.TwoSided, 3_000, -600, 600, 100 ether, 100 ether);
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        _executeLaunch(config);

        assertLt(currency0.balanceOfSelf(), balance0Before);
        assertLt(currency1.balanceOfSelf(), balance1Before);
    }

    function testPreparedActionsManageAndBurnOneOfMultiplePositions() public {
        PrepareStaticsPoolLaunch.PoolLaunchConfig memory config =
            _launchConfig(LaunchLiquidityScript.FundingMode.TwoSided, 3_000, -600, 600, 100 ether, 100 ether);
        uint256 managedId = _executeLaunch(config);
        uint128 initialLiquidity = positionManager.getPositionLiquidity(managedId);

        PrepareStaticsPositionActions.PositionActionConfig memory action =
            PrepareStaticsPositionActions.PositionActionConfig({
                chainId: block.chainid,
                positionManager: address(positionManager),
                currency0: currency0,
                currency1: currency1,
                tokenId: managedId,
                liquidityDelta: initialLiquidity / 4,
                amount0Max: 100 ether,
                amount1Max: 100 ether,
                amount0Min: 1,
                amount1Min: 1,
                recipient: address(this)
            });
        uint256 deadline = block.timestamp + 1 hours;
        prepareActions.validate(action, deadline);

        PrepareStaticsPositionMint.PositionMintConfig memory mintConfig = PrepareStaticsPositionMint.PositionMintConfig({
            chainId: block.chainid,
            poolManager: address(manager),
            positionManager: address(positionManager),
            hook: address(hook),
            currency0: currency0,
            currency1: currency1,
            nativeLpFee: config.nativeLpFee,
            tickSpacing: config.tickSpacing,
            currentSqrtPriceX96: SQRT_PRICE_1_1,
            tickLower: -1_200,
            tickUpper: 1_200,
            liquidity: 0,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            positionOwner: address(this)
        });
        mintConfig.liquidity = prepareMint.calculateLiquidity(mintConfig);
        prepareMint.validate(mintConfig, deadline);
        uint256 sentinelId = positionManager.nextTokenId();
        _call(address(positionManager), prepareMint.mintCalldata(mintConfig, deadline));
        uint128 sentinelLiquidity = positionManager.getPositionLiquidity(sentinelId);

        _call(address(positionManager), prepareActions.increaseCalldata(action, deadline));
        assertEq(positionManager.getPositionLiquidity(managedId), initialLiquidity + action.liquidityDelta);

        _call(address(positionManager), prepareActions.decreaseCalldata(action, deadline));
        assertEq(positionManager.getPositionLiquidity(managedId), initialLiquidity);

        _call(address(positionManager), prepareActions.collectCalldata(action, deadline));
        assertEq(positionManager.getPositionLiquidity(managedId), initialLiquidity);

        _call(address(positionManager), prepareActions.exitAndBurnCalldata(action, deadline));
        vm.expectRevert();
        positionManager.ownerOf(managedId);
        assertEq(positionManager.getPositionLiquidity(sentinelId), sentinelLiquidity);
        assertTrue(hook.poolRegistration(configToKey(config).toId()).active);
    }

    function testArtifactsRoundTripIntoAdditionalPositionAndManagementPreparation() public {
        PrepareStaticsPoolLaunch.PoolLaunchConfig memory config =
            _launchConfig(LaunchLiquidityScript.FundingMode.TwoSided, 3_000, -600, 600, 100 ether, 100 ether);
        uint256 tokenId = _executeLaunch(config);
        uint256 deadline = block.timestamp + 1 hours;
        string memory poolPath = "artifacts/launch-liquidity/test-pool-tooling.json";
        string memory mintPath = "artifacts/launch-liquidity/test-position-mint.json";
        string memory actionPath = "artifacts/launch-liquidity/test-position-actions.json";
        vm.createDir("artifacts/launch-liquidity", true);
        prepareLaunch.writeArtifact(poolPath, "deployment.json", config, deadline);

        vm.setEnv("STATICS_POSITION_TICK_LOWER", "-1200");
        vm.setEnv("STATICS_POSITION_TICK_UPPER", "1200");
        vm.setEnv("STATICS_POSITION_AMOUNT0_MAX", vm.toString(uint256(100 ether)));
        vm.setEnv("STATICS_POSITION_AMOUNT1_MAX", vm.toString(uint256(100 ether)));
        vm.setEnv("STATICS_POSITION_OWNER", vm.toString(address(this)));
        vm.setEnv("STATICS_POSITION_LIQUIDITY", "0");
        PrepareStaticsPositionMint.PositionMintConfig memory mintConfig = prepareMint.loadPoolAndEnvironment(poolPath);
        prepareMint.validate(mintConfig, deadline);
        prepareMint.writeArtifact(mintPath, poolPath, mintConfig, deadline);
        string memory mintArtifact = vm.readFile(mintPath);
        assertEq(vm.parseJsonUint(mintArtifact, ".currentSqrtPriceX96"), SQRT_PRICE_1_1);
        assertEq(bytes4(vm.parseJsonBytes(mintArtifact, ".mintCalldata")), IPositionManager.modifyLiquidities.selector);

        vm.setEnv("STATICS_POSITION_TOKEN_ID", vm.toString(uint256(tokenId)));
        vm.setEnv("STATICS_POSITION_LIQUIDITY_DELTA", vm.toString(uint256(mintConfig.liquidity / 4)));
        vm.setEnv("STATICS_POSITION_AMOUNT0_MIN", "1");
        vm.setEnv("STATICS_POSITION_AMOUNT1_MIN", "1");
        vm.setEnv("STATICS_POSITION_RECIPIENT", vm.toString(address(this)));
        PrepareStaticsPositionActions.PositionActionConfig memory action =
            prepareActions.loadPoolAndEnvironment(poolPath);
        prepareActions.validate(action, deadline);
        prepareActions.writeArtifact(actionPath, poolPath, action, deadline);
        string memory actionArtifact = vm.readFile(actionPath);
        assertEq(
            bytes4(vm.parseJsonBytes(actionArtifact, ".collectCalldata")), IPositionManager.modifyLiquidities.selector
        );
        assertEq(
            bytes4(vm.parseJsonBytes(actionArtifact, ".exitAndBurnCalldata")),
            IPositionManager.modifyLiquidities.selector
        );

        vm.removeFile(actionPath);
        vm.removeFile(mintPath);
        vm.removeFile(poolPath);
    }

    function _launchConfig(
        LaunchLiquidityScript.FundingMode fundingMode,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max
    ) private view returns (PrepareStaticsPoolLaunch.PoolLaunchConfig memory config) {
        config = PrepareStaticsPoolLaunch.PoolLaunchConfig({
            chainId: block.chainid,
            poolManager: address(manager),
            positionManager: address(positionManager),
            hook: address(hook),
            statics: Currency.unwrap(currency0),
            pairedToken: Currency.unwrap(currency1),
            positionOwner: address(this),
            fundingMode: fundingMode,
            nativeLpFee: fee,
            tickSpacing: 60,
            sqrtPriceX96: SQRT_PRICE_1_1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: 0,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            inputFeeBps: 50,
            outputFeeBps: 50
        });
        config.liquidity = prepareLaunch.calculateLiquidity(config);
    }

    function _executeLaunch(PrepareStaticsPoolLaunch.PoolLaunchConfig memory config) private returns (uint256 tokenId) {
        uint256 deadline = block.timestamp + 1 hours;
        prepareLaunch.validate(config, deadline);
        tokenId = positionManager.nextTokenId();
        _call(address(hook), prepareLaunch.registrationCalldata(config));
        _call(address(positionManager), prepareLaunch.initializeAndMintCalldata(config, deadline));
        _call(address(hook), prepareLaunch.activationCalldata(config));
        assertEq(positionManager.getPositionLiquidity(tokenId), config.liquidity);
        assertTrue(hook.poolRegistration(configToKey(config).toId()).active);
    }

    function configToKey(PrepareStaticsPoolLaunch.PoolLaunchConfig memory config)
        private
        view
        returns (PoolKey memory)
    {
        return prepareLaunch.poolKey(config);
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _call(address target, bytes memory data) private {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
