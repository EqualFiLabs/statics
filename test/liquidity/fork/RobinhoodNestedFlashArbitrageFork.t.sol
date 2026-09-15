// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {StaticsFlashArbitrageReceiver} from "../../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {RobinhoodNestedBasketsForkBase} from "../../basket/fork/RobinhoodNestedBasketsFork.t.sol";

/// @notice Demonstrates fee-aware flash arbitrage at the parent layer of a real-token nested basket.
///
/// The parent launches at an internally neutral three-leaf reference price. A normal Universal Router
/// sale then makes sCOMP cheaper in all three canonical pools. The production arbitrage receiver:
///
///   flash-borrows sAI + sPLAT + sGROW
///   -> buys sCOMP in three pools
///   -> redeems sCOMP into the three leaves
///   -> repays every leaf plus the 5-bps flash fee
///   -> pays net leaf profits to the executor
///
/// The executor finally redeems those profits into nine base assets. Stock Token funding remains the
/// fixture's only synthetic step; the mint, swap, flash, redemption, fee, and custody paths use deployed
/// token and Robinhood infrastructure code.
contract RobinhoodNestedFlashArbitrageForkTest is RobinhoodNestedBasketsForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 private constant DISTORTION_SALE = 0.1 ether;
    uint256 private constant FLASH_SHARES = 0.5 ether;
    uint256 private constant PER_POOL_FLASH_INPUT = 0.25 ether;
    uint256 private constant MINIMUM_LEAF_PROFIT = 0.02 ether;
    uint256 private constant PURCHASE_PROBE = 0.05 ether;

    event NestedFlashArbitrageMeasured(
        uint256 flashShares,
        uint256 redeemedParentShares,
        uint256 executionGas,
        uint256 sAiProfit,
        uint256 sPlatProfit,
        uint256 sGrowProfit
    );

    struct ParentFlashSnapshot {
        uint256 parentSupply;
        uint256[3] parentVaults;
        uint256[3] parentReservations;
        uint256[3] treasuryAccruals;
        uint256[3] feeReservations;
        uint128[3] lockedLiquidity;
        uint256[3] purchaseQuotes;
    }

    struct ParentFlashResult {
        address receiver;
        address[] assets;
        uint256[] principals;
        uint256[] fees;
        uint256[] profits;
        uint256 redeemedShares;
        uint256 executionGas;
    }

    function testParentFlashArbitrageRestoresPriceAndPaysNineAssetProfit() public {
        _assertAllCanonicalPools();
        PoolKey[] memory pools = _parentPools();

        _fundDistortionSeller();
        uint256[3] memory baselineQuotes = _parentPurchaseQuotes(pools);
        _distortParentPools();
        ParentFlashSnapshot memory beforeAction = _takeParentFlashSnapshot(pools);
        for (uint256 i; i < pools.length; ++i) {
            assertGt(beforeAction.purchaseQuotes[i], baselineQuotes[i], "sale must make sCOMP cheaper");
        }

        ParentFlashResult memory result = _executeParentFlashArbitrage(pools, beforeAction.parentSupply);
        _assertParentFlashAccounting(pools, baselineQuotes, beforeAction, result);

        uint256[9] memory baseProfits = _redeemLeafProfits(result.profits);
        for (uint256 i; i < baseProfits.length; ++i) {
            assertGt(baseProfits[i], 0, "every nested base asset must reach the executor");
        }

        assertGt(result.executionGas, 0);
        emit log("Nested flash route: [sAI, sPLAT, sGROW] -> sCOMP -> [sAI, sPLAT, sGROW]");
        emit log("Profit redemption: three leaf BasketTokens -> nine base assets, including STATICS");
        emit log_named_uint("Nested flash arbitrage execution gas", result.executionGas);
        emit log_named_uint("sAI profit before base-asset redemption", result.profits[0]);
        emit log_named_uint("sPLAT profit before base-asset redemption", result.profits[1]);
        emit log_named_uint("sGROW profit before base-asset redemption", result.profits[2]);
        emit NestedFlashArbitrageMeasured(
            FLASH_SHARES,
            result.redeemedShares,
            result.executionGas,
            result.profits[0],
            result.profits[1],
            result.profits[2]
        );
    }

    /// @dev Three equally valued leaf constituents make three leaf tokens per sCOMP the neutral
    /// reference used by this deterministic demonstration. It is not an external market-price claim.
    function _parentLaunchSqrtPrice() internal pure override returns (uint160) {
        return uint160(Math.sqrt(uint256(3) << 192));
    }

    function _fundDistortionSeller() private {
        _mintLeaves(bob, 2 ether);
        _approveLeafTokens(bob);
        _mintParent(bob, 1 ether);
    }

    function _distortParentPools() private {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            _quoteAndSwapThroughUniversalRouter(
                SwapRequest({
                    basketId: parentBasketId,
                    asset: leafBasketTokens[i],
                    input: parentBasketToken,
                    output: leafBasketTokens[i],
                    source: bob,
                    swapperKey: PARENT_SWAPPER_KEY,
                    amountIn: uint128(DISTORTION_SALE)
                })
            );
        }
    }

    function _parentPools() private view returns (PoolKey[] memory pools) {
        pools = new PoolKey[](leafBasketTokens.length);
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            pools[i] = _poolKey(basketLiquidity.canonicalPool(parentBasketId, leafBasketTokens[i]));
        }
    }

    function _parentPurchaseQuotes(PoolKey[] memory pools) private returns (uint256[3] memory quotes) {
        for (uint256 i; i < pools.length; ++i) {
            quotes[i] = _quoteParentPurchase(pools[i], leafBasketTokens[i]);
        }
    }

    function _quoteParentPurchase(PoolKey memory pool, address leafToken) private returns (uint256 amountOut) {
        bool zeroForOne = Currency.unwrap(pool.currency0) == leafToken;
        assertTrue(
            Currency.unwrap(zeroForOne ? pool.currency1 : pool.currency0) == parentBasketToken,
            "parent purchase must output sCOMP"
        );
        (amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: pool, zeroForOne: zeroForOne, exactAmount: uint128(PURCHASE_PROBE), hookData: ""
            })
        );
    }

    function _takeParentFlashSnapshot(PoolKey[] memory pools) private returns (ParentFlashSnapshot memory snapshot) {
        snapshot.parentSupply = IERC20(parentBasketToken).totalSupply();
        bytes32 parentAccount = custody.basketCustodyAccount(parentBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < pools.length; ++i) {
            address leafToken = leafBasketTokens[i];
            snapshot.parentVaults[i] = baskets.vaultBalance(parentBasketId, leafToken);
            snapshot.parentReservations[i] = custody.reservedByAccount(parentAccount, leafToken);
            snapshot.treasuryAccruals[i] = globalRewards.treasuryAccrued(leafToken);
            snapshot.feeReservations[i] = custody.reservedByAccount(feeAccount, leafToken);
            snapshot.lockedLiquidity[i] = hook.lockedLiquidity(pools[i].toId());
            snapshot.purchaseQuotes[i] = _quoteParentPurchase(pools[i], leafToken);
        }
    }

    function _executeParentFlashArbitrage(PoolKey[] memory pools, uint256 parentSupplyBefore)
        private
        returns (ParentFlashResult memory result)
    {
        (result.assets, result.principals, result.fees) = flashLoans.quoteFlashLoan(parentBasketId, FLASH_SHARES);
        uint256[] memory inputs = _filledVector(PER_POOL_FLASH_INPUT);
        uint256[] memory minimumProfits = _filledVector(MINIMUM_LEAF_PROFIT);
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        result.receiver = address(receiver);

        address[] memory returnedAssets;
        (returnedAssets, result.profits) = receiver.executeBuyAndRedeem(
            parentBasketId, FLASH_SHARES, pools, inputs, minimumProfits, block.timestamp + 1 minutes
        );
        result.executionGas = vm.lastCallGas().gasTotalUsed;
        result.redeemedShares = parentSupplyBefore - IERC20(parentBasketToken).totalSupply();

        assertEq(returnedAssets.length, result.assets.length);
        for (uint256 i; i < returnedAssets.length; ++i) {
            assertEq(returnedAssets[i], result.assets[i]);
        }
    }

    function _assertParentFlashAccounting(
        PoolKey[] memory pools,
        uint256[3] memory baselineQuotes,
        ParentFlashSnapshot memory beforeAction,
        ParentFlashResult memory result
    ) private {
        assertGt(result.redeemedShares, FIXED_FEE_SHARES);
        assertEq(IERC20(parentBasketToken).totalSupply(), beforeAction.parentSupply - result.redeemedShares);

        IStaticsBasket.BasketView memory parent = baskets.basket(parentBasketId);
        uint256 redemptionFeeShares = baskets.feeSharesFor(parentBasketId, false, result.redeemedShares);
        bytes32 parentAccount = custody.basketCustodyAccount(parentBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < pools.length; ++i) {
            address leafToken = leafBasketTokens[i];
            uint256 releasedPrincipal = Math.mulDiv(parent.bundleAmounts[i], result.redeemedShares, SHARE_SCALE);
            uint256 redemptionFee =
                Math.mulDiv(parent.bundleAmounts[i], redemptionFeeShares, SHARE_SCALE, Math.Rounding.Ceil);

            assertEq(result.assets[i], leafToken);
            assertEq(result.principals[i], FLASH_SHARES);
            assertGt(result.fees[i], 0, "flash fee must be nonzero");
            assertGe(result.profits[i], MINIMUM_LEAF_PROFIT);
            assertEq(IERC20(leafToken).balanceOf(address(this)), result.profits[i]);
            assertEq(IERC20(leafToken).balanceOf(result.receiver), 0);
            assertEq(baskets.vaultBalance(parentBasketId, leafToken), beforeAction.parentVaults[i] - releasedPrincipal);
            assertEq(
                custody.reservedByAccount(parentAccount, leafToken),
                beforeAction.parentReservations[i] - releasedPrincipal
            );
            assertGe(
                globalRewards.treasuryAccrued(leafToken) - beforeAction.treasuryAccruals[i],
                result.fees[i] + redemptionFee
            );
            assertGe(
                custody.reservedByAccount(feeAccount, leafToken) - beforeAction.feeReservations[i],
                result.fees[i] + redemptionFee
            );
            assertEq(IERC20(leafToken).balanceOf(address(diamond)), custody.globalReservedByToken(leafToken));
            assertGt(uint256(hook.lockedLiquidity(pools[i].toId())), uint256(beforeAction.lockedLiquidity[i]));

            uint256 quoteAfter = _quoteParentPurchase(pools[i], leafToken);
            assertLt(quoteAfter, beforeAction.purchaseQuotes[i], "arbitrage must make sCOMP more expensive");
            assertLt(
                _absoluteDifference(quoteAfter, baselineQuotes[i]),
                _absoluteDifference(beforeAction.purchaseQuotes[i], baselineQuotes[i]),
                "arbitrage must move the quote toward its pre-shock reference"
            );
        }
    }

    function _redeemLeafProfits(uint256[] memory profits) private returns (uint256[9] memory baseProfits) {
        assertEq(profits.length, leafBasketTokens.length);
        for (uint256 leaf; leaf < leafBasketTokens.length; ++leaf) {
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            uint256[] memory balancesBefore = new uint256[](configured.assets.length);
            for (uint256 i; i < configured.assets.length; ++i) {
                balancesBefore[i] = IERC20(configured.assets[i]).balanceOf(address(this));
            }

            uint256[] memory quote = baskets.quoteRedeem(leafBasketIds[leaf], profits[leaf]);
            baskets.redeem(leafBasketIds[leaf], profits[leaf], address(this), quote);
            assertEq(IERC20(leafBasketTokens[leaf]).balanceOf(address(this)), 0);
            for (uint256 i; i < configured.assets.length; ++i) {
                uint256 flatIndex = leaf * 3 + i;
                baseProfits[flatIndex] = IERC20(configured.assets[i]).balanceOf(address(this)) - balancesBefore[i];
                assertEq(baseProfits[flatIndex], quote[i]);
                assertEq(
                    IERC20(configured.assets[i]).balanceOf(address(diamond)),
                    custody.globalReservedByToken(configured.assets[i])
                );
            }
        }
    }

    function _filledVector(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](3);
        for (uint256 i; i < values.length; ++i) {
            values[i] = value;
        }
    }

    function _absoluteDifference(uint256 first, uint256 second) private pure returns (uint256) {
        return first > second ? first - second : second - first;
    }
}
