// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {
    DeployStaticsPermissionedPeriphery,
    StaticsPermissionedPeripheryDeployment
} from "../../script/DeployStaticsPermissionedPeriphery.s.sol";

interface IPermissionedPeripheryBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function permissionedHook() external view returns (address);
    function positionClaims() external view returns (address);
}

contract PermissionedPeripheryDependencyMock {}

contract PermissionedPeripheryHookMock {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager manager) {
        poolManager = manager;
    }
}

contract DeployStaticsPermissionedPeripheryTest is Test {
    function testDeploysBoundRouterPositionManagerAndClaims() public {
        IPoolManager manager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        PermissionedPeripheryHookMock hook = new PermissionedPeripheryHookMock(manager);

        address permit2 = deployCode("out/Permit2.sol/Permit2.json");
        address descriptor = address(new PermissionedPeripheryDependencyMock());
        address weth = address(new PermissionedPeripheryDependencyMock());
        DeployStaticsPermissionedPeriphery deployer = new DeployStaticsPermissionedPeriphery();
        StaticsPermissionedPeripheryDeployment memory deployment = deployer.deploy(
            DeployStaticsPermissionedPeriphery.Config({
                poolManager: address(manager),
                permit2: permit2,
                positionDescriptor: descriptor,
                weth: weth,
                permissionedHook: address(hook)
            })
        );

        IPermissionedPeripheryBindings router = IPermissionedPeripheryBindings(deployment.router);
        assertEq(router.poolManager(), address(manager));
        assertEq(router.permit2(), permit2);
        assertEq(router.permissionedHook(), address(hook));

        IPermissionedPeripheryBindings positionManager = IPermissionedPeripheryBindings(deployment.positionManager);
        assertEq(positionManager.poolManager(), address(manager));
        assertEq(positionManager.permit2(), permit2);
        assertEq(positionManager.permissionedHook(), address(hook));
        assertEq(positionManager.positionClaims(), deployment.positionClaims);
        assertTrue(deployment.positionClaims.code.length != 0);
        assertLe(deployment.positionManager.code.length, 24_576 - 1_024);
    }
}
