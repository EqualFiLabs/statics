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
import {IStaticsSwapCallback} from "../../src/interfaces/IStaticsSwapCallback.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {
    FormalProtocolPolPoolManager,
    FormalProtocolPolSwapFeeHook,
    FormalProtocolPolToken
} from "./mocks/FormalProtocolPolMocks.sol";

contract StaticsProtocolPolHookHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;

    FormalProtocolPolPoolManager private manager;
    FormalProtocolPolSwapFeeHook private hook;
    PoolKey private key;
    PoolId private poolId;
    bool private polActivated;
    bool private polOverridden;
    uint16 private polOverrideBps;

    function setUp() public {
        FormalProtocolPolToken tokenA = new FormalProtocolPolToken();
        FormalProtocolPolToken tokenB = new FormalProtocolPolToken();
        manager = new FormalProtocolPolPoolManager();
        hook = new FormalProtocolPolSwapFeeHook(IPoolManager(address(manager)), address(this), 25, 25);
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

    function protocolPoolSwapsBlocked(PoolId) external pure returns (bool) {
        return false;
    }

    function protocolPolFundingConfig(PoolId) external view returns (bool activated, bool overridden, uint16 shareBps) {
        return (polActivated, polOverridden, polOverrideBps);
    }

    function routeProtocolSwapFees(PoolId, address, IStaticsProtocolRevenue.ProtocolFeeDistribution calldata)
        external
        pure
    {
        revert("no preceding distribution");
    }

    function afterStaticsPoolSwap(PoolId, BalanceDelta, uint256, uint256, uint8) external view returns (bytes4) {
        require(msg.sender == address(hook), "hook only");
        return IStaticsSwapCallback.afterStaticsPoolSwap.selector;
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
        uint256 pendingPol = hook.pendingProtocolPol(poolId, key.currency0);
        uint256 pendingStaker = hook.pendingStakerRewards(key.currency0);
        uint256 claimId = uint256(uint160(Currency.unwrap(key.currency0)));

        assertEq(pendingPol, 0);
        assertEq(distribution.basketStaker, 0);
        assertEq(distribution.staticsStaker, 0);
        assertEq(pendingStaker, Math.mulDiv(charged, 3_500, BPS));
        assertEq(distribution.creator, Math.mulDiv(charged, 500, BPS));
        assertEq(distribution.treasury, charged - pendingStaker - distribution.creator);
        assertEq(pendingStaker + _distributionTotal(distribution), charged);
        assertEq(hook.claimLiability(key.currency0), charged);
        assertEq(manager.balanceOf(address(hook), claimId), charged);
    }

    function check_activatedPolAccruesConfiguredShare(uint8 chargedUnits) public {
        vm.assume(chargedUnits > 0);
        polActivated = true;
        uint256 charged = uint256(chargedUnits);
        hook.formalAccrueSwapLegFee(poolId, key.currency0, charged * 400, charged, true);
        uint256 pendingPol = hook.pendingProtocolPol(poolId, key.currency0);
        uint256 pendingStaker = hook.pendingStakerRewards(key.currency0);
        IStaticsSwapFeeHook.FeeDistribution memory distribution = hook.pendingFeeDistribution(poolId, key.currency0);
        assertEq(pendingPol, Math.mulDiv(charged, 4_000, BPS));
        assertEq(pendingStaker, Math.mulDiv(charged, 3_500, BPS));
        assertEq(pendingPol + pendingStaker + _distributionTotal(distribution), charged);
    }

    function check_polOverrideCannotExceedCurrentGlobalBucket(uint8 chargedUnits, uint16 overrideBps) public {
        vm.assume(chargedUnits > 0);
        polActivated = true;
        polOverridden = true;
        polOverrideBps = overrideBps;
        hook.setGeneralFeeAllocation(
            IStaticsSwapFeeHook.GeneralFeeAllocation({
                polShareBps: 0, staticsStakerShareBps: 9_000, treasuryShareBps: 500
            })
        );

        uint256 charged = uint256(chargedUnits);
        hook.formalAccrueSwapLegFee(poolId, key.currency0, charged * 400, charged, true);
        uint256 expectedBps = overrideBps < 500 ? overrideBps : 500;
        uint256 pendingPol = hook.pendingProtocolPol(poolId, key.currency0);
        uint256 pendingStaker = hook.pendingStakerRewards(key.currency0);
        IStaticsSwapFeeHook.FeeDistribution memory distribution = hook.pendingFeeDistribution(poolId, key.currency0);

        assertEq(pendingPol, Math.mulDiv(charged, expectedBps, BPS));
        assertEq(pendingPol + pendingStaker + _distributionTotal(distribution), charged);
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
