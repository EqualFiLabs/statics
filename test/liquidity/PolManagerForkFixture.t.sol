// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {GeneralPoolLifecycleTestBase} from "../../test/helpers/GeneralPoolLifecycleTestBase.sol";

/// @notice Export disposable test genesis allocations for offchain manager fork flows.
/// @dev This is a simulation-only harness. It never broadcasts, installs a production service,
/// funds a production wallet or contains credentials. Pool creation, liquidity and swaps occur
/// afterwards as real transactions on a disposable Anvil fork, preserving receipt evidence.
contract PolManagerForkFixture is GeneralPoolLifecycleTestBase {
    function testExportManagerForkGenesis() public {
        string memory destination = vm.envOr("POL_FIXTURE_DIRECTORY", string(""));
        if (bytes(destination).length == 0) {
            // Artifact export is an opt-in fixture preparation step, not a validation gate.
            vm.skip(true);
            return;
        }
        address tokenA = _newToken("POL fixture Alpha");
        address tokenB = _newToken("POL fixture Beta");
        address stateView = deployCode("out/StateView.sol/StateView.json", abi.encode(address(poolManager)));
        string memory root = "pol-fork-fixture";
        vm.serializeAddress(root, "diamond", address(diamond));
        vm.serializeAddress(root, "owner", address(this));
        vm.serializeAddress(root, "pool_manager", address(poolManager));
        vm.serializeAddress(root, "state_view", stateView);
        vm.serializeAddress(root, "position_manager", address(positionManagerContract));
        vm.serializeAddress(root, "liquidity_manager", address(liquidityManager));
        vm.serializeAddress(root, "permit2", address(permit2Contract));
        vm.serializeAddress(root, "hook", address(swapFeeHook));
        vm.serializeAddress(root, "router", address(v4Router));
        vm.serializeAddress(root, "tokenA", tokenA);
        string memory metadata = vm.serializeAddress(root, "tokenB", tokenB);
        vm.writeJson(metadata, string.concat(destination, "/bindings.json"));
        vm.dumpState(string.concat(destination, "/allocations.json"));
    }
}
