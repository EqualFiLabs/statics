// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GenesisPurchaseQuote, GenesisRedemptionQuote} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {FormalForceNative, FormalGenesisEnvironment} from "./mocks/FormalGenesisMocks.sol";

contract StaticsGenesisVaultHalmosTest is SymTest, FormalGenesisEnvironment {
    address private alice;
    address private nextGovernor;

    function setUp() public {
        alice = makeAddr("formalAlice");
        nextGovernor = makeAddr("formalNextGovernor");
        _deployGenesis(block.timestamp + 7 days);
    }

    /// @dev A uint96 reserve exceeds the native currency that can economically
    ///      exist while keeping symbolic division tractable for the solver.
    function check_epochBoundaryQuotes(uint96 reserve) public {
        _donate(reserve);
        GenesisPurchaseQuote memory duringPurchase = vault.quoteGenesisPurchase();
        GenesisRedemptionQuote memory duringRedemption = vault.quoteGenesisRedemption();
        assertTrue(duringPurchase.epochActive);
        assertEq(duringPurchase.reserveBuyIn, 0);
        assertEq(duringPurchase.nativeFee, 0);
        assertEq(duringPurchase.requiredNative, 0);
        assertTrue(duringRedemption.epochActive);
        assertEq(duringRedemption.reservePayout, 0);

        vm.warp(vault.genesisEpochEnd());
        GenesisPurchaseQuote memory afterPurchase = vault.quoteGenesisPurchase();
        GenesisRedemptionQuote memory afterRedemption = vault.quoteGenesisRedemption();
        uint256 expectedBuyIn = (uint256(reserve) + 5_553) / 5_554;
        assertFalse(afterPurchase.epochActive);
        assertEq(afterPurchase.reserveBuyIn, expectedBuyIn);
        assertEq(afterPurchase.nativeFee, vault.nativeAcquisitionFee());
        assertEq(afterPurchase.requiredNative, expectedBuyIn + vault.nativeAcquisitionFee());
        assertFalse(afterRedemption.epochActive);
        assertEq(afterRedemption.reservePayout, uint256(reserve) / 5_555);
    }

    function check_acquisitionAndRedemptionPreserveSolvency(uint96 reserve, uint96 excessNative) public {
        _donate(reserve);
        vm.warp(vault.genesisEpochEnd());
        uint256 requiredNative = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
        vm.deal(address(this), requiredNative + excessNative);
        vault.buyGenesis{value: requiredNative + excessNative}(1, alice);
        _assertSolvent();
        assertEq(vault.tokenBacking(), vault.GENESIS_PRICE());
        assertEq(vault.circulatingGenesis(), 1);

        uint256 reserveBefore = vault.reserveETH();
        uint256 expectedPayout = reserveBefore / vault.RESERVE_DENOMINATOR();
        vm.startPrank(alice);
        genesis.approve(address(vault), 1);
        vault.redeemGenesis(1, alice);
        vm.stopPrank();
        assertEq(vault.reserveETH(), reserveBefore - expectedPayout);
        assertEq(vault.tokenBacking(), 0);
        assertEq(vault.circulatingGenesis(), 0);
        _assertSolvent();
    }

    function check_directGenesisReturnOnlyOvercollateralizes(uint96 reserve) public {
        _donate(reserve);
        _acquire(1, alice);
        assertEq(vault.tokenBacking(), vault.requiredBacking());
        vm.prank(alice);
        genesis.transferFrom(alice, address(vault), 1);
        assertEq(vault.circulatingGenesis(), 0);
        assertEq(vault.requiredBacking(), 0);
        assertEq(vault.tokenBacking(), vault.GENESIS_PRICE());
        _assertSolvent();
    }

    function check_forcedNativeNeverBecomesAccountedReserve(uint96 donation, uint96 forcedAmount) public {
        _donate(donation);
        uint256 reserveBefore = vault.reserveETH();
        uint256 custodyBefore = address(vault).balance;
        vm.deal(address(this), forcedAmount);
        new FormalForceNative{value: forcedAmount}(payable(address(vault)));
        assertEq(vault.reserveETH(), reserveBefore);
        assertEq(address(vault).balance, custodyBefore + forcedAmount);
        _assertSolvent();
    }

    function check_governanceTransitionsCannotReduceCustody(uint96 reserve, uint96 fee) public {
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
