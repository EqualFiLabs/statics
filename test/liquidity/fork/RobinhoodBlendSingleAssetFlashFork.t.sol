// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsFlashAssetBorrower} from "../../../src/interfaces/IStaticsFlashAssetBorrower.sol";
import {IStaticsFlashLoan} from "../../../src/interfaces/IStaticsFlashLoan.sol";
import {IBlendHook, RobinhoodBlendBasketForkBase} from "../../basket/fork/RobinhoodBlendBasketFork.t.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";

/// @notice Test-only receiver using Statics' dedicated single-asset callback across both hooks.
contract BlendStaticsSingleAssetFlashReceiver is IStaticsFlashAssetBorrower {
    using SafeERC20 for IERC20;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset");

    error InvalidCallback();
    error InvalidRoute();
    error InsufficientMintInput(uint256 available, uint256 fee);
    error MinimumProfitNotMet(uint256 minimum, uint256 actual);

    IStaticsFlashLoan public immutable flashLoans;
    IStaticsBasket public immutable baskets;
    CanonicalV4Router public immutable router;
    address public immutable usdg;
    address public immutable blend;
    uint256 public immutable basketId;
    address public immutable outerBasket;

    PoolKey private _blendPool;
    PoolKey private _staticsPool;
    bool private _active;
    uint256 private _minimumProfit;

    uint256 public observedPrincipal;
    uint256 public observedFee;
    uint256 public mintedOuterShares;

    constructor(
        IStaticsFlashLoan flashLoans_,
        IStaticsBasket baskets_,
        CanonicalV4Router router_,
        address usdg_,
        address blend_,
        uint256 basketId_,
        address outerBasket_,
        PoolKey memory blendPool_,
        PoolKey memory staticsPool_
    ) {
        flashLoans = flashLoans_;
        baskets = baskets_;
        router = router_;
        usdg = usdg_;
        blend = blend_;
        basketId = basketId_;
        outerBasket = outerBasket_;
        _blendPool = blendPool_;
        _staticsPool = staticsPool_;
    }

    function execute(uint256 amount, uint256 minimumProfit) external returns (uint256 profit) {
        if (_active || IERC20(usdg).balanceOf(address(this)) != 0) revert InvalidCallback();
        _active = true;
        _minimumProfit = minimumProfit;
        flashLoans.flashLoanAsset(usdg, amount, address(this), "");
        _active = false;

        profit = IERC20(usdg).balanceOf(address(this));
        if (profit < minimumProfit) revert MinimumProfitNotMet(minimumProfit, profit);
        IERC20(usdg).safeTransfer(msg.sender, profit);
    }

    function onStaticsFlashLoanAsset(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (
            msg.sender != address(flashLoans) || initiator != address(this) || !_active || asset != usdg
                || data.length != 0
        ) revert InvalidCallback();
        observedPrincipal = amount;
        observedFee = fee;

        uint256 purchasedBlend = _swapExactInput(_blendPool, usdg, blend, amount);
        uint256 fixedMintFee = baskets.quoteMint(basketId, 1)[0] - 1;
        if (purchasedBlend <= fixedMintFee) revert InsufficientMintInput(purchasedBlend, fixedMintFee);
        mintedOuterShares = purchasedBlend - fixedMintFee;
        uint256[] memory mintQuote = baskets.quoteMint(basketId, mintedOuterShares);
        IERC20(blend).forceApprove(address(baskets), mintQuote[0]);
        baskets.mint(basketId, mintedOuterShares, address(this), mintQuote);
        IERC20(blend).forceApprove(address(baskets), 0);

        uint256 recoveredBlend = _swapExactInput(_staticsPool, outerBasket, blend, mintedOuterShares);
        uint256 recoveredUsdg = _swapExactInput(_blendPool, blend, usdg, recoveredBlend);
        uint256 repayment = amount + fee;
        uint256 actualProfit = recoveredUsdg > repayment ? recoveredUsdg - repayment : 0;
        if (actualProfit < _minimumProfit) revert MinimumProfitNotMet(_minimumProfit, actualProfit);
        IERC20(usdg).forceApprove(address(flashLoans), repayment);
        return CALLBACK_SUCCESS;
    }

    function _swapExactInput(PoolKey memory pool, address input, address output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne;
        if (Currency.unwrap(pool.currency0) == input && Currency.unwrap(pool.currency1) == output) {
            zeroForOne = true;
        } else if (Currency.unwrap(pool.currency1) == input && Currency.unwrap(pool.currency0) == output) {
            zeroForOne = false;
        } else {
            revert InvalidRoute();
        }
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(address(router), amountIn);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        IERC20(input).forceApprove(address(router), 0);
        amountOut = IERC20(output).balanceOf(address(this)) - outputBefore;
    }
}

contract RobinhoodBlendSingleAssetFlashForkTest is RobinhoodBlendBasketForkBase {
    uint256 private constant USDG_FUNDING = 70_000_000;
    uint256 private constant USDG_BUNDLE = 1_000_000;
    uint256 private constant USDG_POOL_SEED = 5_000_000;
    uint256 private constant USDG_RESERVE_SHARES = 40 ether;
    uint256 private constant FLASH_AMOUNT = 250_000;
    uint256 private constant DISTORTION_INPUT = 0.3 ether;

    CanonicalV4Router private router;

    function setUp() public override {
        super.setUp();
        router = new CanonicalV4Router(poolManager);
    }

    function testSingleAssetUsdGFlashArbitrageTraversesBlendAndStaticsHooks() public {
        _seedLegitimateUsdGCustody();
        _makeOuterBasketExpensive();
        BlendStaticsSingleAssetFlashReceiver receiver = _singleAssetReceiver();

        uint256 quotedFee = flashLoans.quoteFlashLoanAsset(USDG, FLASH_AMOUNT);
        uint256 diamondBefore = IERC20(USDG).balanceOf(address(diamond));
        uint256 reserveBefore = custody.globalReservedByToken(USDG);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(USDG);
        uint256 callerBefore = IERC20(USDG).balanceOf(address(this));
        uint256 gasBefore = gasleft();
        uint256 profit = receiver.execute(FLASH_AMOUNT, 1);
        uint256 executionGas = gasBefore - gasleft();

        assertEq(receiver.observedPrincipal(), FLASH_AMOUNT);
        assertEq(receiver.observedFee(), quotedFee);
        assertGt(receiver.mintedOuterShares(), 0);
        assertGt(profit, 0);
        assertEq(IERC20(USDG).balanceOf(address(this)), callerBefore + profit);
        assertEq(IERC20(USDG).balanceOf(address(receiver)), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(receiver)), 0);
        assertEq(IERC20(USDG).balanceOf(address(diamond)), diamondBefore + quotedFee);
        assertEq(custody.globalReservedByToken(USDG), reserveBefore + quotedFee);
        assertEq(globalRewards.treasuryAccrued(USDG), treasuryBefore + quotedFee);
        assertEq(IERC20(USDG).balanceOf(address(diamond)), custody.globalReservedByToken(USDG));
        assertEq(flashLoans.singleAssetFlashFeeBps(), 5);

        emit log("Statics single-asset flash: USDG -> BlendHook AI -> StaticsHook sBAI -> AI -> USDG");
        emit log_named_uint("Runtime single-asset flash fee", quotedFee);
        emit log_named_uint("USDG profit", profit);
        emit log_named_uint("Single-asset flash execution gas", executionGas);
    }

    function testSingleAssetFlashMinimumProfitFailureRollsBackBothHooks() public {
        _seedLegitimateUsdGCustody();
        _makeOuterBasketExpensive();
        BlendStaticsSingleAssetFlashReceiver receiver = _singleAssetReceiver();
        uint256 diamondBefore = IERC20(USDG).balanceOf(address(diamond));
        uint256 reserveBefore = custody.globalReservedByToken(USDG);
        uint256 outerSupplyBefore = IERC20(staticsBasketToken).totalSupply();

        vm.expectPartialRevert(BlendStaticsSingleAssetFlashReceiver.MinimumProfitNotMet.selector);
        receiver.execute(FLASH_AMOUNT, type(uint256).max);

        assertEq(IERC20(USDG).balanceOf(address(diamond)), diamondBefore);
        assertEq(custody.globalReservedByToken(USDG), reserveBefore);
        assertEq(IERC20(staticsBasketToken).totalSupply(), outerSupplyBefore);
        assertEq(IERC20(USDG).balanceOf(address(receiver)), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(receiver)), 0);
    }

    function _seedLegitimateUsdGCustody() private {
        vm.prank(BLEND_AI_HOLDER);
        assertTrue(IERC20(USDG).transfer(alice, USDG_FUNDING));
        vm.prank(alice);
        assertTrue(IERC20(USDG).approve(address(diamond), type(uint256).max));

        address[] memory assets = new address[](1);
        assets[0] = USDG;
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = USDG_BUNDLE;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Statics USDG Reserve",
            symbol: "sUSDG",
            assets: assets,
            bundleAmounts: bundles,
            mintFeeTiers: _singleFeeTier(MINT_FEE_SHARES),
            redemptionFeeTiers: _singleFeeTier(REDEMPTION_FEE_SHARES),
            flashFeeBps: 5,
            originationFeeBps: 25,
            extensionFeeBps: 10,
            ltvBps: 9_000,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](1);
        pools[0] = IStaticsBasket.PoolLaunchParams({
            lpFee: 3_000,
            tickSpacing: 10,
            sqrtPriceAssetPerBasketX96: _semanticSqrtPrice(USDG_BUNDLE),
            pairedAssetAmount: USDG_POOL_SEED
        });
        uint256[] memory maximums = new uint256[](1);
        maximums[0] = USDG_FUNDING;
        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(alice);
        (uint256 reserveBasketId,) =
            baskets.createBasket{value: creationFee}(params, pools, maximums, block.timestamp + 1 hours);
        uint256[] memory mintQuote = baskets.quoteMint(reserveBasketId, USDG_RESERVE_SHARES);
        vm.prank(alice);
        baskets.mint(reserveBasketId, USDG_RESERVE_SHARES, alice, mintQuote);
        assertGe(flashLoans.maxFlashLoan(USDG), FLASH_AMOUNT);
        assertEq(IERC20(USDG).balanceOf(address(diamond)), custody.globalReservedByToken(USDG));
    }

    function _makeOuterBasketExpensive() private {
        PoolKey memory pool = _outerBasketPool();
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).approve(address(router), DISTORTION_INPUT));
        bool zeroForOne = Currency.unwrap(pool.currency0) == BLEND_AI;
        uint256 outerBefore = IERC20(staticsBasketToken).balanceOf(alice);
        vm.prank(alice);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(DISTORTION_INPUT),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertGt(IERC20(staticsBasketToken).balanceOf(alice), outerBefore);
    }

    function _singleAssetReceiver() private returns (BlendStaticsSingleAssetFlashReceiver receiver) {
        receiver = new BlendStaticsSingleAssetFlashReceiver(
            flashLoans,
            baskets,
            router,
            USDG,
            BLEND_AI,
            staticsBasketId,
            staticsBasketToken,
            IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG),
            _outerBasketPool()
        );
    }

    function _outerBasketPool() private view returns (PoolKey memory pool) {
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        pool = PoolKey({
            currency0: Currency.wrap(canonical.currency0),
            currency1: Currency.wrap(canonical.currency1),
            fee: canonical.lpFee,
            tickSpacing: canonical.tickSpacing,
            hooks: staticsHook
        });
    }

    function _semanticSqrtPrice(uint256 assetUnitsPerShare) private pure returns (uint160) {
        uint256 ratioRoot = Math.sqrt(assetUnitsPerShare * 1 ether);
        return uint160(Math.mulDiv(ratioRoot, 1 << 96, 1 ether));
    }
}
