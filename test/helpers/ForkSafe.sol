// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PhaseTwoRehearsalBatch} from "../../scripts/phase-one-rehearsal/helpers/PhaseTwoRehearsalActors.sol";

interface IForkSafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hash) external;
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes calldata
    ) external payable returns (bool);
}

/// @dev Normal Safe approvals and delegatecall batching on the pinned fork. No Safe storage shortcuts.
abstract contract ForkSafe is Test {
    PhaseTwoRehearsalBatch internal safeBatch;

    function _executeSafe(
        address owner,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        string memory label
    ) internal {
        IForkSafe safe = IForkSafe(owner);
        bytes memory batch = abi.encodeCall(PhaseTwoRehearsalBatch.execute, (targets, values, payloads));
        bytes32 digest =
            safe.getTransactionHash(address(safeBatch), 0, batch, 1, 0, 0, 0, address(0), address(0), safe.nonce());
        address[] memory owners = safe.getOwners();
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (owners[j] < owners[i]) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        bytes memory signatures;
        uint256 threshold = safe.getThreshold();
        assertGt(threshold, 0);
        assertLe(threshold, owners.length);
        for (uint256 i; i < threshold; ++i) {
            bytes memory approval = abi.encodeCall(IForkSafe.approveHash, (digest));
            _recordForkCall("safe-approval", owners[i], owner, approval, "");
            vm.prank(owners[i]);
            safe.approveHash(digest);
            signatures =
                bytes.concat(signatures, abi.encodePacked(bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1)));
        }
        bytes memory execution = abi.encodeCall(
            IForkSafe.execTransaction, (address(safeBatch), 0, batch, 1, 0, 0, 0, address(0), address(0), signatures)
        );
        _recordForkCall(label, _safeExecutor(), owner, execution, "");
        vm.prank(_safeExecutor());
        (bool ok, bytes memory result) = owner.call(execution);
        assertTrue(ok && abi.decode(result, (bool)), "Safe batch failed");
    }

    function _safeExecutor() internal pure returns (address) {
        return address(0xE002);
    }

    function _recordForkCall(string memory, address, address, bytes memory, bytes memory) internal virtual {}
}
