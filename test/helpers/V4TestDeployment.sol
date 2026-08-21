// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4TestDeployment} from "./IV4TestDeployment.sol";

contract V4TestDeployment is DeployPermit2, IV4TestDeployment {
    function deployPoolManager(address owner) external returns (address poolManager) {
        poolManager = address(new PoolManager(owner));
    }

    function deployStack(address owner)
        external
        returns (address poolManager, address permit2, address positionManager)
    {
        IPoolManager manager = IPoolManager(address(new PoolManager(owner)));
        IAllowanceTransfer permit2Contract = IAllowanceTransfer(deployPermit2());
        PositionManager positions = new PositionManager(
            manager,
            permit2Contract,
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );

        poolManager = address(manager);
        permit2 = address(permit2Contract);
        positionManager = address(positions);
    }
}
