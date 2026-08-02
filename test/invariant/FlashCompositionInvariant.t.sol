// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";
import {FlashArbitrageReceiver, ICanonicalV4SwapRouter} from "../mocks/FlashArbitrageReceiver.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

struct FlashCompositionConfig {
    address diamond;
    address assetA;
    address assetB;
    uint256 firstBasketId;
    uint256 secondBasketId;
    uint256 v4BasketId;
    address firstBasketToken;
    address secondBasketToken;
    address v4BasketToken;
    address poolManager;
    address swapFeeHook;
    address v4Router;
    PoolKey v4Pool;
}

contract FlashCompositionHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IStaticsBasket private immutable baskets;
    IStaticsCustody private immutable custody;
    IStaticsFlashLoan private immutable flashLoans;
    IStaticsGlobalRewards private immutable rewards;
    address private immutable assetA;
    address private immutable assetB;
    uint256 private immutable firstBasketId;
    uint256 private immutable secondBasketId;
    uint256 private immutable v4BasketId;
    address private immutable firstBasketToken;
    address private immutable secondBasketToken;
    address private immutable v4BasketToken;
    bytes32 private immutable firstAccount;
    bytes32 private immutable secondAccount;
    bytes32 private immutable v4Account;
    IPoolManager private immutable poolManager;
    StaticsSwapFeeHook private immutable swapFeeHook;
    PoolKey private v4Pool;

    MockFlashBorrower public immutable receiver;
    MockFlashBorrower public immutable crossBasketReceiver;
    MockFlashBorrower public immutable fundedCrossBasketReceiver;
    FlashArbitrageReceiver public immutable v4Receiver;
    bool public principalRestorationBroken;
    bool public flashFeeRoutingBroken;
    bool public failedRouteChangedBooks;
    bool public siblingBasketChanged;
    bool public crossBasketAccountingBroken;
    bool public v4SuccessObserved;
    bool public v4RouteAccountingBroken;

    constructor(FlashCompositionConfig memory config) {
        baskets = IStaticsBasket(config.diamond);
        custody = IStaticsCustody(config.diamond);
        flashLoans = IStaticsFlashLoan(config.diamond);
        rewards = IStaticsGlobalRewards(config.diamond);
        assetA = config.assetA;
        assetB = config.assetB;
        firstBasketId = config.firstBasketId;
        secondBasketId = config.secondBasketId;
        v4BasketId = config.v4BasketId;
        firstBasketToken = config.firstBasketToken;
        secondBasketToken = config.secondBasketToken;
        v4BasketToken = config.v4BasketToken;
        firstAccount = custody.basketCustodyAccount(config.firstBasketId);
        secondAccount = custody.basketCustodyAccount(config.secondBasketId);
        v4Account = custody.basketCustodyAccount(config.v4BasketId);
        poolManager = IPoolManager(config.poolManager);
        swapFeeHook = StaticsSwapFeeHook(config.swapFeeHook);
        v4Pool = config.v4Pool;
        receiver = new MockFlashBorrower(config.diamond);
        crossBasketReceiver = new MockFlashBorrower(config.diamond);
        fundedCrossBasketReceiver = new MockFlashBorrower(config.diamond);
        v4Receiver = new FlashArbitrageReceiver(config.diamond, ICanonicalV4SwapRouter(config.v4Router));

        MockERC20(config.assetA).mint(address(receiver), 1_000_000 ether);
        MockERC20(config.assetB).mint(address(receiver), 1_000_000 ether);
        crossBasketReceiver.approveProtocol(config.assetA, type(uint256).max);
        crossBasketReceiver.approveProtocol(config.assetB, type(uint256).max);
        MockERC20(config.assetA).mint(address(fundedCrossBasketReceiver), 1_000_000 ether);
        MockERC20(config.assetB).mint(address(fundedCrossBasketReceiver), 1_000_000 ether);
        fundedCrossBasketReceiver.approveProtocol(config.assetA, type(uint256).max);
        fundedCrossBasketReceiver.approveProtocol(config.assetB, type(uint256).max);
    }

    function plainFlash(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1 ether);
        (address[] memory assets,, uint256[] memory fees) = flashLoans.quoteFlashLoan(firstBasketId, shares);
        uint256 vaultABefore = baskets.vaultBalance(firstBasketId, assetA);
        uint256 vaultBBefore = baskets.vaultBalance(firstBasketId, assetB);
        uint256 treasuryABefore = rewards.treasuryAccrued(assetA);
        uint256 treasuryBBefore = rewards.treasuryAccrued(assetB);
        receiver.setRepay(true);
        receiver.setReentryData(bytes(""));
        try receiver.execute(firstBasketId, shares, bytes("plain")) {
            if (
                baskets.vaultBalance(firstBasketId, assetA) != vaultABefore
                    || baskets.vaultBalance(firstBasketId, assetB) != vaultBBefore
            ) principalRestorationBroken = true;
            if (
                rewards.treasuryAccrued(assets[0]) - treasuryABefore != fees[0]
                    || rewards.treasuryAccrued(assets[1]) - treasuryBBefore != fees[1]
            ) flashFeeRoutingBroken = true;
        } catch {
            principalRestorationBroken = true;
        }
    }

    function composedMint(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1 ether);
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(firstBasketId, shares);
        uint256[] memory maximums = baskets.quoteMint(firstBasketId, shares);
        uint256 vaultABefore = baskets.vaultBalance(firstBasketId, assetA);
        uint256 vaultBBefore = baskets.vaultBalance(firstBasketId, assetB);
        receiver.approveProtocol(assetA, type(uint256).max);
        receiver.approveProtocol(assetB, type(uint256).max);
        receiver.setRepay(true);
        receiver.setReentryData(
            abi.encodeCall(IStaticsBasket.mint, (firstBasketId, shares, address(receiver), maximums))
        );
        try receiver.execute(firstBasketId, shares, bytes("mint")) {
            if (
                baskets.vaultBalance(firstBasketId, assetA) != vaultABefore + amounts[0]
                    || baskets.vaultBalance(firstBasketId, assetB) != vaultBBefore + amounts[1]
                    || !receiver.reentrySucceeded()
            ) principalRestorationBroken = true;
        } catch {
            principalRestorationBroken = true;
        }
    }

    function composedRedeem(uint256 rawShares) external {
        uint256 available = IERC20(firstBasketToken).balanceOf(address(receiver));
        if (available < 1e12) return;
        uint256 upper = available < 1 ether ? available : 1 ether;
        uint256 shares = bound(rawShares, 1e12, upper);
        uint256[] memory expectedOut = baskets.quoteRedeem(firstBasketId, shares);
        uint256 vaultABefore = baskets.vaultBalance(firstBasketId, assetA);
        uint256 vaultBBefore = baskets.vaultBalance(firstBasketId, assetB);
        receiver.setRepay(true);
        receiver.setReentryData(
            abi.encodeCall(IStaticsBasket.redeem, (firstBasketId, shares, address(receiver), new uint256[](2)))
        );
        try receiver.execute(firstBasketId, shares, bytes("redeem")) {
            if (
                baskets.vaultBalance(firstBasketId, assetA) != vaultABefore - expectedOut[0]
                    || baskets.vaultBalance(firstBasketId, assetB) != vaultBBefore - expectedOut[1]
                    || !receiver.reentrySucceeded()
            ) principalRestorationBroken = true;
        } catch {
            principalRestorationBroken = true;
        }
    }

    function failedRepayment(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1 ether);
        bytes32 booksBefore = _booksHash(receiver);
        receiver.setReentryData(bytes(""));
        receiver.setRepay(false);
        try receiver.execute(firstBasketId, shares, bytes("underpay")) {
            failedRouteChangedBooks = true;
        } catch {}
        receiver.setRepay(true);
        if (_booksHash(receiver) != booksBefore) failedRouteChangedBooks = true;
    }

    function failedCrossBasketMint(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1 ether);
        uint256[] memory maximums = baskets.quoteMint(secondBasketId, shares);
        bytes32 firstBefore = _basketHash(firstBasketId, firstAccount);
        bytes32 secondBefore = _basketHash(secondBasketId, secondAccount);
        crossBasketReceiver.setRepay(true);
        crossBasketReceiver.setReentryData(
            abi.encodeCall(IStaticsBasket.mint, (secondBasketId, shares, address(crossBasketReceiver), maximums))
        );
        try crossBasketReceiver.execute(firstBasketId, shares, bytes("cross basket")) {
            siblingBasketChanged = true;
        } catch {}
        if (_basketHash(firstBasketId, firstAccount) != firstBefore) failedRouteChangedBooks = true;
        if (_basketHash(secondBasketId, secondAccount) != secondBefore) siblingBasketChanged = true;
        if (
            IERC20(assetA).balanceOf(address(crossBasketReceiver)) != 0
                || IERC20(assetB).balanceOf(address(crossBasketReceiver)) != 0
                || IERC20(secondBasketToken).balanceOf(address(crossBasketReceiver)) != 0
        ) siblingBasketChanged = true;
    }

    function successfulCrossBasketMint(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1 ether);
        uint256[] memory maximums = baskets.quoteMint(secondBasketId, shares);
        uint256 firstABefore = baskets.vaultBalance(firstBasketId, assetA);
        uint256 firstBBefore = baskets.vaultBalance(firstBasketId, assetB);
        uint256 secondABefore = baskets.vaultBalance(secondBasketId, assetA);
        uint256 secondBBefore = baskets.vaultBalance(secondBasketId, assetB);
        fundedCrossBasketReceiver.approveProtocol(assetA, type(uint256).max);
        fundedCrossBasketReceiver.approveProtocol(assetB, type(uint256).max);
        fundedCrossBasketReceiver.setRepay(true);
        fundedCrossBasketReceiver.setReentryData(
            abi.encodeCall(IStaticsBasket.mint, (secondBasketId, shares, address(fundedCrossBasketReceiver), maximums))
        );
        try fundedCrossBasketReceiver.execute(firstBasketId, shares, bytes("funded cross basket")) {
            if (
                !fundedCrossBasketReceiver.reentrySucceeded()
                    || baskets.vaultBalance(firstBasketId, assetA) != firstABefore
                    || baskets.vaultBalance(firstBasketId, assetB) != firstBBefore
                    || baskets.vaultBalance(secondBasketId, assetA) != secondABefore + maximums[0]
                    || baskets.vaultBalance(secondBasketId, assetB) != secondBBefore + maximums[1]
            ) crossBasketAccountingBroken = true;
        } catch {
            crossBasketAccountingBroken = true;
        }
    }

    function successfulV4Redeem(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 0.01 ether, 0.1 ether);
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(v4BasketId, shares);
        try v4Receiver.executeBuyAndRedeem(v4BasketId, shares, v4Pool, amounts[0], 0) {
            v4SuccessObserved = true;
            if (
                v4Receiver.lastProfit(assetA) == 0
                    || custody.reservedByAccount(v4Account, assetA) != baskets.vaultBalance(v4BasketId, assetA)
                    || IERC20(assetA).balanceOf(address(baskets)) < custody.globalReservedByToken(assetA)
            ) v4RouteAccountingBroken = true;
        } catch {}
    }

    function failedV4Redeem(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 0.01 ether, 0.1 ether);
        (, uint256[] memory amounts,) = flashLoans.quoteFlashLoan(v4BasketId, shares);
        bytes32 booksBefore = _v4BooksHash();
        try v4Receiver.executeBuyAndRedeem(v4BasketId, shares, v4Pool, amounts[0], 1_000_000 ether) {
            v4RouteAccountingBroken = true;
        } catch {}
        if (_v4BooksHash() != booksBefore) v4RouteAccountingBroken = true;
    }

    function _booksHash(MockFlashBorrower borrower) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _basketHash(firstBasketId, firstAccount),
                _basketHash(secondBasketId, secondAccount),
                rewards.treasuryAccrued(assetA),
                rewards.treasuryAccrued(assetB),
                IERC20(assetA).balanceOf(address(borrower)),
                IERC20(assetB).balanceOf(address(borrower))
            )
        );
    }

    function _basketHash(uint256 basketId, bytes32 account) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                baskets.vaultBalance(basketId, assetA),
                baskets.vaultBalance(basketId, assetB),
                custody.reservedByAccount(account, assetA),
                custody.reservedByAccount(account, assetB),
                custody.globalReservedByToken(assetA),
                custody.globalReservedByToken(assetB),
                IERC20(assetA).balanceOf(address(baskets)),
                IERC20(assetB).balanceOf(address(baskets))
            )
        );
    }

    function _v4BooksHash() private view returns (bytes32) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(v4Pool.toId());
        return keccak256(
            abi.encode(
                baskets.vaultBalance(v4BasketId, assetA),
                custody.reservedByAccount(v4Account, assetA),
                custody.globalReservedByToken(assetA),
                rewards.treasuryAccrued(assetA),
                rewards.treasuryAccrued(v4BasketToken),
                custody.reservedByAccount(custody.feeCustodyAccount(), v4BasketToken),
                custody.reservedByAccount(custody.stakingCustodyAccount(), v4BasketToken),
                custody.globalReservedByToken(v4BasketToken),
                IERC20(v4BasketToken).balanceOf(address(baskets)),
                IERC20(assetA).balanceOf(address(poolManager)),
                IERC20(v4BasketToken).balanceOf(address(poolManager)),
                IERC20(assetA).balanceOf(address(v4Receiver)),
                IERC20(v4BasketToken).balanceOf(address(v4Receiver)),
                swapFeeHook.lockedLiquidity(v4Pool.toId()),
                sqrtPriceX96,
                tick
            )
        );
    }
}

contract FlashCompositionInvariantTest is StdInvariant, CanonicalPoolTestBase {
    FlashCompositionHandler private handler;
    uint256 private firstBasketId;
    uint256 private secondBasketId;
    address private firstBasketToken;
    address private secondBasketToken;
    uint256 private v4BasketId;
    address private v4BasketToken;
    PoolKey private v4Pool;

    function setUp() public override {
        super.setUp();
        (firstBasketId, firstBasketToken) = _createDefaultBasket(0, 0);
        (secondBasketId, secondBasketToken) = _createDefaultBasket(0, 0);
        _mintSupply(firstBasketId, firstBasketToken, 1_000 ether);
        _mintSupply(secondBasketId, secondBasketToken, 1_000 ether);
        (v4BasketId, v4BasketToken, v4Pool) = _createV4Basket();
        handler = new FlashCompositionHandler(
            FlashCompositionConfig({
                diamond: address(diamond),
                assetA: address(assetA),
                assetB: address(assetB),
                firstBasketId: firstBasketId,
                secondBasketId: secondBasketId,
                v4BasketId: v4BasketId,
                firstBasketToken: firstBasketToken,
                secondBasketToken: secondBasketToken,
                v4BasketToken: v4BasketToken,
                poolManager: address(poolManager),
                swapFeeHook: address(swapFeeHook),
                v4Router: address(v4Router),
                v4Pool: v4Pool
            })
        );
        address compositionReceiver = address(handler.receiver());
        vm.prank(alice);
        IERC20(firstBasketToken).transfer(compositionReceiver, 100 ether);
        handler.successfulV4Redeem(0.05 ether);
        assertTrue(handler.v4SuccessObserved());
        targetContract(address(handler));
    }

    function invariantPhysicalBalancesCoverGlobalReservations() public view {
        assertGe(assetA.balanceOf(address(diamond)), custody.globalReservedByToken(address(assetA)));
        assertGe(assetB.balanceOf(address(diamond)), custody.globalReservedByToken(address(assetB)));
        assertGe(IERC20(firstBasketToken).balanceOf(address(diamond)), custody.globalReservedByToken(firstBasketToken));
        assertGe(
            IERC20(secondBasketToken).balanceOf(address(diamond)), custody.globalReservedByToken(secondBasketToken)
        );
        assertGe(IERC20(v4BasketToken).balanceOf(address(diamond)), custody.globalReservedByToken(v4BasketToken));
    }

    function invariantBasketAccountsMatchVaultAndRecoveryBooks() public view {
        _assertBasketAccount(firstBasketId);
        _assertBasketAccount(secondBasketId);
        _assertBasketAccount(v4BasketId);
    }

    function invariantSuccessfulFlashAccountingRemainsExact() public view {
        assertFalse(handler.principalRestorationBroken());
        assertFalse(handler.flashFeeRoutingBroken());
    }

    function invariantFailedRoutesRemainAtomicAndBasketIsolated() public view {
        assertFalse(handler.failedRouteChangedBooks());
        assertFalse(handler.siblingBasketChanged());
        assertFalse(handler.crossBasketAccountingBroken());
        assertFalse(handler.v4RouteAccountingBroken());
        assertTrue(handler.v4SuccessObserved());
    }

    function _assertBasketAccount(uint256 basketId) private view {
        bytes32 account = custody.basketCustodyAccount(basketId);
        assertEq(custody.reservedByAccount(account, address(assetA)), baskets.vaultBalance(basketId, address(assetA)));
        assertEq(custody.reservedByAccount(account, address(assetB)), baskets.vaultBalance(basketId, address(assetB)));
    }

    function _mintSupply(uint256 basketId, address basketToken, uint256 shares) private {
        uint256[] memory maximums = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, maximums[0], maximums[1]);
        vm.prank(alice);
        baskets.mint(basketId, shares, alice, maximums);
        assertEq(IERC20(basketToken).balanceOf(alice), shares);
    }

    function _createV4Basket() private returns (uint256 basketId, address basketToken, PoolKey memory pool) {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1.5 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Invariant V4 Basket",
            symbol: "iv4",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0.01 ether),
            redemptionFeeTiers: _singleFeeTier(0.01 ether),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (IStaticsBasket.PoolLaunchParams[] memory launchPools, uint256[] memory launchMaximums) =
            _fundDefaultLaunch(assets, alice);
        vm.prank(alice);
        (basketId, basketToken) = baskets.createBasket{value: 1 ether}(params, launchPools, launchMaximums, type(uint256).max);
        uint256[] memory maximums = baskets.quoteMint(basketId, 100 ether);
        assetA.mint(alice, maximums[0] + 100 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        assetA.approve(address(v4Router), type(uint256).max);
        baskets.mint(basketId, 100 ether, alice, maximums);
        IERC20(basketToken).approve(address(v4Router), type(uint256).max);
        vm.stopPrank();

        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        pool = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
        vm.prank(alice);
        v4Router.modifyLiquidity(
            pool,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(configured.tickSpacing),
                tickUpper: TickMath.maxUsableTick(configured.tickSpacing),
                liquidityDelta: 40 ether,
                salt: bytes32(0)
            })
        );
    }
}
