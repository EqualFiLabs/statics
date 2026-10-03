// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {GovernanceFacet} from "../../../src/facets/GovernanceFacet.sol";
import {LibDiamond} from "../../../src/libraries/LibDiamond.sol";
import {LibGovernance} from "../../../src/libraries/LibGovernance.sol";
import {LibProtocolPools} from "../../../src/libraries/LibProtocolPools.sol";

contract PhaseOneGovernanceHarness is GovernanceFacet {
    using PoolIdLibrary for PoolKey;

    address public constant OWNER = address(0xA11CE);
    address public constant GUARDIAN = address(0xBEEF);

    PoolId private immutable firstPool;
    PoolId private immutable secondPool;

    constructor() {
        LibDiamond.initializeOwnership(OWNER);
        LibGovernance.governanceStorage().guardian = GUARDIAN;
        firstPool = _register(3_000);
        secondPool = _register(500);
    }

    function poolIds() external view returns (PoolId first, PoolId second) {
        return (firstPool, secondPool);
    }

    function pauseStakeMask() external pure returns (uint256) {
        return LibGovernance.PAUSE_STAKE;
    }

    function pauseRedeemMask() external pure returns (uint256) {
        return LibGovernance.PAUSE_REDEEM;
    }

    function _register(uint24 fee) private returns (PoolId poolId) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: fee,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();
        LibProtocolPools.GeneralPool storage pool = LibProtocolPools.protocolPoolStorage().generalPools[poolId];
        pool.key = key;
        pool.creator = OWNER;
        pool.registered = true;
    }
}
