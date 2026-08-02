// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

interface IRobinhoodTestnetPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

contract RobinhoodTestnetV4DeploymentForkTest is Test {
    string private constant MANIFEST = "deployments/robinhood-chain-testnet-46630.json";

    function testRobinhoodTestnetDependenciesMatchPinnedManifest() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        string memory manifest = vm.readFile(MANIFEST);
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        vm.createSelectFork(rpcUrl, forkBlock);

        address poolManager = vm.parseJsonAddress(manifest, ".contracts.poolManager.address");
        address positionManager = vm.parseJsonAddress(manifest, ".contracts.positionManager.address");
        address permit2 = vm.parseJsonAddress(manifest, ".contracts.permit2.address");
        address weth = vm.parseJsonAddress(manifest, ".staticsDollarDependencies.weth.address");

        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        assertEq(block.number, forkBlock);
        assertEq(block.timestamp, vm.parseJsonUint(manifest, ".forkBlockTimestamp"));
        _assertCodeHash(poolManager, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        _assertCodeHash(positionManager, vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"));
        _assertCodeHash(permit2, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        _assertCodeHash(weth, vm.parseJsonBytes32(manifest, ".staticsDollarDependencies.weth.runtimeCodeHash"));

        IRobinhoodTestnetPositionManager manager = IRobinhoodTestnetPositionManager(positionManager);
        assertEq(manager.poolManager(), poolManager);
        assertEq(manager.permit2(), permit2);
    }

    function _assertCodeHash(address target, bytes32 expected) private view {
        assertTrue(target.code.length > 0);
        assertEq(target.codehash, expected);
    }
}
