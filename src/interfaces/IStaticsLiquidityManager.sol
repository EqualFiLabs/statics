// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsLiquidityManager {
    struct PositionRequest {
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

    struct ManagedLiquidityRequest {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Limit;
        uint256 amount1Limit;
        uint256 deadline;
        address receiver;
    }

    struct ManagedPositionState {
        PoolId poolId;
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address owner;
        address subscriber;
    }

    struct ManagedPositionMovement {
        uint256 tokenId;
        uint128 liquidityBefore;
        uint128 liquidityAfter;
        uint256 spent0;
        uint256 spent1;
        uint256 received0;
        uint256 received1;
        uint256 refund0;
        uint256 refund1;
    }

    event UserPositionMinted(
        bytes32 indexed poolId,
        uint256 indexed tokenId,
        address recipient,
        address refundRecipient,
        uint256 spent0,
        uint256 spent1,
        uint256 refund0,
        uint256 refund1
    );
    event ManagedPositionMinted(bytes32 indexed poolId, uint256 indexed tokenId, uint128 liquidity);
    event ManagedPositionAttached(bytes32 indexed poolId, uint256 indexed tokenId, address indexed previousOwner);
    event ManagedPositionLiquidityChanged(
        bytes32 indexed poolId, uint256 indexed tokenId, uint128 liquidityBefore, uint128 liquidityAfter
    );
    event ManagedPositionFeesCollected(
        bytes32 indexed poolId, uint256 indexed tokenId, address indexed receiver, uint256 amount0, uint256 amount1
    );
    event ManagedPositionBurned(
        bytes32 indexed poolId, uint256 indexed tokenId, address indexed receiver, uint256 amount0, uint256 amount1
    );
    event ManagedPositionExited(
        bytes32 indexed poolId, uint256 indexed tokenId, address indexed receiver, uint256 amount0, uint256 amount1
    );
    event UnboundPositionRecovered(uint256 indexed tokenId, address indexed receiver);

    function staticsDiamond() external view returns (address);
    function positionManager() external view returns (address);
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function mintUserPosition(PositionRequest calldata request, address recipient, address refundRecipient)
        external
        returns (PositionMovement memory movement, uint256 refund0, uint256 refund1);
    function mintManagedPosition(PositionRequest calldata request, address refundRecipient)
        external
        returns (ManagedPositionMovement memory movement);
    function attachManagedPosition(address owner, PoolId expectedPoolId, uint256 tokenId)
        external
        returns (ManagedPositionState memory state);
    function inspectManagedPosition(uint256 tokenId) external view returns (ManagedPositionState memory state);
    function increaseManagedPosition(ManagedLiquidityRequest calldata request)
        external
        returns (ManagedPositionMovement memory movement);
    function decreaseManagedPosition(ManagedLiquidityRequest calldata request)
        external
        returns (ManagedPositionMovement memory movement);
    function collectManagedPositionFees(ManagedLiquidityRequest calldata request)
        external
        returns (ManagedPositionMovement memory movement);
    function burnManagedPosition(ManagedLiquidityRequest calldata request)
        external
        returns (ManagedPositionMovement memory movement);
    function exitManagedPosition(ManagedLiquidityRequest calldata request)
        external
        returns (ManagedPositionMovement memory movement);
    function recoverUnboundPosition(uint256 tokenId, address receiver) external;
}
