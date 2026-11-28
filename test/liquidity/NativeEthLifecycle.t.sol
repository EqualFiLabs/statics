// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsSwapRewardFunding} from "../../src/interfaces/IStaticsSwapRewardFunding.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LibCurrency} from "../../src/libraries/LibCurrency.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract RejectNativeLiquidityReceiver {
    receive() external payable {
        revert();
    }
}

contract ApprovalSweepToken is MockERC20 {
    address private manager;
    IPositionManager private posm;
    bool private armed;

    constructor() MockERC20("Approval Sweep", "SWEEP", 18) {}

    receive() external payable {}

    function arm(address manager_, IPositionManager posm_) external {
        manager = manager_;
        posm = posm_;
        armed = true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (armed && msg.sender == manager) {
            armed = false;
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(Currency.wrap(address(0)), address(this));
            posm.modifyLiquidities(abi.encode(abi.encodePacked(bytes1(uint8(Actions.SWEEP))), params), block.timestamp);
        }
        return super.approve(spender, amount);
    }
}

/// @notice Real v4 liquidity and claims; no synthetic native principal or reward credits.
contract NativeEthLifecycleTest is RangeGaugeLifecycleTestBase {
    using PoolIdLibrary for PoolKey;

    IStaticsProtocolPools private pools;
    IStaticsProtocolRevenue private revenue;
    PoolId private nativePool;
    PoolKey private nativeKey;
    uint256 private initialWethSupply;

    function setUp() public virtual override {
        super.setUp();
        initialWethSupply = wrappedNative.totalSupply();
        pools = IStaticsProtocolPools(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        nativePool = _createRangeGaugePool(alice, address(0), address(assetA));
        nativeKey = _poolKey(nativePool);
        vm.deal(alice, 1_000 ether);
        pools.setProtocolPolOperator(address(this));
    }

    function testRewardFundingCapabilityRejectsExternalCallers() public {
        vm.expectRevert("Statics: only self");
        IStaticsSwapRewardFunding(address(diamond)).fundPublicSwapRewards(address(wrappedNative), 1);
    }

    function testPartialFundingCoalescesPendingSourcesAndRequeuesConsumedSources() public {
        _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        _provide(_createPosition(alice), nativePool, alice);
        PoolId second = _createNativePool(address(assetB), 3_000);
        _provide(_createPosition(alice), second, alice);

        address reward = address(wrappedNative);
        _swap(nativeKey, true, -int256(0.1 ether));
        uint256 firstPending = globalRewards.unfundedSwapRewards(reward);
        _swap(_poolKey(second), true, -int256(0.1 ether));
        uint256 secondPending = globalRewards.unfundedSwapRewards(reward) - firstPending;
        assertGt(firstPending, 0);
        assertGt(secondPending, 0);

        uint256 partialAmount = firstPending / 2;
        assertEq(globalRewards.settlePublicSwapRewards(reward, partialAmount), partialAmount);
        uint256 beforeAccrual = globalRewards.unfundedSwapRewards(reward);
        _swap(nativeKey, true, -int256(0.1 ether));
        uint256 added = globalRewards.unfundedSwapRewards(reward) - beforeAccrual;
        uint256 firstRemaining = firstPending - partialAmount + added;
        assertEq(globalRewards.settlePublicSwapRewards(reward, firstRemaining), firstRemaining);
        assertEq(globalRewards.unfundedSwapRewards(reward), secondPending);

        _swap(nativeKey, true, -int256(0.1 ether));
        uint256 requeued = globalRewards.unfundedSwapRewards(reward) - secondPending;
        assertGt(requeued, 0);
        assertEq(globalRewards.settlePublicSwapRewards(reward, secondPending), secondPending);
        assertEq(globalRewards.unfundedSwapRewards(reward), requeued);
        assertEq(globalRewards.settlePublicSwapRewards(reward, type(uint256).max), requeued);
        assertEq(globalRewards.unfundedSwapRewards(reward), 0);
        assertEq(IStaticsSwapFeeHook(address(nativeKey.hooks)).pendingStakerRewards(nativeKey.currency0), 0);
    }

    function testMoreThanThirtyTwoSharedHookSourcesRequireBoundedRepeatedFunding() public {
        _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        for (uint256 i; i < 33; ++i) {
            MockERC20 paired = new MockERC20("Bounded Source", "SOURCE", 18);
            PoolId poolId = _createNativePool(address(paired), 3_000);
            _provide(_createPosition(alice), poolId, alice);
            _swap(_poolKey(poolId), true, -int256(0.01 ether));
        }

        uint256 unfunded = globalRewards.unfundedSwapRewards(address(wrappedNative));
        assertGt(unfunded, 0);
        uint256 first = globalRewards.settlePublicSwapRewards(address(wrappedNative), type(uint256).max);
        uint256 remaining = globalRewards.unfundedSwapRewards(address(wrappedNative));
        assertGt(first, 0);
        assertGt(remaining, 0);
        assertEq(globalRewards.settlePublicSwapRewards(address(wrappedNative), type(uint256).max), remaining);
        assertEq(globalRewards.unfundedSwapRewards(address(wrappedNative)), 0);
    }

    function testNativeManagedLifecycleRefundFeesRebalanceAndExit() public {
        uint256 pnft = _createPosition(alice);
        uint256 beforeNative = alice.balance;
        IStaticsRangeGauge.LiquidityMovement memory minted = _provide(pnft, nativePool, alice);
        assertEq(beforeNative - alice.balance, minted.spent0);
        assertEq(minted.spent0 + minted.received0, TOKEN_MAXIMUM);
        assertEq(address(diamond).balance, 0);
        assertEq(address(rangeLiquidityManager).balance, 0);
        assertEq(address(rangePositionManager).balance, 0);
        _fundAndApprovePoolAssets(nativeKey, alice, TOKEN_MAXIMUM);
        beforeNative = alice.balance;
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory increased = rangeGauge.increaseLiquidity{value: TOKEN_MAXIMUM}(
            pnft,
            nativePool,
            IStaticsRangeGauge.IncreaseLiquidityParams(1 ether, TOKEN_MAXIMUM, TOKEN_MAXIMUM, block.timestamp + 1 hours)
        );
        assertEq(beforeNative - alice.balance, increased.spent0);
        assertEq(increased.liquidity, 6 ether);
        _swap(nativeKey, true, -int256(0.2 ether));
        _swap(nativeKey, false, -int256(0.2 ether));
        beforeNative = alice.balance;
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory fees =
            rangeGauge.collectNativeFees(pnft, nativePool, 0, 0, block.timestamp + 1 hours);
        assertGt(fees.received0, 0);
        assertEq(alice.balance - beforeNative, fees.received0);
        assertEq(wrappedNative.balanceOf(alice), 0);
        vm.prank(alice);
        rangeGauge.decreaseLiquidity(
            pnft, nativePool, IStaticsRangeGauge.DecreaseLiquidityParams(1 ether, 0, 0, block.timestamp + 1 hours)
        );
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory replacement = rangeGauge.rebalanceLiquidity(
            pnft,
            nativePool,
            IStaticsRangeGauge.RebalanceLiquidityParams(-600, 600, 1 ether, 0, 0, 0, 0, block.timestamp + 1 hours)
        );
        assertTrue(replacement.posmTokenId != minted.posmTokenId);
        _assertPosmBurned(minted.posmTokenId);
        beforeNative = alice.balance;
        IStaticsRangeGauge.LiquidityMovement memory exited = _exit(pnft, nativePool, alice);
        assertEq(alice.balance - beforeNative, exited.received0);
        _assertPosmBurned(replacement.posmTokenId);
        assertEq(rangeGauge.gaugePool(nativePool).activeGaugeLiquidity, 0);
        assertEq(address(diamond).balance, 0);
    }

    function testAttachExternalNativeNftCanCollectDecreaseAndExit() public {
        uint256 nft = _mintUnmanagedPosition(nativeKey, alice);
        uint256 pnft = _createPosition(alice);
        vm.prank(alice);
        IERC721(address(rangePositionManager)).approve(address(rangeLiquidityManager), nft);
        vm.prank(alice);
        rangeGauge.attachLiquidity(pnft, nativePool, nft);
        _swap(nativeKey, true, -int256(0.1 ether));
        vm.prank(alice);
        rangeGauge.collectNativeFees(pnft, nativePool, 0, 0, block.timestamp + 1 hours);
        vm.prank(alice);
        rangeGauge.decreaseLiquidity(
            pnft, nativePool, IStaticsRangeGauge.DecreaseLiquidityParams(1 ether, 0, 0, block.timestamp + 1 hours)
        );
        assertGt(_exit(pnft, nativePool, alice).received0, 0);
        _assertPosmBurned(nft);
    }

    function testExactInputAndOutputBothDirectionsAndLazyNativeClaims() public {
        _provide(_createPosition(alice), nativePool, alice);
        _swap(nativeKey, true, -int256(0.1 ether));
        _swap(nativeKey, false, -int256(0.1 ether));
        _swap(nativeKey, true, int256(0.01 ether));
        _swap(nativeKey, false, int256(0.01 ether));
        assertGt(swapFeeHook.claimLiability(Currency.wrap(address(0))), 0);
        assertEq(poolManager.balanceOf(address(swapFeeHook), 0), swapFeeHook.claimLiability(Currency.wrap(address(0))));
        assertEq(wrappedNative.totalSupply(), initialWethSupply);
        assertEq(address(diamond).balance, 0);
    }

    function testFuzzNativeStaticLpFee(uint256 fee) public {
        fee = bound(fee, 0, 999_999);
        PoolId poolId = _createNativePool(address(assetB), uint24(fee));
        assertEq(pools.protocolPool(poolId).key.fee, fee);
    }

    function testZeroLpFeeRetainsBilateralHookFeesAndNativeLiquidity() public {
        PoolId poolId = _createNativePool(address(assetB), 0);
        PoolKey memory key = _poolKey(poolId);
        _provide(_createPosition(alice), poolId, alice);
        _swap(key, true, -int256(0.1 ether));
        _swap(key, false, int256(0.01 ether));
        assertGt(IStaticsSwapFeeHook(address(key.hooks)).claimLiability(key.currency0), 0);
    }

    function testNativeAndWethFeesShareOneOptInAndLazyRewardBook() public {
        uint256 staker = _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        _provide(_createPosition(alice), nativePool, alice);
        _swap(nativeKey, true, -int256(0.1 ether));
        uint256 nativePending = swapFeeHook.pendingStakerRewards(nativeKey.currency0);
        assertGt(nativePending, 0);
        assertEq(globalRewards.unfundedSwapRewards(address(wrappedNative)), nativePending);
        assertEq(globalRewards.unfundedSwapRewards(address(0)), 0);
        assertEq(wrappedNative.totalSupply(), initialWethSupply);
        PoolId wethPool = _createRangeGaugePool(alice, address(wrappedNative), address(assetB));
        PoolKey memory wethKey = _poolKey(wethPool);
        _mintWethLiquidity(wethPool);
        // Deposit-backed WETH, including the swap payer's input.
        wrappedNative.deposit{value: 1 ether}();
        wrappedNative.transfer(alice, 1 ether);
        vm.prank(alice);
        wrappedNative.approve(address(v4Router), type(uint256).max);
        vm.prank(alice);
        v4Router.swap(
            wethKey,
            SwapParams(
                Currency.unwrap(wethKey.currency0) == address(wrappedNative),
                -int256(0.1 ether),
                Currency.unwrap(wethKey.currency0) == address(wrappedNative)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        uint256 wethPending =
            IStaticsSwapFeeHook(address(wethKey.hooks)).pendingStakerRewards(Currency.wrap(address(wrappedNative)));
        assertGt(wethPending, 0);
        uint256 combined = nativePending + wethPending;
        assertEq(globalRewards.unfundedSwapRewards(address(wrappedNative)), combined);
        // New accruals retain their original currency and fund in source arrival order.
        // Both source claims still back the same unchanged WETH reward entitlement.
        uint256 requested = wethPending + nativePending / 2;
        assertEq(globalRewards.settlePublicSwapRewards(address(wrappedNative), requested), requested);
        uint256 nativeFunded = requested < nativePending ? requested : nativePending;
        assertEq(swapFeeHook.pendingStakerRewards(nativeKey.currency0), nativePending - nativeFunded);
        assertEq(
            IStaticsSwapFeeHook(address(wethKey.hooks)).pendingStakerRewards(Currency.wrap(address(wrappedNative))),
            wethPending - (requested - nativeFunded)
        );
        globalRewards.settlePublicSwapRewards(address(wrappedNative), type(uint256).max);
        address[] memory assets = new address[](1);
        assets[0] = address(wrappedNative);
        uint256[] memory minimum = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(staker, assets, alice, minimum);
        assertGt(claimed[0], 0);
        assertLe(claimed[0], combined);
        assertEq(globalRewards.unfundedSwapRewards(address(wrappedNative)), 0);
    }

    function testNativeCreatorTreasuryAndMaintenanceTipAreWeth() public {
        _provide(_createPosition(alice), nativePool, alice);
        _swap(nativeKey, true, -int256(0.1 ether));
        IStaticsSwapFeeHook.FeeDistribution memory pending =
            swapFeeHook.pendingFeeDistribution(nativePool, nativeKey.currency0);
        pools.setProtocolPoolMaintenanceConfig(IStaticsProtocolPools.ProtocolPoolMaintenanceConfig(100));
        (uint256 gross, uint256 tip) = pools.settleProtocolPoolRevenue(nativePool, address(0));
        assertEq(gross, pending.creator + pending.treasury);
        assertGt(tip, 0);
        assertEq(wrappedNative.balanceOf(address(this)), tip);
        assertEq(revenue.creatorRevenue(nativePool, address(0)), 0);
        assertEq(revenue.creatorRevenue(nativePool, address(wrappedNative)), pending.creator);
        revenue.claimCreatorRevenue(nativePool, address(wrappedNative), alice, pending.creator);
        assertEq(wrappedNative.balanceOf(alice), pending.creator);
        uint256 treasuryAmount = globalRewards.treasuryAccrued(address(wrappedNative));
        globalRewards.distributeTreasuryFees(address(wrappedNative));
        assertEq(wrappedNative.balanceOf(treasury), treasuryAmount);
        assertEq(address(diamond).balance, 0);
    }

    function testExactNativeValueAndNoEthForErc20Provide() public {
        uint256 pnft = _createPosition(alice);
        _fundAndApprovePoolAssets(nativeKey, alice, TOKEN_MAXIMUM);
        IStaticsRangeGauge.ProvideLiquidityParams memory params = _provideParams(nativePool, -600, 600);
        vm.prank(alice);
        vm.expectPartialRevert(LibCurrency.InvalidMsgValue.selector);
        rangeGauge.provideLiquidity(pnft, params);
        vm.prank(alice);
        vm.expectPartialRevert(LibCurrency.InvalidMsgValue.selector);
        rangeGauge.provideLiquidity{value: TOKEN_MAXIMUM + 1}(pnft, params);
        PoolId ercPool = _createRangeGaugePool(alice);
        vm.prank(alice);
        vm.expectPartialRevert(LibCurrency.InvalidMsgValue.selector);
        rangeGauge.provideLiquidity{value: 1}(pnft, _provideParams(ercPool, -600, 600));
    }

    function testUnexpectedNativeSenderRejectedByDiamondAndManager() public {
        vm.expectPartialRevert(StaticsDiamond.NativeSenderNotAllowed.selector);
        _send(address(diamond), 1);
        vm.expectPartialRevert(StaticsLiquidityManager.UnauthorizedETHSender.selector);
        _send(address(rangeLiquidityManager), 1);
        // Even the PoolManager may not send outside an authorized operation.
        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        vm.expectPartialRevert(StaticsDiamond.NativeSenderNotAllowed.selector);
        _send(address(diamond), 1);
    }

    function testRejectedNativeExitReceiverRollsBackNftAndGauge() public {
        uint256 pnft = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory minted = _provide(pnft, nativePool, alice);
        RejectNativeLiquidityReceiver rejector = new RejectNativeLiquidityReceiver();
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, address(rejector), pnft);
        vm.prank(address(rejector));
        vm.expectPartialRevert(LibCurrency.NativeTransferFailed.selector);
        rangeGauge.exitLiquidity(pnft, nativePool, 0, 0, block.timestamp + 1 hours);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(minted.posmTokenId), address(rangeLiquidityManager));
        assertEq(rangeGauge.gaugePool(nativePool).activeGaugeLiquidity, INITIAL_LIQUIDITY);
    }

    function testPeripheryAndManagerForcedSurplusDoNotInflateRefund() public {
        // Deliberately force balances: neither production receive path permits unsolicited sends.
        vm.deal(address(rangePositionManager), 0.7 ether);
        vm.deal(address(rangeLiquidityManager), 0.3 ether);
        uint256 beforeNative = alice.balance;
        IStaticsRangeGauge.LiquidityMovement memory minted = _provide(_createPosition(alice), nativePool, alice);
        assertEq(beforeNative - alice.balance, minted.spent0);
        assertEq(minted.received0 + minted.spent0, TOKEN_MAXIMUM);
        assertEq(address(rangeLiquidityManager).balance, 1 ether);
        assertEq(address(rangePositionManager).balance, 0);
    }

    function testApprovalCallbackCannotChargePeripherySurplusToNativeMint() public {
        ApprovalSweepToken token = new ApprovalSweepToken();
        PoolId pool = _createRangeGaugePool(alice, address(0), address(token));
        uint256 pnft = _createPosition(alice);
        // Forced periphery ETH exercises a public SWEEP callback without synthetic LP accounting.
        vm.deal(address(rangePositionManager), 1 ether);
        token.arm(address(rangeLiquidityManager), rangePositionManager);
        uint256 beforeNative = alice.balance;
        IStaticsRangeGauge.LiquidityMovement memory movement = _provide(pnft, pool, alice);
        assertEq(address(token).balance, 1 ether);
        assertEq(beforeNative - alice.balance, movement.spent0);
        assertEq(movement.spent0 + movement.received0, TOKEN_MAXIMUM);
        assertEq(address(rangeLiquidityManager).balance, 0);
        assertEq(address(rangePositionManager).balance, 0);
    }

    function testApprovalCallbackCannotChargePeripherySurplusToNativeIncrease() public {
        ApprovalSweepToken token = new ApprovalSweepToken();
        PoolId pool = _createRangeGaugePool(alice, address(0), address(token));
        uint256 pnft = _createPosition(alice);
        _provide(pnft, pool, alice);
        PoolKey memory key = _poolKey(pool);
        _fundAndApprovePoolAssets(key, alice, TOKEN_MAXIMUM);
        // The callback changes only old periphery surplus; ERC-20 transfers remain exact.
        vm.deal(address(rangePositionManager), 1 ether);
        token.arm(address(rangeLiquidityManager), rangePositionManager);
        uint256 beforeNative = alice.balance;
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory movement = rangeGauge.increaseLiquidity{value: TOKEN_MAXIMUM}(
            pnft,
            pool,
            IStaticsRangeGauge.IncreaseLiquidityParams(1 ether, TOKEN_MAXIMUM, TOKEN_MAXIMUM, block.timestamp + 1 hours)
        );
        assertEq(address(token).balance, 1 ether);
        assertEq(beforeNative - alice.balance, movement.spent0);
        assertEq(movement.spent0 + movement.received0, TOKEN_MAXIMUM);
        assertEq(address(rangeLiquidityManager).balance, 0);
        assertEq(address(rangePositionManager).balance, 0);
    }

    function testDirectGaugeRewardsAccrueForNativeRange() public {
        uint256 pnft = _createPosition(alice);
        _provide(pnft, nativePool, alice);
        MockERC20 reward = new MockERC20("Direct", "DIR", 18);
        _fundReward(nativePool, reward, 700 ether);
        vm.warp(block.timestamp + 1 days);
        assertGt(_claim(pnft, nativePool, address(reward), 0, alice, alice), 0);
    }

    function testOutOfRangeNativeGaugeHasZeroActiveWeight() public {
        uint256 pnft = _createPosition(alice);
        _fundAndApprovePoolAssets(nativeKey, alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        rangeGauge.provideLiquidity{value: TOKEN_MAXIMUM}(pnft, _provideParams(nativePool, 100, 200));
        assertEq(rangeGauge.gaugePool(nativePool).activeGaugeLiquidity, 0);
        MockERC20 reward = new MockERC20("Direct", "DIR", 18);
        _fundReward(nativePool, reward, 700 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(rangeGauge.lpLeg(pnft, nativePool).claimable[1], 0);
    }

    function testNativePolPortfolioAndWethRewardsCannotConsumeItsPrincipal() public {
        _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        _provide(_createPosition(alice), nativePool, alice);
        vm.prank(alice);
        pools.activateProtocolPoolPol(nativePool);
        _swap(nativeKey, true, -int256(0.2 ether));
        _swap(nativeKey, false, -int256(0.2 ether));
        _settlePol(nativePool, nativeKey);
        uint256 nativeReserved = _nativeReserve(nativePool);
        assertGt(nativeReserved, 0);
        assertEq(address(diamond).balance, nativeReserved);
        globalRewards.settlePublicSwapRewards(address(wrappedNative), type(uint256).max);
        pools.settleProtocolPoolRevenue(nativePool, address(0));
        assertEq(_nativeReserve(nativePool), nativeReserved);
        assertEq(address(diamond).balance, nativeReserved);
        uint256 polId = _openPol(nativePool, nativeKey, 1e15);
        assertEq(pools.protocolPolPosition(polId).liquidity, 1e15);
        _swap(nativeKey, true, -int256(0.1 ether));
        _swap(nativeKey, false, -int256(0.1 ether));
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(wrappedNative));
        pools.collectProtocolPolFees(polId, block.timestamp + 1 hours);
        assertGt(globalRewards.treasuryAccrued(address(wrappedNative)), treasuryBefore);
        pools.increaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams(
                polId, 1e15, _nativeReserve(nativePool), _tokenReserve(nativePool, nativeKey), block.timestamp + 1 hours
            )
        );
        pools.decreaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams(polId, 1e15, 0, 0, block.timestamp + 1 hours)
        );
        pools.closeProtocolPolPosition(polId, 0, 0, block.timestamp + 1 hours);
        assertEq(address(diamond).balance, _nativeReserve(nativePool));
        assertEq(custody.globalReservedByToken(address(0)), address(diamond).balance);
        assertEq(address(rangeLiquidityManager).balance, 0);
    }

    function testMultipleNativePoolsCannotSpendEachOthersPolReservations() public {
        _provide(_createPosition(alice), nativePool, alice);
        vm.prank(alice);
        pools.activateProtocolPoolPol(nativePool);
        _swap(nativeKey, true, -int256(0.2 ether));
        _swap(nativeKey, false, -int256(0.2 ether));
        _settlePol(nativePool, nativeKey);
        uint256 firstReserve = _nativeReserve(nativePool);
        PoolId other = _createNativePool(address(assetB), 1_000);
        PoolKey memory otherKey = _poolKey(other);
        vm.prank(alice);
        pools.activateProtocolPoolPol(other);
        vm.expectPartialRevert(LibCustody.InsufficientAccountReservation.selector);
        pools.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams(
                other, -600, 600, 1e15, firstReserve, 0, block.timestamp + 1 hours
            )
        );
        assertEq(_nativeReserve(nativePool), firstReserve);
        _provide(_createPosition(alice), other, alice);
        _swap(otherKey, true, -int256(0.1 ether));
        _swap(otherKey, false, -int256(0.1 ether));
        _settlePol(other, otherKey);
        uint256 polId = _openPol(other, otherKey, 1e15);
        pools.closeProtocolPolPosition(polId, 0, 0, block.timestamp + 1 hours);
        assertEq(_nativeReserve(nativePool), firstReserve);
        assertEq(address(diamond).balance, firstReserve + _nativeReserve(other));
    }

    function testNativePolRebalanceAndDecommissionClassifyPrincipalOnlyAtTreasuryBoundary() public {
        _provide(_createPosition(alice), nativePool, alice);
        vm.prank(alice);
        pools.activateProtocolPoolPol(nativePool);
        _swap(nativeKey, true, -int256(0.2 ether));
        _swap(nativeKey, false, -int256(0.2 ether));
        _settlePol(nativePool, nativeKey);
        uint256 original = _openPol(nativePool, nativeKey, 1e15);
        IStaticsProtocolPools.ProtocolPolCloseLeg[] memory closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](1);
        closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(original, 0, 0);
        IStaticsProtocolPools.ProtocolPolOpenLeg[] memory opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](1);
        opens[0] = IStaticsProtocolPools.ProtocolPolOpenLeg(
            -1200, 1200, 1e15, _nativeReserve(nativePool), _tokenReserve(nativePool, nativeKey)
        );
        uint256[] memory replaced = pools.rebalanceProtocolPolPositions(
            IStaticsProtocolPools.ProtocolPolRebalanceParams(
                nativePool, closes, opens, opens[0].amount0Maximum, opens[0].amount1Maximum, block.timestamp + 1 hours
            )
        );
        assertFalse(pools.protocolPolPosition(original).active);
        assertTrue(pools.protocolPolPosition(replaced[0]).active);
        pools.closeProtocolPolPosition(replaced[0], 0, 0, block.timestamp + 1 hours);
        uint256 nativeBefore = _nativeReserve(nativePool);
        uint256 wethBefore = wrappedNative.balanceOf(address(diamond));
        pools.beginGeneralPoolDecommission(nativePool);
        pools.finalizeGeneralPoolDecommission(nativePool);
        assertEq(_nativeReserve(nativePool), 0);
        assertEq(address(diamond).balance, 0);
        assertGe(wrappedNative.balanceOf(address(diamond)) - wethBefore, nativeBefore);
        assertEq(swapFeeHook.pendingProtocolPol(nativePool, nativeKey.currency0), 0);
        assertEq(swapFeeHook.pendingFeeDistribution(nativePool, nativeKey.currency0).treasury, 0);
    }

    function testStaticsAllocationRewardsNativeGauge() public {
        _installGaugeActions();
        uint256 pnft = _stakeWeth();
        _provide(pnft, nativePool, alice);
        IStaticsGaugeIncentives incentives = IStaticsGaugeIncentives(address(diamond));
        vm.warp(block.timestamp + 7 days);
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = nativePool;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10 ether;
        vm.prank(alice);
        incentives.setGaugeAllocations(pnft, ids, allocations);
        stakingAsset.mint(address(this), 1_000 ether);
        stakingAsset.approve(address(diamond), 1_000 ether);
        incentives.fundGaugeReserve(1_000 ether);
        incentives.activateGaugeSchedule();
        vm.warp(block.timestamp + 1 days);
        uint8[] memory slots = new uint8[](1);
        uint256[] memory minimum = new uint256[](1);
        vm.prank(alice);
        uint256[] memory amounts = rangeGauge.claimLpRewards(pnft, nativePool, slots, minimum, alice);
        assertGt(amounts[0], 0);
    }

    function testNativeIncreaseAndRebalanceRejectExcessValue() public {
        uint256 pnft = _createPosition(alice);
        _provide(pnft, nativePool, alice);
        vm.prank(alice);
        vm.expectPartialRevert(LibCurrency.InvalidMsgValue.selector);
        rangeGauge.increaseLiquidity{value: 1}(
            pnft, nativePool, IStaticsRangeGauge.IncreaseLiquidityParams(1 ether, 0, 0, block.timestamp + 1 hours)
        );
        vm.prank(alice);
        vm.expectPartialRevert(LibCurrency.InvalidMsgValue.selector);
        rangeGauge.rebalanceLiquidity{value: 1}(
            pnft,
            nativePool,
            IStaticsRangeGauge.RebalanceLiquidityParams(-600, 600, 1 ether, 0, 0, 0, 0, block.timestamp + 1 hours)
        );
        assertEq(rangeGauge.gaugePool(nativePool).activeGaugeLiquidity, INITIAL_LIQUIDITY);
    }

    function testFuzzNativeMixedSettlementConservation(uint256 seed) public {
        _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        uint256 pnft = _createPosition(alice);
        _provide(pnft, nativePool, alice);
        vm.prank(alice);
        pools.activateProtocolPoolPol(nativePool);
        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _swap(nativeKey, seed & 1 == 0, -int256(1e15 + seed % 1e17));
            if (seed & 2 != 0) _settlePol(nativePool, nativeKey);
            if (seed & 4 != 0) pools.settleProtocolPoolRevenue(nativePool, address(0));
            if (seed & 8 != 0) globalRewards.settlePublicSwapRewards(address(wrappedNative), seed % 1e16);
            assertEq(poolManager.balanceOf(address(swapFeeHook), 0), swapFeeHook.claimLiability(nativeKey.currency0));
            assertEq(address(diamond).balance, custody.globalReservedByToken(address(0)));
            assertEq(address(diamond).balance, _nativeReserve(nativePool));
            assertGe(wrappedNative.balanceOf(address(diamond)), custody.globalReservedByToken(address(wrappedNative)));
            assertEq(address(rangeLiquidityManager).balance, 0);
        }
        _exit(pnft, nativePool, alice);
        assertEq(address(diamond).balance, _nativeReserve(nativePool));
    }

    function testEthWethPoolSharesOneRewardBookAndHarvestsBothCurrencies() public {
        _stakeWeth();
        vm.warp(block.timestamp + 25 hours);
        PoolId poolId = _createNativePool(address(wrappedNative), 3000);
        PoolKey memory key = _poolKey(poolId);
        uint256 pnft = _createPosition(alice);
        wrappedNative.deposit{value: 20 ether}();
        wrappedNative.transfer(alice, 20 ether);
        vm.startPrank(alice);
        wrappedNative.approve(address(diamond), type(uint256).max);
        wrappedNative.approve(address(v4Router), type(uint256).max);
        rangeGauge.provideLiquidity{value: TOKEN_MAXIMUM}(pnft, _provideParams(poolId, -600, 600));
        pools.activateProtocolPoolPol(poolId);
        vm.stopPrank();
        _swap(key, true, -int256(0.1 ether));
        vm.prank(alice);
        v4Router.swap(key, SwapParams(false, -int256(0.1 ether), TickMath.MAX_SQRT_PRICE - 1));
        assertEq(
            globalRewards.unfundedSwapRewards(address(wrappedNative)),
            IStaticsSwapFeeHook(address(key.hooks)).pendingStakerRewards(key.currency0)
                + IStaticsSwapFeeHook(address(key.hooks)).pendingStakerRewards(key.currency1)
        );
        _settlePol(poolId, key);
        uint256 polId = _openPol(poolId, key, 1e15);
        _swap(key, true, -int256(0.1 ether));
        vm.prank(alice);
        v4Router.swap(key, SwapParams(false, -int256(0.1 ether), TickMath.MAX_SQRT_PRICE - 1));
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(wrappedNative));
        pools.collectProtocolPolFees(polId, block.timestamp + 1 hours);
        assertGt(globalRewards.treasuryAccrued(address(wrappedNative)), treasuryBefore);
        globalRewards.settlePublicSwapRewards(address(wrappedNative), type(uint256).max);
        pools.closeProtocolPolPosition(polId, 0, 0, block.timestamp + 1 hours);
        assertEq(address(diamond).balance, _nativeReserve(poolId));
        assertGe(wrappedNative.balanceOf(address(diamond)), custody.globalReservedByToken(address(wrappedNative)));
    }

    function _installGaugeActions() private {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = GaugeIncentiveFacet.fundGaugeReserve.selector;
        selectors[1] = GaugeIncentiveFacet.setGaugeAllocations.selector;
        selectors[2] = GaugeIncentiveFacet.activateGaugeSchedule.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(new GaugeIncentiveFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _send(address receiver, uint256 amount) private {
        (bool ok, bytes memory reason) = receiver.call{value: amount}("");
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 specified) private {
        address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        uint256 maximum = specified < 0 ? uint256(-specified) : 1 ether;
        if (input != address(0)) {
            MockERC20(input).mint(alice, maximum);
            _approveV4Router(alice, input);
        }
        vm.prank(alice);
        v4Router.swap{value: input == address(0) ? maximum : 0}(
            key,
            SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function _prepareNativePool(IStaticsProtocolPools.CreatePoolParams memory) internal virtual {}

    function _createNativePool(address paired, uint24 fee) private returns (PoolId poolId) {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams(
            address(0),
            paired,
            fee,
            10,
            SQRT_PRICE_1_1,
            IStaticsProtocolPools.PoolSwapFeeRate(2_500, 2_500),
            alice,
            false,
            0,
            block.timestamp + 1 hours
        );
        _prepareNativePool(params);
        poolId = pools.createPool(params, "");
    }

    function _provideParams(PoolId poolId, int24 lower, int24 upper)
        private
        view
        returns (IStaticsRangeGauge.ProvideLiquidityParams memory)
    {
        return IStaticsRangeGauge.ProvideLiquidityParams(
            poolId, lower, upper, INITIAL_LIQUIDITY, TOKEN_MAXIMUM, TOKEN_MAXIMUM, block.timestamp + 1 hours
        );
    }

    function _stakeWeth() private returns (uint256 positionId) {
        address[] memory assets = new address[](1);
        assets[0] = address(wrappedNative);
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        positionId = globalRewards.createAndStake(10 ether, alice, assets);
        vm.stopPrank();
    }

    function _mintWethLiquidity(PoolId poolId) private {
        wrappedNative.deposit{value: TOKEN_MAXIMUM}();
        wrappedNative.transfer(alice, TOKEN_MAXIMUM);
        assetB.mint(alice, TOKEN_MAXIMUM);
        uint256 pnft = _createPosition(alice);
        vm.startPrank(alice);
        wrappedNative.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        rangeGauge.provideLiquidity(
            pnft, _provideParams(poolId, TickMath.minUsableTick(10), TickMath.maxUsableTick(10))
        );
        vm.stopPrank();
    }

    function _settlePol(PoolId poolId, PoolKey memory key) private {
        pools.settleProtocolPoolPol(poolId, address(0), 0);
        pools.settleProtocolPoolPol(poolId, Currency.unwrap(key.currency1), 0);
    }

    function _nativeReserve(PoolId poolId) private view returns (uint256) {
        return custody.reservedByAccount(custody.protocolPolCustodyAccount(PoolId.unwrap(poolId)), address(0));
    }

    function _tokenReserve(PoolId poolId, PoolKey memory key) private view returns (uint256) {
        return custody.reservedByAccount(
            custody.protocolPolCustodyAccount(PoolId.unwrap(poolId)), Currency.unwrap(key.currency1)
        );
    }

    function _openPol(PoolId poolId, PoolKey memory key, uint128 liquidity) private returns (uint256) {
        return pools.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams(
                poolId,
                -600,
                600,
                liquidity,
                _nativeReserve(poolId),
                _tokenReserve(poolId, key),
                block.timestamp + 1 hours
            )
        );
    }
}
