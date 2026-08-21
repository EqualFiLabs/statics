// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

interface IV4TestDeployment {
    function deployPoolManager(address owner) external returns (address poolManager);

    function deployStack(address owner)
        external
        returns (address poolManager, address permit2, address positionManager);
}
