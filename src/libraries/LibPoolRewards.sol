// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibNativeReceipt} from "./LibNativeReceipt.sol";

interface IPoolRewardWeth {
    function deposit() external payable;
}

/// @notice One boundary between pool currencies and the existing ERC-20 revenue rails.
library LibPoolRewards {
    event NativeRevenueWrappedToWeth(address indexed weth, uint256 amount);
    error InexactNativeWrap(uint256 expected, uint256 spent);
    error IncompatibleRewardReceipt(address asset, uint256 expected, uint256 received);

    function rewardAsset(address source) internal view returns (address) {
        return source == address(0) ? IStaticsSwapFeeHook(LibBasketLiquidity.liquidityStorage().hook).weth() : source;
    }

    /// @dev Only an explicitly classified, unreserved receipt may be wrapped.
    function materialize(address source, uint256 amount) internal returns (address asset) {
        asset = rewardAsset(source);
        if (source != address(0) || amount == 0) return asset;
        uint256 beforeNative = LibCustody.beginUnreservedDebit(address(0), amount);
        uint256 beforeWeth = IERC20(asset).balanceOf(address(this));
        IPoolRewardWeth(asset).deposit{value: amount}();
        uint256 spent = LibCustody.finishUnreservedDebit(address(0), beforeNative, amount);
        if (spent != amount) revert InexactNativeWrap(amount, spent);
        enforceReceipt(asset, beforeWeth, amount);
        emit NativeRevenueWrappedToWeth(asset, amount);
    }

    function enforceReceipt(address source, uint256 beforeBalance, uint256 amount) internal view {
        uint256 afterBalance = LibCurrency.balance(source, address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) revert IncompatibleRewardReceipt(source, amount, received);
    }

    function settleDistribution(PoolKey memory key, Currency currency)
        internal
        returns (IStaticsSwapFeeHook.FeeDistribution memory distribution, address asset)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        address source = Currency.unwrap(currency);
        uint256 beforeBalance = LibCurrency.balance(source, address(this));
        if (source == address(0)) LibNativeReceipt.expect(ls.poolManager);
        distribution = IStaticsSwapFeeHook(ls.hook).settleFeeDistribution(key, currency, address(this));
        LibNativeReceipt.clear();
        uint256 amount =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        enforceReceipt(source, beforeBalance, amount);
        asset = materialize(source, amount);
    }

    /// @dev WETH and native source claims fund the same WETH reward book, without changing its math.
    function settleStaker(address asset, uint256 amount) internal {
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(LibBasketLiquidity.liquidityStorage().hook);
        uint256 tokenAmount = amount;
        if (asset == hook.weth()) {
            uint256 pending = hook.pendingStakerRewards(Currency.wrap(asset));
            if (tokenAmount > pending) tokenAmount = pending;
        }
        if (tokenAmount != 0) _redeemStaker(hook, asset, tokenAmount);
        uint256 nativeAmount = amount - tokenAmount;
        if (nativeAmount != 0) {
            _redeemStaker(hook, address(0), nativeAmount);
            materialize(address(0), nativeAmount);
        }
    }

    function _redeemStaker(IStaticsSwapFeeHook hook, address source, uint256 amount) private {
        uint256 beforeBalance = LibCurrency.balance(source, address(this));
        if (source == address(0)) LibNativeReceipt.expect(LibBasketLiquidity.liquidityStorage().poolManager);
        uint256 settled = hook.settleStakerRewards(Currency.wrap(source), address(this), amount);
        LibNativeReceipt.clear();
        if (settled != amount) revert IncompatibleRewardReceipt(source, amount, settled);
        enforceReceipt(source, beforeBalance, amount);
    }
}
