// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {IGenesisLaunchDistributor} from "../../src/interfaces/IGenesisLaunchDistributor.sol";
import {
    GenesisCreditConfig,
    GenesisCreditRecoveryQuote,
    GenesisCreditServiceQuote,
    GenesisCreditView,
    GenesisVaultAccounting,
    IStaticsGenesisVault
} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";
import {MockGenesisCreditProtocol} from "../mocks/MockGenesisCreditProtocol.sol";

contract CreditDopplerFeeSource {
    address public asset;
    address public numeraire;
    address public beneficiary;
    uint256 public pendingStatics;

    function configure(address asset_, address numeraire_, address beneficiary_) external {
        asset = asset_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function queueStatics(uint256 amount) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        pendingStatics += amount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 amount = pendingStatics;
        delete pendingStatics;
        IERC20(asset).transfer(msg.sender, amount);
        return (uint128(amount), 0);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        (currency0, currency1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract IncompatibleGenesisCreditProtocol {
    address public immutable genesisCollection;

    constructor(address collection) {
        genesisCollection = collection;
    }

    function linkedPosition(uint256) external pure returns (uint256) {
        return 0;
    }

    function onGenesisRecovery(uint256, address) external pure returns (bytes4) {
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }
}

/// @dev Test-only accounting harness for the economically unreachable low-backing draw branch.
contract GenesisCreditVaultHarness is StaticsGenesisVault {
    constructor(
        IERC20 statics_,
        address bootstrapper_,
        address governance_,
        uint256 genesisEpochEnd_,
        GenesisCreditConfig memory creditConfig_
    ) StaticsGenesisVault(statics_, bootstrapper_, governance_, genesisEpochEnd_, creditConfig_) {}

    function setTokenBackingForTest(uint256 backing) external {
        tokenBacking = backing;
    }
}

contract GenesisSecuredCreditTest is Test {
    uint256 private constant PRICE = 180_000 ether;
    uint256 private constant INITIAL_BACKING = 99_900_000 ether;
    uint256 private constant MAX_PRINCIPAL = 171_000 ether;
    uint256 private constant RESIDUAL = 9_000 ether;
    uint256 private constant ORIGINATION_FEE = 0.003 ether;
    uint256 private constant EXTENSION_FEE = 0.003 ether;
    bytes32 private constant POOL_ID = keccak256("GENESIS_SECURED_CREDIT");

    address private governance;
    address private treasury;
    address private alice;
    address private bob;
    address private keeper;
    uint256 private epochEnd;

    MockDopplerToken private statics;
    MockDopplerToken private weth;
    CreditDopplerFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private activationRegistry;
    GenesisCreditVaultHarness private vault;
    StaticsGenesis private genesis;
    GenesisLaunchDistributor private distributor;

    function setUp() public {
        governance = makeAddr("governance");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        epochEnd = block.timestamp + 7 days;

        statics = new MockDopplerToken(address(this));
        weth = new MockDopplerToken(address(this));
        feeSource = new CreditDopplerFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(weth), governance);
        feeSource.configure(address(statics), address(weth), address(feeReceiver));
        vm.prank(governance);
        feeReceiver.bindMarket(address(statics), POOL_ID);

        activationRegistry = new GenesisActivationRegistry(statics, address(this), governance, treasury);
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: ORIGINATION_FEE,
            extensionFee: EXTENSION_FEE,
            recoveryCallerShareBps: 2_000
        });
        vault = new GenesisCreditVaultHarness(statics, address(this), governance, epochEnd, creditConfig);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(
            address(vault),
            address(this),
            address(activationRegistry),
            renderer,
            governance,
            treasury,
            "ipfs://statics-genesis/contract.json"
        );
        activationRegistry.bindGenesisCollection(address(genesis));
        statics.transfer(address(vault), vault.INITIAL_TOKEN_BACKING());
        vault.finalizeGenesisCollection(address(genesis));

        distributor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 7_500);
        vm.startPrank(governance);
        feeReceiver.bindReserveVault(address(vault));
        feeReceiver.proposeDistributor(address(distributor));
        vm.stopPrank();
        vm.prank(governance);
        distributor.acceptFeeReceiverRole();
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(distributor));
        vm.prank(governance);
        distributor.acceptActivationConsumer();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(keeper, 100 ether);
        vm.warp(epochEnd);
    }

    function testOpenExtendRepayPreservesGenesisAndExactAccounting() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        distributor.registerGenesis(1);
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        GenesisCreditServiceQuote memory originationQuote = vault.quoteGenesisCredit(100_000 ether);
        assertEq(originationQuote.totalNativeFee, ORIGINATION_FEE);
        assertEq(originationQuote.reserveShareBps, 1_000);
        assertEq(originationQuote.treasuryShareBps, 9_000);
        assertEq(originationQuote.reservePortion, 0.0003 ether);
        assertEq(originationQuote.treasuryPortion, 0.0027 ether);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        GenesisCreditView memory state = vault.credit(1);
        assertEq(state.owner, alice);
        assertEq(state.principal, 100_000 ether);
        assertEq(state.maturity, block.timestamp + 30 days);
        assertTrue(state.active);
        assertTrue(genesis.locked(1));
        assertEq(statics.balanceOf(alice), 100_000 ether);
        assertEq(vault.tokenBacking(), INITIAL_BACKING + 80_000 ether);
        assertEq(vault.requiredBacking(), INITIAL_BACKING + 80_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), 100_000 ether);
        assertEq(vault.reserveETH(), reserveBefore + 0.0003 ether);
        assertEq(treasury.balance, treasuryBefore + 0.0027 ether);

        statics.approve(address(feeSource), 100 ether);
        feeSource.queueStatics(100 ether);
        distributor.accrue();
        uint256 rewardsBefore = statics.balanceOf(alice);
        vm.prank(alice);
        distributor.claimGenesis(1, address(statics), alice);
        assertEq(statics.balanceOf(alice) - rewardsBefore, 75 ether);

        vm.prank(governance);
        vault.setCreditExtensionFee(0.005 ether);
        uint40 maturityBefore = state.maturity;
        assertEq(vault.credit(1).maturity, maturityBefore);
        GenesisCreditServiceQuote memory extensionQuote = vault.quoteGenesisCreditExtension(1);
        assertEq(extensionQuote.totalNativeFee, 0.005 ether);

        vm.warp(maturityBefore);
        vm.prank(alice);
        vault.extendGenesisCredit{value: 0.005 ether}(1);
        assertEq(vault.credit(1).maturity, uint256(maturityBefore) + 30 days);

        vm.startPrank(bob);
        statics.approve(address(vault), 100_000 ether);
        vm.stopPrank();
        statics.transfer(bob, 100_000 ether);
        vm.prank(bob);
        vault.repayGenesisCredit(1, 100_000 ether);

        assertFalse(vault.creditActive(1));
        assertFalse(genesis.locked(1));
        assertEq(genesis.ownerOf(1), alice);
        assertEq(vault.tokenBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.requiredBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
    }

    function testCreditOriginationRejectsBeforeEpochEnd() public {
        _buyGenesis(alice, 1);
        vm.warp(epochEnd - 1);

        vm.prank(alice);
        vm.expectRevert(StaticsGenesisVault.CreditUnavailableDuringEpoch.selector);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
    }

    function testPartialRepaymentKeepsLockUntilFinalRepayment() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        uint256 backingBefore = vault.tokenBacking();
        statics.transfer(bob, 40_000 ether);
        vm.startPrank(bob);
        statics.approve(address(vault), 40_000 ether);
        vault.repayGenesisCredit(1, 40_000 ether);
        vm.stopPrank();

        assertEq(vault.credit(1).principal, 60_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), 60_000 ether);
        assertEq(vault.tokenBacking(), backingBefore + 40_000 ether);
        assertTrue(vault.creditActive(1));
        assertTrue(genesis.locked(1));

        statics.transfer(bob, 60_000 ether);
        vm.startPrank(bob);
        statics.approve(address(vault), 60_000 ether);
        vault.repayGenesisCredit(1, 60_000 ether);
        vm.stopPrank();

        assertFalse(vault.creditActive(1));
        assertFalse(genesis.locked(1));
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertEq(vault.tokenBacking(), backingBefore + 100_000 ether);
    }

    function testRepaymentRejectsZeroAndExcessAmounts() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidRepaymentAmount.selector, 0, 100_000 ether));
        vault.repayGenesisCredit(1, 0);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsGenesisVault.InvalidRepaymentAmount.selector, 100_000 ether + 1, 100_000 ether
            )
        );
        vault.repayGenesisCredit(1, 100_000 ether + 1);
    }

    function testCreditAvailableTracksCapacityAndBacking() public {
        _buyGenesis(alice, 1);
        assertEq(vault.creditAvailable(1), 0);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        assertEq(vault.creditAvailable(1), 71_000 ether);

        statics.transfer(bob, 40_000 ether);
        vm.startPrank(bob);
        statics.approve(address(vault), 40_000 ether);
        vault.repayGenesisCredit(1, 40_000 ether);
        vm.stopPrank();
        assertEq(vault.creditAvailable(1), 111_000 ether);

        vm.prank(alice);
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 20_000 ether);
        assertEq(vault.creditAvailable(1), 91_000 ether);
    }

    function testRepayThenDrawChargesCurrentOriginationFeeWithoutChangingMaturity() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        statics.transfer(bob, 40_000 ether);
        vm.startPrank(bob);
        statics.approve(address(vault), 40_000 ether);
        vault.repayGenesisCredit(1, 40_000 ether);
        vm.stopPrank();

        vm.prank(governance);
        vault.setCreditOriginationFee(10_001 wei);
        uint256 backingBefore = vault.tokenBacking();
        uint256 outstandingBefore = vault.totalOutstandingGenesisCredit();
        uint256 balanceBefore = statics.balanceOf(alice);
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;
        uint40 maturityBefore = vault.credit(1).maturity;

        vm.expectEmit(true, true, false, true, address(vault));
        emit IStaticsGenesisVault.GenesisCreditDrawn(1, alice, 20_000 ether, 80_000 ether, 10_001 wei);
        vm.prank(alice);
        vault.drawGenesisCredit{value: 10_001 wei}(1, 20_000 ether);

        assertEq(vault.credit(1).principal, 80_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), outstandingBefore + 20_000 ether);
        assertEq(vault.tokenBacking(), backingBefore - 20_000 ether);
        assertEq(vault.credit(1).maturity, maturityBefore);
        assertEq(statics.balanceOf(alice), balanceBefore + 20_000 ether);
        assertEq(vault.reserveETH() - reserveBefore, 1_000 wei);
        assertEq(treasury.balance - treasuryBefore, 9_001 wei);
        assertTrue(genesis.locked(1));
    }

    function testRepeatedDrawRepayRedrawUsesOnlyCurrentPrincipalCapacity() public {
        _buyGenesis(alice, 1);
        vm.startPrank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        statics.approve(address(vault), type(uint256).max);

        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 50_000 ether);
        assertEq(vault.credit(1).principal, 150_000 ether);
        vault.repayGenesisCredit(1, 60_000 ether);
        assertEq(vault.credit(1).principal, 90_000 ether);

        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 70_000 ether);
        assertEq(vault.credit(1).principal, 160_000 ether);
        vault.repayGenesisCredit(1, 100_000 ether);
        assertEq(vault.credit(1).principal, 60_000 ether);

        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 111_000 ether);
        assertEq(vault.credit(1).principal, MAX_PRINCIPAL);
        assertEq(vault.creditAvailable(1), 0);
        vault.repayGenesisCredit(1, MAX_PRINCIPAL);
        vm.stopPrank();

        assertFalse(vault.creditActive(1));
        assertFalse(genesis.locked(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditNotActive.selector, 1));
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
    }

    function testDrawRejectsInvalidOwnerFeeCapacityAndBacking() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.NotGenesisOwner.selector, 1, bob, alice));
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsGenesisVault.IncorrectNativeFee.selector, ORIGINATION_FEE - 1, ORIGINATION_FEE
            )
        );
        vault.drawGenesisCredit{value: ORIGINATION_FEE - 1}(1, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditDrawAmount.selector, 0, 71_000 ether));
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditDrawAmount.selector, 71_000 ether + 1, 71_000 ether)
        );
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 71_000 ether + 1);

        vault.setTokenBackingForTest(1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.InsufficientCreditBacking.selector, 1 ether, 2 ether)
        );
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 2 ether);
    }

    function testCreditAvailableReturnsZeroWhenPausedOrExpiredAndUsesBackingMinimum() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        uint40 maturity = vault.credit(1).maturity;

        vault.setTokenBackingForTest(10_000 ether);
        assertEq(vault.creditAvailable(1), 10_000 ether);
        vm.prank(governance);
        vault.setCreditIncreasesPaused(true);
        assertEq(vault.creditAvailable(1), 0);
        vm.prank(governance);
        vault.setCreditIncreasesPaused(false);
        vm.warp(uint256(maturity) + 1);
        assertEq(vault.creditAvailable(1), 0);
    }

    function testDrawAtMaturityBoundariesAndExpiredRepaymentRemainsLive() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        vm.prank(bob);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(2, 100_000 ether);
        uint40 maturity = vault.credit(1).maturity;

        vm.warp(uint256(maturity) - 1);
        vm.prank(alice);
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
        vm.warp(maturity);
        vm.prank(bob);
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(2, 1 ether);

        vm.warp(uint256(maturity) + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditExpired.selector, 1, maturity));
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditExpired.selector, 2, maturity));
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(2, 1 ether);

        vm.startPrank(alice);
        statics.approve(address(vault), 1 ether);
        vault.repayGenesisCredit(1, 1 ether);
        vm.stopPrank();
        assertEq(vault.credit(1).principal, 100_000 ether);
    }

    function testCreditLimitReturnsZeroForNonexistentGenesis() public view {
        assertEq(vault.creditLimit(genesis.COLLECTION_SIZE() + 1), 0);
    }

    function testApprovedOperatorCannotOriginateOwnerCredit() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        genesis.approve(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.NotGenesisOwner.selector, 1, bob, alice));
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
    }

    function testOriginationRejectsInvalidPrincipalAndSecondFacility() public {
        _buyGenesis(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditPrincipal.selector, 0));
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditPrincipal.selector, MAX_PRINCIPAL + 1));
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL + 1);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditAlreadyActive.selector, 1));
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
    }

    function testRepaymentPreservesActivationWeightAndRestoresTransfer() public {
        _buyGenesis(alice, 1);
        statics.transfer(alice, 10_000 ether);
        vm.startPrank(alice);
        statics.approve(address(activationRegistry), 10_000 ether);
        activationRegistry.activate(1, 1);
        distributor.registerGenesis(1);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 10_000 ether);
        statics.approve(address(vault), 10_000 ether);
        vault.repayGenesisCredit(1, 10_000 ether);
        vm.stopPrank();

        assertEq(activationRegistry.tierOf(1), 1);
        assertEq(distributor.effectiveWeight(1), 11_000);
        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        assertEq(activationRegistry.tierOf(1), 0);
        assertEq(distributor.effectiveWeight(1), 10_000);
        assertEq(genesis.ownerOf(1), bob);
    }

    function testInitialExtensionFeeSplitsTenNinety() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1 ether);
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(1);

        assertEq(vault.reserveETH() - reserveBefore, 0.0003 ether);
        assertEq(treasury.balance - treasuryBefore, 0.0027 ether);
    }

    function testFeeSplitConfigurationEmitsAndRejectsUnauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setCreditServiceFeeSplit(2_000, 8_000);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IStaticsGenesisVault.CreditServiceFeeSplitSet(1_000, 9_000, 2_000, 8_000);
        vm.prank(governance);
        vault.setCreditServiceFeeSplit(2_000, 8_000);
    }

    function testCreditTimeBoundariesKeepRepaymentLive() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        vm.prank(bob);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(2, 1 ether);
        uint40 maturity = vault.credit(1).maturity;

        vm.warp(uint256(maturity) - 1);
        vm.prank(bob);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(2);
        assertEq(vault.credit(2).maturity, uint256(maturity) + 30 days);

        vm.warp(uint256(maturity) + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditExpired.selector, 1, maturity));
        vault.extendGenesisCredit{value: EXTENSION_FEE}(1);

        vm.startPrank(alice);
        statics.approve(address(vault), MAX_PRINCIPAL);
        vault.repayGenesisCredit(1, MAX_PRINCIPAL);
        vm.stopPrank();
        assertFalse(vault.creditActive(1));
    }

    function testMultipleCreditsRepayAndRecoverIndependently() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 20_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(2, 40_000 ether);

        assertEq(vault.totalOutstandingGenesisCredit(), 60_000 ether);
        vm.startPrank(alice);
        statics.approve(address(vault), 20_000 ether);
        vault.repayGenesisCredit(1, 20_000 ether);
        vm.stopPrank();
        assertFalse(vault.creditActive(1));
        assertTrue(vault.creditActive(2));
        assertEq(vault.totalOutstandingGenesisCredit(), 40_000 ether);

        uint40 bobRecoverableAt = vault.creditRecoverableAt(2);
        vm.warp(uint256(bobRecoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(2);
        assertEq(genesis.ownerOf(1), alice);
        assertEq(genesis.ownerOf(2), address(vault));
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
    }

    function testRecoveryAtGraceBoundaryAndResidualDistribution() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        distributor.registerGenesis(1);
        vm.prank(bob);
        distributor.registerGenesis(2);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        uint256 reserveBeforeRecovery = vault.reserveETH();
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        assertEq(quote.unusedCredit, 0);
        assertEq(quote.recoveryResidual, RESIDUAL);
        assertEq(quote.callerIncentive, 1_800 ether);
        assertEq(quote.genesisDistribution, 7_200 ether);

        vm.warp(quote.recoverableAt);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.CreditNotRecoverable.selector, 1, quote.recoverableAt)
        );
        vault.recoverGenesisCredit(1);

        uint256 keeperBefore = statics.balanceOf(keeper);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertEq(genesis.ownerOf(1), address(vault));
        assertEq(activationRegistry.tierOf(1), 0);
        assertEq(distributor.effectiveWeight(1), 0);
        assertEq(statics.balanceOf(keeper) - keeperBefore, 1_800 ether);
        assertEq(vault.tokenBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.requiredBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertEq(vault.reserveETH(), reserveBeforeRecovery);

        uint256 bobBefore = statics.balanceOf(bob);
        vm.prank(bob);
        distributor.claimGenesis(2, address(statics), bob);
        assertEq(statics.balanceOf(bob) - bobBefore, 7_200 ether);
    }

    function testRecoveryAfterDrawAndRepayUsesCurrentPrincipalAndExactResidualSplit() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        distributor.registerGenesis(1);
        vm.prank(bob);
        distributor.registerGenesis(2);

        vm.startPrank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);
        vault.drawGenesisCredit{value: ORIGINATION_FEE}(1, 50_000 ether);
        statics.approve(address(vault), 30_000 ether);
        vault.repayGenesisCredit(1, 30_000 ether);
        vm.stopPrank();

        assertEq(vault.credit(1).principal, 120_000 ether);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        assertEq(quote.unusedCredit, 51_000 ether);
        assertEq(quote.callerIncentive, 1_800 ether);
        assertEq(quote.genesisDistribution, 7_200 ether);
        uint256 aliceBefore = statics.balanceOf(alice);
        uint256 keeperBefore = statics.balanceOf(keeper);

        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertEq(statics.balanceOf(alice) - aliceBefore, 51_000 ether);
        assertEq(statics.balanceOf(keeper) - keeperBefore, 1_800 ether);
        assertEq(distributor.pendingGenesis(2, address(statics)), 7_200 ether);
        assertEq(vault.tokenBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.requiredBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
    }

    function testSmallPrincipalRecoveryReturnsUnusedCapacity() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 1_000 ether);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        assertEq(quote.unusedCredit, 170_000 ether);

        uint256 aliceBefore = statics.balanceOf(alice);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);
        assertEq(statics.balanceOf(alice) - aliceBefore, 170_000 ether);
        assertEq(statics.balanceOf(alice), MAX_PRINCIPAL);
        assertEq(vault.tokenBacking(), INITIAL_BACKING);
        assertEq(vault.requiredBacking(), INITIAL_BACKING);
    }

    function testRecoveryStaysPendingUntilEligibleWeightReturns() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);
        assertEq(distributor.pendingGenesisRecovery(), 7_200 ether);

        _buyGenesis(bob, 2);
        vm.prank(bob);
        distributor.registerGenesis(2);
        assertEq(distributor.pendingGenesisRecovery(), 0);
        assertEq(distributor.pendingGenesis(2, address(statics)), 7_200 ether);
    }

    function testCompatibleDistributorCanReplaceLaunchDistributorBeforeRecovery() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);

        GenesisLaunchDistributor successor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 7_500);
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(successor));
        vm.prank(governance);
        successor.acceptFeeReceiverRole();
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(successor));
        vm.prank(governance);
        successor.acceptActivationConsumer();
        vm.prank(bob);
        successor.registerGenesis(2);

        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);
        assertEq(successor.pendingGenesis(2, address(statics)), quote.genesisDistribution);
    }

    function testRecoveryPausesDuringDistributorConsumerHandoff() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);

        GenesisLaunchDistributor successor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 7_500);
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(successor));
        vm.prank(governance);
        successor.acceptFeeReceiverRole();

        vm.prank(bob);
        vm.expectRevert(GenesisLaunchDistributor.RecoveryRolesNotActive.selector);
        successor.registerGenesis(2);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.InvalidRecoveryDistributor.selector, address(successor))
        );
        vault.recoverGenesisCredit(1);

        vm.prank(governance);
        activationRegistry.proposeConsumer(address(successor));
        vm.prank(governance);
        successor.acceptActivationConsumer();
        vm.prank(bob);
        successor.registerGenesis(2);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);
        assertEq(successor.pendingGenesis(2, address(statics)), quote.genesisDistribution);
    }

    function testDetachedDistributorCannotBeReactivatedWithStaleWeights() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        distributor.registerGenesis(1);

        GenesisLaunchDistributor successor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 7_500);
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(successor));
        vm.prank(governance);
        successor.acceptFeeReceiverRole();
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(successor));
        vm.prank(governance);
        successor.acceptActivationConsumer();

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsFeeReceiver.DistributorAlreadyActivated.selector, address(distributor))
        );
        feeReceiver.proposeDistributor(address(distributor));
    }

    function testRecoveryHarvestsAndCrystallizesFeesBeforeRemovingWeight() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        distributor.registerGenesis(1);
        vm.prank(bob);
        distributor.registerGenesis(2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);

        statics.approve(address(feeSource), 100 ether);
        feeSource.queueStatics(100 ether);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertEq(distributor.ownerClaimable(alice, address(statics)), 37.5 ether);
        uint256 aliceBefore = statics.balanceOf(alice);
        vm.prank(alice);
        distributor.claimOwnerRewards(address(statics), alice);
        assertEq(statics.balanceOf(alice) - aliceBefore, 37.5 ether);
        assertEq(distributor.pendingGenesis(2, address(statics)), 37.5 ether + quote.genesisDistribution);
    }

    function testPendingRecoveryMigratesToSuccessorAndWaitsForEligibleWeight() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        GenesisLaunchDistributor successor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 7_500);
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(successor));
        vm.prank(governance);
        successor.acceptFeeReceiverRole();
        assertEq(distributor.pendingGenesisRecovery(), 0);
        assertEq(successor.pendingGenesisRecovery(), quote.genesisDistribution);
        assertEq(statics.balanceOf(address(successor)), quote.genesisDistribution);

        vm.prank(governance);
        activationRegistry.proposeConsumer(address(successor));
        vm.prank(governance);
        successor.acceptActivationConsumer();
        _buyGenesis(bob, 2);
        vm.prank(bob);
        successor.registerGenesis(2);
        assertEq(feeReceiver.activeDistributor(), address(successor));
        assertEq(successor.pendingGenesisRecovery(), 0);
        assertEq(successor.pendingGenesis(2, address(statics)), quote.genesisDistribution);
    }

    function testRecoverySeversFutureProtocolLinkAndPreservesOtherState() public {
        _buyGenesis(alice, 1);
        MockGenesisCreditProtocol protocol = new MockGenesisCreditProtocol(address(genesis));
        vm.prank(governance);
        genesis.bindProtocol(address(protocol));
        protocol.link(1, 42);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertTrue(protocol.recoveryCalled());
        assertEq(protocol.linkedPosition(1), 0);
        assertEq(protocol.unrelatedLedgerValue(), 77);
        assertEq(genesis.ownerOf(1), address(vault));
    }

    function testUnlinkedRecoveryDoesNotCallBoundProtocol() public {
        _buyGenesis(alice, 1);
        MockGenesisCreditProtocol protocol = new MockGenesisCreditProtocol(address(genesis));
        vm.prank(governance);
        genesis.bindProtocol(address(protocol));
        protocol.setRejectRecovery(true);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);

        assertFalse(protocol.recoveryCalled());
        assertEq(genesis.ownerOf(1), address(vault));
    }

    function testProtocolBindingRequiresRecoveryCapability() public {
        IncompatibleGenesisCreditProtocol incompatible = new IncompatibleGenesisCreditProtocol(address(genesis));

        vm.prank(governance);
        vm.expectRevert(StaticsGenesis.InvalidProtocol.selector);
        genesis.bindProtocol(address(incompatible));
    }

    function testRecoveryRejectsAcknowledgementWithoutClearedLink() public {
        _buyGenesis(alice, 1);
        MockGenesisCreditProtocol protocol = new MockGenesisCreditProtocol(address(genesis));
        vm.prank(governance);
        genesis.bindProtocol(address(protocol));
        protocol.link(1, 42);
        protocol.setClearLinkOnRecovery(false);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsGenesis.RecoveryLinkNotCleared.selector, address(protocol), uint256(1), uint256(42)
            )
        );
        vault.recoverGenesisCredit(1);

        assertTrue(vault.creditActive(1));
        assertEq(genesis.ownerOf(1), alice);
        assertEq(protocol.linkedPosition(1), 42);
    }

    function testRepaymentPreservesFutureProtocolLink() public {
        _buyGenesis(alice, 1);
        MockGenesisCreditProtocol protocol = new MockGenesisCreditProtocol(address(genesis));
        vm.prank(governance);
        genesis.bindProtocol(address(protocol));
        protocol.link(1, 42);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 10_000 ether);
        vm.startPrank(alice);
        statics.approve(address(vault), 10_000 ether);
        vault.repayGenesisCredit(1, 10_000 ether);
        vm.stopPrank();

        assertEq(protocol.linkedPosition(1), 42);
        assertFalse(protocol.recoveryCalled());
        assertTrue(genesis.locked(1));
    }

    function testRejectedProtocolRecoveryRevertsEverything() public {
        _buyGenesis(alice, 1);
        MockGenesisCreditProtocol protocol = new MockGenesisCreditProtocol(address(genesis));
        vm.prank(governance);
        genesis.bindProtocol(address(protocol));
        protocol.link(1, 42);
        protocol.setRejectRecovery(true);

        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, MAX_PRINCIPAL);
        GenesisCreditRecoveryQuote memory quote = vault.quoteGenesisCreditRecovery(1);
        uint256 backingBefore = vault.tokenBacking();
        vm.warp(uint256(quote.recoverableAt) + 1);
        vm.prank(keeper);
        vm.expectRevert("RECOVERY_REJECTED");
        vault.recoverGenesisCredit(1);

        assertTrue(vault.creditActive(1));
        assertEq(vault.tokenBacking(), backingBefore);
        assertEq(genesis.ownerOf(1), alice);
        assertEq(protocol.linkedPosition(1), 42);
    }

    function testCreditLockBlocksTransferAndRedemptionButAllowsActivation() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
        genesis.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditAlreadyActive.selector, 1));
        vault.redeemGenesis(1, alice);

        statics.transfer(alice, 10_000 ether);
        vm.startPrank(alice);
        statics.approve(address(activationRegistry), 10_000 ether);
        activationRegistry.activate(1, 1);
        vm.stopPrank();
        assertEq(activationRegistry.tierOf(1), 1);
    }

    function testGovernedFeeSplitUsesExactRoundingAndPauseStopsCreditIncreases() public {
        _buyGenesis(alice, 1);
        vm.startPrank(governance);
        vault.setCreditOriginationFee(10_001 wei);
        vault.setCreditServiceFeeSplit(1_000, 9_000);
        vm.stopPrank();
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vault.openGenesisCredit{value: 10_001 wei}(1, 10_000 ether);
        assertEq(vault.reserveETH() - reserveBefore, 1_000 wei);
        assertEq(treasury.balance - treasuryBefore, 9_001 wei);

        vm.prank(governance);
        vault.setCreditIncreasesPaused(true);
        _buyGenesis(bob, 2);
        vm.prank(bob);
        vm.expectRevert(StaticsGenesisVault.CreditIncreasesPaused.selector);
        vault.openGenesisCredit{value: 10_001 wei}(2, 1 ether);
        vm.prank(alice);
        vm.expectRevert(StaticsGenesisVault.CreditIncreasesPaused.selector);
        vault.drawGenesisCredit{value: 10_001 wei}(1, 1 ether);

        statics.transfer(bob, 10_000 ether);
        vm.startPrank(bob);
        statics.approve(address(vault), 10_000 ether);
        vault.repayGenesisCredit(1, 10_000 ether);
        vm.stopPrank();
        assertFalse(vault.creditActive(1));
    }

    function testFeeSplitEndpointsAndDonationRemainExact() public {
        _buyGenesis(alice, 1);
        vm.startPrank(governance);
        vault.setCreditOriginationFee(10_001 wei);
        vault.setCreditExtensionFee(10_001 wei);
        vault.setCreditServiceFeeSplit(0, 10_000);
        vm.stopPrank();
        uint256 reserveBefore = vault.reserveETH();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vault.openGenesisCredit{value: 10_001 wei}(1, 1 ether);
        assertEq(vault.reserveETH(), reserveBefore);
        assertEq(treasury.balance - treasuryBefore, 10_001 wei);

        vm.prank(governance);
        vault.setCreditServiceFeeSplit(10_000, 0);
        vm.prank(alice);
        vault.extendGenesisCredit{value: 10_001 wei}(1);
        assertEq(vault.reserveETH() - reserveBefore, 10_001 wei);
        assertEq(treasury.balance - treasuryBefore, 10_001 wei);

        vm.prank(bob);
        vault.donate{value: 123 wei}();
        assertEq(vault.reserveETH() - reserveBefore, 10_124 wei);
    }

    function testPausedCreditIncreasesKeepRepaymentExtensionAndRecoveryLive() public {
        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 10_000 ether);
        vm.prank(bob);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(2, 20_000 ether);
        vm.prank(governance);
        vault.setCreditIncreasesPaused(true);
        uint40 maturityBefore = vault.credit(2).maturity;
        vm.prank(bob);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(2);
        assertEq(vault.credit(2).maturity, uint256(maturityBefore) + 30 days);

        vm.startPrank(alice);
        statics.approve(address(vault), 10_000 ether);
        vault.repayGenesisCredit(1, 10_000 ether);
        vm.stopPrank();
        uint40 recoverableAt = vault.creditRecoverableAt(2);
        vm.warp(uint256(recoverableAt) + 1);
        vm.prank(keeper);
        vault.recoverGenesisCredit(2);

        assertFalse(vault.creditActive(1));
        assertFalse(vault.creditActive(2));
    }

    function testRecoveryDistributorRejectsUnauthenticatedAccrual() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisLaunchDistributor.UnauthorizedRecoveryVault.selector, alice));
        distributor.accrueGenesisRecovery(1 ether);
    }

    function testCreditRequiresExactCurrentFee() public {
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsGenesisVault.IncorrectNativeFee.selector, ORIGINATION_FEE - 1, ORIGINATION_FEE
            )
        );
        vault.openGenesisCredit{value: ORIGINATION_FEE - 1}(1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsGenesisVault.IncorrectNativeFee.selector, ORIGINATION_FEE + 1, ORIGINATION_FEE
            )
        );
        vault.openGenesisCredit{value: ORIGINATION_FEE + 1}(1, 1 ether);
        assertFalse(vault.creditActive(1));
        assertEq(vault.tokenBacking(), INITIAL_BACKING + PRICE);
    }

    function testTreasuryPaymentFailureRollsBackOrigination() public {
        _buyGenesis(alice, 1);
        uint256 reserveBefore = vault.reserveETH();
        vm.etch(treasury, hex"60006000fd");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.NativeTreasuryTransferFailed.selector, treasury, 0.0027 ether)
        );
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, 100_000 ether);

        assertFalse(vault.creditActive(1));
        assertEq(vault.tokenBacking(), INITIAL_BACKING + PRICE);
        assertEq(vault.reserveETH(), reserveBefore);
        assertEq(statics.balanceOf(alice), 0);
    }

    function testGovernanceRejectsInvalidCreditEconomics() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setCreditOriginationFee(1 ether);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditServiceFeeSplit.selector, 5_000, 4_999));
        vault.setCreditServiceFeeSplit(5_000, 4_999);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidRecoveryCallerShare.selector, 0));
        vault.setRecoveryCallerShareBps(0);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.InvalidRecoveryCallerShare.selector, 10_000));
        vault.setRecoveryCallerShareBps(10_000);
    }

    function testFuzzCreditAccountingRoundTrip(uint256 principal) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        _buyGenesis(alice, 1);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(1, principal);
        GenesisVaultAccounting memory openAccounting = vault.vaultAccounting();
        assertEq(openAccounting.grossBacking, INITIAL_BACKING + PRICE);
        assertEq(openAccounting.outstandingGenesisCredit, principal);
        assertEq(openAccounting.requiredBacking, INITIAL_BACKING + PRICE - principal);
        assertEq(openAccounting.tokenBacking, INITIAL_BACKING + PRICE - principal);

        statics.transfer(bob, principal);
        vm.startPrank(bob);
        statics.approve(address(vault), principal);
        vault.repayGenesisCredit(1, principal);
        vm.stopPrank();
        GenesisVaultAccounting memory repaidAccounting = vault.vaultAccounting();
        assertEq(repaidAccounting.grossBacking, INITIAL_BACKING + PRICE);
        assertEq(repaidAccounting.outstandingGenesisCredit, 0);
        assertEq(repaidAccounting.requiredBacking, INITIAL_BACKING + PRICE);
        assertEq(repaidAccounting.tokenBacking, INITIAL_BACKING + PRICE);
    }

    function _buyGenesis(address buyer, uint256 genesisId) private {
        statics.transfer(buyer, PRICE);
        uint256 requiredNative = vault.quoteGenesisPurchase().requiredNative;
        vm.startPrank(buyer);
        statics.approve(address(vault), PRICE);
        vault.buyGenesis{value: requiredNative}(genesisId, buyer);
        vm.stopPrank();
    }
}
