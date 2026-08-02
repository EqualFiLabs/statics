// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockLaunchLiquidityManager {
    address public immutable staticsDiamond;
    address public immutable poolManager;

    mapping(uint256 basketId => mapping(address asset => bytes32 poolKeyHash)) public canonicalPoolHash;

    constructor(address diamond, address manager) {
        staticsDiamond = diamond;
        poolManager = manager;
    }

    function positionManager() external view returns (address) {
        return address(this);
    }

    function setApprovalForAll(address, bool) external {}

    function registerCanonicalPool(uint256 basketId, address asset, PoolKey calldata key) external {
        require(msg.sender == staticsDiamond);
        canonicalPoolHash[basketId][asset] = keccak256(abi.encode(key));
    }
}
