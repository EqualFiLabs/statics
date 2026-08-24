// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GenesisPurchaseQuote, GenesisRedemptionQuote} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {FormalGenesisEnvironment} from "./mocks/FormalGenesisMocks.sol";

contract StaticsGenesisVaultHalmosTest is SymTest, FormalGenesisEnvironment {
    address private alice;
    address private nextGovernor;

    function setUp() public {
        alice = makeAddr("formalAlice");
        nextGovernor = makeAddr("formalNextGovernor");
        _deployGenesis(block.timestamp + 7 days);
    }

    receive() external payable {}

    /// @dev A uint88 reserve exceeds the native currency that can economically
    ///      exist while keeping symbolic division tractable for the solver.
    function check_epochQuotesDuring(uint88 reserve) public {
        _donate(reserve);
        GenesisPurchaseQuote memory duringPurchase = vault.quoteGenesisPurchase();
        GenesisRedemptionQuote memory duringRedemption = vault.quoteGenesisRedemption();
        assertTrue(duringPurchase.epochActive);
        assertEq(duringPurchase.reserveBuyIn, 0);
        assertEq(duringPurchase.nativeFee, 0);
        assertEq(duringPurchase.requiredNative, 0);
        assertTrue(duringRedemption.epochActive);
        assertEq(duringRedemption.reservePayout, 0);
    }

    /// @dev Foundry regression beside Certora's full-width arithmetic rule.
    function testFuzz_epochPurchaseQuoteAfter(uint64 quotient, uint16 remainder) public {
        vm.assume(remainder < 5_554);
        uint256 reserve = uint256(quotient) * 5_554 + remainder;
        _donate(reserve);
        vm.warp(vault.genesisEpochEnd());
        GenesisPurchaseQuote memory afterPurchase = vault.quoteGenesisPurchase();
        assertFalse(afterPurchase.epochActive);
        assertEq(afterPurchase.nativeFee, vault.nativeAcquisitionFee());
        assertEq(afterPurchase.requiredNative, afterPurchase.reserveBuyIn + vault.nativeAcquisitionFee());
        uint256 expectedBuyIn = uint256(quotient) + (remainder == 0 ? 0 : 1);
        assertEq(afterPurchase.reserveBuyIn, expectedBuyIn);
    }

    function testFuzz_epochRedemptionQuoteAfter(uint64 quotient, uint16 remainder) public {
        vm.assume(remainder < 5_555);
        uint256 reserve = uint256(quotient) * 5_555 + remainder;
        _donate(reserve);
        vm.warp(vault.genesisEpochEnd());
        GenesisRedemptionQuote memory afterRedemption = vault.quoteGenesisRedemption();
        assertFalse(afterRedemption.epochActive);
        assertEq(afterRedemption.reservePayout, quotient);
    }

    function check_acquisitionAndRedemptionPreserveSolvency(uint88 reserve, uint88 excessNative) public {
        uint256 backingBefore = vault.tokenBacking();
        uint256 circulatingBefore = vault.circulatingGenesis();
        _donate(reserve);
        vm.warp(vault.genesisEpochEnd());
        uint256 requiredNative = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
        vm.deal(address(this), requiredNative + excessNative);
        vault.buyGenesis{value: requiredNative + excessNative}(1, alice);
        _assertSolvent();
        assertEq(vault.tokenBacking(), backingBefore + vault.GENESIS_PRICE());
        assertEq(vault.circulatingGenesis(), circulatingBefore + 1);

        uint256 reserveBefore = vault.reserveETH();
        uint256 expectedPayout = reserveBefore / vault.RESERVE_DENOMINATOR();
        vm.startPrank(alice);
        genesis.approve(address(vault), 1);
        vault.redeemGenesis(1, alice);
        vm.stopPrank();
        assertEq(vault.reserveETH(), reserveBefore - expectedPayout);
        assertEq(vault.tokenBacking(), backingBefore);
        assertEq(vault.circulatingGenesis(), circulatingBefore);
        _assertSolvent();
    }

    function check_directGenesisReturnOnlyOvercollateralizes(uint88 reserve) public {
        uint256 backingBefore = vault.tokenBacking();
        uint256 requiredBefore = vault.requiredBacking();
        _donate(reserve);
        _acquire(1, alice);
        assertEq(vault.tokenBacking(), vault.requiredBacking());
        vm.prank(alice);
        genesis.transferFrom(alice, address(vault), 1);
        assertEq(vault.circulatingGenesis(), 0);
        assertEq(vault.requiredBacking(), requiredBefore);
        assertEq(vault.tokenBacking(), backingBefore + vault.GENESIS_PRICE());
        _assertSolvent();
    }

    function check_forcedNativeNeverBecomesAccountedReserve(uint96 donation, uint96 forcedAmount) public {
        _donate(donation);
        uint256 reserveBefore = vault.reserveETH();
        uint256 custodyBefore = address(vault).balance;
        vm.deal(address(vault), custodyBefore + forcedAmount);
        assertEq(vault.reserveETH(), reserveBefore);
        assertEq(address(vault).balance, custodyBefore + forcedAmount);
        _assertSolvent();
    }

    function check_governanceTransitionsCannotReduceCustody(uint88 reserve, uint96 fee) public {
        vm.assume(fee <= vault.MAX_NATIVE_ACQUISITION_FEE());
        _donate(reserve);
        uint256 tokenCustody = statics.balanceOf(address(vault));
        uint256 nativeCustody = address(vault).balance;
        uint256 accountedReserve = vault.reserveETH();

        vault.setPurchasesPaused(true);
        vault.setNativeAcquisitionFee(fee);
        vault.transferOwnership(nextGovernor);
        vm.prank(nextGovernor);
        vault.acceptOwnership();

        assertEq(statics.balanceOf(address(vault)), tokenCustody);
        assertEq(address(vault).balance, nativeCustody);
        assertEq(vault.reserveETH(), accountedReserve);
        _assertSolvent();
    }

    function _donate(uint256 amount) private {
        if (amount == 0) return;
        vm.deal(address(this), amount);
        vault.donate{value: amount}();
    }

    function _assertSolvent() private view {
        assertGe(vault.tokenBacking(), vault.circulatingGenesis() * vault.GENESIS_PRICE());
        assertGe(statics.balanceOf(address(vault)), vault.tokenBacking());
        assertGe(address(vault).balance, vault.reserveETH());
    }
}
