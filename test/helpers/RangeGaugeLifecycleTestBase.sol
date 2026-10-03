// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "./RangeGaugeFeatureTestBase.sol";

abstract contract RangeGaugeLifecycleTestBase is RangeGaugeFeatureTestBase {
    uint128 internal constant INITIAL_LIQUIDITY = 5 ether;
    uint256 internal constant TOKEN_MAXIMUM = 10 ether;

    function _createPosition(address owner) internal returns (uint256 positionId) {
        vm.prank(owner);
        positionId = IStaticsPosition(address(diamond)).createPosition(owner);
    }

    function _provide(uint256 positionId, PoolId poolId, address payer)
        internal
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        _fundAndApprovePoolAssets(_poolKey(poolId), payer, TOKEN_MAXIMUM);
        vm.prank(payer);
        movement = rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _assignReward(PoolId poolId, address asset) internal returns (uint8 slot) {
        rangeGauge.setGaugeRewardAssetAllowed(asset, true);
        vm.prank(alice);
        slot = rangeGauge.appendPoolRewardAsset(poolId, asset);
    }

    function _fundReward(PoolId poolId, MockERC20 reward, uint256 amount) internal returns (uint256 received) {
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        reward.mint(alice, amount);
        vm.startPrank(alice);
        reward.approve(address(diamond), amount);
        received = rangeGauge.fundPoolReward(poolId, slot, amount, 0, 0);
        vm.stopPrank();
    }

    function _claim(
        uint256 positionId,
        PoolId poolId,
        address asset,
        uint256 minimumAmount,
        address receiver,
        address caller
    ) internal returns (uint256 received) {
        uint8 slot = _ordinaryRewardSlot(poolId, asset);
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        minimums[0] = minimumAmount;
        vm.prank(caller);
        uint256[] memory amounts = rangeGauge.claimLpRewards(positionId, poolId, slots, minimums, receiver);
        received = amounts[0];
    }

    function _exit(uint256 positionId, PoolId poolId, address caller)
        internal
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        vm.prank(caller);
        movement = rangeGauge.exitLiquidity(positionId, poolId, 0, 0, block.timestamp + 1 hours);
    }

    function _fundAndApprovePoolAssets(PoolKey memory key, address user, uint256 amount) internal {
        MockERC20(Currency.unwrap(key.currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(key.currency0)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _poolKey(PoolId poolId) internal view returns (PoolKey memory key) {
        key = IStaticsProtocolPools(address(diamond)).protocolPool(poolId).key;
    }

    function _assertPosmBurned(uint256 posmTokenId) internal {
        vm.expectRevert();
        IERC721(address(rangePositionManager)).ownerOf(posmTokenId);
    }

    function _ordinaryRewardSlot(PoolId poolId, address asset) internal view returns (uint8 slot) {
        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        for (uint8 candidate = 1; candidate < config.slotCount; ++candidate) {
            if (config.assets[candidate] == asset) return candidate;
        }
        revert("ordinary reward slot not found");
    }

    function _ensureOrdinaryRewardSlot(PoolId poolId, address asset) internal returns (uint8 slot) {
        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        for (uint8 candidate = 1; candidate < config.slotCount; ++candidate) {
            if (config.assets[candidate] == asset) return candidate;
        }
        return _assignReward(poolId, asset);
    }

    function _mintUnmanagedPosition(PoolKey memory key, address owner) internal returns (uint256 posmTokenId) {
        _fundAndApprovePoolAssets(key, owner, TOKEN_MAXIMUM);
        uint48 deadline = uint48(block.timestamp + 1 hours);
        posmTokenId = rangePositionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            uint256(INITIAL_LIQUIDITY),
            uint128(TOKEN_MAXIMUM),
            uint128(TOKEN_MAXIMUM),
            owner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.startPrank(owner);
        IERC20(Currency.unwrap(key.currency0)).approve(address(rangePermit2), TOKEN_MAXIMUM);
        IERC20(Currency.unwrap(key.currency1)).approve(address(rangePermit2), TOKEN_MAXIMUM);
        rangePermit2.approve(
            Currency.unwrap(key.currency0), address(rangePositionManager), uint160(TOKEN_MAXIMUM), deadline
        );
        rangePermit2.approve(
            Currency.unwrap(key.currency1), address(rangePositionManager), uint160(TOKEN_MAXIMUM), deadline
        );
        rangePositionManager.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
    }
}
