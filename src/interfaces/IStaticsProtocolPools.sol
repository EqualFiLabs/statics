// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsProtocolPools {
    enum ProtocolPoolKind {
        None,
        BasketCanonical,
        General
    }

    struct PoolSwapFeeRate {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
    }

    struct BasketFeeAllocation {
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct GeneralFeeAllocation {
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct CreatePoolParams {
        address tokenA;
        address tokenB;
        int24 tickSpacing;
        uint160 sqrtPriceBPerAX96;
        PoolSwapFeeRate feeRate;
        address creator;
        uint256 nonce;
        uint256 deadline;
    }

    struct GeneralPoolQuote {
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        PoolSwapFeeRate feeRate;
        uint256 creationFee;
        bytes32 authorizationDigest;
    }

    struct ProtocolPoolView {
        PoolId poolId;
        PoolKey key;
        ProtocolPoolKind kind;
        bool decommissioned;
        uint256 basketId;
        address basketAsset;
        address creator;
        uint128 permanentLiquidity;
    }

    event ProtocolPoolCreated(
        PoolId indexed poolId,
        address indexed creator,
        address indexed currency0,
        address currency1,
        int24 tickSpacing,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event PoolCreationFeeSet(uint256 amount);
    event PoolCreationNonceInvalidated(address indexed creator, uint256 indexed nonce);
    event ProtocolPoolFeeRateSet(PoolId indexed poolId, uint16 inputFeeBps, uint16 outputFeeBps);
    event BasketFeeAllocationSet(
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    );
    event GeneralFeeAllocationSet(
        uint16 polShareBps, uint16 liquidityProviderShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps
    );
    event GeneralPoolDecommissioned(
        PoolId indexed poolId, address indexed currency0, address indexed currency1, uint256 amount0, uint256 amount1
    );
    event LiquidityManagerReplaced(address indexed oldManager, address indexed newManager);

    // --- Creation facet ---
    function quotePool(CreatePoolParams calldata params) external view returns (GeneralPoolQuote memory quote);
    function createPool(CreatePoolParams calldata params, bytes calldata creatorAuthorization)
        external
        payable
        returns (PoolId poolId);
    function invalidatePoolCreationNonce(uint256 nonce) external;

    // --- Admin facet ---
    function setPoolCreationFee(uint256 amount) external;
    function setProtocolPoolFeeRate(PoolId poolId, PoolSwapFeeRate calldata feeRate) external;
    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external;
    function setGeneralFeeAllocation(GeneralFeeAllocation calldata allocation) external;
    function decommissionGeneralPool(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
    function replaceLiquidityManager(address newManager) external;

    // --- View facet ---
    function protocolPool(PoolId poolId) external view returns (ProtocolPoolView memory pool);
    function isProtocolPool(PoolId poolId) external view returns (bool registered);
    function poolCreationFee() external view returns (uint256 amount);
    function isPoolCreationNonceUsed(address creator, uint256 nonce) external view returns (bool used);
    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation);
    function generalFeeAllocation() external view returns (GeneralFeeAllocation memory allocation);
    function protocolPoolFeeRate(PoolId poolId) external view returns (PoolSwapFeeRate memory feeRate);
    function protocolPoolCreator(PoolId poolId) external view returns (address creator);
}
