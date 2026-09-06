// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketCollateral} from "../../src/libraries/LibBasketCollateral.sol";
import {LibBasketRewards} from "../../src/libraries/LibBasketRewards.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";

/// @dev Narrow storage harness for reward-index arithmetic and denominator changes.
contract BasketRewardIndexHarness {
    uint256 private constant BASKET_ID = 1;
    address private constant REWARD_ASSET = address(0xA11CE);

    constructor(uint256 eligibleShares, uint256 positionShares) {
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[BASKET_ID];
        configured.token = REWARD_ASSET;
        LibBasketRewards.RewardStorage storage rs = LibBasketRewards.rewardStorage();
        rs.totalEligibleShares[BASKET_ID] = eligibleShares;
        if (positionShares != 0) {
            rs.positions[1][BASKET_ID].eligibleShares = positionShares;
            LibBasketCollateral.collateralStorage().positions[1][BASKET_ID].depositedShares = positionShares;
        }
    }

    function accrue(uint256 amount) external {
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[BASKET_ID];
        LibBasketRewards.accrueReserved(BASKET_ID, configured, REWARD_ASSET, amount);
    }

    function decrease(uint256 shares) external {
        LibBasketRewards.decreasePosition(1, BASKET_ID, LibBasket.basketStorage().baskets[BASKET_ID], shares);
    }

    function accounting()
        external
        view
        returns (uint256 indexRay, uint256 remainder, uint256 indexedAmount, uint256 crystallized, uint256 treasury)
    {
        LibBasketRewards.RewardBook storage book = LibBasketRewards.rewardStorage().books[BASKET_ID][REWARD_ASSET];
        return (
            book.indexRay,
            book.indexRemainder,
            book.indexedAmount,
            book.crystallizedAmount,
            LibGlobalRewards.rewardStorage().treasuryAccrued[REWARD_ASSET]
        );
    }
}

/// @dev Narrow storage harness for reward-index arithmetic and denominator changes.
contract GlobalRewardIndexHarness {
    address private constant REWARD_ASSET = address(0xB0B);

    constructor(uint256 eligibleWeight, uint256 positionWeight) {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.RewardBook storage book = rs.books[REWARD_ASSET];
        book.eligibleStake = eligibleWeight;
        book.eligibleWeight = eligibleWeight;
        book.weightInitialized = true;
        if (positionWeight != 0) {
            LibGlobalRewards.StakePosition storage position = rs.positions[1];
            position.balance = positionWeight;
            position.optedInAssets.push(REWARD_ASSET);
            position.optedInIndexPlusOne[REWARD_ASSET] = 1;
            LibGlobalRewards.PositionSelection storage selection = position.selections[REWARD_ASSET];
            selection.eligibleStake = positionWeight;
            selection.eligibleWeight = positionWeight;
            selection.weightInitialized = true;
        }
    }

    function accrue(uint256 amount) external {
        LibGlobalRewards.accrueReservedSwapStakerFee(REWARD_ASSET, amount);
    }

    function decrease(uint256 amount) external {
        LibGlobalRewards.decreaseStake(1, amount);
    }

    function accounting()
        external
        view
        returns (uint256 indexRay, uint256 remainder, uint256 indexedAmount, uint256 crystallized, uint256 treasury)
    {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.RewardBook storage book = rs.books[REWARD_ASSET];
        return (
            book.indexRay,
            book.indexRemainder,
            book.indexedAmount,
            book.crystallizedAmount,
            rs.treasuryAccrued[REWARD_ASSET]
        );
    }
}

contract RewardIndexRemainderTest is Test {
    uint256 private constant RAY = 1e27;

    function test_BasketFragmentedAccrualMatchesAggregateAccrual() public {
        BasketRewardIndexHarness fragmented = new BasketRewardIndexHarness(3, 0);
        BasketRewardIndexHarness aggregate = new BasketRewardIndexHarness(3, 0);

        fragmented.accrue(1);
        fragmented.accrue(1);
        fragmented.accrue(1);
        aggregate.accrue(3);

        (uint256 fragmentedIndex, uint256 fragmentedRemainder, uint256 fragmentedIndexed,,) = fragmented.accounting();
        (uint256 aggregateIndex, uint256 aggregateRemainder, uint256 aggregateIndexed,,) = aggregate.accounting();
        assertEq(fragmentedIndex, aggregateIndex);
        assertEq(fragmentedIndex, RAY);
        assertEq(fragmentedRemainder, aggregateRemainder);
        assertEq(fragmentedRemainder, 0);
        assertEq(fragmentedIndexed, aggregateIndexed);
        assertEq(fragmentedIndexed, 3);
    }

    function test_GlobalFragmentedAccrualMatchesAggregateAccrual() public {
        GlobalRewardIndexHarness fragmented = new GlobalRewardIndexHarness(3, 0);
        GlobalRewardIndexHarness aggregate = new GlobalRewardIndexHarness(3, 0);

        fragmented.accrue(1);
        fragmented.accrue(1);
        fragmented.accrue(1);
        aggregate.accrue(3);

        (uint256 fragmentedIndex, uint256 fragmentedRemainder, uint256 fragmentedIndexed,,) = fragmented.accounting();
        (uint256 aggregateIndex, uint256 aggregateRemainder, uint256 aggregateIndexed,,) = aggregate.accounting();
        assertEq(fragmentedIndex, aggregateIndex);
        assertEq(fragmentedIndex, RAY);
        assertEq(fragmentedRemainder, aggregateRemainder);
        assertEq(fragmentedRemainder, 0);
        assertEq(fragmentedIndexed, aggregateIndexed);
        assertEq(fragmentedIndexed, 3);
    }

    function test_BasketDenominatorChangeRoutesWholeCarriedDust() public {
        uint256 eligibleShares = 2 * RAY + 1;
        BasketRewardIndexHarness harness = new BasketRewardIndexHarness(eligibleShares, eligibleShares);
        harness.accrue(1);

        harness.decrease(1);

        (uint256 indexRay, uint256 remainder, uint256 indexedAmount, uint256 crystallized, uint256 treasury) =
            harness.accounting();
        assertEq(indexRay, 0);
        assertEq(remainder, 0);
        assertEq(indexedAmount, 0);
        assertEq(crystallized, 0);
        assertEq(treasury, 1);
    }

    function test_GlobalDenominatorChangeRoutesWholeCarriedDust() public {
        uint256 eligibleWeight = 2 * RAY + 1;
        GlobalRewardIndexHarness harness = new GlobalRewardIndexHarness(eligibleWeight, eligibleWeight);
        harness.accrue(1);

        harness.decrease(1);

        (uint256 indexRay, uint256 remainder, uint256 indexedAmount, uint256 crystallized, uint256 treasury) =
            harness.accounting();
        assertEq(indexRay, 0);
        assertEq(remainder, 0);
        assertEq(indexedAmount, 0);
        assertEq(crystallized, 0);
        assertEq(treasury, 1);
    }
}
