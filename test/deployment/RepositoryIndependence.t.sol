// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract RepositoryIndependenceTest is Test {
    function test_activePathsDoNotReachAdjacentRepository() public view {
        _checkTree("src");
        _checkTree("test");
        _checkTree("script");
        _checkTree("deployments");
        _checkFile("foundry.toml");
        _checkFile("remappings.txt");
    }

    function _checkTree(string memory path) private view {
        Vm.DirEntry[] memory entries = vm.readDir(path, 32, false);
        for (uint256 i; i < entries.length; ++i) {
            assertFalse(entries[i].isSymlink, string.concat("symlink in active tree: ", entries[i].path));
            if (!entries[i].isDir) _checkFile(entries[i].path);
        }
    }

    function _checkFile(string memory path) private view {
        bytes memory contents = bytes(vm.readFile(path));
        bytes memory oldRelativePath = bytes(string.concat("../market-ui", "/ether-dollar"));
        bytes memory oldRepository = bytes(string.concat("EqualFiLabs", "/ether-dollar"));
        assertFalse(_contains(contents, oldRelativePath), string.concat("old checkout path in ", path));
        assertFalse(_contains(contents, oldRepository), string.concat("old repository URL in ", path));
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        require(needle.length <= 32, "repository marker exceeds one word");

        bytes32 expected;
        assembly ("memory-safe") {
            expected := mload(add(needle, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - needle.length) * 8));
        expected &= mask;
        uint256 last = haystack.length - needle.length;
        for (uint256 i; i <= last; ++i) {
            bytes32 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(haystack, 0x20), i))
            }
            if (candidate & mask == expected) return true;
        }
        return false;
    }
}
