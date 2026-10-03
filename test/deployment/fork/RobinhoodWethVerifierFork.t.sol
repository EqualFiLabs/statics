// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {RobinhoodWethVerifier} from "../../../script/libraries/RobinhoodWethVerifier.sol";

contract RobinhoodWethVerifierForkTest is Test {
    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";

    function testCanonicalWethAuthorityMatchesPinnedManifest() public {
        string memory manifest = _selectPinnedFork();
        address weth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        assertNotEq(this.validateCanonicalWeth(weth), bytes32(0));
    }

    function testCanonicalWethImplementationDriftIsRejected() public {
        string memory manifest = _selectPinnedFork();
        address weth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        address implementation = vm.parseJsonAddress(manifest, ".contracts.weth.implementation.address");
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.implementation.runtimeCodeHash");
        vm.etch(implementation, hex"60006000fd");

        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodWethVerifier.InvalidRobinhoodDependencyCodeHash.selector,
                implementation,
                expectedCodeHash,
                implementation.codehash
            )
        );
        this.validateCanonicalWeth(weth);
    }

    function validateCanonicalWeth(address weth) external view returns (bytes32) {
        return RobinhoodWethVerifier.validateMainnet(vm, weth);
    }

    function _selectPinnedFork() private returns (string memory manifest) {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return "";
        }
        manifest = vm.readFile(MANIFEST_PATH);
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        bytes32 forkBlockHash = vm.parseJsonBytes32(manifest, ".forkBlockHash");
        string memory pinnedBlock =
            vm.rpcJson(rpcUrl, "eth_getBlockByHash", string.concat("[\"", vm.toString(forkBlockHash), "\",false]"));
        assertEq(vm.parseJsonBytes32(pinnedBlock, ".hash"), forkBlockHash, "Robinhood manifest block hash drift");
        assertEq(vm.parseJsonUint(pinnedBlock, ".number"), forkBlock, "Robinhood manifest block number drift");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 4_663);
    }
}
