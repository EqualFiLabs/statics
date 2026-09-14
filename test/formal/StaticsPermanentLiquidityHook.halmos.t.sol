// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {
    FormalPermanentPoolManager,
    FormalPermanentLiquidityMath,
    FormalPermanentSwapFeeHook,
    FormalPermanentToken
} from "./mocks/FormalPermanentLiquidityMocks.sol";

contract StaticsPermanentLiquidityHookHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;

    FormalPermanentPoolManager private manager;
    FormalPermanentSwapFeeHook private hook;
    PoolKey private key;
    PoolId private poolId;

    function setUp() public {
        FormalPermanentToken tokenA = new FormalPermanentToken();
        FormalPermanentToken tokenB = new FormalPermanentToken();
        manager = new FormalPermanentPoolManager();
        FormalPermanentLiquidityMath permanentLiquidityMath = new FormalPermanentLiquidityMath();
        hook = new FormalPermanentSwapFeeHook(
            IPoolManager(address(manager)), address(this), 25, 25, permanentLiquidityMath
        );
        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 10, hooks: IHooks(hook)});
        poolId = hook.registerPool(key, IStaticsSwapFeeHook.PoolKind.General, address(this));
    }

    function canAccrueStakerRewards(address) external pure returns (bool) {
        return true;
    }

    function canAccrueBasketRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function routeProtocolSwapFees(PoolId, address, IStaticsProtocolRevenue.ProtocolFeeDistribution calldata)
        external
        pure
    {
        revert("no preceding distribution");
    }

    function check_registeredPoolsAcceptIndependentStaticLpFees(uint24 lpFee) public {
        vm.assume(lpFee <= 999_999 && lpFee != key.fee);
        PoolKey memory second = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: lpFee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks
        });
        PoolId secondPoolId = hook.registerPool(second, IStaticsSwapFeeHook.PoolKind.General, address(this));
        assertTrue(hook.poolRegistration(secondPoolId).registered);
        assertNotEq(PoolId.unwrap(secondPoolId), PoolId.unwrap(poolId));
    }

    function check_poolOverrideIgnoresGlobalChangesUntilCleared(
        uint8 defaultInput,
        uint8 defaultOutput,
        uint8 overrideInput,
        uint8 overrideOutput
    ) public {
        vm.assume(uint256(defaultInput) + defaultOutput <= 200);
        vm.assume(uint256(overrideInput) + overrideOutput <= 200);
        hook.setPoolFeeRate(poolId, overrideInput, overrideOutput);
        hook.setDefaultFeeRate(defaultInput, defaultOutput);

        IStaticsSwapFeeHook.PoolFeeRate memory overridden = hook.poolFeeRate(poolId);
        assertEq(overridden.inputFeeBps, overrideInput);
        assertEq(overridden.outputFeeBps, overrideOutput);
        assertTrue(overridden.overridden);

        hook.clearPoolFeeRate(poolId);
        IStaticsSwapFeeHook.PoolFeeRate memory inherited = hook.poolFeeRate(poolId);
        assertEq(inherited.inputFeeBps, defaultInput);
        assertEq(inherited.outputFeeBps, defaultOutput);
        assertFalse(inherited.overridden);
    }

    function check_specifiedFeeAllocationEqualsMintedClaim(uint8 chargedUnits) public {
        vm.assume(chargedUnits > 0);
        uint256 charged = uint256(chargedUnits);
        hook.formalAccrueSwapLegFee(poolId, key.currency0, charged * 400, charged, true);
        IStaticsSwapFeeHook.FeeDistribution memory distribution = hook.pendingFeeDistribution(poolId, key.currency0);
        uint256 pendingPol = hook.pendingPermanentLiquidity(poolId, key.currency0);
        uint256 claimId = uint256(uint160(Currency.unwrap(key.currency0)));

        assertEq(pendingPol, Math.mulDiv(charged, 4_000, BPS));
        assertEq(distribution.basketStaker, 0);
        assertEq(distribution.staticsStaker, Math.mulDiv(charged, 3_500, BPS));
        assertEq(distribution.creator, Math.mulDiv(charged, 500, BPS));
        assertEq(pendingPol + _distributionTotal(distribution), charged);
        assertEq(hook.claimLiability(key.currency0), charged);
        assertEq(manager.balanceOf(address(hook), claimId), charged);
    }

    function check_claimFundedCompoundingConservesLiabilities(uint16 debit0, uint16 debit1) public {
        uint256 grossAmount = 1_000_000;
        uint16 feeBps = 100;
        uint256 charged = _feeFromGross(grossAmount, feeBps);
        uint256 pendingPol = Math.mulDiv(charged, 4_000, BPS);
        vm.assume(debit0 > 0 && debit0 <= pendingPol);
        vm.assume(debit1 > 0 && debit1 <= pendingPol);
        hook.setPoolFeeRate(poolId, feeBps, feeBps);
        manager.setModifyDebits(debit0, debit1);

        int128 specifiedDelta = int128(-int256(grossAmount) + int256(charged));
        manager.callSwapHooks(
            IHooks(hook),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(grossAmount), sqrtPriceLimitX96: 0}),
            toBalanceDelta(specifiedDelta, int128(int256(grossAmount)))
        );

        _assertPostCompound(key.currency0, charged, pendingPol, debit0);
        _assertPostCompound(key.currency1, charged, pendingPol, debit1);
        assertGt(hook.lockedLiquidity(poolId), 0);
    }

    function check_claimFundedCompoundingRejectsOverspend(uint16 validDebit) public {
        uint256 grossAmount = 1_000_000;
        uint16 feeBps = 100;
        uint256 charged = _feeFromGross(grossAmount, feeBps);
        uint256 pendingPol = Math.mulDiv(charged, 4_000, BPS);
        vm.assume(validDebit > 0 && validDebit <= pendingPol);
        hook.setPoolFeeRate(poolId, feeBps, feeBps);
        manager.setModifyDebits(uint128(pendingPol + 1), validDebit);

        int128 specifiedDelta = int128(-int256(grossAmount) + int256(charged));
        (bool success, bytes memory reason) = address(manager)
            .call(
                abi.encodeCall(
                    manager.callSwapHooks,
                    (
                        IHooks(hook),
                        key,
                        SwapParams({zeroForOne: true, amountSpecified: -int256(grossAmount), sqrtPriceLimitX96: 0}),
                        toBalanceDelta(specifiedDelta, int128(int256(grossAmount)))
                    )
                )
            );

        assertFalse(success);
        assertEq(_revertSelector(reason), StaticsSwapFeeHook.PermanentLiquidityExceedsPending.selector);
        assertEq(hook.claimLiability(key.currency0), 0);
        assertEq(hook.claimLiability(key.currency1), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency0), 0);
        assertEq(hook.pendingPermanentLiquidity(poolId, key.currency1), 0);
        assertEq(_distributionTotal(hook.pendingFeeDistribution(poolId, key.currency0)), 0);
        assertEq(_distributionTotal(hook.pendingFeeDistribution(poolId, key.currency1)), 0);
        uint256 claimId0 = uint256(uint160(Currency.unwrap(key.currency0)));
        uint256 claimId1 = uint256(uint160(Currency.unwrap(key.currency1)));
        assertEq(manager.balanceOf(address(hook), claimId0), 0);
        assertEq(manager.balanceOf(address(hook), claimId1), 0);
        assertEq(manager.totalBurned(claimId0), 0);
        assertEq(manager.totalBurned(claimId1), 0);
        assertEq(hook.lockedLiquidity(poolId), 0);
    }

    function _assertPostCompound(Currency currency, uint256 charged, uint256 pendingPol, uint256 debit) private view {
        IStaticsSwapFeeHook.FeeDistribution memory distribution = hook.pendingFeeDistribution(poolId, currency);
        uint256 expectedLiability = charged - debit;
        uint256 claimId = uint256(uint160(Currency.unwrap(currency)));
        assertEq(hook.pendingPermanentLiquidity(poolId, currency), pendingPol - debit);
        assertEq(_distributionTotal(distribution) + pendingPol - debit, expectedLiability);
        assertEq(hook.claimLiability(currency), expectedLiability);
        assertEq(manager.balanceOf(address(hook), claimId), expectedLiability);
        assertEq(manager.totalBurned(claimId), debit);
    }

    function _distributionTotal(IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
        pure
        returns (uint256)
    {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }

    function _feeFromGross(uint256 grossAmount, uint256 feeBps) private pure returns (uint256) {
        return Math.mulDiv(grossAmount, feeBps, BPS, Math.Rounding.Ceil);
    }

    function _revertSelector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}
