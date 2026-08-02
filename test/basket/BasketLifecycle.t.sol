// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {
    MockERC20,
    MockFeeOnTransferERC20,
    MockOutboundFeeERC20,
    MockReentrantERC20,
    MockSenderExtraFeeERC20
} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketLifecycleTest is StaticsTestBase {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function testPermissionlessCreationRecordsCreatorAndForwardsNativeFee() public {
        uint256 treasuryBefore = treasury.balance;
        (uint256 basketId, address token) = _createDefaultBasket(0.1 ether, 0.05 ether);
        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        (uint256 registeredId, bool exists) = baskets.basketIdOf(token);

        assertEq(basketId, 0);
        assertEq(baskets.basketCount(), 1);
        assertEq(registeredId, basketId);
        assertTrue(exists);
        assertEq(configured.token, token);
        assertEq(configured.creator, alice);
        assertEq(configured.assets.length, 2);
        assertEq(configured.mintFeeTiers.length, 1);
        assertEq(configured.mintFeeTiers[0].feeShares, 0.1 ether);
        assertEq(configured.redemptionFeeTiers[0].feeShares, 0.05 ether);
        assertEq(configured.originationFeeBps, 100);
        assertEq(configured.recoveryPenaltyBps, 500);
        assertEq(treasury.balance - treasuryBefore, 1 ether);
        assertEq(address(diamond).balance, 0);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBasket).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBasketAdmin).interfaceId));
    }

    function testZeroCreationFeeRestrictsGenesisToOwner() public {
        basketAdmin.setCreationFee(0);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);

        vm.prank(alice);
        vm.expectRevert(BasketFacet.PermissionlessBasketCreationDisabled.selector);
        baskets.createBasket(params, _defaultPoolLaunchParams(2), _defaultLaunchMaximums(2), type(uint256).max);

        uint256 treasuryBefore = treasury.balance;
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, address(this));
        (uint256 basketId,) = baskets.createBasket(params, pools, maximums, type(uint256).max);
        assertEq(baskets.basket(basketId).creator, address(this));
        assertEq(treasury.balance, treasuryBefore);
    }

    function testOwnerCannotAttachNativeValueWhileCreationIsClosed() public {
        basketAdmin.setCreationFee(0);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.IncorrectCreationFee.selector, 0, 1 ether));
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        baskets.createBasket{value: 1 ether}(
            params,
            _defaultPoolLaunchParams(params.assets.length),
            _defaultLaunchMaximums(params.assets.length),
            type(uint256).max
        );
    }

    function testPositiveFeeReopensPermissionlessCreationAfterClosure() public {
        basketAdmin.setCreationFee(0);
        basketAdmin.setCreationFee(2 ether);
        vm.deal(bob, 2 ether);
        uint256 treasuryBefore = treasury.balance;

        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, bob);
        vm.prank(bob);
        (uint256 basketId,) = baskets.createBasket{value: 2 ether}(params, pools, maximums, type(uint256).max);

        assertEq(baskets.basket(basketId).creator, bob);
        assertEq(treasury.balance - treasuryBefore, 2 ether);
    }

    function testCreationRejectsExpiredLaunchDeadlineBeforeTakingValue() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.warp(1 days);
        uint256 expired = block.timestamp - 1;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.LaunchDeadlineExpired.selector, expired, block.timestamp));
        baskets.createBasket{value: 1 ether}(params, pools, maximums, expired);

        assertEq(baskets.basketCount(), 0);
        assertEq(treasury.balance, treasuryBefore);
    }

    function testClosingCreationDoesNotDisableExistingBasketLifecycle() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        basketAdmin.setCreationFee(0);

        vm.prank(alice);
        vm.expectRevert(BasketFacet.PermissionlessBasketCreationDisabled.selector);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        baskets.createBasket(params, _defaultPoolLaunchParams(2), _defaultLaunchMaximums(2), type(uint256).max);

        _fundAndApprove(alice, 2 ether, 5 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);
        uint256[] memory minimums = baskets.quoteRedeem(basketId, 1 ether);
        vm.prank(alice);
        baskets.redeem(basketId, 1 ether, alice, minimums);
    }

    function testStaticTierFeesDoNotChargeHistoricalBuyIn() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.mintFeeTiers = new IStaticsBasket.FeeTier[](2);
        params.mintFeeTiers[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: 0.1 ether});
        params.mintFeeTiers[1] = IStaticsBasket.FeeTier({minActionShares: 100 ether, feeShares: 0.5 ether});
        params.redemptionFeeTiers = new IStaticsBasket.FeeTier[](2);
        params.redemptionFeeTiers[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: 0.05 ether});
        params.redemptionFeeTiers[1] = IStaticsBasket.FeeTier({minActionShares: 100 ether, feeShares: 0.2 ether});
        (uint256 basketId, address token) = _launch(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVaultA = baskets.vaultBalance(basketId, address(assetA));
        uint256 launchTreasuryA = globalRewards.treasuryAccrued(address(assetA));
        _fundAndApprove(alice, 30 ether, 60 ether);
        _fundAndApprove(bob, 220 ether, 520 ether);

        uint256[] memory aliceQuote = baskets.quoteMint(basketId, 10 ether);
        assertEq(aliceQuote[0], 20.2 ether);
        assertEq(aliceQuote[1], 50.5 ether);
        vm.prank(alice);
        baskets.mint(basketId, 10 ether, alice, aliceQuote);
        assertEq(baskets.vaultBalance(basketId, address(assetA)) - launchVaultA, 20 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - launchTreasuryA, 0.2 ether);

        uint256[] memory sameActionQuote = baskets.quoteMint(basketId, 10 ether);
        assertEq(sameActionQuote[0], aliceQuote[0]);
        assertEq(baskets.feeSharesFor(basketId, true, 99 ether), 0.1 ether);
        assertEq(baskets.feeSharesFor(basketId, true, 100 ether), 0.5 ether);

        uint256[] memory bobQuote = baskets.quoteMint(basketId, 100 ether);
        assertEq(bobQuote[0], 201 ether);
        vm.prank(bob);
        baskets.mint(basketId, 100 ether, bob, bobQuote);
        assertEq(baskets.vaultBalance(basketId, address(assetA)) - launchVaultA, 220 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - launchTreasuryA, 1.2 ether);

        uint256[] memory redeemQuote = baskets.quoteRedeem(basketId, 10 ether);
        assertEq(redeemQuote[0], 19.9 ether);
        uint256 aliceBefore = assetA.balanceOf(alice);
        vm.prank(alice);
        baskets.redeem(basketId, 10 ether, alice, redeemQuote);
        assertEq(assetA.balanceOf(alice) - aliceBefore, redeemQuote[0]);
        assertEq(IERC20(token).balanceOf(alice), 0);

        uint256[] memory finalQuote = baskets.quoteRedeem(basketId, 100 ether);
        assertEq(finalQuote[0], 199.6 ether);
        vm.prank(bob);
        baskets.redeem(basketId, 100 ether, bob, finalQuote);
        assertEq(IERC20(token).totalSupply(), launchSupply);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVaultA);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - launchTreasuryA, 1.7 ether);
    }

    function testGuardianPauseLeavesRedemptionAvailable() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        _fundAndApprove(alice, 10 ether, 20 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);

        vm.prank(guardian);
        governance.pause(1 << 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.ActionPaused.selector, 1 << 0));
        baskets.mint(basketId, 1 ether, alice, quote);

        uint256[] memory minimums = baskets.quoteRedeem(basketId, 1 ether);
        vm.prank(alice);
        baskets.redeem(basketId, 1 ether, alice, minimums);
    }

    function testLiquidityPauseBlocksAtomicBasketLaunch() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(guardian);
        governance.pause(LibGovernance.PAUSE_LIQUIDITY);

        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.ActionPaused.selector, LibGovernance.PAUSE_LIQUIDITY));
        baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);

        assertEq(baskets.basketCount(), 0);
    }

    function testTreasuryClaimsOnlyRecordedRevenue() public {
        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        _fundAndApprove(alice, 10 ether, 20 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);
        uint256 revenue = globalRewards.treasuryAccrued(address(assetA));
        uint256 before = assetA.balanceOf(treasury);
        globalRewards.distributeTreasuryFees(address(assetA));
        assertEq(assetA.balanceOf(treasury) - before, revenue);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0);
    }

    function testCreationAcceptsArbitraryAssetsAndRejectsStructuralErrors() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[1] = address(new MockERC20("Untrusted Constituent", "UNTRUSTED", 18));
        IStaticsBasket.PoolLaunchParams[] memory pools = _defaultPoolLaunchParams(2);
        uint256[] memory maximums = _defaultLaunchMaximums(2);
        MockERC20(params.assets[0]).mint(alice, 1_000_000 ether);
        MockERC20(params.assets[1]).mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        IERC20(params.assets[0]).approve(address(diamond), 1_000_000 ether);
        IERC20(params.assets[1]).approve(address(diamond), 1_000_000 ether);
        baskets.createBasket{value: 1 ether}(params, pools, maximums, type(uint256).max);

        params.assets[1] = params.assets[0];
        vm.expectRevert(BasketFacet.InvalidBasketDefinition.selector);
        baskets.createBasket{value: 1 ether}(params, pools, maximums, type(uint256).max);

        params.assets[1] = address(assetB);
        params.flashFeeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.FeeExceedsCap.selector, 10_001));
        baskets.createBasket{value: 1 ether}(params, pools, maximums, type(uint256).max);
        vm.stopPrank();
    }

    function testCreationRequiresExactConfiguredNativeFee() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.IncorrectCreationFee.selector, 1 ether, 0));
        baskets.createBasket(params, _defaultPoolLaunchParams(2), _defaultLaunchMaximums(2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.IncorrectCreationFee.selector, 1 ether, 2 ether));
        baskets.createBasket{value: 2 ether}(
            params, _defaultPoolLaunchParams(2), _defaultLaunchMaximums(2), type(uint256).max
        );
        vm.stopPrank();
    }

    function testRecoveryPenaltyCannotMakeMaximumSeizureExceedCollateral() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.ltvBps = 9_500;
        params.recoveryPenaltyBps = 527;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BasketFacet.InvalidRecoveryParameters.selector, uint16(9_500), uint16(527))
        );
        baskets.createBasket{value: 1 ether}(
            params,
            _defaultPoolLaunchParams(params.assets.length),
            _defaultLaunchMaximums(params.assets.length),
            type(uint256).max
        );

        params.recoveryPenaltyBps = 526;
        (uint256 basketId,) = _launch(params, alice, 1 ether);
        assertEq(baskets.basket(basketId).recoveryPenaltyBps, 526);
    }

    function testCreationAllowsFullRangeCreatorFees() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(50_000 ether, 75_000 ether);
        params.flashFeeBps = 10_000;
        params.originationFeeBps = 10_000;
        params.extensionFeeBps = 10_000;

        (uint256 basketId,) = _launch(params, alice, 1 ether);

        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        assertEq(configured.mintFeeTiers[0].feeShares, 50_000 ether);
        assertEq(configured.redemptionFeeTiers[0].feeShares, 75_000 ether);
        assertEq(configured.originationFeeBps, 10_000);
    }

    function testFeesAggregateByAssetAcrossBaskets() public {
        (uint256 firstBasket,) = _createDefaultBasket(0.1 ether, 0);
        (uint256 secondBasket,) = _createDefaultBasket(0.1 ether, 0);
        uint256 launchRevenue = globalRewards.treasuryAccrued(address(assetA));
        _fundAndApprove(alice, 20 ether, 50 ether);
        uint256[] memory firstQuote = baskets.quoteMint(firstBasket, 1 ether);
        uint256[] memory secondQuote = baskets.quoteMint(secondBasket, 2 ether);
        vm.startPrank(alice);
        baskets.mint(firstBasket, 1 ether, alice, firstQuote);
        baskets.mint(secondBasket, 2 ether, alice, secondQuote);
        vm.stopPrank();

        uint256 aggregateRevenue = globalRewards.treasuryAccrued(address(assetA));
        assertEq(aggregateRevenue - launchRevenue, 0.4 ether);
        globalRewards.distributeTreasuryFees(address(assetA));
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0);
    }

    function testDirectDonationRemainsUnallocatedSurplus() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 reservedBefore = custody.globalReservedByToken(address(assetA));
        uint256 balanceBefore = assetA.balanceOf(address(diamond));
        assetA.mint(address(diamond), 1 ether);

        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0);
        assertEq(assetA.balanceOf(address(diamond)) - balanceBefore, 1 ether);
        assertEq(custody.globalReservedByToken(address(assetA)), reservedBefore);
        assertEq(custody.unreservedBalance(address(assetA)), 1 ether);
    }

    function testTreasuryRejectsZeroAndDiamondDestinations() public {
        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.InvalidTreasury.selector, address(0)));
        basketAdmin.setTreasury(address(0));

        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.InvalidTreasury.selector, address(diamond)));
        basketAdmin.setTreasury(address(diamond));

        assertEq(basketAdmin.treasury(), treasury);
    }

    function testGuardianConfigurationDoesNotProbeChosenAddress() public {
        governance.setGuardian(address(0));

        assertEq(governance.guardian(), address(0));
    }

    function testInboundTaxCreditsObservedNetWithoutUnderbacking() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0.02 ether, 0);
        params.assets[0] = address(taxed);
        IStaticsBasket.PoolLaunchParams[] memory pools = _defaultPoolLaunchParams(2);
        pools[0].pairedAssetAmount = 1;
        pools[1].pairedAssetAmount = 1;
        (uint256 basketId, address token) = _launchWith(params, pools, alice, 1 ether);
        uint256 launchVault = baskets.vaultBalance(basketId, address(taxed));
        uint256 launchBasketReserved = custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(taxed));
        uint256 launchReserved = custody.globalReservedByToken(address(taxed));
        uint256 launchTreasury = globalRewards.treasuryAccrued(address(taxed));
        vm.startPrank(alice);
        taxed.mint(alice, 10 ether);
        assetB.mint(alice, 10 ether);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        baskets.mint(basketId, 1 ether, alice, quote);
        vm.stopPrank();

        uint256 received = quote[0] * 99 / 100;
        uint256 backingIncrease = baskets.vaultBalance(basketId, address(taxed)) - launchVault;
        assertEq(IERC20(token).balanceOf(alice), 1 ether);
        assertGt(backingIncrease, 0);
        uint256 feeReceived = received - backingIncrease;
        assertEq(globalRewards.treasuryAccrued(address(taxed)) - launchTreasury, feeReceived);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(taxed)) - launchBasketReserved,
            backingIncrease
        );
        assertEq(custody.globalReservedByToken(address(taxed)) - launchReserved, received);
    }

    function testMinimumRedemptionUsesObservedReceiverDelta() public {
        MockOutboundFeeERC20 taxed = new MockOutboundFeeERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[0] = address(taxed);
        (uint256 basketId, address token) = _launch(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVault = baskets.vaultBalance(basketId, address(taxed));
        vm.startPrank(alice);
        taxed.mint(alice, 10 ether);
        assetB.mint(alice, 10 ether);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory inputs = baskets.quoteMint(basketId, 1 ether);
        baskets.mint(basketId, 1 ether, alice, inputs);
        taxed.setTaxedSender(address(diamond));
        uint256[] memory outputs = baskets.quoteRedeem(basketId, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketFacet.MinimumOutputNotMet.selector, address(taxed), outputs[0] * 99 / 100, outputs[0]
            )
        );
        baskets.redeem(basketId, 1 ether, alice, outputs);
        outputs[0] = outputs[0] * 99 / 100;
        uint256 beforeBalance = taxed.balanceOf(alice);
        baskets.redeem(basketId, 1 ether, alice, outputs);
        vm.stopPrank();

        assertEq(taxed.balanceOf(alice) - beforeBalance, outputs[0]);
        assertEq(IERC20(token).totalSupply(), launchSupply);
        assertEq(baskets.vaultBalance(basketId, address(taxed)), launchVault);
    }

    function testSenderExtraTaxCannotConsumeSharedCustody() public {
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[0] = address(taxed);
        (uint256 firstBasket, address firstToken) = _launch(params, alice, 1 ether);
        (uint256 secondBasket,) = _launch(params, alice, 1 ether);
        uint256 firstSupplyBefore = IERC20(firstToken).totalSupply();
        uint256 firstVaultBefore = baskets.vaultBalance(firstBasket, address(taxed));
        uint256 secondVaultBefore = baskets.vaultBalance(secondBasket, address(taxed));
        vm.startPrank(alice);
        taxed.mint(alice, 20 ether);
        assetB.mint(alice, 20 ether);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory firstInputs = baskets.quoteMint(firstBasket, 1 ether);
        uint256[] memory secondInputs = baskets.quoteMint(secondBasket, 1 ether);
        baskets.mint(firstBasket, 1 ether, alice, firstInputs);
        baskets.mint(secondBasket, 1 ether, alice, secondInputs);
        taxed.setTaxedSender(address(diamond));
        uint256[] memory outputs = baskets.quoteRedeem(firstBasket, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(LibCustody.DebitExceedsAuthorization.selector, address(taxed), 2.02 ether, 2 ether)
        );
        baskets.redeem(firstBasket, 1 ether, alice, outputs);
        vm.stopPrank();

        bytes32 firstAccount = custody.basketCustodyAccount(firstBasket);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasket);
        assertEq(IERC20(firstToken).totalSupply(), firstSupplyBefore + 1 ether);
        assertEq(baskets.vaultBalance(firstBasket, address(taxed)), firstVaultBefore + 2 ether);
        assertEq(custody.reservedByAccount(firstAccount, address(taxed)), firstVaultBefore + 2 ether);
        assertEq(custody.reservedByAccount(secondAccount, address(taxed)), secondVaultBefore + 2 ether);
    }

    function testProtocolRevenueCallbackCannotCrossIntoBasketFacet() public {
        MockReentrantERC20 reentrant = new MockReentrantERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0.01 ether, 0);
        params.assets[0] = address(reentrant);
        (uint256 basketId,) = _launch(params, alice, 1 ether);
        vm.startPrank(alice);
        reentrant.mint(alice, 10 ether);
        assetB.mint(alice, 10 ether);
        reentrant.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory inputs = baskets.quoteMint(basketId, 1 ether);
        baskets.mint(basketId, 1 ether, alice, inputs);
        vm.stopPrank();

        uint256[] memory minimums = new uint256[](2);
        reentrant.setCallback(
            address(diamond),
            address(diamond),
            abi.encodeCall(IStaticsBasket.redeem, (basketId, 1, address(reentrant), minimums))
        );
        globalRewards.distributeTreasuryFees(address(reentrant));

        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function testSingleAssetBasketFractionalizesOneConstituent() public {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0.05 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Fractional Stock",
            symbol: "sSTOCK",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: _singleFeeTier(0),
            redemptionFeeTiers: _singleFeeTier(0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (uint256 basketId, address token) = _launch(params, alice, 1 ether);
        uint256 launchVault = baskets.vaultBalance(basketId, address(assetA));
        assetA.mint(alice, 0.15 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        uint256[] memory quote = baskets.quoteMint(basketId, 3 ether);
        assertEq(quote[0], 0.15 ether);
        baskets.mint(basketId, 3 ether, alice, quote);
        uint256[] memory outputs = baskets.quoteRedeem(basketId, 1 ether);
        assertEq(outputs[0], 0.05 ether);
        baskets.redeem(basketId, 1 ether, alice, outputs);
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(alice), 2 ether);
        assertEq(baskets.vaultBalance(basketId, address(assetA)) - launchVault, 0.1 ether);
    }

    function testCreatedBasketTokenSupportsPermit() public {
        uint256 ownerKey = 0xa11ce;
        address owner = vm.addr(ownerKey);
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _fundAndApprove(owner, 2 ether, 5 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(owner);
        baskets.mint(basketId, 1 ether, owner, quote);

        uint256 deadline = block.timestamp + 1 days;
        uint256 value = 0.75 ether;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, bob, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        IERC20Permit(token).permit(owner, bob, value, deadline, v, r, s);

        assertEq(IERC20(token).allowance(owner, bob), value);
        assertEq(IERC20Permit(token).nonces(owner), 1);
    }

    function _launch(IStaticsBasket.CreateBasketParams memory params, address creator, uint256 value)
        private
        returns (uint256 basketId, address token)
    {
        return _launchWith(params, _defaultPoolLaunchParams(params.assets.length), creator, value);
    }

    function _launchWith(
        IStaticsBasket.CreateBasketParams memory params,
        IStaticsBasket.PoolLaunchParams[] memory pools,
        address creator,
        uint256 value
    ) private returns (uint256 basketId, address token) {
        (, uint256[] memory maximums) = _fundDefaultLaunch(params.assets, creator);
        vm.prank(creator);
        return baskets.createBasket{value: value}(params, pools, maximums, type(uint256).max);
    }

    function testFuzzFractionalMintAndFinalRedeemClearBacking(uint256 rawShares) public {
        uint256 shares = bound(rawShares, 1, 1_000_000 ether);
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVaultA = baskets.vaultBalance(basketId, address(assetA));
        uint256 launchVaultB = baskets.vaultBalance(basketId, address(assetB));
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, shares, alice, quote);

        uint256[] memory outputs = baskets.quoteRedeem(basketId, shares);
        vm.prank(alice);
        baskets.redeem(basketId, shares, alice, outputs);
        assertEq(IERC20(token).totalSupply(), launchSupply);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVaultA);
        assertEq(baskets.vaultBalance(basketId, address(assetB)), launchVaultB);
    }
}
