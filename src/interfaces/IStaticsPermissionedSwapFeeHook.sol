// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsPermissionedSwapFeeHook {
    struct FeeAllocation {
        uint16 creatorShareBps;
        uint16 treasuryShareBps;
        uint16 staticsStakerShareBps;
        uint16 basketStakerShareBps;
    }

    struct PoolEconomics {
        uint16 venueFeeBps;
        uint8 additionalRewardRestrictedMask;
        FeeAllocation allocation;
    }

    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        address controller;
        address creator;
        bool registered;
        bool decommissioned;
    }

    event PermissionedPoolRegistered(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        address controller,
        address creator,
        PoolEconomics economics
    );
    event PermissionedPoolEconomicsSet(PoolId indexed poolId, PoolEconomics oldEconomics, PoolEconomics newEconomics);
    event PermissionedPoolDecommissioned(PoolId indexed poolId);
    event TrustedPermissionedPeripherySet(address indexed periphery, bool trusted);
    event PermissionedVenueFeeCharged(
        PoolId indexed poolId,
        Currency indexed outputCurrency,
        uint256 grossOutput,
        uint256 chargedAmount,
        uint256 creatorAmount,
        uint256 treasuryAmount,
        uint256 staticsStakerAmount,
        uint256 basketStakerAmount
    );
    event PermissionedRewardsNormalized(
        PoolId indexed poolId,
        Currency indexed restrictedCurrency,
        Currency indexed rewardCurrency,
        uint256 amountIn,
        uint256 amountOut
    );

    function staticsDiamond() external view returns (address);
    function registerPool(PoolKey calldata key, address controller, address creator, PoolEconomics calldata economics)
        external
        returns (PoolId poolId);
    function setPoolEconomics(PoolId poolId, PoolEconomics calldata economics) external;
    function decommissionPool(PoolKey calldata key) external;
    function setTrustedPeriphery(address periphery, bool trusted) external;
    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function poolEconomics(PoolId poolId) external view returns (PoolEconomics memory economics);
    function trustedPeriphery(address periphery) external view returns (bool trusted);
}
