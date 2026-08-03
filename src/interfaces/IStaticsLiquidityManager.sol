// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsLiquidityManager {
    struct PositionRequest {
        uint256 basketId;
        address asset;
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint256 amount0Limit;
        uint256 amount1Limit;
        uint256 deadline;
    }

    struct PositionMovement {
        uint256 tokenId;
        uint256 spent0;
        uint256 received0;
        uint256 spent1;
        uint256 received1;
    }

    event CanonicalPoolRegistered(uint256 indexed basketId, address indexed asset, bytes32 indexed poolKeyHash);
    event UserPositionMinted(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed tokenId,
        address recipient,
        address refundRecipient,
        uint256 spent0,
        uint256 spent1,
        uint256 refund0,
        uint256 refund1
    );
    event UserPositionIncreased(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed tokenId,
        address refundRecipient,
        uint256 liquidity,
        uint256 spent0,
        uint256 spent1,
        uint256 refund0,
        uint256 refund1
    );

    function staticsDiamond() external view returns (address);
    function positionManager() external view returns (address);
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function registerCanonicalPool(uint256 basketId, address asset, PoolKey calldata key) external;
    function mintUserPosition(PositionRequest calldata request, address recipient, address refundRecipient)
        external
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1);
    function increaseUserPosition(PositionRequest calldata request, uint256 tokenId, address refundRecipient)
        external
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1);
    function canonicalPoolHash(uint256 basketId, address asset) external view returns (bytes32);
}
