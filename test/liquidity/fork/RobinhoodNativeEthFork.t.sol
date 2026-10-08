// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockWrappedNative} from "../../mocks/MockWrappedNative.sol";
import {NativeEthLifecycleTest} from "../NativeEthLifecycle.t.sol";

interface IRobinhoodNativeWethBinding {
    function WETH9() external view returns (address);
}

/// @notice Run the identical native lifecycle against runtime-pinned Robinhood contracts.
contract RobinhoodNativeEthForkTest is NativeEthLifecycleTest {
    string private constant MANIFEST = "deployments/robinhood-chain-4663.json";
    address private pinnedPoolManager;
    address private pinnedPositionManager;
    address private pinnedPermit2;
    address private pinnedWeth;

    function setUp() public override {
        string memory manifest = vm.readFile(MANIFEST);
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        bytes32 expectedHash = vm.parseJsonBytes32(manifest, ".forkBlockHash");
        string memory header =
            vm.rpcJson(rpc, "eth_getBlockByHash", string.concat("[\"", vm.toString(expectedHash), "\",false]"));
        assertEq(vm.parseJsonBytes32(header, ".hash"), expectedHash);
        assertEq(vm.parseJsonUint(header, ".number"), forkBlock);
        vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 4663);
        pinnedPoolManager = _dependency(manifest, "poolManager");
        pinnedPositionManager = _dependency(manifest, "positionManager");
        pinnedPermit2 = _dependency(manifest, "permit2");
        pinnedWeth = _dependency(manifest, "weth");
        assertEq(IRobinhoodNativeWethBinding(pinnedPositionManager).WETH9(), pinnedWeth);
        super.setUp();
    }

    function _dependency(string memory manifest, string memory name) private view returns (address target) {
        string memory path = string.concat(".contracts.", name);
        target = vm.parseJsonAddress(manifest, string.concat(path, ".address"));
        assertEq(target.codehash, vm.parseJsonBytes32(manifest, string.concat(path, ".runtimeCodeHash")));
    }

    function _deployWrappedNative() internal view override returns (MockWrappedNative) {
        return MockWrappedNative(payable(pinnedWeth));
    }

    function _deployPoolManager() internal view override returns (IPoolManager) {
        return IPoolManager(pinnedPoolManager);
    }

    function _deployRangePeriphery() internal view override returns (IAllowanceTransfer, IPositionManager) {
        return (IAllowanceTransfer(pinnedPermit2), IPositionManager(pinnedPositionManager));
    }
}
