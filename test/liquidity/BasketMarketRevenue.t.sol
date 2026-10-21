// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBasketPreparation} from "../../src/interfaces/IStaticsBasketPreparation.sol";
import {IStaticsBasketSettlement} from "../../src/interfaces/IStaticsBasketSettlement.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {ProtocolPolFacet} from "../../src/facets/ProtocolPolFacet.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

/// @dev Full Diamond launches, real V4 swaps and funded claims; no synthetic reward balances.
contract BasketMarketRevenueTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    address private creator = makeAddr("market creator");
    uint256 private constant ACTIVATION_FEE = 0.025 ether;
    IStaticsProtocolPools private pools;
    IStaticsProtocolRevenue private revenue;
    IStaticsSwapFeeHook private hook;
    address[2] private tokens;
    uint256[2] private positions;
    PoolKey private key;
    PoolId private poolId;
    uint256 private globalPosition;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        hook = IStaticsSwapFeeHook(address(_localBasketHook));
        vm.deal(bob, 100 ether);
        vm.deal(creator, 100 ether);
        pools.setPoolCreationFee(1 ether);
        pools.setProtocolPolActivationFee(ACTIVATION_FEE);
    }

    function testBilateralRewardsWithBasketZeroAsCurrencyZero() public {
        _market(true, 3);
        _globalStake();
        _exerciseAndClaim();
    }

    function testBilateralRewardsWithBasketZeroAsCurrencyOne() public {
        _market(false, 3);
        _globalStake();
        _exerciseAndClaim();
    }

    function testEachBasketEligibilityFallsBackIndependentlyWithAndWithoutPol() public {
        for (uint256 flags; flags < 8; ++flags) {
            uint256 snapshot = vm.snapshotState();
            _market(true, flags);
            _fourSwaps();
            for (uint256 i; i < 2; ++i) {
                Currency currency = Currency.wrap(tokens[i]);
                IStaticsSwapFeeHook.FeeDistribution memory pending = hook.pendingFeeDistribution(poolId, currency);
                bool eligible = flags & (1 << i) != 0;
                bool pol = flags & 4 != 0;
                assertEq(pending.basketStaker > 0, eligible);
                assertEq(hook.pendingProtocolPol(poolId, currency) > 0, pol);
                uint256 charged = hook.claimLiability(currency);
                assertEq(
                    charged,
                    pending.basketStaker + pending.creator + pending.treasury
                        + hook.pendingProtocolPol(poolId, currency)
                );
                // Each leg rounds separately; rounding tolerance is bounded by the four swaps.
                assertApproxEqAbs(pending.creator, charged * 500 / 10_000, 4);
                assertApproxEqAbs(pending.basketStaker, eligible ? charged * 3000 / 10_000 : 0, 4);
                assertApproxEqAbs(
                    hook.pendingProtocolPol(poolId, currency), pol ? charged * (eligible ? 1500 : 4500) / 10_000 : 0, 8
                );
                uint256 otherIndex = basketRewards.basketRewardState(1 - i, tokens[1 - i]).indexRay;
                pools.settleProtocolPoolRevenue(poolId, tokens[i]);
                assertEq(basketRewards.basketRewardState(i, tokens[i]).indexedReserve, pending.basketStaker);
                assertEq(basketRewards.basketRewardState(1 - i, tokens[1 - i]).indexRay, otherIndex);
            }
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function testPoolCreatorControlsPaidActivationInsteadOfEitherBasketCreator() public {
        _market(true, 0);
        for (uint256 i; i < 2; ++i) {
            address caller = i == 0 ? alice : bob;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.OnlyPoolCreator.selector, caller, creator));
            pools.activateProtocolPoolPol{value: ACTIVATION_FEE}(poolId);
        }
        uint256 beforeBalance = treasury.balance;
        vm.prank(creator);
        pools.activateProtocolPoolPol{value: ACTIVATION_FEE}(poolId);
        assertEq(treasury.balance - beforeBalance, ACTIVATION_FEE);
        assertTrue(pools.protocolPool(poolId).polActivated);
        assertEq(pools.protocolPoolCreator(basketLiquidity.canonicalPool(0, address(assetA)).poolId), alice);
        assertEq(pools.protocolPoolCreator(basketLiquidity.canonicalPool(1, address(assetA)).poolId), bob);
    }

    function _market(bool basketZeroLow, uint256 flags) private {
        _launch(alice, true, true);
        _launch(bob, false, basketZeroLow);
        assertEq(tokens[0] < tokens[1], basketZeroLow);
        _fundAndApprove(alice, 1000 ether, 1000 ether);
        for (uint256 i; i < 2; ++i) {
            uint256[] memory quote = baskets.quoteMint(i, 100 ether);
            vm.startPrank(alice);
            baskets.mint(i, 100 ether, alice, quote);
            IERC20(tokens[i]).approve(address(v4Router), type(uint256).max);
            if (flags & (1 << i) != 0) {
                IERC20(tokens[i]).approve(address(diamond), 1 ether);
                positions[i] = basketCollateral.createAndDepositBasketCollateral(i, 1 ether, alice);
            }
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 25 hours);
        key = PoolKey(
            Currency.wrap(basketZeroLow ? tokens[0] : tokens[1]),
            Currency.wrap(basketZeroLow ? tokens[1] : tokens[0]),
            3000,
            10,
            _localBasketHook
        );
        poolId = key.toId();
        IStaticsBasketMarkets.MarketParams memory params = IStaticsBasketMarkets.MarketParams(
            tokens[0], tokens[1], 3000, 10, 1 << 96, 1 ether, type(uint256).max, flags & 4 != 0
        );
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IStaticsBasketMarkets.BasketMarketCreated(poolId, creator, address(hook), basketZeroLow ? 0 : 1);
        vm.prank(creator);
        PoolId created = IStaticsBasketMarkets(address(diamond))
        .createBasketMarket{value: 1 ether + (flags & 4 != 0 ? ACTIVATION_FEE : 0)}(
            params
        );
        assertEq(PoolId.unwrap(created), PoolId.unwrap(poolId));
        assertEq(pools.protocolPoolCreator(poolId), creator);
        assertEq(_localBasketHook.poolRegistration(poolId).creator, creator);
        vm.prank(alice);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), int256(10 ether), bytes32(0))
        );
        IStaticsBasketSettlement settlement = IStaticsBasketSettlement(address(diamond));
        for (uint256 i; i < 2; ++i) {
            assertEq(settlement.canAccrueBasketCurrencyRewards(poolId, tokens[i]), flags & (1 << i) != 0);
        }
        assertFalse(settlement.canAccrueBasketCurrencyRewards(poolId, address(assetA)));
        assertFalse(settlement.canAccrueBasketCurrencyRewards(PoolId.wrap(bytes32(uint256(123))), tokens[0]));
    }

    function _launch(address owner, bool first, bool basketZeroLow) private {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        IStaticsBasket.PoolLaunchParams[] memory launch = _defaultPoolLaunchParams(2);
        for (uint256 i; i < 2; ++i) {
            launch[i].pairedAssetAmount = 0;
            launch[i].activateManagedPol = false;
        }
        uint256[] memory maximums = new uint256[](2);
        uint256 fee = basketAdmin.creationFee();
        if (first) {
            vm.prank(owner);
            (uint256 id, address token) = baskets.createBasket{value: fee}(params, launch, maximums, type(uint256).max);
            assertEq(id, 0);
            tokens[0] = token;
        } else {
            IStaticsBasketPreparation prep = IStaticsBasketPreparation(address(diamond));
            bytes32 hash = prep.basketCreationConfigurationHash(params, launch, maximums, type(uint256).max);
            uint256 nonce;
            for (; nonce < 256; ++nonce) {
                (address predicted,) =
                    _localBasketFactory.predict(_localBasketFactory.preparedSaltFor(owner, hash, nonce));
                if ((tokens[0] < predicted) == basketZeroLow) break;
            }
            assertLt(nonce, 256);
            vm.startPrank(owner);
            (bytes32 preparation, uint256 id, address token) =
                prep.prepareBasketToken(params, launch, maximums, type(uint256).max, nonce);
            baskets.createBasketPrepared{value: fee}(params, launch, maximums, type(uint256).max, preparation);
            vm.stopPrank();
            assertEq(id, 1);
            tokens[1] = token;
        }
    }

    function _globalStake() private {
        stakingAsset.mint(bob, 10 ether);
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), 10 ether);
        globalPosition = globalRewards.createAndStake(10 ether, bob, _rewardAssets());
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
    }

    function _fourSwaps() private {
        for (uint256 i; i < 4; ++i) {
            uint256 before0 = hook.claimLiability(key.currency0);
            uint256 before1 = hook.claimLiability(key.currency1);
            bool direction = i % 2 == 0;
            vm.prank(alice);
            v4Router.swap(
                key,
                SwapParams(
                    direction,
                    i < 2 ? -int256(0.1 ether) : int256(0.05 ether),
                    direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                )
            );
            assertGt(hook.claimLiability(key.currency0), before0);
            assertGt(hook.claimLiability(key.currency1), before1);
        }
    }

    function _exerciseAndClaim() private {
        _fourSwaps();
        uint256[] memory earnedGlobal = globalRewards.pendingRewards(globalPosition, _rewardAssets());
        for (uint256 i; i < 2; ++i) {
            Currency currency = Currency.wrap(tokens[i]);
            IStaticsSwapFeeHook.FeeDistribution memory pending = hook.pendingFeeDistribution(poolId, currency);
            uint256 global = hook.pendingStakerRewards(currency);
            assertGt(pending.basketStaker, 0);
            assertGt(global, 0);
            assertEq(hook.claimLiability(currency), pending.basketStaker + pending.creator + pending.treasury + global);
            uint256 otherIndex = basketRewards.basketRewardState(1 - i, tokens[1 - i]).indexRay;
            pools.settleProtocolPoolRevenue(poolId, tokens[i]);
            assertEq(basketRewards.basketRewardState(i, tokens[i]).indexedReserve, pending.basketStaker);
            assertEq(basketRewards.basketRewardState(1 - i, tokens[1 - i]).indexRay, otherIndex);
            // A repeated settlement must not credit either index again.
            pools.settleProtocolPoolRevenue(poolId, tokens[i]);
            assertEq(basketRewards.basketRewardState(i, tokens[i]).indexedReserve, pending.basketStaker);
            assertEq(globalRewards.settlePublicSwapRewards(tokens[i], type(uint256).max), global);
            assertEq(hook.claimLiability(currency), 0);
            assertEq(globalRewards.unfundedSwapRewards(tokens[i]), 0);
            for (uint256 j; j < 2; ++j) {
                address caller = j == 0 ? alice : bob;
                vm.prank(caller);
                vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.OnlyPoolCreator.selector, caller, creator));
                revenue.claimCreatorRevenue(poolId, tokens[i], caller, 0);
            }
            uint256 beforeBalance = IERC20(tokens[i]).balanceOf(creator);
            vm.prank(creator);
            revenue.claimCreatorRevenue(poolId, tokens[i], creator, pending.creator);
            assertEq(IERC20(tokens[i]).balanceOf(creator) - beforeBalance, pending.creator);
            beforeBalance = IERC20(tokens[i]).balanceOf(alice);
            vm.prank(alice);
            (, uint256[] memory paid) = basketRewards.claimBasketRewards(positions[i], i, alice);
            assertEq(paid[0], pending.basketStaker);
            assertEq(IERC20(tokens[i]).balanceOf(alice) - beforeBalance, pending.basketStaker);
            assertGe(IERC20(tokens[i]).balanceOf(address(diamond)), custody.globalReservedByToken(tokens[i]));
        }
        assertEq(globalRewards.pendingRewards(globalPosition, _rewardAssets()), earnedGlobal);
        uint256 before0 = IERC20(tokens[0]).balanceOf(bob);
        uint256 before1 = IERC20(tokens[1]).balanceOf(bob);
        vm.prank(bob);
        uint256[] memory paidGlobal = globalRewards.claimRewards(globalPosition, _rewardAssets(), bob, new uint256[](2));
        assertEq(paidGlobal, earnedGlobal);
        assertEq(IERC20(tokens[0]).balanceOf(bob) - before0, paidGlobal[0]);
        assertEq(IERC20(tokens[1]).balanceOf(bob) - before1, paidGlobal[1]);
    }

    function _rewardAssets() private view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = tokens[0];
        assets[1] = tokens[1];
    }
}
