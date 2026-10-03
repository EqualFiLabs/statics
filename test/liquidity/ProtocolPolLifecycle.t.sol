// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {ProtocolPolFacet} from "../../src/facets/ProtocolPolFacet.sol";
import {ProtocolPoolAdminFacet} from "../../src/facets/ProtocolPoolAdminFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

contract ProtocolPolLifecycleTest is GeneralPoolLifecycleTestBase {
    using PoolIdLibrary for PoolKey;

    address private creator = makeAddr("pol-creator");
    address private operator = makeAddr("pol-operator");
    address private lp = makeAddr("pol-market-lp");
    address private trader = makeAddr("pol-trader");
    IStaticsRangeGauge private rangeGauge;

    function setUp() public override {
        super.setUp();
        RangeGaugeViewFacet viewFacet = new RangeGaugeViewFacet();
        RangeGaugeLivenessFacet livenessFacet = new RangeGaugeLivenessFacet();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        bytes4[] memory viewSelectors = new bytes4[](1);
        viewSelectors[0] = RangeGaugeViewFacet.posmBinding.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: viewSelectors
        });
        bytes4[] memory livenessSelectors = new bytes4[](1);
        livenessSelectors[0] = RangeGaugeLivenessFacet.recoverUnboundPosm.selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(livenessFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: livenessSelectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        rangeGauge = IStaticsRangeGauge(address(diamond));
        pools.setProtocolPolOperator(operator);
    }

    function testActivationIsCreatorPaidProspectiveAndPermanent() public {
        address tokenA = _newToken("Activation Alpha");
        address tokenB = _newToken("Activation Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);

        _swapGeneralPool(key, trader, true, 0.2 ether);
        assertEq(swapFeeHook.pendingProtocolPol(poolId, key.currency0), 0);
        assertEq(swapFeeHook.pendingProtocolPol(poolId, key.currency1), 0);

        uint256 fee = 0.25 ether;
        pools.setProtocolPolActivationFee(fee);
        vm.deal(creator, fee * 2);
        vm.deal(trader, fee);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.OnlyPoolCreator.selector, trader, creator));
        pools.activateProtocolPoolPol{value: fee}(poolId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.IncorrectProtocolPolActivationFee.selector, fee, 0));
        pools.activateProtocolPoolPol(poolId);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(creator);
        pools.activateProtocolPoolPol{value: fee}(poolId);
        assertEq(treasury.balance - treasuryBefore, fee);
        assertTrue(pools.protocolPool(poolId).polActivated);

        _swapGeneralPool(key, trader, false, 0.2 ether);
        uint256 pendingBeforeOverride = _pendingPol(poolId, key);
        assertGt(pendingBeforeOverride, 0);

        pools.setProtocolPoolPolShare(poolId, 0);
        _swapGeneralPool(key, trader, true, 0.2 ether);
        assertEq(_pendingPol(poolId, key), pendingBeforeOverride);
        assertTrue(pools.protocolPool(poolId).polActivated);
        assertEq(pools.protocolPool(poolId).polShareBps, 0);

        pools.clearProtocolPoolPolShare(poolId);
        _swapGeneralPool(key, trader, false, 0.2 ether);
        assertGt(_pendingPol(poolId, key), pendingBeforeOverride);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.ProtocolPolAlreadyActivated.selector, poolId));
        pools.activateProtocolPoolPol{value: fee}(poolId);
    }

    function testGlobalAllocationReductionCapsExistingPoolOverride() public {
        address tokenA = _newToken("Override Alpha");
        address tokenB = _newToken("Override Beta");
        (PoolId poolId, PoolKey memory key) = _createGeneralPool(tokenA, tokenB, 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);
        vm.prank(creator);
        pools.activateProtocolPoolPol(poolId);

        pools.setProtocolPoolPolShare(poolId, 6_000);
        assertEq(pools.protocolPool(poolId).polShareBps, 6_000);

        pools.setGeneralFeeAllocation(
            IStaticsProtocolPools.GeneralFeeAllocation({
                polShareBps: 0, staticsStakerShareBps: 9_000, treasuryShareBps: 500
            })
        );
        assertEq(pools.protocolPool(poolId).polShareBps, 500);

        _swapGeneralPool(key, trader, true, 0.2 ether);
        assertGt(_pendingPol(poolId, key), 0);
    }

    function testManagedPortfolioKeepsPrincipalBoundAndRoutesNativeFeesToTreasury() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Portfolio Alpha", "Portfolio Beta");
        uint256 firstPosition = _openPosition(poolId, key, -600, 600, 1e15, operator);
        uint256 secondPosition = _openPosition(poolId, key, -1_200, 1_200, 1e15, operator);

        assertEq(pools.protocolPool(poolId).activePolPositions, 2);
        _assertProtocolBinding(firstPosition);
        _assertProtocolBinding(secondPosition);

        IStaticsProtocolPools.ProtocolPolPositionView memory first = pools.protocolPolPosition(firstPosition);
        vm.expectPartialRevert(StaticsLiquidityManager.BoundPositionRecovery.selector);
        rangeGauge.recoverUnboundPosm(first.manager, first.posmTokenId, trader);

        uint256 treasuryBefore = globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
            + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1));
        _swapGeneralPool(key, trader, true, 0.5 ether);
        _swapGeneralPool(key, trader, false, 0.5 ether);
        vm.prank(operator);
        pools.collectProtocolPolFees(firstPosition, block.timestamp + 1 days);
        assertGt(
            globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
                + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1)),
            treasuryBefore
        );

        _settlePol(poolId, key);
        uint128 liquidityBefore = pools.protocolPolPosition(firstPosition).liquidity;
        vm.prank(operator);
        pools.increaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams({
                positionId: firstPosition,
                liquidity: 5e14,
                amount0Limit: _polReserve(poolId, key.currency0),
                amount1Limit: _polReserve(poolId, key.currency1),
                deadline: block.timestamp + 1 days
            })
        );
        assertEq(pools.protocolPolPosition(firstPosition).liquidity, liquidityBefore + 5e14);

        vm.prank(operator);
        pools.decreaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams({
                positionId: firstPosition,
                liquidity: 5e14,
                amount0Limit: 0,
                amount1Limit: 0,
                deadline: block.timestamp + 1 days
            })
        );
        assertEq(pools.protocolPolPosition(firstPosition).liquidity, liquidityBefore);

        pools.setProtocolPoolPolShare(poolId, 0);
        assertEq(pools.protocolPool(poolId).activePolPositions, 2);
        _closePosition(firstPosition, operator);
        _closePosition(secondPosition, operator);
        assertEq(pools.protocolPool(poolId).activePolPositions, 0);
        assertEq(rangeGauge.posmBinding(first.posmTokenId), bytes32(0));
    }

    function testManagerReplacementPreservesOldPortfolioAndRoutesNewPositionsToReplacement() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Manager Alpha", "Manager Beta");
        uint256 oldPosition = _openPosition(poolId, key, -600, 600, 1e15, operator);
        address oldManager = pools.protocolPolPosition(oldPosition).manager;

        _decreasePositionToZero(oldPosition, operator);

        StaticsLiquidityManager replacement = new StaticsLiquidityManager(
            address(diamond), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        pools.replaceLiquidityManager(address(replacement));
        vm.prank(operator);
        pools.collectProtocolPolFees(oldPosition, block.timestamp + 1 days);
        _increasePosition(oldPosition, poolId, key, 1e15, operator);
        _fundPol(poolId, key);
        uint256 newPosition = _openPosition(poolId, key, -1_200, 1_200, 1e15, operator);

        assertEq(pools.protocolPolPosition(oldPosition).manager, oldManager);
        assertEq(pools.protocolPolPosition(newPosition).manager, address(replacement));
        _closePosition(oldPosition, operator);
        _closePosition(newPosition, operator);
        assertEq(pools.protocolPool(poolId).activePolPositions, 0);
    }

    function testFullDecreaseSupportsEmptyHarvestRefillAndClose() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Empty Alpha", "Empty Beta");
        uint256 positionId = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolPositionView memory opened = pools.protocolPolPosition(positionId);
        uint256 reserve0Before = _polReserve(poolId, key.currency0);
        uint256 reserve1Before = _polReserve(poolId, key.currency1);

        _decreasePositionToZero(positionId, operator);
        assertEq(pools.protocolPool(poolId).activePolPositions, 1);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(opened.posmTokenId), opened.manager);
        assertNotEq(rangeGauge.posmBinding(opened.posmTokenId), bytes32(0));
        assertGt(_polReserve(poolId, key.currency0), reserve0Before);
        assertGt(_polReserve(poolId, key.currency1), reserve1Before);
        _assertManagerHasNoTokenBalance(opened.manager, key);

        vm.prank(operator);
        pools.collectProtocolPolFees(positionId, block.timestamp + 1 days);
        _increasePosition(positionId, poolId, key, 1e15, operator);
        assertEq(pools.protocolPolPosition(positionId).liquidity, 1e15);

        _swapGeneralPool(key, trader, true, 0.1 ether);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
            + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1));
        vm.prank(operator);
        pools.collectProtocolPolFees(positionId, block.timestamp + 1 days);
        assertGt(
            globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
                + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1)),
            treasuryBefore
        );

        _closePosition(positionId, operator);
        assertEq(pools.protocolPool(poolId).activePolPositions, 0);
        assertEq(rangeGauge.posmBinding(opened.posmTokenId), bytes32(0));
        _assertManagerHasNoTokenBalance(opened.manager, key);
    }

    function testFullDecreaseSupportsDirectCloseAndIncrementalDecommission() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Close Alpha", "Close Beta");
        uint256 emptyPosition = _openPosition(poolId, key, -600, 600, 1e15, operator);
        uint256 livePosition = _openPosition(poolId, key, -1_200, 1_200, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolPositionView memory emptied = pools.protocolPolPosition(emptyPosition);

        _decreasePositionToZero(emptyPosition, operator);
        uint256 reserve0BeforeClose = _polReserve(poolId, key.currency0);
        uint256 reserve1BeforeClose = _polReserve(poolId, key.currency1);
        pools.beginGeneralPoolDecommission(poolId);

        _closePosition(emptyPosition, operator);
        assertEq(_polReserve(poolId, key.currency0), reserve0BeforeClose);
        assertEq(_polReserve(poolId, key.currency1), reserve1BeforeClose);
        assertEq(pools.protocolPool(poolId).activePolPositions, 1);
        assertEq(rangeGauge.posmBinding(emptied.posmTokenId), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolAdminFacet.ActiveProtocolPolPositions.selector, poolId, 1));
        pools.finalizeGeneralPoolDecommission(poolId);

        _closePosition(livePosition, operator);
        assertEq(pools.protocolPool(poolId).activePolPositions, 0);
        pools.finalizeGeneralPoolDecommission(poolId);
        assertTrue(pools.protocolPool(poolId).decommissioned);
    }

    function testPauseBlocksExposureGrowthButNotExitAndDecommissionIsIncremental() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Exit Alpha", "Exit Beta");
        uint256 positionId = _openPosition(poolId, key, -600, 600, 1e15, operator);

        vm.prank(guardian);
        governance.pause(LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.ActionPaused.selector, LibGovernance.PAUSE_LIQUIDITY));
        pools.increaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams({
                positionId: positionId,
                liquidity: 1,
                amount0Limit: 0,
                amount1Limit: 0,
                deadline: block.timestamp + 1 days
            })
        );

        pools.beginGeneralPoolDecommission(poolId);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolAdminFacet.ActiveProtocolPolPositions.selector, poolId, 1));
        pools.finalizeGeneralPoolDecommission(poolId);

        _closePosition(positionId, operator);
        pools.finalizeGeneralPoolDecommission(poolId);
        assertTrue(pools.protocolPool(poolId).decommissioned);
        assertEq(pools.protocolPool(poolId).activePolPositions, 0);
        assertEq(_polReserve(poolId, key.currency0), 0);
        assertEq(_polReserve(poolId, key.currency1), 0);
    }

    function testAtomicRebalancePreservesCustodyAndRoutesFees() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Atomic Alpha", "Atomic Beta");
        uint256 oldId = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolPositionView memory oldPosition = pools.protocolPolPosition(oldId);
        _swapGeneralPool(key, trader, true, 0.1 ether);
        _swapGeneralPool(key, trader, false, 0.1 ether);
        _settlePol(poolId, key);
        uint256 feesBefore = globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
            + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1));
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, oldId);
        vm.prank(operator);
        uint256[] memory ids = pools.rebalanceProtocolPolPositions(params);
        assertEq(ids.length, 1);
        assertFalse(pools.protocolPolPosition(oldId).active);
        assertEq(rangeGauge.posmBinding(oldPosition.posmTokenId), bytes32(0));
        _assertProtocolBinding(ids[0]);
        assertEq(pools.protocolPool(poolId).activePolPositions, 1);
        assertGt(
            globalRewards.treasuryAccrued(Currency.unwrap(key.currency0))
                + globalRewards.treasuryAccrued(Currency.unwrap(key.currency1)),
            feesBefore
        );
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(operator), 0);
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(operator), 0);
        _closePosition(ids[0], operator);
        assertGt(_polReserve(poolId, key.currency0), 0);
        assertGt(_polReserve(poolId, key.currency1), 0);
    }

    function testAtomicRebalanceRollsBackCloseWhenLaterOpenFails() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Rollback Alpha", "Rollback Beta");
        uint256 oldId = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolPositionView memory oldPosition = pools.protocolPolPosition(oldId);
        uint256 reserve0 = _polReserve(poolId, key.currency0);
        uint256 reserve1 = _polReserve(poolId, key.currency1);
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, oldId);
        params.opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](2);
        params.opens[0] = IStaticsProtocolPools.ProtocolPolOpenLeg(-1_200, 1_200, 1e10, reserve0 / 2, reserve1 / 2);
        // The second leg has an invalid range; the first new mint must also roll back.
        params.opens[1] = IStaticsProtocolPools.ProtocolPolOpenLeg(0, 0, 1e10, reserve0 / 2, reserve1 / 2);
        vm.prank(operator);
        vm.expectRevert();
        pools.rebalanceProtocolPolPositions(params);
        assertTrue(pools.protocolPolPosition(oldId).active);
        assertEq(pools.protocolPolPosition(oldId).liquidity, oldPosition.liquidity);
        _assertProtocolBinding(oldId);
        assertEq(_polReserve(poolId, key.currency0), reserve0);
        assertEq(_polReserve(poolId, key.currency1), reserve1);
        assertEq(pools.protocolPool(poolId).activePolPositions, 1);
        assertEq(pools.protocolPolPositionIds(poolId).length, 1);
    }

    function testAtomicRebalanceRejectsForeignDuplicateAndGrossDebits() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Bound Alpha", "Bound Beta");
        uint256 id = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, id);
        params.maximumCustodyDebit0 = params.opens[0].amount0Maximum - 1;
        vm.prank(operator);
        vm.expectPartialRevert(ProtocolPolFacet.ProtocolPolAggregateDebitExceeded.selector);
        pools.rebalanceProtocolPolPositions(params);
        params.maximumCustodyDebit0 += 1;
        params.closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](2);
        params.closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(id, 0, 0);
        params.closes[1] = IStaticsProtocolPools.ProtocolPolCloseLeg(id, 0, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.DuplicateProtocolPolClose.selector, id));
        pools.rebalanceProtocolPolPositions(params);
        (PoolId foreignId,) = _activatedFundedPool("Foreign Alpha", "Foreign Beta");
        params.poolId = foreignId;
        params.closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](1);
        params.closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(id, 0, 0);
        vm.prank(operator);
        vm.expectPartialRevert(bytes4(keccak256("ProtocolPolPositionPoolMismatch(uint256,bytes32,bytes32)")));
        pools.rebalanceProtocolPolPositions(params);
        assertTrue(pools.protocolPolPosition(id).active);
    }

    function testAtomicRebalanceRequiresOperatorDeadlineAndActiveIngress() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Authority Alpha", "Authority Beta");
        uint256 id = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, id);
        vm.prank(trader);
        vm.expectPartialRevert(ProtocolPolFacet.OnlyProtocolPolOperator.selector);
        pools.rebalanceProtocolPolPositions(params);
        params.deadline = block.timestamp - 1;
        vm.prank(operator);
        vm.expectPartialRevert(ProtocolPolFacet.ProtocolPolRebalanceExpired.selector);
        pools.rebalanceProtocolPolPositions(params);
        params.deadline = block.timestamp + 1 days;
        governance.pause(LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(operator);
        vm.expectPartialRevert(ProtocolPolFacet.ActionPaused.selector);
        pools.rebalanceProtocolPolPositions(params);
        // The existing independent custody exit remains usable during the pause.
        _closePosition(id, operator);
    }

    function testAtomicRebalanceUsesOriginatingManagerAndReplacementForNewLegs() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Rotate Alpha", "Rotate Beta");
        uint256 id = _openPosition(poolId, key, -600, 600, 1e15, operator);
        address oldManager = pools.protocolPolPosition(id).manager;
        StaticsLiquidityManager replacement = new StaticsLiquidityManager(
            address(diamond), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        pools.replaceLiquidityManager(address(replacement));
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, id);
        vm.prank(operator);
        uint256[] memory ids = pools.rebalanceProtocolPolPositions(params);
        assertEq(pools.protocolPolPosition(id).manager, oldManager);
        assertEq(pools.protocolPolPosition(ids[0]).manager, address(replacement));
        _assertProtocolBinding(ids[0]);
        _assertManagerHasNoTokenBalance(oldManager, key);
        _assertManagerHasNoTokenBalance(address(replacement), key);
    }

    function testAtomicRebalanceRejectsEmptyOversizedAndDecommissionedLegs() public {
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Leg Alpha", "Leg Beta");
        uint256 id = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, id);
        params.opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](0);
        vm.prank(operator);
        vm.expectPartialRevert(ProtocolPolFacet.InvalidProtocolPolRebalanceLegs.selector);
        pools.rebalanceProtocolPolPositions(params);
        params.opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](9);
        vm.prank(operator);
        vm.expectPartialRevert(ProtocolPolFacet.InvalidProtocolPolRebalanceLegs.selector);
        pools.rebalanceProtocolPolPositions(params);
        params = _rebalanceParams(poolId, key, id);
        pools.beginGeneralPoolDecommission(poolId);
        vm.prank(operator);
        vm.expectRevert();
        pools.rebalanceProtocolPolPositions(params);
        assertTrue(pools.protocolPolPosition(id).active);
        _closePosition(id, operator);
    }

    function testFuzzAtomicRebalanceRetainsPrincipalAndRefunds(uint256 nextLiquidity) public {
        nextLiquidity = bound(nextLiquidity, 1e6, 1e10);
        (PoolId poolId, PoolKey memory key) = _activatedFundedPool("Fuzz Alpha", "Fuzz Beta");
        uint256 id = _openPosition(poolId, key, -600, 600, 1e15, operator);
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params = _rebalanceParams(poolId, key, id);
        params.opens[0].liquidity = uint128(nextLiquidity);
        uint256 reserve0 = _polReserve(poolId, key.currency0);
        uint256 reserve1 = _polReserve(poolId, key.currency1);
        vm.prank(operator);
        uint256[] memory ids = pools.rebalanceProtocolPolPositions(params);
        assertEq(pools.protocolPolPosition(ids[0]).liquidity, nextLiquidity);
        _closePosition(ids[0], operator);
        // Principal stays in this book; only small integer rounding loss is permitted.
        assertGe(_polReserve(poolId, key.currency0) + 2, reserve0);
        assertGe(_polReserve(poolId, key.currency1) + 2, reserve1);
        _assertManagerHasNoTokenBalance(pools.protocolPolPosition(ids[0]).manager, key);
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(operator), 0);
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(operator), 0);
    }

    function _rebalanceParams(PoolId poolId, PoolKey memory key, uint256 id)
        private
        view
        returns (IStaticsProtocolPools.ProtocolPolRebalanceParams memory params)
    {
        params.poolId = poolId;
        params.closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](1);
        params.closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(id, 0, 0);
        params.opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](1);
        params.maximumCustodyDebit0 = _polReserve(poolId, key.currency0);
        params.maximumCustodyDebit1 = _polReserve(poolId, key.currency1);
        params.opens[0] = IStaticsProtocolPools.ProtocolPolOpenLeg(
            -1_200, 1_200, 1e10, params.maximumCustodyDebit0, params.maximumCustodyDebit1
        );
        params.deadline = block.timestamp + 1 days;
    }

    function _activatedFundedPool(string memory nameA, string memory nameB)
        private
        returns (PoolId poolId, PoolKey memory key)
    {
        (poolId, key) = _createGeneralPool(_newToken(nameA), _newToken(nameB), 10, creator);
        _mintFullRangeGeneralPosition(key, lp, 5 ether);
        vm.prank(creator);
        pools.activateProtocolPoolPol(poolId);
        _fundPol(poolId, key);
    }

    function _fundPol(PoolId poolId, PoolKey memory key) private {
        _swapGeneralPool(key, trader, true, 0.5 ether);
        _swapGeneralPool(key, trader, false, 0.5 ether);
        _settlePol(poolId, key);
        assertGt(_polReserve(poolId, key.currency0), 0);
        assertGt(_polReserve(poolId, key.currency1), 0);
    }

    function _settlePol(PoolId poolId, PoolKey memory key) private {
        pools.settleProtocolPoolPol(poolId, Currency.unwrap(key.currency0), 0);
        pools.settleProtocolPoolPol(poolId, Currency.unwrap(key.currency1), 0);
    }

    function _openPosition(
        PoolId poolId,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address caller
    ) private returns (uint256 positionId) {
        vm.prank(caller);
        positionId = pools.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams({
                poolId: poolId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0Maximum: _polReserve(poolId, key.currency0),
                amount1Maximum: _polReserve(poolId, key.currency1),
                deadline: block.timestamp + 1 days
            })
        );
    }

    function _closePosition(uint256 positionId, address caller) private {
        vm.prank(caller);
        pools.closeProtocolPolPosition(positionId, 0, 0, block.timestamp + 1 days);
        assertFalse(pools.protocolPolPosition(positionId).active);
    }

    function _decreasePositionToZero(uint256 positionId, address caller) private {
        uint128 liquidity = pools.protocolPolPosition(positionId).liquidity;
        vm.prank(caller);
        pools.decreaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams({
                positionId: positionId,
                liquidity: liquidity,
                amount0Limit: 0,
                amount1Limit: 0,
                deadline: block.timestamp + 1 days
            })
        );
        IStaticsProtocolPools.ProtocolPolPositionView memory position = pools.protocolPolPosition(positionId);
        assertEq(position.liquidity, 0);
        assertEq(positionManagerContract.getPositionLiquidity(position.posmTokenId), 0);
    }

    function _increasePosition(uint256 positionId, PoolId poolId, PoolKey memory key, uint128 liquidity, address caller)
        private
    {
        vm.prank(caller);
        pools.increaseProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolLiquidityParams({
                positionId: positionId,
                liquidity: liquidity,
                amount0Limit: _polReserve(poolId, key.currency0),
                amount1Limit: _polReserve(poolId, key.currency1),
                deadline: block.timestamp + 1 days
            })
        );
    }

    function _assertManagerHasNoTokenBalance(address manager, PoolKey memory key) private view {
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(manager), 0);
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(manager), 0);
    }

    function _assertProtocolBinding(uint256 positionId) private view {
        IStaticsProtocolPools.ProtocolPolPositionView memory position = pools.protocolPolPosition(positionId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(position.posmTokenId), position.manager);
        assertNotEq(rangeGauge.posmBinding(position.posmTokenId), bytes32(0));
    }

    function _polReserve(PoolId poolId, Currency currency) private view returns (uint256 amount) {
        IStaticsCustody custodyView = IStaticsCustody(address(diamond));
        amount = custodyView.reservedByAccount(
            custodyView.protocolPolCustodyAccount(PoolId.unwrap(poolId)), Currency.unwrap(currency)
        );
    }

    function _pendingPol(PoolId poolId, PoolKey memory key) private view returns (uint256 amount) {
        amount = swapFeeHook.pendingProtocolPol(poolId, key.currency0)
            + swapFeeHook.pendingProtocolPol(poolId, key.currency1);
    }
}
