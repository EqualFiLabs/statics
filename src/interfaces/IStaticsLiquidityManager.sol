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
    event ProtocolInventoryCredited(uint256 indexed basketId, address indexed token, uint256 amount);
    event ProtocolInventoryReturned(uint256 indexed basketId, address indexed token, uint256 spent, uint256 received);
    event ProtocolPositionMinted(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed tokenId,
        uint256 liquidity,
        uint256 spent0,
        uint256 spent1
    );
    event ProtocolPositionIncreased(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed tokenId,
        uint256 liquidity,
        uint256 spent0,
        uint256 received0,
        uint256 spent1,
        uint256 received1
    );
    event ProtocolPositionCollected(
        uint256 indexed basketId, address indexed asset, uint256 indexed tokenId, uint256 received0, uint256 received1
    );
    event ProtocolPositionReduced(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed tokenId,
        uint256 liquidity,
        uint256 received0,
        uint256 received1
    );
    event ProtocolPositionTransferred(
        uint256 indexed basketId, address indexed asset, uint256 indexed tokenId, address receiver
    );
    event ProtocolPositionBurned(
        uint256 indexed basketId, address indexed asset, uint256 indexed tokenId, uint256 received0, uint256 received1
    );
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
    function creditProtocolInventory(uint256 basketId, address token, uint256 amount) external;
    function mintProtocolPosition(PositionRequest calldata request) external returns (PositionMovement memory movement);
    function increaseProtocolPosition(PositionRequest calldata request)
        external
        returns (PositionMovement memory movement);
    function collectProtocolPosition(uint256 basketId, address asset, uint256 deadline)
        external
        returns (PositionMovement memory movement);
    function removeProtocolLiquidity(
        uint256 basketId,
        address asset,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (PositionMovement memory movement);
    function burnProtocolPosition(
        uint256 basketId,
        address asset,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (PositionMovement memory movement);
    function returnProtocolInventory(uint256 basketId, address token, uint256 amount)
        external
        returns (uint256 spent, uint256 received);
    function transferProtocolPosition(uint256 basketId, address asset, address receiver)
        external
        returns (uint256 tokenId);
    function mintUserPosition(PositionRequest calldata request, address recipient, address refundRecipient)
        external
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1);
    function increaseUserPosition(PositionRequest calldata request, uint256 tokenId, address refundRecipient)
        external
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1);
    function canonicalPoolHash(uint256 basketId, address asset) external view returns (bytes32);
    function protocolInventory(uint256 basketId, address token) external view returns (uint256 amount);
    function totalProtocolInventory(address token) external view returns (uint256 amount);
    function protocolPositionId(uint256 basketId, address asset) external view returns (uint256 tokenId);
}
