// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsPermanentLiquidityMath} from "../../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalV4Router} from "./CanonicalPoolTestBase.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";

interface IPendleMarket is IERC20Metadata {
    function swapExactPtForSy(address receiver, uint256 exactPtIn, bytes calldata data)
        external
        returns (uint256 netSyOut, uint256 netSyFee);

    function swapSyForExactPt(address receiver, uint256 exactPtOut, bytes calldata data)
        external
        returns (uint256 netSyIn, uint256 netSyFee);

    function readTokens() external view returns (address sy, address pt, address yt);
    function isExpired() external view returns (bool);
    function factory() external view returns (address);
    function expiry() external view returns (uint256);
}

interface IPendleMarketSwapCallback {
    function swapCallback(int256 ptToAccount, int256 syToAccount, bytes calldata data) external;
}

interface IPendleSY is IERC20Metadata {
    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256 amountSharesOut);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    function exchangeRate() external view returns (uint256);
    function getTokensIn() external view returns (address[] memory);
    function getTokensOut() external view returns (address[] memory);
    function isValidTokenIn(address token) external view returns (bool);
    function isValidTokenOut(address token) external view returns (bool);
    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        external
        view
        returns (uint256 amountSharesOut);
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        external
        view
        returns (uint256 amountTokenOut);
}

interface IPendleRouterStatic {
    function swapExactPtForSyStatic(address market, uint256 exactPtIn)
        external
        view
        returns (uint256 netSyOut, uint256 netSyFee, uint256 priceImpact, uint256 exchangeRateAfter);

    function swapSyForExactPtStatic(address market, uint256 exactPtOut)
        external
        view
        returns (uint256 netSyIn, uint256 netSyFee, uint256 priceImpact, uint256 exchangeRateAfter);
}

interface IRobinhoodV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IRobinhoodV3Quoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IRobinhoodV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @notice Minimal test router for the production Pendle market callback interface.
/// @dev A Pendle exact-PT purchase transfers PT before requesting the SY payment. This router
///      authenticates that callback and caps the SY debt without adding a Pendle dependency.
contract PendleForkSwapRouter is IPendleMarketSwapCallback {
    using SafeERC20 for IERC20;

    error ActiveSwap();
    error DirtyBalance(address token);
    error InvalidCallback();
    error SlippageExceeded(uint256 limit, uint256 actual);

    address private _activeMarket;
    address private _activeSy;
    uint256 private _activePtOut;
    uint256 private _maximumSyIn;

    function buyExactPt(address market, uint256 exactPtOut, uint256 maximumSyIn, address receiver)
        external
        returns (uint256 netSyIn, uint256 netSyFee)
    {
        if (_activeMarket != address(0)) revert ActiveSwap();
        (address sy,,) = IPendleMarket(market).readTokens();
        if (IERC20(sy).balanceOf(address(this)) != 0) revert DirtyBalance(sy);

        IERC20(sy).safeTransferFrom(msg.sender, address(this), maximumSyIn);
        _activeMarket = market;
        _activeSy = sy;
        _activePtOut = exactPtOut;
        _maximumSyIn = maximumSyIn;
        (netSyIn, netSyFee) = IPendleMarket(market).swapSyForExactPt(receiver, exactPtOut, hex"01");
        if (netSyIn > maximumSyIn) revert SlippageExceeded(maximumSyIn, netSyIn);

        _activeMarket = address(0);
        _activeSy = address(0);
        _activePtOut = 0;
        _maximumSyIn = 0;
        uint256 refund = IERC20(sy).balanceOf(address(this));
        if (refund != 0) IERC20(sy).safeTransfer(msg.sender, refund);
    }

    function sellExactPt(address market, uint256 exactPtIn, uint256 minimumSyOut, address receiver)
        external
        returns (uint256 netSyOut, uint256 netSyFee)
    {
        (, address pt,) = IPendleMarket(market).readTokens();
        if (IERC20(pt).balanceOf(address(this)) != 0) revert DirtyBalance(pt);
        IERC20(pt).safeTransferFrom(msg.sender, market, exactPtIn);
        (netSyOut, netSyFee) = IPendleMarket(market).swapExactPtForSy(receiver, exactPtIn, "");
        if (netSyOut < minimumSyOut) revert SlippageExceeded(minimumSyOut, netSyOut);
    }

    function swapCallback(int256 ptToAccount, int256 syToAccount, bytes calldata data) external {
        if (
            msg.sender != _activeMarket || data.length != 1 || data[0] != 0x01 || ptToAccount <= 0 || syToAccount >= 0
                || uint256(ptToAccount) != _activePtOut
        ) revert InvalidCallback();
        uint256 syOwed = uint256(-syToAccount);
        if (syOwed > _maximumSyIn) revert SlippageExceeded(_maximumSyIn, syOwed);
        IERC20(_activeSy).safeTransfer(msg.sender, syOwed);
    }
}

/// @notice Shared deterministic Robinhood fork setup for PT composition, lending, and arbitrage proofs.
abstract contract RobinhoodPendleForkBase is StaticsTestBase {
    using Math for uint256;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    string internal constant CHAIN_MANIFEST = "deployments/robinhood-chain-4663.json";

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant SHARED_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PENDLE_MARKET_FACTORY = 0x544BF81c855AE84c1e8b65d5E38770898D01EeE2;
    address internal constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal constant PENDLE_ROUTER_STATIC = 0x6813d43782395A1F2AAb42f39aeEDE03ac655e09;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant PT_NVDA = 0x4bCb25FCE9618E62e9F9fBA8D65af50CF867b812;
    address internal constant SY_NVDA = 0x82cC738064816eD7441E3c4D917503Ca5388dFE9;
    address internal constant YT_NVDA = 0x9Cc22e51C6F0cb4aA1BfD1F18E85df1451EBB9b3;
    address internal constant MARKET_NVDA = 0x206a5cD00E9FfaBb8CA564076B64799A78DF19b9;

    address internal constant PFE = 0x7066A64c24e4206CD62E83bf198c1E7EB361F51e;
    address internal constant PT_PFE = 0xf9cD484F7E7799aE32b7F9A75E60c478Fd1f0B6e;
    address internal constant SY_PFE = 0x8c7454D4d64aBd04fbf5F5ffe0Dbcd5E3ABcEcf6;
    address internal constant YT_PFE = 0x7600d0A61F83D7e4C4154c4664b19BE6d9ACf180;
    address internal constant MARKET_PFE = 0x892DeFBf510D9baA96dBd2a51B13E879A857a79b;

    address internal constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address internal constant PT_SGOV = 0x9f1e57d8984D9Ae2b081eD6fceFf2fb60CB785F1;
    address internal constant SY_SGOV = 0x06fC2568fa3C8A9862D8f35bc6758355b3A32F51;
    address internal constant YT_SGOV = 0x7eeE53B86290e58179ED96Bea7887A37e8A1B7b9;
    address internal constant MARKET_SGOV = 0xd6E26E957B3207a5C618213d928647Ec84150cA0;

    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address internal constant V3_NVDA_USDG = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address internal constant V3_PFE_USDG = 0xC7d573Fcda6D2107C97fb582ae18411F9Db32E7f;
    address internal constant V3_SGOV_USDG = 0x6Ba50150B17Ffd0972915Aaf04fFd5E8f4Fa49b4;

    address internal constant LIVE_USDG_HOLDER = 0x914AadaBE98d9fc4293EC67cF28537acb3117822;

    uint256 internal constant FORK_BLOCK = 63_211_853;
    bytes32 internal constant FORK_BLOCK_HASH = 0xbe73a3e0b16be6199ff78bea03c50b3ad3006a4ed5ae20f7844369629b311ff8;
    uint256 internal constant SHARE_SCALE = 1 ether;
    uint256 internal constant MINT_FEE_SHARES = 0.01 ether;
    uint256 internal constant REDEMPTION_FEE_SHARES = 0.005 ether;
    uint256 internal constant TERM_COMPONENT_USDG = 1_000_000;
    uint256 internal constant PT_VALUE_PROBE = 0.01 ether;
    uint256 internal constant PT_SETUP_FUNDING = 10 ether;
    uint40 internal constant TERM_LOAN_DURATION = 14 days;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    bytes32 private constant V3_FACTORY_CODE_HASH = 0xec72b1abd1f2faee020cfea9c646bd8994f9fb389054f6e574f103a895091739;
    bytes32 private constant V3_ROUTER_CODE_HASH = 0x6f36c378e272c6324c48f045182bcb54bd8ad654cf9ebd42e8893d52c4cb25dc;
    bytes32 private constant V3_QUOTER_CODE_HASH = 0x3db0868d945e9304c9bc6a8b2181948109ea617647142f3c4083e14393496a28;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    struct TermMarket {
        address market;
        address sy;
        address pt;
        address yt;
        address underlying;
        address v3Pool;
        uint24 v3Fee;
    }

    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    IAllowanceTransfer internal permit2;
    IV4Quoter internal v4Quoter;
    StaticsSwapFeeHook internal staticsHook;
    StaticsLiquidityManager internal liquidityManager;
    CanonicalV4Router internal canonicalRouter;
    PendleForkSwapRouter internal pendleSwapRouter;

    uint256[3] internal termBundles;
    uint256 internal wrapperBasketId;
    address internal wrapperBasketToken;
    uint256 internal termBasketId;
    address internal termBasketToken;

    function setUp() public virtual override {
        if (!_selectPinnedFork()) return;
        super.setUp();

        string memory manifest = vm.readFile(CHAIN_MANIFEST);
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        v4Quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        _assertInfrastructure(manifest);

        staticsHook = _deployStaticsHook();
        liquidityManager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(staticsHook));
        basketLiquidity.installLiquidityManager(address(liquidityManager));
        canonicalRouter = new CanonicalV4Router(poolManager);
        pendleSwapRouter = new PendleForkSwapRouter();

        _deriveTermBundles();
    }

    function _fundAliceWithPts() internal {
        for (uint256 i; i < 3; ++i) {
            _acquireExactPtFromSyntheticUnderlying(alice, i, PT_SETUP_FUNDING);
            vm.prank(alice);
            IERC20(_termMarket(i).pt).forceApprove(address(diamond), type(uint256).max);
        }
    }

    function _fundAliceWithLiveUsdg(uint256 amount) internal {
        uint256 holderBefore = IERC20(USDG).balanceOf(LIVE_USDG_HOLDER);
        assertGe(holderBefore, amount, "live USDG fixture balance drift");
        vm.prank(LIVE_USDG_HOLDER);
        IERC20(USDG).safeTransfer(alice, amount);
    }

    function _launchPtWrapper(uint256 poolSeed) internal returns (uint256 basketId, address basketToken) {
        address[] memory assets = new address[](1);
        assets[0] = PT_NVDA;
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = SHARE_SCALE;
        uint256[] memory poolSeeds = new uint256[](1);
        poolSeeds[0] = poolSeed;
        (basketId, basketToken) = _launchPendleBasket("Statics PT-NVDA", "sPT-NVDA", assets, bundles, poolSeeds);
        wrapperBasketId = basketId;
        wrapperBasketToken = basketToken;
    }

    function _launchTermBasket(uint256 seedShares) internal returns (uint256 basketId, address basketToken) {
        address[] memory assets = _termPts();
        uint256[] memory bundles = _termBundleVector();
        uint256[] memory poolSeeds = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            poolSeeds[i] = Math.mulDiv(bundles[i], seedShares, SHARE_SCALE);
        }
        (basketId, basketToken) = _launchPendleBasket("Statics Equal-Dollar PT", "sTERM", assets, bundles, poolSeeds);
        termBasketId = basketId;
        termBasketToken = basketToken;
    }

    function _launchUsdgReserve(uint256 poolSeed, uint256 reserveShares)
        internal
        returns (uint256 basketId, address basketToken)
    {
        vm.prank(alice);
        IERC20(USDG).forceApprove(address(diamond), type(uint256).max);
        address[] memory assets = new address[](1);
        assets[0] = USDG;
        uint256[] memory bundles = new uint256[](1);
        bundles[0] = 1_000_000;
        uint256[] memory poolSeeds = new uint256[](1);
        poolSeeds[0] = poolSeed;
        (basketId, basketToken) = _launchPendleBasket("Statics USDG Reserve", "sUSDG", assets, bundles, poolSeeds);
        uint256[] memory quote = baskets.quoteMint(basketId, reserveShares);
        vm.prank(alice);
        baskets.mint(basketId, reserveShares, alice, quote);
    }

    function _launchPendleBasket(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory bundles,
        uint256[] memory poolSeeds
    ) internal returns (uint256 basketId, address basketToken) {
        uint256 length = assets.length;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
            assets: assets,
            bundleAmounts: bundles,
            mintFeeTiers: _singleFeeTier(MINT_FEE_SHARES),
            redemptionFeeTiers: _singleFeeTier(REDEMPTION_FEE_SHARES),
            flashFeeBps: 5,
            originationFeeBps: 25,
            extensionFeeBps: 10,
            ltvBps: 9_000,
            recoveryPenaltyBps: 500,
            loanDuration: TERM_LOAN_DURATION
        });
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](length);
        uint256[] memory maximums = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            vm.prank(alice);
            IERC20(assets[i]).forceApprove(address(diamond), type(uint256).max);
            pools[i] = IStaticsBasket.PoolLaunchParams({
                lpFee: 3_000,
                tickSpacing: 10,
                sqrtPriceAssetPerBasketX96: _semanticSqrtPrice(bundles[i]),
                pairedAssetAmount: poolSeeds[i]
            });
            maximums[i] = IERC20(assets[i]).balanceOf(alice);
        }
        vm.prank(alice);
        return
            baskets.createBasket{value: basketAdmin.creationFee()}(params, pools, maximums, block.timestamp + 1 hours);
    }

    function _canonicalPool(uint256 basketId, address asset) internal view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured = basketLiquidity.canonicalPool(basketId, asset);
        key = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
    }

    function _assertCanonicalPool(uint256 basketId, address basketToken, address asset) internal view {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured = basketLiquidity.canonicalPool(basketId, asset);
        PoolKey memory key = _canonicalPool(basketId, asset);
        assertEq(configured.basketToken, basketToken);
        assertEq(configured.asset, asset);
        assertEq(configured.hook, address(staticsHook));
        assertEq(PoolId.unwrap(configured.poolId), PoolId.unwrap(key.toId()));
        assertGt(poolManager.getLiquidity(configured.poolId), 0);
        assertGt(staticsHook.lockedLiquidity(configured.poolId), 0);
    }

    function _swapCanonicalExactInput(
        address actor,
        PoolKey memory pool,
        address input,
        address output,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        bool zeroForOne = _canonicalDirection(pool, input, output);
        uint256 beforeOut = IERC20(output).balanceOf(actor);
        vm.startPrank(actor);
        IERC20(input).forceApprove(address(canonicalRouter), amountIn);
        canonicalRouter.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? 4_295_128_740
                    : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
            })
        );
        IERC20(input).forceApprove(address(canonicalRouter), 0);
        vm.stopPrank();
        amountOut = IERC20(output).balanceOf(actor) - beforeOut;
    }

    function _quoteCanonicalExactInput(PoolKey memory pool, address input, address output, uint128 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (amountOut,) = v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: pool, zeroForOne: _canonicalDirection(pool, input, output), exactAmount: amountIn, hookData: ""
            })
        );
    }

    function _canonicalDirection(PoolKey memory pool, address input, address output)
        internal
        pure
        returns (bool zeroForOne)
    {
        if (Currency.unwrap(pool.currency0) == input && Currency.unwrap(pool.currency1) == output) return true;
        if (Currency.unwrap(pool.currency1) == input && Currency.unwrap(pool.currency0) == output) return false;
        revert("invalid canonical route");
    }

    function _sellPtForUsdg(address actor, uint256 marketIndex, uint256 exactPtIn) internal returns (uint256 usdgOut) {
        TermMarket memory configured = _termMarket(marketIndex);
        uint256 syBefore = IERC20(configured.sy).balanceOf(actor);
        vm.startPrank(actor);
        IERC20(configured.pt).forceApprove(address(pendleSwapRouter), exactPtIn);
        pendleSwapRouter.sellExactPt(configured.market, exactPtIn, 1, actor);
        IERC20(configured.pt).forceApprove(address(pendleSwapRouter), 0);
        uint256 syOut = IERC20(configured.sy).balanceOf(actor) - syBefore;
        uint256 underlyingOut = IPendleSY(configured.sy).redeem(actor, syOut, configured.underlying, 1, false);
        vm.stopPrank();
        usdgOut = _v3ExactInput(actor, configured, configured.underlying, USDG, underlyingOut);
    }

    function _buyExactPtWithUsdg(address actor, uint256 marketIndex, uint256 exactPtOut)
        internal
        returns (uint256 usdgSpent)
    {
        TermMarket memory configured = _termMarket(marketIndex);
        (uint256 syIn,,,) =
            IPendleRouterStatic(PENDLE_ROUTER_STATIC).swapSyForExactPtStatic(configured.market, exactPtOut);
        uint256 underlyingNeeded = _underlyingForSy(configured, syIn);
        uint256 usdgBefore = IERC20(USDG).balanceOf(actor);
        uint256 syBefore = IERC20(configured.sy).balanceOf(actor);
        _v3ExactOutput(actor, configured, USDG, configured.underlying, underlyingNeeded);

        vm.startPrank(actor);
        IERC20(configured.underlying).forceApprove(configured.sy, underlyingNeeded);
        uint256 syOut = IPendleSY(configured.sy).deposit(actor, configured.underlying, underlyingNeeded, syIn);
        IERC20(configured.underlying).forceApprove(configured.sy, 0);
        IERC20(configured.sy).forceApprove(address(pendleSwapRouter), syOut);
        pendleSwapRouter.buyExactPt(configured.market, exactPtOut, syOut, actor);
        IERC20(configured.sy).forceApprove(address(pendleSwapRouter), 0);
        vm.stopPrank();

        uint256 remainingSy = IERC20(configured.sy).balanceOf(actor) - syBefore;
        if (remainingSy != 0) {
            vm.prank(actor);
            uint256 recoveredUnderlying =
                IPendleSY(configured.sy).redeem(actor, remainingSy, configured.underlying, 1, false);
            _v3ExactInput(actor, configured, configured.underlying, USDG, recoveredUnderlying);
        }
        usdgSpent = usdgBefore - IERC20(USDG).balanceOf(actor);
    }

    function _v3ExactInput(address actor, TermMarket memory configured, address input, address output, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        uint256 quote = _quoteV3ExactInput(configured, input, output, amountIn);
        vm.startPrank(actor);
        IERC20(input).forceApprove(V3_ROUTER, amountIn);
        amountOut = IRobinhoodV3Router(V3_ROUTER)
            .exactInputSingle(
                IRobinhoodV3Router.ExactInputSingleParams({
                    tokenIn: input,
                    tokenOut: output,
                    fee: configured.v3Fee,
                    recipient: actor,
                    amountIn: amountIn,
                    amountOutMinimum: Math.mulDiv(quote, BPS - SLIPPAGE_BPS, BPS),
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(input).forceApprove(V3_ROUTER, 0);
        vm.stopPrank();
    }

    function _v3ExactOutput(
        address actor,
        TermMarket memory configured,
        address input,
        address output,
        uint256 amountOut
    ) internal returns (uint256 amountIn) {
        uint256 quote = _quoteV3ExactOutput(configured, input, output, amountOut);
        uint256 maximum = Math.mulDiv(quote, BPS + SLIPPAGE_BPS, BPS, Math.Rounding.Ceil);
        vm.startPrank(actor);
        IERC20(input).forceApprove(V3_ROUTER, maximum);
        amountIn = IRobinhoodV3Router(V3_ROUTER)
            .exactOutputSingle(
                IRobinhoodV3Router.ExactOutputSingleParams({
                    tokenIn: input,
                    tokenOut: output,
                    fee: configured.v3Fee,
                    recipient: actor,
                    amountOut: amountOut,
                    amountInMaximum: maximum,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(input).forceApprove(V3_ROUTER, 0);
        vm.stopPrank();
    }

    function _quotePtUsdg(uint256 marketIndex, uint256 exactPtIn) internal returns (uint256 usdgOut) {
        TermMarket memory configured = _termMarket(marketIndex);
        (uint256 syOut,,,) =
            IPendleRouterStatic(PENDLE_ROUTER_STATIC).swapExactPtForSyStatic(configured.market, exactPtIn);
        uint256 underlyingOut = IPendleSY(configured.sy).previewRedeem(configured.underlying, syOut);
        usdgOut = _quoteV3ExactInput(configured, configured.underlying, USDG, underlyingOut);
    }

    function _quoteUsdgForExactPt(uint256 marketIndex, uint256 exactPtOut) internal returns (uint256 usdgIn) {
        TermMarket memory configured = _termMarket(marketIndex);
        (uint256 syIn,,,) =
            IPendleRouterStatic(PENDLE_ROUTER_STATIC).swapSyForExactPtStatic(configured.market, exactPtOut);
        usdgIn = _quoteV3ExactOutput(configured, USDG, configured.underlying, _underlyingForSy(configured, syIn));
    }

    function _quoteV3ExactInput(TermMarket memory configured, address input, address output, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (amountOut,,,) = IRobinhoodV3Quoter(V3_QUOTER)
            .quoteExactInputSingle(
                IRobinhoodV3Quoter.QuoteExactInputSingleParams({
                    tokenIn: input, tokenOut: output, amountIn: amountIn, fee: configured.v3Fee, sqrtPriceLimitX96: 0
                })
            );
    }

    function _quoteV3ExactOutput(TermMarket memory configured, address input, address output, uint256 amountOut)
        internal
        returns (uint256 amountIn)
    {
        (amountIn,,,) = IRobinhoodV3Quoter(V3_QUOTER)
            .quoteExactOutputSingle(
                IRobinhoodV3Quoter.QuoteExactOutputSingleParams({
                    tokenIn: input, tokenOut: output, amount: amountOut, fee: configured.v3Fee, sqrtPriceLimitX96: 0
                })
            );
    }

    function _termMarket(uint256 index) internal pure returns (TermMarket memory configured) {
        if (index == 0) {
            return TermMarket({
                market: MARKET_NVDA,
                sy: SY_NVDA,
                pt: PT_NVDA,
                yt: YT_NVDA,
                underlying: NVDA,
                v3Pool: V3_NVDA_USDG,
                v3Fee: 500
            });
        }
        if (index == 1) {
            return TermMarket({
                market: MARKET_PFE,
                sy: SY_PFE,
                pt: PT_PFE,
                yt: YT_PFE,
                underlying: PFE,
                v3Pool: V3_PFE_USDG,
                v3Fee: 3_000
            });
        }
        if (index == 2) {
            return TermMarket({
                market: MARKET_SGOV,
                sy: SY_SGOV,
                pt: PT_SGOV,
                yt: YT_SGOV,
                underlying: SGOV,
                v3Pool: V3_SGOV_USDG,
                v3Fee: 500
            });
        }
        revert("invalid term market");
    }

    function _termPts() internal pure returns (address[] memory assets) {
        assets = new address[](3);
        assets[0] = PT_NVDA;
        assets[1] = PT_PFE;
        assets[2] = PT_SGOV;
    }

    function _termBundleVector() internal view returns (uint256[] memory bundles) {
        bundles = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            bundles[i] = termBundles[i];
        }
    }

    function _deriveTermBundles() private {
        for (uint256 i; i < 3; ++i) {
            uint256 usdgOut = _quotePtUsdg(i, PT_VALUE_PROBE);
            assertGt(usdgOut, 0);
            termBundles[i] = Math.mulDiv(PT_VALUE_PROBE, TERM_COMPONENT_USDG, usdgOut);
            uint256 derivedValue = _quotePtUsdg(i, termBundles[i]);
            assertApproxEqRel(derivedValue, TERM_COMPONENT_USDG, 0.03 ether, "PT bundle value drift");
        }
    }

    function _acquireExactPtFromSyntheticUnderlying(address receiver, uint256 marketIndex, uint256 exactPtOut) private {
        TermMarket memory configured = _termMarket(marketIndex);
        (uint256 syIn,,,) =
            IPendleRouterStatic(PENDLE_ROUTER_STATIC).swapSyForExactPtStatic(configured.market, exactPtOut);
        uint256 underlyingIn = _underlyingForSy(configured, syIn);

        // Robinhood Stock Token primary issuance is permissioned and holder balances drift. Only
        // this funding edge is synthetic; SY deposits and Pendle market settlement use live code.
        deal(configured.underlying, receiver, underlyingIn, true);
        vm.startPrank(receiver);
        IERC20(configured.underlying).forceApprove(configured.sy, underlyingIn);
        uint256 syOut = IPendleSY(configured.sy).deposit(receiver, configured.underlying, underlyingIn, syIn);
        IERC20(configured.underlying).forceApprove(configured.sy, 0);
        IERC20(configured.sy).forceApprove(address(pendleSwapRouter), syOut);
        pendleSwapRouter.buyExactPt(configured.market, exactPtOut, syOut, receiver);
        IERC20(configured.sy).forceApprove(address(pendleSwapRouter), 0);
        vm.stopPrank();
        assertEq(IERC20(configured.pt).balanceOf(receiver), exactPtOut);
    }

    function _underlyingForSy(TermMarket memory configured, uint256 syAmount)
        internal
        view
        returns (uint256 underlyingAmount)
    {
        uint256 preview = IPendleSY(configured.sy).previewRedeem(configured.underlying, syAmount);
        underlyingAmount = Math.mulDiv(preview, BPS + SLIPPAGE_BPS, BPS, Math.Rounding.Ceil) + 1;
        assertGe(IPendleSY(configured.sy).previewDeposit(configured.underlying, underlyingAmount), syAmount);
    }

    function _semanticSqrtPrice(uint256 assetUnitsPerShare) internal pure returns (uint160) {
        uint256 ratioRoot = Math.sqrt(assetUnitsPerShare * SHARE_SCALE);
        return uint160(Math.mulDiv(ratioRoot, 1 << 96, SHARE_SCALE));
    }

    function _assertInfrastructure(string memory manifest) private view {
        assertEq(address(poolManager), SHARED_POOL_MANAGER);
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        assertEq(address(v4Quoter).codehash, vm.parseJsonBytes32(manifest, ".contracts.quoter.runtimeCodeHash"));
        assertEq(V3_FACTORY.codehash, V3_FACTORY_CODE_HASH);
        assertEq(V3_ROUTER.codehash, V3_ROUTER_CODE_HASH);
        assertEq(V3_QUOTER.codehash, V3_QUOTER_CODE_HASH);
        assertGt(PENDLE_ROUTER.code.length, 0);
        assertGt(PENDLE_ROUTER_STATIC.code.length, 0);

        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            (address sy, address pt, address yt) = IPendleMarket(configured.market).readTokens();
            assertEq(IPendleMarket(configured.market).factory(), PENDLE_MARKET_FACTORY);
            assertEq(sy, configured.sy);
            assertEq(pt, configured.pt);
            assertEq(yt, configured.yt);
            assertFalse(IPendleMarket(configured.market).isExpired());
            assertGt(IPendleMarket(configured.market).expiry(), block.timestamp + TERM_LOAN_DURATION);
            assertEq(IERC20Metadata(configured.pt).decimals(), 18);
            assertEq(IERC20Metadata(configured.sy).decimals(), 18);
            assertEq(IERC20Metadata(configured.underlying).decimals(), 18);
            assertTrue(IPendleSY(configured.sy).isValidTokenIn(configured.underlying));
            assertTrue(IPendleSY(configured.sy).isValidTokenOut(configured.underlying));
            assertEq(
                IRobinhoodV3Factory(V3_FACTORY).getPool(configured.underlying, USDG, configured.v3Fee),
                configured.v3Pool
            );
        }

        emit log_named_uint("Robinhood fork block", FORK_BLOCK);
        emit log_named_address("Pendle market factory", PENDLE_MARKET_FACTORY);
        emit log_named_address("Pendle RouterStatic", PENDLE_ROUTER_STATIC);
    }

    function _deployStaticsHook() private returns (StaticsSwapFeeHook deployed) {
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        bytes memory constructorArgs =
            abi.encode(poolManager, address(diamond), uint16(25), uint16(25), permanentLiquidityMath);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 25, 25, permanentLiquidityMath);
        assertEq(address(deployed), expected);
    }

    function _selectPinnedFork() private returns (bool selected) {
        if (block.chainid == 4_663 && block.number == FORK_BLOCK) return true;
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return false;
        }
        uint256 forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "fork block hash drift");
        vm.rollFork(forkId, FORK_BLOCK);
        assertEq(block.chainid, 4_663, "fork chain id drift");
        assertEq(block.number, FORK_BLOCK, "fork block number drift");
        return true;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }
}
