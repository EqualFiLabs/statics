// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsGenesisVault} from "../src/genesis/StaticsGenesisVault.sol";
import {StaticsHookController} from "../src/genesis/StaticsHookController.sol";
import {StaticsV4Hook} from "../src/liquidity/StaticsV4Hook.sol";
import {StaticsAvatarSVG} from "../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../src/tokens/StaticsToken.sol";

struct StaticsGenesisDeploymentConfig {
    address governance;
    address treasury;
    address weth;
    address poolManager;
    uint16 inputFeeBps;
    uint16 outputFeeBps;
}

struct StaticsGenesisDeployment {
    address statics;
    address genesis;
    address genesisVault;
    address genesisRenderer;
    address avatarSVG;
    address hookController;
    address v4Hook;
}

/// @notice Fresh-deployment-only launcher. It leaves the canonical pool inert for a separate governance launch call.
contract DeployStaticsGenesis is Script {
    using SafeERC20 for IERC20;

    uint256 private constant FOUNDER_BACKING = 99_905_550 ether;
    uint256 private constant FOUNDER_LIQUID = 90_005_000 ether;
    uint256 private constant PUBLIC_LAUNCH_INVENTORY = 810_045_000 ether;
    address private constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    error ZeroAddress();
    error InvalidFeeRate(uint256 combinedFeeBps);
    error HookAddressMismatch(address expected, address actual);
    error AllocationMismatch(uint256 remaining);

    function run() external returns (StaticsGenesisDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 inputFeeBps = vm.envUint("STATICS_GENESIS_INPUT_FEE_BPS");
        uint256 outputFeeBps = vm.envUint("STATICS_GENESIS_OUTPUT_FEE_BPS");
        uint256 combinedFeeBps = inputFeeBps + outputFeeBps;
        if (combinedFeeBps > 200) revert InvalidFeeRate(combinedFeeBps);
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: vm.envAddress("STATICS_GENESIS_GOVERNANCE"),
            treasury: vm.envAddress("STATICS_GENESIS_TREASURY"),
            weth: vm.envAddress("WETH_ADDRESS"),
            poolManager: vm.envAddress("POOL_MANAGER_ADDRESS"),
            inputFeeBps: uint16(inputFeeBps),
            outputFeeBps: uint16(outputFeeBps)
        });
        _validate(config);

        vm.startBroadcast(privateKey);
        deployment = _deployBootstrap(config, deployer, deployer);
        vm.stopBroadcast();

        bytes memory constructorArgs = _hookConstructorArgs(deployment, config);
        (address expectedHook, bytes32 salt) = HookMiner.find(
            FOUNDRY_CREATE2_DEPLOYER, REQUIRED_HOOK_FLAGS, type(StaticsV4Hook).creationCode, constructorArgs
        );

        vm.startBroadcast(privateKey);
        deployment = _deployMarket(deployment, config, salt, expectedHook, deployer);
        vm.stopBroadcast();
        _log(deployment);
    }

    function deploy(StaticsGenesisDeploymentConfig memory config)
        public
        returns (StaticsGenesisDeployment memory deployment)
    {
        _validate(config);
        deployment = _deployBootstrap(config, address(this), address(this));
        bytes memory constructorArgs = _hookConstructorArgs(deployment, config);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsV4Hook).creationCode, constructorArgs);
        deployment = _deployMarket(deployment, config, salt, expectedHook, address(this));
    }

    function _deployBootstrap(
        StaticsGenesisDeploymentConfig memory config,
        address initialTokenHolder,
        address hookBinder
    ) private returns (StaticsGenesisDeployment memory deployment) {
        StaticsToken statics = new StaticsToken(initialTokenHolder);
        StaticsGenesisVault vault =
            new StaticsGenesisVault(IERC20(address(statics)), initialTokenHolder, config.governance, config.treasury);
        StaticsAvatarSVG avatar = new StaticsAvatarSVG();
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
        StaticsGenesis genesis = new StaticsGenesis(config.treasury, address(vault), renderer, config.governance);
        StaticsHookController controller = new StaticsHookController(config.governance, hookBinder);

        IERC20(address(statics)).safeTransfer(address(vault), FOUNDER_BACKING);
        IERC20(address(statics)).safeTransfer(config.treasury, FOUNDER_LIQUID);
        vault.finalizeGenesisCollection(address(genesis));

        deployment = StaticsGenesisDeployment({
            statics: address(statics),
            genesis: address(genesis),
            genesisVault: address(vault),
            genesisRenderer: address(renderer),
            avatarSVG: address(avatar),
            hookController: address(controller),
            v4Hook: address(0)
        });
    }

    function _deployMarket(
        StaticsGenesisDeployment memory deployment,
        StaticsGenesisDeploymentConfig memory config,
        bytes32 salt,
        address expectedHook,
        address assetHolder
    ) private returns (StaticsGenesisDeployment memory) {
        StaticsV4Hook hook = new StaticsV4Hook{salt: salt}(
            IPoolManager(config.poolManager),
            deployment.hookController,
            deployment.statics,
            config.weth,
            config.treasury,
            config.inputFeeBps,
            config.outputFeeBps
        );
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));
        StaticsHookController(deployment.hookController).bindHook(address(hook));
        IERC20(deployment.statics).safeTransfer(address(hook), PUBLIC_LAUNCH_INVENTORY);
        uint256 remaining = IERC20(deployment.statics).balanceOf(assetHolder);
        uint256 expectedRemaining = config.treasury == assetHolder ? FOUNDER_LIQUID : 0;
        if (remaining != expectedRemaining) revert AllocationMismatch(remaining);
        deployment.v4Hook = address(hook);
        return deployment;
    }

    function _hookConstructorArgs(
        StaticsGenesisDeployment memory deployment,
        StaticsGenesisDeploymentConfig memory config
    ) private pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(config.poolManager),
            deployment.hookController,
            deployment.statics,
            config.weth,
            config.treasury,
            config.inputFeeBps,
            config.outputFeeBps
        );
    }

    function _validate(StaticsGenesisDeploymentConfig memory config) private view {
        if (
            config.governance == address(0) || config.treasury == address(0) || config.weth == address(0)
                || config.poolManager == address(0) || config.weth.code.length == 0
                || config.poolManager.code.length == 0
        ) revert ZeroAddress();
        uint256 combinedFee = uint256(config.inputFeeBps) + config.outputFeeBps;
        if (combinedFee > 200) revert InvalidFeeRate(combinedFee);
    }

    function _log(StaticsGenesisDeployment memory deployment) private pure {
        console2.log("STATICS_TOKEN_ADDRESS", deployment.statics);
        console2.log("STATICS_GENESIS_NFT_ADDRESS", deployment.genesis);
        console2.log("STATICS_GENESIS_VAULT_ADDRESS", deployment.genesisVault);
        console2.log("STATICS_GENESIS_RENDERER_ADDRESS", deployment.genesisRenderer);
        console2.log("STATICS_GENESIS_AVATAR_SVG_ADDRESS", deployment.avatarSVG);
        console2.log("STATICS_HOOK_CONTROLLER_ADDRESS", deployment.hookController);
        console2.log("STATICS_V4_HOOK_ADDRESS", deployment.v4Hook);
    }
}
