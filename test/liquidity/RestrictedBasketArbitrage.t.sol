// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketArbitrage} from "../../src/interfaces/IStaticsBasketArbitrage.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsFlashArbitrageReceiver} from "../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract RestrictedBasketArbitrageTest is CanonicalPoolTestBase {
    struct Fixture {
        uint256 basketId;
        address token;
        address nested;
        PoolKey[] pools;
    }

    function testMintAndSellSettlesRestrictedTopUpsAndProfitWithoutSpendingOldBalances() public {
        Fixture memory f = _fixture(false);
        StaticsFlashArbitrageReceiver receiver = _receiver();
        _donateNested(f, receiver);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 0.5 ether;
        uint256[] memory minima = new uint256[](2);
        minima[0] = 0.01 ether;
        minima[1] = 0.01 ether;
        uint256 nestedBefore = IERC20(f.nested).balanceOf(alice);
        uint256 assetBefore = assetA.balanceOf(alice);
        vm.startPrank(alice);
        assetA.approve(address(receiver), type(uint256).max);
        IERC20(f.nested).approve(address(diamond), type(uint256).max);
        (address[] memory assets, uint256[] memory profits) =
            receiver.executeMintAndSell(f.basketId, 1 ether, f.pools, amounts, minima, block.timestamp);
        vm.stopPrank();
        _assertReturns(f, receiver, assets, profits, nestedBefore, assetBefore);
    }

    function testBuyAndRedeemSettlesRestrictedProfitWithoutSpendingOldBalances() public {
        Fixture memory f = _fixture(true);
        StaticsFlashArbitrageReceiver receiver = _receiver();
        _donateNested(f, receiver);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 0.5 ether;
        uint256[] memory minima = new uint256[](2);
        minima[0] = 0.01 ether;
        minima[1] = 0.01 ether;
        uint256 nestedBefore = IERC20(f.nested).balanceOf(alice);
        uint256 assetBefore = assetA.balanceOf(alice);
        vm.prank(alice);
        (address[] memory assets, uint256[] memory profits) =
            receiver.executeBuyAndRedeem(f.basketId, 1 ether, f.pools, amounts, minima, block.timestamp);
        _assertReturns(f, receiver, assets, profits, nestedBefore, assetBefore);
    }

    function testUnregisteredReceiverAndOutOfScopeSettlementCannotMoveRestrictedTokens() public {
        Fixture memory f = _fixture(false);
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 0.5 ether;
        vm.prank(alice);
        vm.expectRevert();
        receiver.executeMintAndSell(f.basketId, 1 ether, f.pools, amounts, new uint256[](2), block.timestamp);
        receiver = _receiver();
        vm.prank(address(receiver));
        vm.expectRevert();
        IStaticsBasketArbitrage(address(diamond)).settleBasketArbitrageOutput(f.nested, alice, 1);
        vm.prank(bob);
        vm.expectRevert();
        IStaticsBasketArbitrage(address(diamond)).beginBasketArbitrage(f.basketId, 1 ether, alice);
        assertEq(IERC20(f.nested).balanceOf(address(receiver)), 0);
    }

    function testProfitBoundFailureRollsBackRestrictedTopUpsAndAuthorizations() public {
        Fixture memory f = _fixture(false);
        StaticsFlashArbitrageReceiver receiver = _receiver();
        _donateNested(f, receiver);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 0.5 ether;
        uint256[] memory minima = new uint256[](2);
        minima[0] = 100 ether;
        minima[1] = 100 ether;
        uint256 beforeBalance = IERC20(f.nested).balanceOf(alice);
        vm.startPrank(alice);
        assetA.approve(address(receiver), type(uint256).max);
        IERC20(f.nested).approve(address(diamond), type(uint256).max);
        vm.expectRevert();
        receiver.executeMintAndSell(f.basketId, 1 ether, f.pools, amounts, minima, block.timestamp);
        vm.stopPrank();
        assertEq(IERC20(f.nested).balanceOf(alice), beforeBalance);
        assertEq(IERC20(f.nested).balanceOf(address(receiver)), 0.2 ether);
        vm.prank(address(receiver));
        vm.expectRevert();
        IStaticsBasketArbitrage(address(diamond)).settleBasketArbitrageOutput(f.nested, alice, 1);
    }

    function testScopedTicketsRejectWrongExecutorReplayAndPreexistingBalance() public {
        this.checkScopedSettlementFailures();
    }

    /// @dev Impersonate the immutable receiver only to reach invalid callback arguments its production code
    /// cannot produce. The two successful NAV tests above cover the real value-moving entrypoints.
    function checkScopedSettlementFailures() external {
        Fixture memory f = _fixture(false);
        StaticsFlashArbitrageReceiver receiver = _receiver();
        _donateNested(f, receiver);
        IStaticsBasketArbitrage arb = IStaticsBasketArbitrage(address(diamond));
        (address[] memory assets, uint256[] memory principal,) = flashLoans.quoteFlashLoan(f.basketId, 1 ether);
        uint256[] memory quote = baskets.quoteMint(f.basketId, 1 ether);
        uint256 amount;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == f.nested) amount = quote[i] - principal[i];
        }
        assertGt(amount, 0);
        vm.prank(alice);
        IERC20(f.nested).approve(address(diamond), amount);
        vm.startPrank(address(receiver));
        arb.beginBasketArbitrage(f.basketId, 1 ether, alice);
        vm.expectRevert();
        arb.settleBasketArbitrageInput(f.nested, bob, amount);
        vm.expectRevert();
        arb.settleBasketArbitrageInput(address(assetB), alice, amount);
        vm.expectRevert();
        arb.settleBasketArbitrageInput(f.nested, alice, amount + 1);
        arb.settleBasketArbitrageInput(f.nested, alice, amount);
        vm.expectRevert();
        arb.settleBasketArbitrageInput(f.nested, alice, 1);
        IERC20(f.nested).approve(address(diamond), type(uint256).max);
        vm.expectRevert();
        arb.settleBasketArbitrageOutput(f.nested, bob, amount);
        vm.expectRevert();
        arb.settleBasketArbitrageOutput(f.nested, alice, amount + 1);
        arb.settleBasketArbitrageOutput(f.nested, alice, amount);
        IERC20(f.nested).approve(address(diamond), 0);
        arb.endBasketArbitrage();
        vm.expectRevert();
        arb.settleBasketArbitrageOutput(f.nested, alice, 1);
        vm.stopPrank();
        assertEq(IERC20(f.nested).balanceOf(address(receiver)), 0.2 ether);
    }

    function _assertReturns(
        Fixture memory f,
        StaticsFlashArbitrageReceiver receiver,
        address[] memory assets,
        uint256[] memory profits,
        uint256 nestedBefore,
        uint256 assetBefore
    ) private view {
        for (uint256 i; i < assets.length; ++i) {
            assertGt(profits[i], 0);
            if (assets[i] == f.nested) assertEq(IERC20(f.nested).balanceOf(alice), nestedBefore + profits[i]);
            else assertEq(assetA.balanceOf(alice), assetBefore + profits[i]);
        }
        assertEq(IERC20(f.nested).balanceOf(address(receiver)), 0.2 ether);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(IERC20(f.token).balanceOf(address(receiver)), 0);
        assertEq(IERC20(f.nested).allowance(address(receiver), address(diamond)), 0);
        assertGe(IERC20(f.nested).balanceOf(address(diamond)), custody.globalReservedByToken(f.nested));
    }

    function _receiver() private returns (StaticsFlashArbitrageReceiver receiver) {
        IStaticsBasketArbitrage arb = IStaticsBasketArbitrage(address(diamond));
        address deployed = arb.deployBasketArbitrageReceiver();
        assertEq(arb.deployBasketArbitrageReceiver(), deployed);
        assertLe(deployed.code.length, 24_576);
        receiver = StaticsFlashArbitrageReceiver(deployed);
    }

    function _donateNested(Fixture memory f, StaticsFlashArbitrageReceiver receiver) private {
        (uint256 id,) = baskets.basketIdOf(f.nested);
        uint256[] memory quote = baskets.quoteMint(id, 0.2 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(id, 0.2 ether, address(receiver), quote);
    }

    function _fixture(bool underpriced) private returns (Fixture memory f) {
        (uint256 innerId, address inner) = _createDefaultBasket(0, 0);
        uint256[] memory innerQuote = baskets.quoteMint(innerId, 1_000 ether);
        _fundAndApprove(alice, innerQuote[0], innerQuote[1]);
        vm.prank(alice);
        baskets.mint(innerId, 1_000 ether, alice, innerQuote);
        _fundAndApprove(alice, 10_000 ether, 10_000 ether);
        f.nested = inner;
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0.01 ether, 0.01 ether);
        params.assets[0] = address(assetA);
        params.assets[1] = inner;
        params.bundleAmounts[0] = underpriced ? 1.5 ether : 0.4 ether;
        params.bundleAmounts[1] = params.bundleAmounts[0];
        _ensureTestBasketSalts(_localBasketFactory, 2);
        IStaticsBasket.PoolLaunchParams[] memory launch = _defaultPoolLaunchParams(2);
        uint256[] memory maximums = _defaultLaunchMaximums(2);
        vm.startPrank(alice);
        IERC20(inner).approve(address(diamond), type(uint256).max);
        (f.basketId, f.token) = baskets.createBasket{value: 1 ether}(params, launch, maximums, type(uint256).max);
        uint256[] memory quote = baskets.quoteMint(f.basketId, 100 ether);
        baskets.mint(f.basketId, 100 ether, alice, quote);
        f.pools = new PoolKey[](2);
        IStaticsProtocolPools protocol = IStaticsProtocolPools(address(diamond));
        for (uint256 i; i < 2; ++i) {
            f.pools[i] = protocol.protocolPool(basketLiquidity.canonicalPool(f.basketId, params.assets[i]).poolId).key;
            IERC20(params.assets[i]).approve(address(v4Router), type(uint256).max);
            IERC20(f.token).approve(address(v4Router), type(uint256).max);
            v4Router.modifyLiquidity(
                f.pools[i],
                ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 40 ether, bytes32(0))
            );
        }
        vm.stopPrank();
    }
}
