// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IPendleMarket, IPendleSY, RobinhoodPendleForkBase} from "../../helpers/RobinhoodPendleForkBase.sol";

/// @notice Proves live Pendle PTs compose as generic fee-bearing Statics constituents.
///
///   NVDA -> SY-NVDA -> PT-NVDA -> sPT-NVDA
///
///   equal USDG value of PT-NVDA + PT-PFE + PT-SGOV -> sTERM
///
/// Statics custody never calls a Pendle-specific interface. Pendle look-through data remains
/// available to UI/periphery code through each market and SY adapter.
contract RobinhoodPendleBasketForkTest is RobinhoodPendleForkBase {
    using Math for uint256;

    uint256 private wrapperLaunchGas;
    uint256 private termLaunchGas;

    struct AssetBooks {
        uint256 user;
        uint256 vault;
        uint256 basketReserve;
        uint256 feeReserve;
        uint256 globalReserve;
        uint256 treasury;
        uint256 diamondBalance;
    }

    struct BasketBooks {
        uint256 supply;
        uint256 userShares;
        AssetBooks[3] assets;
    }

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();

        uint256 gasBefore = gasleft();
        _launchPtWrapper(2 ether);
        wrapperLaunchGas = gasBefore - gasleft();

        gasBefore = gasleft();
        _launchTermBasket(2 ether);
        termLaunchGas = gasBefore - gasleft();
    }

    function testLivePendlePtsCreateCanonicalStaticsBaskets() public {
        IStaticsBasket.BasketView memory wrapper = baskets.basket(wrapperBasketId);
        assertEq(wrapper.token, wrapperBasketToken);
        assertEq(wrapper.assets.length, 1);
        assertEq(wrapper.assets[0], PT_NVDA);
        assertEq(wrapper.bundleAmounts[0], 1 ether);
        _assertCanonicalPool(wrapperBasketId, wrapperBasketToken, PT_NVDA);

        IStaticsBasket.BasketView memory term = baskets.basket(termBasketId);
        assertEq(term.token, termBasketToken);
        assertEq(term.assets, _termPts());
        assertEq(term.bundleAmounts, _termBundleVector());
        assertEq(term.loanDuration, TERM_LOAN_DURATION);
        for (uint256 i; i < 3; ++i) {
            _assertCanonicalPool(termBasketId, termBasketToken, term.assets[i]);
            assertNotEq(term.assets[i], _termMarket(i).market);
        }

        emit log("PT-NVDA -> 1:1 Statics wrapper; three live PTs -> equal-dollar sTERM");
        emit log_named_uint("sPT-NVDA launch gas", wrapperLaunchGas);
        emit log_named_uint("sTERM launch gas", termLaunchGas);
    }

    function testFeeBearingTermBasketMintsAndRedeemsThroughGenericCustody() public {
        uint256 shares = 2 ether;
        BasketBooks memory beforeAction = _snapshot();
        uint256[] memory mintQuote = baskets.quoteMint(termBasketId, shares);
        uint256 mintGas = _mint(shares, mintQuote);
        _assertMint(beforeAction, shares, mintQuote);

        uint256[] memory redeemQuote = baskets.quoteRedeem(termBasketId, shares);
        uint256 redeemGas = _redeem(shares, redeemQuote);
        _assertRoundTrip(beforeAction, mintQuote, redeemQuote);

        emit log("Generic custody round trip: PT vector -> sTERM -> same PT vector, less configured fees");
        emit log_named_uint("sTERM mint gas", mintGas);
        emit log_named_uint("sTERM redeem gas", redeemGas);
    }

    function testPendleLookThroughAndEqualDollarCompositionRemainExternal() public {
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            (address sy, address pt, address yt) = IPendleMarket(configured.market).readTokens();
            assertEq(sy, configured.sy);
            assertEq(pt, configured.pt);
            assertEq(yt, configured.yt);
            assertTrue(IPendleSY(sy).isValidTokenOut(configured.underlying));
            assertGt(IPendleSY(sy).exchangeRate(), 0);
            assertGt(IPendleMarket(configured.market).expiry(), block.timestamp + TERM_LOAN_DURATION);

            uint256 usdgValue = _quotePtUsdg(i, termBundles[i]);
            assertApproxEqRel(usdgValue, TERM_COMPONENT_USDG, 0.03 ether);
            emit log_named_address("Statics PT constituent", pt);
            emit log_named_address("Pendle market", configured.market);
            emit log_named_address("Pendle SY underlying", configured.underlying);
            emit log_named_uint("PT units per sTERM share", termBundles[i]);
            emit log_named_uint("Pinned USDG quote", usdgValue);
        }
    }

    function _mint(uint256 shares, uint256[] memory quote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.mint(termBasketId, shares, alice, quote);
        executionGas = gasBefore - gasleft();
    }

    function _redeem(uint256 shares, uint256[] memory quote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.redeem(termBasketId, shares, alice, quote);
        executionGas = gasBefore - gasleft();
    }

    function _snapshot() private view returns (BasketBooks memory snapshot) {
        snapshot.supply = IERC20(termBasketToken).totalSupply();
        snapshot.userShares = IERC20(termBasketToken).balanceOf(alice);
        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            snapshot.assets[i] = AssetBooks({
                user: IERC20(pt).balanceOf(alice),
                vault: baskets.vaultBalance(termBasketId, pt),
                basketReserve: custody.reservedByAccount(basketAccount, pt),
                feeReserve: custody.reservedByAccount(feeAccount, pt),
                globalReserve: custody.globalReservedByToken(pt),
                treasury: globalRewards.treasuryAccrued(pt),
                diamondBalance: IERC20(pt).balanceOf(address(diamond))
            });
        }
    }

    function _assertMint(BasketBooks memory beforeAction, uint256 shares, uint256[] memory quote) private view {
        assertEq(IERC20(termBasketToken).totalSupply(), beforeAction.supply + shares);
        assertEq(IERC20(termBasketToken).balanceOf(alice), beforeAction.userShares + shares);
        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            uint256 principal = Math.mulDiv(termBundles[i], shares, SHARE_SCALE);
            uint256 fee = quote[i] - principal;
            AssetBooks memory prior = beforeAction.assets[i];
            assertGt(fee, 0);
            assertEq(IERC20(pt).balanceOf(alice), prior.user - quote[i]);
            assertEq(baskets.vaultBalance(termBasketId, pt), prior.vault + principal);
            assertEq(custody.reservedByAccount(basketAccount, pt), prior.basketReserve + principal);
            assertEq(custody.reservedByAccount(feeAccount, pt), prior.feeReserve + fee);
            assertEq(custody.globalReservedByToken(pt), prior.globalReserve + quote[i]);
            assertEq(globalRewards.treasuryAccrued(pt), prior.treasury + fee);
            assertEq(IERC20(pt).balanceOf(address(diamond)), prior.diamondBalance + quote[i]);
        }
    }

    function _assertRoundTrip(BasketBooks memory beforeAction, uint256[] memory mintQuote, uint256[] memory redeemQuote)
        private
        view
    {
        assertEq(IERC20(termBasketToken).totalSupply(), beforeAction.supply);
        assertEq(IERC20(termBasketToken).balanceOf(alice), beforeAction.userShares);
        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            uint256 principal = Math.mulDiv(termBundles[i], 2 ether, SHARE_SCALE);
            uint256 totalFees = mintQuote[i] - principal + principal - redeemQuote[i];
            AssetBooks memory prior = beforeAction.assets[i];
            assertGt(totalFees, 0);
            assertEq(IERC20(pt).balanceOf(alice), prior.user - totalFees);
            assertEq(baskets.vaultBalance(termBasketId, pt), prior.vault);
            assertEq(custody.reservedByAccount(basketAccount, pt), prior.basketReserve);
            assertEq(custody.reservedByAccount(feeAccount, pt), prior.feeReserve + totalFees);
            assertEq(custody.globalReservedByToken(pt), prior.globalReserve + totalFees);
            assertEq(globalRewards.treasuryAccrued(pt), prior.treasury + totalFees);
            assertEq(IERC20(pt).balanceOf(address(diamond)), prior.diamondBalance + totalFees);
            assertEq(IERC20(pt).balanceOf(address(diamond)), custody.globalReservedByToken(pt));
        }
    }
}
