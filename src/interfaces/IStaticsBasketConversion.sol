// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsBasketConversion {
    struct Configuration {
        address hook;
        address zap;
        address router;
        address poolManager;
    }

    struct Market {
        PoolKey key;
        uint256 basketId;
        address basketToken;
        address quote;
        bool active;
    }

    event BasketConversionMarketCreated(PoolId indexed poolId, uint256 indexed basketId, address indexed quote);
    event BasketConversionMarketDecommissioned(PoolId indexed poolId);

    function basketConversionConfiguration() external view returns (Configuration memory);
    function basketConversionMarket(PoolId poolId) external view returns (Market memory);
    function createBasketConversionMarket(uint256 basketId, address quote, uint256 maximumCreationFee, uint256 deadline)
        external
        payable
        returns (PoolId);
    function decommissionBasketConversionMarket(PoolId poolId) external;
    function mintBasketConversion(PoolId poolId, uint256 shares, address receiver, uint256[] calldata expected) external;
    function prefundBasketConversion(PoolId poolId, address payer, uint256 amount) external;
}

interface IStaticsBasketConversionDelivery {
    function deliverBasketConversion(
        PoolId poolId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata amounts
    ) external;
}
