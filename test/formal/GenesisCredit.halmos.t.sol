// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {
    GenesisCreditConfig,
    GenesisCreditRecoveryQuote,
    GenesisCreditView
} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {FormalFeeSource, FormalToken, FormalWrappedNative} from "./mocks/FormalGenesisMocks.sol";

contract GenesisCreditRepresentativeTest is Test {
    uint256 private constant ORIGINATION_FEE = 10_001 wei;
    uint256 private constant EXTENSION_FEE = 20_003 wei;

    FormalToken private statics;
    FormalWrappedNative private weth;
    FormalFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private registry;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;
    StaticsTreasuryVesting private vesting;
    GenesisLaunchDistributor private distributor;
    address private treasury;
    address private alice;
    address private bob;
    address private keeper;

    function setUp() public {
        treasury = makeAddr("formalCreditTreasury");
        alice = makeAddr("formalCreditAlice");
        bob = makeAddr("formalCreditBob");
        keeper = makeAddr("formalCreditKeeper");
        statics = new FormalToken("Formal STATICS", "FSTATICS");
        weth = new FormalWrappedNative();
        feeSource = new FormalFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(weth), address(this));
        feeSource.configure(statics, weth, address(feeReceiver));
        feeReceiver.bindMarket(address(statics), keccak256("formal-credit-pool"));

        vesting = new StaticsTreasuryVesting(address(this), address(this), treasury);
        statics.mint(address(vesting), 200_000_000 ether);
        statics.mint(makeAddr("formalCreditDopplerInventory"), 800_000_000 ether);
        registry = new GenesisActivationRegistry(statics, address(this), address(this), treasury);
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: ORIGINATION_FEE,
            extensionFee: EXTENSION_FEE,
            recoveryCallerShareBps: 2_000
        });
        vault =
            new StaticsGenesisVault(statics, address(vesting), address(this), block.timestamp + 1 days, creditConfig);
        genesis = new StaticsGenesis(
            address(vault),
            address(vesting),
            address(registry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            address(this),
            treasury,
            "ipfs://formal-credit/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vesting.finalizeBootstrap(address(statics), address(vault), address(genesis));
        feeReceiver.bindReserveVault(address(vault));
        distributor = new GenesisLaunchDistributor(feeReceiver, genesis, registry, treasury, address(this), 7_500);
        feeReceiver.proposeDistributor(address(distributor));
        distributor.acceptFeeReceiverRole();
        registry.proposeConsumer(address(distributor));
        distributor.acceptActivationConsumer();

        statics.mint(alice, 600_000 ether);
        statics.mint(bob, 600_000 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.startPrank(alice);
        statics.approve(address(vault), type(uint256).max);
        vault.buyGenesis{value: vault.quoteGenesisPurchase().requiredNative}(1, alice);
        distributor.registerGenesis(1);
        vm.stopPrank();
        vm.startPrank(bob);
        statics.approve(address(vault), type(uint256).max);
        vault.buyGenesis{value: vault.quoteGenesisPurchase().requiredNative}(2, bob);
        distributor.registerGenesis(2);
        vm.stopPrank();
        vm.warp(vault.genesisEpochEnd());
    }

    function testCreditLifecycleRepresentative() public {
        check_openAndRepayAreExactInverses(90_000 ether);
    }

    function testCreditExtensionRepresentative() public {
        check_extensionOnlyChangesMaturityAndFeeAccounting(90_000 ether);
    }

    function testCreditPrincipalAdjustmentRepresentative() public {
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        uint256 backingBefore = vault.tokenBacking();
        uint256 outstandingBefore = vault.totalOutstandingGenesisCredit();
        uint256 aliceBefore = statics.balanceOf(alice);

        vm.prank(alice);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(1, 120_000 ether);
        assertEq(vault.credit(1).principal, 120_000 ether);
        assertEq(vault.tokenBacking(), backingBefore - 20_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), outstandingBefore + 20_000 ether);
        assertEq(statics.balanceOf(alice), aliceBefore + 20_000 ether);

        vm.startPrank(alice);
        statics.approve(address(vault), 70_000 ether);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(1, 50_000 ether);
        vm.stopPrank();
        assertEq(vault.credit(1).principal, 50_000 ether);
        assertEq(vault.tokenBacking(), backingBefore + 50_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), outstandingBefore - 50_000 ether);

        vm.prank(alice);
        statics.approve(address(vault), 50_000 ether);
        vm.prank(alice);
        vault.repayGenesisCredit(1, 50_000 ether);
        assertFalse(vault.creditActive(1));
    }

    function testCreditRecoveryRepresentative() public {
        check_recoveryConservesResidualAndRemovesWeightBeforeIndexing(90_000 ether);
    }

    function testCreditFeeSplitRepresentative() public {
        check_governedFeeSplitAlwaysConservesExactFee(1_000);
    }

    function check_openAndRepayAreExactInverses(uint256 principal) public {
        vm.assume(principal <= type(uint96).max);
        vm.assume(principal > 0 && principal <= vault.MAX_CREDIT_PRINCIPAL());
        uint256 backingBefore = vault.tokenBacking();
        uint256 custodyBefore = statics.balanceOf(address(vault));
        uint256 grossBefore = vault.grossBacking();
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, principal);

        assertEq(vault.tokenBacking(), backingBefore - principal);
        assertEq(vault.totalOutstandingGenesisCredit(), principal);
        assertEq(statics.balanceOf(address(vault)), custodyBefore - principal);
        assertEq(vault.grossBacking(), grossBefore);
        assertEq(vault.requiredBacking(), grossBefore - principal);
        assertEq(vault.tokenBacking() + vault.totalOutstandingGenesisCredit(), grossBefore);
        uint256 reserveFee = Math.mulDiv(ORIGINATION_FEE, 1_000, 10_000);
        assertEq(vault.reserveETH() - reserveBefore, reserveFee);
        assertEq(treasury.balance - treasuryBefore, ORIGINATION_FEE - reserveFee);

        vm.prank(alice);
        vault.repayGenesisCredit(1, principal);
        assertEq(vault.tokenBacking(), backingBefore);
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertEq(statics.balanceOf(address(vault)), custodyBefore);
        assertEq(vault.requiredBacking(), grossBefore);
        assertFalse(vault.creditActive(1));
    }

    function check_extensionOnlyChangesMaturityAndFeeAccounting(uint256 principal) public {
        vm.assume(principal <= type(uint96).max);
        vm.assume(principal > 0 && principal <= vault.MAX_CREDIT_PRINCIPAL());
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, principal);
        GenesisCreditView memory beforeExtension = vault.credit(1);
        uint256 backingBefore = vault.tokenBacking();
        uint256 custodyBefore = statics.balanceOf(address(vault));
        uint256 outstandingBefore = vault.totalOutstandingGenesisCredit();
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(1, principal);

        GenesisCreditView memory afterExtension = vault.credit(1);
        assertEq(afterExtension.owner, beforeExtension.owner);
        assertEq(afterExtension.principal, beforeExtension.principal);
        assertEq(afterExtension.maturity, uint256(beforeExtension.maturity) + vault.CREDIT_TERM());
        assertEq(vault.tokenBacking(), backingBefore);
        assertEq(statics.balanceOf(address(vault)), custodyBefore);
        assertEq(vault.totalOutstandingGenesisCredit(), outstandingBefore);
        uint256 reserveFee = Math.mulDiv(EXTENSION_FEE, 1_000, 10_000);
        assertEq(vault.reserveETH() - reserveBefore, reserveFee);
        assertEq(treasury.balance - treasuryBefore, EXTENSION_FEE - reserveFee);
    }

    function check_recoveryConservesResidualAndRemovesWeightBeforeIndexing(uint256 principal) public {
        vm.assume(principal <= type(uint96).max);
        vm.assume(principal > 0 && principal <= vault.MAX_CREDIT_PRINCIPAL());
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, principal);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        assertEq(quote.unusedCredit + quote.callerIncentive + quote.genesisDistribution, 180_000 ether - principal);
        uint256 backingBefore = vault.tokenBacking();
        uint256 custodyBefore = statics.balanceOf(address(vault));
        uint256 grossBefore = vault.grossBacking();
        uint256 aliceBefore = statics.balanceOf(alice);
        uint256 keeperBefore = statics.balanceOf(keeper);
        vm.warp(uint256(quote.recoverableAt) + 1);

        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertEq(genesis.ownerOf(1), address(vault));
        assertFalse(vault.creditActive(1));
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertEq(vault.grossBacking(), grossBefore - vault.GENESIS_PRICE());
        assertEq(vault.tokenBacking(), backingBefore - (vault.GENESIS_PRICE() - principal));
        assertEq(statics.balanceOf(address(vault)), custodyBefore - (vault.GENESIS_PRICE() - principal));
        assertEq(statics.balanceOf(alice) - aliceBefore, quote.unusedCredit);
        assertEq(statics.balanceOf(keeper) - keeperBefore, quote.callerIncentive);
        assertEq(distributor.effectiveWeight(1), 0);
        assertEq(distributor.totalWeight(), distributor.effectiveWeight(2));
        assertEq(distributor.pendingGenesis(1, address(statics)), 0);
        assertEq(distributor.pendingGenesis(2, address(statics)), quote.genesisDistribution);
        assertGe(vault.tokenBacking(), vault.requiredBacking());
        assertGe(statics.balanceOf(address(vault)), vault.tokenBacking());
    }

    function check_governedFeeSplitAlwaysConservesExactFee(uint256 reserveShareBps) public {
        vm.assume(reserveShareBps <= 10_000);
        vault.setCreditServiceFeeSplit(uint16(reserveShareBps), uint16(10_000 - reserveShareBps));
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
        uint256 reserveDelta = vault.reserveETH() - reserveBefore;
        uint256 treasuryDelta = treasury.balance - treasuryBefore;
        assertEq(reserveDelta + treasuryDelta, ORIGINATION_FEE);
        assertEq(reserveDelta, Math.mulDiv(ORIGINATION_FEE, reserveShareBps, 10_000));
    }
}

/// @notice Algebraic credit transition model used where Halmos cannot tractably
///         symbolically execute the complete deployed Genesis environment.
/// @dev Production-source behavior is paired with the representative tests above,
///      Genesis secured-credit fuzz tests, and the vault invariant suite.
contract GenesisCreditHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant GENESIS_PRICE = 180_000 ether;
    uint256 private constant MAX_CREDIT_PRINCIPAL = 171_000 ether;
    uint256 private constant RECOVERY_RESIDUAL = 9_000 ether;
    uint256 private constant CREDIT_TERM = 30 days;
    uint256 private constant ORIGINATION_FEE = 10_001 wei;
    uint256 private constant EXTENSION_FEE = 20_003 wei;

    function check_openAndRepayAreExactInverses(uint256 principalSeed) public pure {
        uint256 principal = principalSeed % MAX_CREDIT_PRINCIPAL + 1;
        uint256 backingAfterOpen = GENESIS_PRICE - principal;
        uint256 outstandingAfterOpen = principal;
        assertEq(backingAfterOpen + outstandingAfterOpen, GENESIS_PRICE);

        uint256 backingAfterRepay = backingAfterOpen + principal;
        uint256 outstandingAfterRepay = outstandingAfterOpen - principal;
        assertEq(backingAfterRepay, GENESIS_PRICE);
        assertEq(outstandingAfterRepay, 0);
    }

    function check_extensionOnlyChangesMaturityAndFeeAccounting(uint256 principalSeed) public pure {
        uint256 principal = principalSeed % MAX_CREDIT_PRINCIPAL + 1;
        uint256 backing = GENESIS_PRICE - principal;
        uint256 outstanding = principal;
        uint256 maturity = 31 days;
        uint256 reserveFee = Math.mulDiv(EXTENSION_FEE, 1_000, BPS);
        uint256 treasuryFee = EXTENSION_FEE - reserveFee;

        assertEq(maturity + CREDIT_TERM, 61 days);
        assertEq(backing + outstanding, GENESIS_PRICE);
        assertEq(reserveFee + treasuryFee, EXTENSION_FEE);
    }

    function check_principalAdjustmentConservesAccounting(uint256 currentSeed, uint256 targetSeed) public pure {
        uint256 currentPrincipal = currentSeed % (MAX_CREDIT_PRINCIPAL - 1) + 1;
        uint256 newPrincipal = targetSeed % MAX_CREDIT_PRINCIPAL + 1;
        uint256 backing = GENESIS_PRICE - currentPrincipal;
        uint256 outstanding = currentPrincipal;

        if (newPrincipal > currentPrincipal) {
            uint256 increase = newPrincipal - currentPrincipal;
            backing -= increase;
            outstanding += increase;
        } else {
            uint256 decrease = currentPrincipal - newPrincipal;
            backing += decrease;
            outstanding -= decrease;
        }

        assertEq(backing + outstanding, GENESIS_PRICE);
        assertEq(outstanding, newPrincipal);
        assertLe(newPrincipal, MAX_CREDIT_PRINCIPAL);
        assertGt(newPrincipal, 0);
    }

    function check_recoveryConservesResidualAndRemovesWeightBeforeIndexing(uint256 principalSeed) public pure {
        uint256 principal = principalSeed % MAX_CREDIT_PRINCIPAL + 1;
        uint256 unusedCredit = MAX_CREDIT_PRINCIPAL - principal;
        uint256 callerIncentive = Math.mulDiv(RECOVERY_RESIDUAL, 2_000, BPS);
        uint256 genesisDistribution = RECOVERY_RESIDUAL - callerIncentive;
        uint256 totalWeightBefore = 25_000;
        uint256 defaultedWeight = 12_500;
        uint256 totalWeightAtIndexing = totalWeightBefore - defaultedWeight;

        assertEq(unusedCredit + callerIncentive + genesisDistribution, GENESIS_PRICE - principal);
        assertEq(totalWeightAtIndexing, 12_500);
        assertEq(genesisDistribution, RECOVERY_RESIDUAL - callerIncentive);
    }

    function check_governedFeeSplitAlwaysConservesExactFee(uint256 reserveShareSeed) public pure {
        uint256 reserveShareBps = reserveShareSeed % (BPS + 1);
        uint256 reserveFee = ORIGINATION_FEE * reserveShareBps / BPS;
        uint256 treasuryFee = ORIGINATION_FEE - reserveFee;
        assertEq(reserveFee + treasuryFee, ORIGINATION_FEE);
        assertLe(reserveFee, ORIGINATION_FEE);
    }
}
