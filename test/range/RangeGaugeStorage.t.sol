// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeHarness} from "../helpers/RangeGaugeHarness.sol";

contract RangeGaugeStorageTest is Test {
    PoolId private constant POOL_A = PoolId.wrap(bytes32(uint256(0xA)));
    PoolId private constant POOL_B = PoolId.wrap(bytes32(uint256(0xB)));
    PoolId private constant POOL_C = PoolId.wrap(bytes32(uint256(0xC)));

    RangeGaugeHarness private gauge;
    MockERC20 private statics;

    function setUp() public {
        gauge = new RangeGaugeHarness();
        statics = new MockERC20("Statics", "STATICS", 18);
        gauge.initialize(address(statics));
    }

    function testUsesDedicatedNamespaceAndLpModule() public view {
        assertEq(gauge.storagePosition(), keccak256("statics.storage.range.gauge.v1"));
        assertEq(gauge.lpModule(), keccak256("statics.position.module.lp"));
        assertEq(
            gauge.lpLegKey(address(gauge), POOL_A),
            keccak256(abi.encode(address(gauge), keccak256("statics.position.module.lp"), PoolId.unwrap(POOL_A)))
        );
    }

    function testInitializesDefaultDurationAndSourcesStaticsSlotZero() public {
        gauge.initializePool(POOL_A, -17);

        (bool initialized, uint8 slotCount, address[4] memory assets) = gauge.rewardConfig(POOL_A);
        assertTrue(initialized);
        assertEq(slotCount, 1);
        assertEq(assets[0], address(statics));
        assertEq(gauge.staticsToken(), address(statics));
        assertEq(gauge.rewardDuration(), 7 days);
        (uint8 slot, bool assigned) = gauge.rewardSlot(POOL_A, address(statics));
        assertTrue(assigned);
        assertEq(slot, 0);
    }

    function testRewardDurationBoundsAndAllowlistState() public {
        address reward = makeAddr("reward");
        gauge.setRewardAssetAllowed(reward, true);
        assertTrue(gauge.rewardAssetAllowed(reward));
        gauge.setRewardAssetAllowed(reward, false);
        assertFalse(gauge.rewardAssetAllowed(reward));

        gauge.setRewardDuration(1 days);
        assertEq(gauge.rewardDuration(), 1 days);
        gauge.setRewardDuration(30 days);
        assertEq(gauge.rewardDuration(), 30 days);

        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.InvalidRewardDuration.selector, uint40(1 days - 1)));
        gauge.setRewardDuration(1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.InvalidRewardDuration.selector, uint40(30 days + 1)));
        gauge.setRewardDuration(30 days + 1);
    }

    function testRewardSlotsAreAppendOnlyAndLifetimeBounded() public {
        gauge.initializePool(POOL_A, 0);
        address rewardOne = makeAddr("rewardOne");
        address rewardTwo = makeAddr("rewardTwo");
        address rewardThree = makeAddr("rewardThree");
        assertEq(gauge.appendRewardAsset(POOL_A, rewardOne), 1);
        assertEq(gauge.appendRewardAsset(POOL_A, rewardTwo), 2);
        assertEq(gauge.appendRewardAsset(POOL_A, rewardThree), 3);

        (uint8 slot, bool assigned) = gauge.rewardSlot(POOL_A, rewardTwo);
        assertTrue(assigned);
        assertEq(slot, 2);
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.RewardAssetAlreadyAssigned.selector, POOL_A, rewardTwo));
        gauge.appendRewardAsset(POOL_A, rewardTwo);
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.RewardSlotLimitReached.selector, POOL_A));
        gauge.appendRewardAsset(POOL_A, makeAddr("rewardFour"));
    }

    function testStoresLpLegPerPositionAndPool() public {
        address manager = makeAddr("manager");
        gauge.seedLeg(7, POOL_A, manager, 91, -120, 240, 1_000);

        (address storedManager, uint256 posmTokenId, int24 lower, int24 upper, uint128 liquidity) = gauge.leg(POOL_A, 7);
        assertEq(storedManager, manager);
        assertEq(posmTokenId, 91);
        assertEq(lower, -120);
        assertEq(upper, 240);
        assertEq(liquidity, 1_000);
        (storedManager,,,,) = gauge.leg(POOL_B, 7);
        assertEq(storedManager, address(0));
    }

    function testPaginatesAndRemovesPositionPoolsWithoutScanningRegistry() public {
        gauge.addPositionPool(7, POOL_A);
        gauge.addPositionPool(7, POOL_B);
        gauge.addPositionPool(7, POOL_C);

        (PoolId[] memory first, uint256 cursor) = gauge.positionPools(7, 0, 2);
        assertEq(first.length, 2);
        assertEq(PoolId.unwrap(first[0]), PoolId.unwrap(POOL_A));
        assertEq(PoolId.unwrap(first[1]), PoolId.unwrap(POOL_B));
        assertEq(cursor, 2);

        gauge.removePositionPool(7, POOL_B);
        (PoolId[] memory remaining, uint256 nextCursor) = gauge.positionPools(7, 0, 10);
        assertEq(remaining.length, 2);
        assertEq(PoolId.unwrap(remaining[0]), PoolId.unwrap(POOL_A));
        assertEq(PoolId.unwrap(remaining[1]), PoolId.unwrap(POOL_C));
        assertEq(nextCursor, 2);
    }

    function testPosmReverseBindingIsUniqueAndExact() public {
        bytes32 binding = gauge.bindPosm(91, 7, POOL_A);
        assertEq(gauge.posmBinding(91), binding);

        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.PosmAlreadyBound.selector, 91, binding));
        gauge.bindPosm(91, 8, POOL_B);

        bytes32 wrong = keccak256(abi.encode(uint256(8), PoolId.unwrap(POOL_A)));
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.PosmBindingMismatch.selector, 91, wrong, binding));
        gauge.unbindPosm(91, 8, POOL_A);

        gauge.unbindPosm(91, 7, POOL_A);
        assertEq(gauge.posmBinding(91), bytes32(0));
    }
}
