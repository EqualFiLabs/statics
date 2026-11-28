// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsProtocolPools} from "./IStaticsProtocolPools.sol";

/// @notice Owner-controlled administration of compatible standalone hooks.
interface IStaticsHookAdministration {
    function setDefaultProtocolPoolFeeRate(address hook, IStaticsProtocolPools.PoolSwapFeeRate calldata feeRate)
        external;
    function setBasketFeeAllocation(address hook, IStaticsProtocolPools.BasketFeeAllocation calldata allocation)
        external;
    function setGeneralFeeAllocation(address hook, IStaticsProtocolPools.GeneralFeeAllocation calldata allocation)
        external;
    function defaultProtocolPoolFeeRate(address hook)
        external
        view
        returns (IStaticsProtocolPools.PoolSwapFeeRate memory);
    function basketFeeAllocation(address hook) external view returns (IStaticsProtocolPools.BasketFeeAllocation memory);
    function generalFeeAllocation(address hook)
        external
        view
        returns (IStaticsProtocolPools.GeneralFeeAllocation memory);
}
