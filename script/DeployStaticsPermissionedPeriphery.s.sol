// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IStaticsPermissionedSwapFeeHook} from "../src/interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {StaticsPermissionedPositionManager} from "../src/permissioned/StaticsPermissionedPositionManager.sol";
import {StaticsPermissionedRouter} from "../src/permissioned/StaticsPermissionedRouter.sol";

struct StaticsPermissionedPeripheryDeployment {
    address router;
    address positionManager;
    address positionClaims;
}

/// @notice Deploys the exact-0.8.26 permissioned v4 periphery after the Phase 1 Diamond and hook exist.
/// @dev Installation and trusted-periphery activation remain a separate atomic timelock ceremony.
contract DeployStaticsPermissionedPeriphery is Script {
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;

    struct Config {
        address poolManager;
        address permit2;
        address positionDescriptor;
        address weth;
        address permissionedHook;
    }

    error InvalidContract(address target);
    error InvalidBinding(address target, address expected, address actual);
    error RuntimeTooLarge(address target, uint256 actual, uint256 maximum);

    function run() external returns (StaticsPermissionedPeripheryDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory manifest = vm.readFile(_manifestPath(block.chainid));
        Config memory config = Config({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            positionDescriptor: vm.parseJsonAddress(manifest, ".contracts.positionDescriptor.address"),
            weth: vm.envAddress("WETH_ADDRESS"),
            permissionedHook: vm.envAddress("STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS")
        });
        vm.startBroadcast(privateKey);
        deployment = deploy(config);
        vm.stopBroadcast();
        _log(deployment);
    }

    function deploy(Config memory config) public returns (StaticsPermissionedPeripheryDeployment memory deployment) {
        _contract(config.poolManager);
        _contract(config.permit2);
        _contract(config.positionDescriptor);
        _contract(config.weth);
        _contract(config.permissionedHook);
        IStaticsPermissionedSwapFeeHook hook = IStaticsPermissionedSwapFeeHook(config.permissionedHook);
        _binding(
            config.permissionedHook,
            config.poolManager,
            address(StaticsHookPoolManager(config.permissionedHook).poolManager())
        );

        StaticsPermissionedRouter router = new StaticsPermissionedRouter(
            IPoolManager(config.poolManager), IAllowanceTransfer(config.permit2), config.permissionedHook
        );
        deployment.router = address(router);
        StaticsPermissionedPositionManager positionManager = new StaticsPermissionedPositionManager(
            IPoolManager(config.poolManager),
            IAllowanceTransfer(config.permit2),
            100_000,
            IPositionDescriptor(config.positionDescriptor),
            IWETH9(config.weth),
            hook
        );
        deployment.positionManager = address(positionManager);
        deployment.positionClaims = address(positionManager.positionClaims());
        _binding(deployment.router, config.poolManager, address(router.poolManager()));
        _binding(deployment.router, config.permit2, address(router.permit2()));
        _binding(deployment.router, config.permissionedHook, router.permissionedHook());
        _binding(deployment.positionManager, config.poolManager, address(positionManager.poolManager()));
        _binding(deployment.positionManager, config.permit2, address(positionManager.permit2()));
        _binding(deployment.positionManager, config.permissionedHook, address(positionManager.permissionedHook()));
        if (deployment.positionManager.code.length > EIP170_RUNTIME_LIMIT) {
            revert RuntimeTooLarge(
                deployment.positionManager, deployment.positionManager.code.length, EIP170_RUNTIME_LIMIT
            );
        }
    }

    function _manifestPath(uint256 chainId) private pure returns (string memory path) {
        if (chainId == 4_663) return "deployments/robinhood-chain-4663.json";
        if (chainId == 46_630) return "deployments/robinhood-chain-testnet-46630.json";
        revert("UNSUPPORTED_CHAIN");
    }

    function _contract(address target) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidContract(target);
    }

    function _binding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidBinding(target, expected, actual);
    }

    function _log(StaticsPermissionedPeripheryDeployment memory deployment) private view {
        console2.log("STATICS_PERMISSIONED_ROUTER_ADDRESS", deployment.router);
        console2.log("STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.router.codehash);
        console2.log("STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS", deployment.positionManager);
        console2.log("STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.positionManager.codehash);
        console2.log("STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS", deployment.positionClaims);
        console2.log("STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.positionClaims.codehash);
    }
}

interface StaticsHookPoolManager {
    function poolManager() external view returns (IPoolManager);
}
