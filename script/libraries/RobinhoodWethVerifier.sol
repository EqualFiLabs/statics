// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

interface IRobinhoodProxyAdminOwner {
    function owner() external view returns (address);
}

/// @notice Verifies the canonical Robinhood mainnet WETH proxy and its complete upgrade authority chain.
library RobinhoodWethVerifier {
    uint256 internal constant ROBINHOOD_MAINNET_CHAIN_ID = 4_663;
    string internal constant ROBINHOOD_MAINNET_MANIFEST = "deployments/robinhood-chain-4663.json";
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error InvalidRobinhoodWeth(address expected, address actual);
    error InvalidRobinhoodWethCodeHash(bytes32 expected, bytes32 actual);
    error InvalidRobinhoodDependency(address expected, address actual);
    error InvalidRobinhoodDependencyCodeHash(address dependency, bytes32 expected, bytes32 actual);

    function validateMainnet(Vm vm, address configuredWeth) internal view returns (bytes32 dependencyHash) {
        if (block.chainid != ROBINHOOD_MAINNET_CHAIN_ID) return bytes32(0);
        string memory manifest = vm.readFile(ROBINHOOD_MAINNET_MANIFEST);
        address expectedWeth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        if (configuredWeth != expectedWeth) revert InvalidRobinhoodWeth(expectedWeth, configuredWeth);

        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash");
        bytes32 actualCodeHash = configuredWeth.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidRobinhoodWethCodeHash(expectedCodeHash, actualCodeHash);
        }

        address implementation = _slotAddress(vm, configuredWeth, ERC1967_IMPLEMENTATION_SLOT);
        address expectedImplementation = vm.parseJsonAddress(manifest, ".contracts.weth.implementation.address");
        if (implementation != expectedImplementation) {
            revert InvalidRobinhoodDependency(expectedImplementation, implementation);
        }
        bytes32 expectedImplementationCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.implementation.runtimeCodeHash");
        _requireCodeHash(implementation, expectedImplementationCodeHash);

        bytes32 authorityHash = _validateAuthority(vm, configuredWeth, manifest);
        dependencyHash = keccak256(
            abi.encode(expectedCodeHash, expectedImplementation, expectedImplementationCodeHash, authorityHash)
        );
    }

    function _validateAuthority(Vm vm, address configuredWeth, string memory manifest)
        private
        view
        returns (bytes32 authorityHash)
    {
        address proxyAdmin = _slotAddress(vm, configuredWeth, ERC1967_ADMIN_SLOT);
        address expectedProxyAdmin = vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.address");
        if (proxyAdmin != expectedProxyAdmin) revert InvalidRobinhoodDependency(expectedProxyAdmin, proxyAdmin);
        bytes32 expectedProxyAdminCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.runtimeCodeHash");
        _requireCodeHash(proxyAdmin, expectedProxyAdminCodeHash);

        bytes32 ownerHash = _validateProxyAdminOwner(vm, proxyAdmin, manifest);
        authorityHash = keccak256(abi.encode(expectedProxyAdmin, expectedProxyAdminCodeHash, ownerHash));
    }

    function _validateProxyAdminOwner(Vm vm, address proxyAdmin, string memory manifest)
        private
        view
        returns (bytes32 ownerHash)
    {
        address proxyAdminOwner = IRobinhoodProxyAdminOwner(proxyAdmin).owner();
        address expectedProxyAdminOwner = vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.owner.address");
        if (proxyAdminOwner != expectedProxyAdminOwner) {
            revert InvalidRobinhoodDependency(expectedProxyAdminOwner, proxyAdminOwner);
        }
        bytes32 expectedProxyAdminOwnerCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.owner.runtimeCodeHash");
        _requireCodeHash(proxyAdminOwner, expectedProxyAdminOwnerCodeHash);

        address ownerImplementation = _slotAddress(vm, proxyAdminOwner, ERC1967_IMPLEMENTATION_SLOT);
        address expectedOwnerImplementation =
            vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.owner.implementation.address");
        if (ownerImplementation != expectedOwnerImplementation) {
            revert InvalidRobinhoodDependency(expectedOwnerImplementation, ownerImplementation);
        }
        bytes32 expectedOwnerImplementationCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.owner.implementation.runtimeCodeHash");
        _requireCodeHash(ownerImplementation, expectedOwnerImplementationCodeHash);

        address ownerProxyAdmin = _slotAddress(vm, proxyAdminOwner, ERC1967_ADMIN_SLOT);
        if (ownerProxyAdmin != proxyAdmin) revert InvalidRobinhoodDependency(proxyAdmin, ownerProxyAdmin);
        ownerHash = keccak256(
            abi.encode(
                expectedProxyAdminOwner,
                expectedProxyAdminOwnerCodeHash,
                expectedOwnerImplementation,
                expectedOwnerImplementationCodeHash
            )
        );
    }

    function _slotAddress(Vm vm, address target, bytes32 slot) private view returns (address value) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    function _requireCodeHash(address dependency, bytes32 expectedCodeHash) private view {
        bytes32 actualCodeHash = dependency.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidRobinhoodDependencyCodeHash(dependency, expectedCodeHash, actualCodeHash);
        }
    }
}
