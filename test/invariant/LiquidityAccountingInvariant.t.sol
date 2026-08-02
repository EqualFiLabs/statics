// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract LiquidityAccountingHandler is Test {
    PoolSwapTest private immutable router;
    IStaticsBasketLiquidity private immutable liquidity;
    uint256 private immutable firstBasketId;
    uint256 private immutable secondBasketId;
    address private immutable asset;
    PoolKey private firstKey;
    PoolKey private secondKey;

    constructor(
        PoolSwapTest router_,
        IStaticsBasketLiquidity liquidity_,
        uint256 firstBasketId_,
        uint256 secondBasketId_,
        address asset_,
        PoolKey memory firstKey_,
        PoolKey memory secondKey_
    ) {
        router = router_;
        liquidity = liquidity_;
        firstBasketId = firstBasketId_;
        secondBasketId = secondBasketId_;
        asset = asset_;
        firstKey = firstKey_;
        secondKey = secondKey_;
        IERC20(Currency.unwrap(firstKey_.currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(firstKey_.currency1)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(secondKey_.currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(secondKey_.currency1)).approve(address(router_), type(uint256).max);
    }

    function swapFirst(uint256 rawAmount, bool zeroForOne) external {
        _swap(firstKey, rawAmount, zeroForOne);
    }

    function swapSecond(uint256 rawAmount, bool zeroForOne) external {
        _swap(secondKey, rawAmount, zeroForOne);
    }

    function settleFirst() external {
        try liquidity.settleCanonicalHookFees(firstBasketId, asset) {} catch {}
    }

    function settleSecond() external {
        try liquidity.settleCanonicalHookFees(secondBasketId, asset) {} catch {}
    }

    function collectFirst() external {
        try liquidity.collectProtocolLpFees(firstBasketId, asset) {} catch {}
    }

    function collectSecond() external {
        try liquidity.collectProtocolLpFees(secondBasketId, asset) {} catch {}
    }

    function compoundFirst() external {
        _compound(firstBasketId);
    }

    function compoundSecond() external {
        _compound(secondBasketId);
    }

    function _compound(uint256 basketId) private {
        vm.warp(block.timestamp + 24 hours);
        try liquidity.compoundBasketLiquidity(basketId) {} catch {}
    }

    function _swap(PoolKey storage stored, uint256 rawAmount, bool zeroForOne) private {
        PoolKey memory key = stored;
        address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        uint256 balance = IERC20(input).balanceOf(address(this));
        if (balance < 1e12) return;
        uint256 maximum = balance < 0.001 ether ? balance : 0.001 ether;
        uint256 amount = 1e12 + rawAmount % (maximum - 1e12 + 1);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }
}

contract LiquidityAccountingInvariantTest is StaticsTestBase {
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2Contract;
    StaticsSwapFeeHook private hook;
    StaticsLiquidityManager private manager;
    PoolSwapTest private router;
    LiquidityAccountingHandler private handler;
    uint256 private firstBasketId;
    uint256 private secondBasketId;
    address private firstBasketToken;
    address private secondBasketToken;
    uint256 private firstUserTokenId;
    uint256 private secondUserTokenId;
    PoolKey private firstKey;
    PoolKey private secondKey;

    function setUp() public override {
        super.setUp();
        poolManager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        positionManager = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        hook = _deployHook();
        manager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(address(manager));

        (firstBasketId, firstBasketToken) = _createSharedBasket("Static Shared A", "sSHARED-A");
        (secondBasketId, secondBasketToken) = _createSharedBasket("Static Shared B", "sSHARED-B");
        uint256 firstPosition = _mintPosition(firstBasketId, 100 ether);
        uint256 secondPosition = _mintPosition(secondBasketId, 100 ether);
        basketLiquidity.initializeCanonicalPool(firstBasketId, address(assetA), SQRT_PRICE_1_1);
        basketLiquidity.initializeCanonicalPool(secondBasketId, address(assetA), SQRT_PRICE_1_1);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(firstBasketId, address(assetA));
        basketLiquidity.activateCanonicalPool(secondBasketId, address(assetA));
        basketLiquidity.compoundBasketLiquidity(firstBasketId);
        basketLiquidity.compoundBasketLiquidity(secondBasketId);
        firstUserTokenId = _borrowLiquidity(firstBasketId, firstPosition);
        secondUserTokenId = _borrowLiquidity(secondBasketId, secondPosition);

        firstKey = _poolKey(firstBasketId);
        secondKey = _poolKey(secondBasketId);
        router = new PoolSwapTest(poolManager);
        handler = new LiquidityAccountingHandler(
            router, basketLiquidity, firstBasketId, secondBasketId, address(assetA), firstKey, secondKey
        );
        _fundHandler(firstBasketId, firstBasketToken);
        _fundHandler(secondBasketId, secondBasketToken);
        assetA.mint(address(handler), 100 ether);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = LiquidityAccountingHandler.swapFirst.selector;
        selectors[1] = LiquidityAccountingHandler.swapSecond.selector;
        selectors[2] = LiquidityAccountingHandler.settleFirst.selector;
        selectors[3] = LiquidityAccountingHandler.settleSecond.selector;
        selectors[4] = LiquidityAccountingHandler.collectFirst.selector;
        selectors[5] = LiquidityAccountingHandler.collectSecond.selector;
        selectors[6] = LiquidityAccountingHandler.compoundFirst.selector;
        selectors[7] = LiquidityAccountingHandler.compoundSecond.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantDiamondReservationsMatchIsolatedBasketBooks() public view {
        _assertBasketBooks(firstBasketId, firstBasketToken);
        _assertBasketBooks(secondBasketId, secondBasketToken);
        bytes32 firstAccount = custody.basketCustodyAccount(firstBasketId);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasketId);
        assertEq(
            custody.globalReservedByToken(address(assetA)),
            custody.reservedByAccount(firstAccount, address(assetA))
                + custody.reservedByAccount(secondAccount, address(assetA))
        );
        assertGe(IERC20(address(assetA)).balanceOf(address(diamond)), custody.globalReservedByToken(address(assetA)));
    }

    function invariantHookLiabilitiesRemainCoveredAndPoolIsolated() public view {
        PoolId firstPoolId = firstKey.toId();
        PoolId secondPoolId = secondKey.toId();
        assertEq(
            hook.totalLiability(Currency.wrap(address(assetA))),
            hook.accruedFees(firstPoolId, Currency.wrap(address(assetA)))
                + hook.accruedFees(secondPoolId, Currency.wrap(address(assetA)))
        );
        _assertHookCurrency(firstPoolId, secondPoolId, firstBasketToken);
        _assertHookCurrency(firstPoolId, secondPoolId, secondBasketToken);
        assertGe(assetA.balanceOf(address(hook)), hook.totalLiability(Currency.wrap(address(assetA))));
    }

    function invariantManagerInventoryIsSolventAndBasketIsolated() public view {
        assertEq(
            manager.totalProtocolInventory(address(assetA)),
            manager.protocolInventory(firstBasketId, address(assetA))
                + manager.protocolInventory(secondBasketId, address(assetA))
        );
        assertEq(
            manager.totalProtocolInventory(firstBasketToken), manager.protocolInventory(firstBasketId, firstBasketToken)
        );
        assertEq(
            manager.totalProtocolInventory(secondBasketToken),
            manager.protocolInventory(secondBasketId, secondBasketToken)
        );
        assertEq(assetA.balanceOf(address(manager)), manager.totalProtocolInventory(address(assetA)));
        assertEq(IERC20(firstBasketToken).balanceOf(address(manager)), manager.totalProtocolInventory(firstBasketToken));
        assertEq(
            IERC20(secondBasketToken).balanceOf(address(manager)), manager.totalProtocolInventory(secondBasketToken)
        );
    }

    function invariantProtocolLpFeesConserveAndUserPositionsStayIndependent() public view {
        _assertLpConservation(firstBasketId);
        _assertLpConservation(secondBasketId);
        uint256 firstProtocolTokenId = manager.protocolPositionId(firstBasketId, address(assetA));
        uint256 secondProtocolTokenId = manager.protocolPositionId(secondBasketId, address(assetA));
        assertEq(IERC721(address(positionManager)).ownerOf(firstProtocolTokenId), address(manager));
        assertEq(IERC721(address(positionManager)).ownerOf(secondProtocolTokenId), address(manager));
        assertEq(IERC721(address(positionManager)).ownerOf(firstUserTokenId), bob);
        assertEq(IERC721(address(positionManager)).ownerOf(secondUserTokenId), bob);
        assertNotEq(firstUserTokenId, firstProtocolTokenId);
        assertNotEq(secondUserTokenId, secondProtocolTokenId);
    }

    function _assertBasketBooks(uint256 basketId, address basketToken) private view {
        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        bytes32 account = custody.basketCustodyAccount(basketId);
        uint256 backing = baskets.vaultBalance(basketId, address(assetA));
        uint256 debt = lending.outstandingPrincipal(basketId, address(assetA));
        uint256 required =
            Math.mulDiv(configured.bundleAmounts[0], IERC20(basketToken).totalSupply(), 1e18, Math.Rounding.Ceil);
        assertGe(backing + debt, required);
        uint256 recorded = backing + basketAdmin.protocolRevenue(basketId, address(assetA))
            + basketLiquidity.liquidityReserve(basketId, address(assetA))
            + basketRewards.basketRewardState(basketId, address(assetA)).feeYieldReserve
            + lending.recoverySurplus(basketId, address(assetA));
        assertEq(custody.reservedByAccount(account, address(assetA)), recorded);
        assertEq(custody.reservedByAccount(account, basketToken), IERC20(basketToken).balanceOf(address(diamond)));
    }

    function _assertHookCurrency(PoolId firstPoolId, PoolId secondPoolId, address token) private view {
        Currency currency = Currency.wrap(token);
        assertEq(
            hook.totalLiability(currency),
            hook.accruedFees(firstPoolId, currency) + hook.accruedFees(secondPoolId, currency)
        );
        assertGe(IERC20(token).balanceOf(address(hook)), hook.totalLiability(currency));
    }

    function _assertLpConservation(uint256 basketId) private view {
        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory totals =
            basketLiquidity.cumulativeProtocolLpFees(basketId, address(assetA));
        assertEq(totals.constituentCollected, totals.constituentPolRetained + totals.constituentRevenueDebit);
        assertEq(totals.constituentRevenueDebit, totals.constituentRevenue);
        assertEq(totals.basketTokenCollected, totals.basketTokenPolRetained + totals.basketTokenRevenueDebit);
        assertEq(totals.basketTokenRevenueDebit, totals.basketTokensBurned);
        assertEq(totals.constituentRevenueDebit, Math.mulDiv(totals.constituentCollected, 1_000, 10_000));
        assertEq(totals.basketTokenRevenueDebit, Math.mulDiv(totals.basketTokenCollected, 1_000, 10_000));
        assertGe(totals.constituentPolRetained * 10, totals.constituentCollected * 9);
        assertGe(totals.basketTokenPolRetained * 10, totals.basketTokenCollected * 9);
    }

    function _createSharedBasket(string memory name, string memory symbol)
        private
        returns (uint256 basketId, address basketToken)
    {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0.2 ether),
            redemptionFeeTiers: _singleFeeTier(0.1 ether),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        return baskets.createBasket{value: basketAdmin.creationFee()}(params);
    }

    function _mintPosition(uint256 basketId, uint256 shares) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        assetA.mint(alice, quote[0]);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        (positionId,) = basketRewards.createAndMintBasket(basketId, shares, alice, quote);
        vm.stopPrank();
    }

    function _borrowLiquidity(uint256 basketId, uint256 positionId) private returns (uint256 tokenId) {
        IStaticsBorrowLiquidity.LiquidityParams[] memory pools = new IStaticsBorrowLiquidity.LiquidityParams[](1);
        pools[0] = IStaticsBorrowLiquidity.LiquidityParams({
            asset: address(assetA),
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidity: 5 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            deadline: block.timestamp + 1 hours
        });
        vm.prank(alice);
        (, uint256[] memory tokenIds) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(positionId, basketId, 20 ether, pools, bob);
        return tokenIds[0];
    }

    function _fundHandler(uint256 basketId, address basketToken) private {
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        assetA.mint(alice, quote[0]);
        vm.prank(alice);
        baskets.mint(basketId, 10 ether, address(handler), quote);
        assertEq(IERC20(basketToken).balanceOf(address(handler)), 10 ether);
    }

    function _poolKey(uint256 basketId) private view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(poolManager, address(diamond), uint16(1))
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 1);
        assertEq(address(deployed), expected);
    }
}
