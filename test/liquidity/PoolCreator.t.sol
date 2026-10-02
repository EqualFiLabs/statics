// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {LibGaugeBribes} from "../../src/libraries/LibGaugeBribes.sol";
import {MockERC20, MockReentrantERC20, MockRevertingERC20} from "../mocks/MockERC20.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

/// @notice A permissionless transaction can collect to the configured contract and fund incentives
/// atomically. Funding is an explicit call, never a token-receipt callback.
contract CreatorGaugeFunder {
    IStaticsProtocolRevenue public immutable revenue;
    IStaticsRangeGauge public immutable gauge;

    constructor(address diamond) {
        revenue = IStaticsProtocolRevenue(diamond);
        gauge = IStaticsRangeGauge(diamond);
    }

    function collectAndFund(PoolId poolId, address asset, uint8 slot, uint16 allocatorShareBps)
        external
        returns (uint256 amount)
    {
        (, amount) = revenue.claimCreatorRevenue(poolId, asset, address(this), 0);
        IERC20(asset).approve(address(gauge), amount);
        gauge.fundPoolReward(poolId, slot, amount, 0, allocatorShareBps);
    }
}

contract PoolCreatorTest is GeneralPoolLifecycleTestBase {
    IStaticsProtocolRevenue private revenue;
    address private creator = makeAddr("creator");
    address private successor = makeAddr("successor");
    PoolId private poolId;
    PoolKey private key;

    function setUp() public override {
        super.setUp();
        revenue = IStaticsProtocolRevenue(address(diamond));
        (poolId, key) = _createGeneralPool(address(assetA), address(assetB), 10, creator);
    }

    function testTransferMovesSettledAndUnsettledRealSwapRevenue() public {
        _mintFullRangeGeneralPosition(key, makeAddr("lp"), 5 ether);
        _swapGeneralPool(key, makeAddr("trader"), true, 0.05 ether);
        _settlePool(poolId, key);
        uint256 settled = revenue.creatorRevenue(poolId, Currency.unwrap(key.currency0));
        assertGt(settled, 0);
        _swapGeneralPool(key, makeAddr("trader"), false, 0.05 ether);
        address distributor = makeAddr("old-distributor");
        vm.prank(creator);
        revenue.setCreatorRevenueRecipient(poolId, distributor);
        _transfer(poolId, creator, successor);
        _settlePool(poolId, key);
        assertEq(pools.protocolPoolCreator(poolId), successor);
        (address actual, address pending, address recipient) = revenue.poolCreatorConfiguration(poolId);
        assertEq(actual, successor);
        assertEq(pending, address(0));
        assertEq(recipient, successor);
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
            uint256 owed = revenue.creatorRevenue(poolId, asset);
            assertGt(owed, 0);
            uint256 before = IERC20(asset).balanceOf(successor);
            revenue.claimCreatorRevenue(poolId, asset, successor, owed);
            assertEq(IERC20(asset).balanceOf(successor) - before, owed);
            assertEq(revenue.totalCreatorRevenue(asset), 0);
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.OnlyPoolCreator.selector, creator, successor));
        revenue.setCreatorRevenueRecipient(poolId, creator);
        vm.prank(creator);
        vm.expectRevert();
        pools.activateProtocolPoolPol(poolId);
        vm.prank(successor);
        pools.activateProtocolPoolPol(poolId);
    }

    function testProposalsReplaceCancelAndRequireAcceptance() public {
        address third = makeAddr("third");
        vm.expectRevert();
        revenue.proposePoolCreator(poolId, successor);
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.InvalidPoolCreator.selector, creator));
        revenue.proposePoolCreator(poolId, creator);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.InvalidPoolCreator.selector, address(diamond)));
        revenue.proposePoolCreator(poolId, address(diamond));
        revenue.proposePoolCreator(poolId, successor);
        revenue.proposePoolCreator(poolId, third);
        vm.stopPrank();
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.OnlyPendingPoolCreator.selector, successor, third));
        revenue.acceptPoolCreator(poolId);
        vm.prank(creator);
        revenue.proposePoolCreator(poolId, address(0));
        vm.prank(third);
        vm.expectRevert();
        revenue.acceptPoolCreator(poolId);
        _transfer(poolId, creator, successor);
        vm.prank(successor);
        vm.expectRevert();
        revenue.acceptPoolCreator(poolId);
    }

    function testRecipientIsFixedForAllCallersAndResetFollowsCreator() public {
        address recipient = makeAddr("recipient");
        vm.prank(creator);
        revenue.setCreatorRevenueRecipient(poolId, recipient);
        _credit(poolId, address(assetA), 500);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolRevenueFacet.UnexpectedRevenueRecipient.selector, creator, recipient)
        );
        revenue.claimCreatorRevenue(poolId, address(assetA), creator, 0);
        revenue.claimCreatorRevenue(poolId, address(assetA), recipient, 500);
        assertEq(assetA.balanceOf(recipient), 500);
        vm.prank(creator);
        revenue.setCreatorRevenueRecipient(poolId, address(0));
        _credit(poolId, address(assetA), 700);
        revenue.claimCreatorRevenue(poolId, address(assetA), creator, 700);
        assertEq(assetA.balanceOf(creator), 700);
    }

    function testDecommissionPreservesTransfersAndOutstandingClaims() public {
        _credit(poolId, address(assetA), 500);
        pools.beginGeneralPoolDecommission(poolId);
        pools.finalizeGeneralPoolDecommission(poolId);
        _transfer(poolId, creator, successor);
        vm.prank(successor);
        revenue.setCreatorRevenueRecipient(poolId, creator);
        revenue.claimCreatorRevenue(poolId, address(assetA), creator, 500);
        assertEq(assetA.balanceOf(creator), 500);
    }

    function testUnsupportedAndUnknownPoolsRejectConfiguration() public {
        vm.expectRevert();
        revenue.proposePoolCreator(PoolId.wrap(bytes32(uint256(123))), successor);
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        PoolId canonical = basketLiquidity.canonicalPool(basketId, address(assetA)).poolId;
        vm.expectRevert(abi.encodeWithSelector(ProtocolRevenueFacet.UnsupportedCreatorPool.selector, canonical));
        revenue.proposePoolCreator(canonical, successor);
        vm.expectRevert();
        revenue.acceptPoolCreator(canonical);
        vm.expectRevert();
        revenue.setCreatorRevenueRecipient(canonical, successor);
        vm.expectRevert();
        revenue.poolCreatorConfiguration(canonical);
    }

    function testTokenCallbackCannotChangeCreatorOrRecipientDuringClaim() public {
        MockReentrantERC20 token = new MockReentrantERC20();
        (PoolId callbackPool,) = _createGeneralPool(address(token), address(assetB), 10, address(token));
        vm.prank(address(token));
        revenue.proposePoolCreator(callbackPool, successor);
        _credit(callbackPool, address(token), 500);
        token.setCallback(
            address(diamond),
            address(diamond),
            abi.encodeCall(revenue.setCreatorRevenueRecipient, (callbackPool, successor))
        );
        revenue.claimCreatorRevenue(callbackPool, address(token), address(token), 500);
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        (, address pending, address recipient) = revenue.poolCreatorConfiguration(callbackPool);
        assertEq(pending, successor);
        assertEq(recipient, address(token));
        _transfer(callbackPool, address(token), successor);
        _credit(callbackPool, address(token), 700);
        vm.prank(successor);
        revenue.proposePoolCreator(callbackPool, address(token));
        token.setCallback(address(diamond), address(diamond), abi.encodeCall(revenue.acceptPoolCreator, (callbackPool)));
        revenue.claimCreatorRevenue(callbackPool, address(token), successor, 700);
        assertFalse(token.reentrySucceeded());
        assertEq(pools.protocolPoolCreator(callbackPool), successor);
    }

    function testRevertingTokenDeliveryPreservesCreditAndBacking() public {
        MockRevertingERC20 token = new MockRevertingERC20();
        (PoolId blockedPool,) = _createGeneralPool(address(token), address(assetB), 10, creator);
        _credit(blockedPool, address(token), 500);
        token.setTransfersRevert(true);
        vm.expectRevert(MockRevertingERC20.TransferBlocked.selector);
        revenue.claimCreatorRevenue(blockedPool, address(token), creator, 0);
        assertEq(revenue.creatorRevenue(blockedPool, address(token)), 500);
        assertEq(revenue.totalCreatorRevenue(address(token)), 500);
        assertEq(token.balanceOf(address(diamond)), 500);
        token.setTransfersRevert(false);
        revenue.claimCreatorRevenue(blockedPool, address(token), creator, 500);
        assertEq(token.balanceOf(creator), 500);
    }

    function testConfiguredContractCollectsAndFundsAllocatorIncentivesAtomically() public {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new RangeGaugeFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.rangeGaugeActions()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        _mintFullRangeGeneralPosition(key, makeAddr("lp"), 5 ether);
        _swapGeneralPool(key, makeAddr("trader"), true, 0.05 ether);
        _settlePool(poolId, key);
        address asset = Currency.unwrap(key.currency0);
        IStaticsRangeGauge gauge = IStaticsRangeGauge(address(diamond));
        gauge.setGaugeRewardAssetAllowed(asset, true);
        vm.prank(creator);
        uint8 slot = gauge.appendPoolRewardAsset(poolId, asset);
        vm.prank(creator);
        gauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        CreatorGaugeFunder funder = new CreatorGaugeFunder(address(diamond));
        vm.prank(creator);
        revenue.setCreatorRevenueRecipient(poolId, address(funder));
        uint256 owed = revenue.creatorRevenue(poolId, asset);
        assertGt(owed, 0);
        assertEq(funder.collectAndFund(poolId, asset, slot, 10_000), owed);
        assertEq(revenue.creatorRevenue(poolId, asset), 0);
        assertEq(IERC20(asset).balanceOf(address(funder)), 0);
        assertEq(IERC20(asset).allowance(address(funder), address(diamond)), 0);
        assertEq(custody.reservedByAccount(LibGaugeBribes.account(poolId, slot), asset), owed);
    }

    function testFuzz_TransferAndClaimKeepPoolsAndAssetsIsolated(uint256 first, uint256 second) public {
        first = bound(first, 1, 1e24);
        second = bound(second, 1, 1e24);
        (PoolId other,) = _createGeneralPool(address(assetA), address(assetB), 60, creator);
        _credit(poolId, address(assetA), first);
        _credit(other, address(assetA), second);
        _credit(poolId, address(assetB), second);
        _transfer(poolId, creator, successor);
        revenue.claimCreatorRevenue(poolId, address(assetA), successor, first);
        assertEq(revenue.totalCreatorRevenue(address(assetA)), second);
        assertEq(revenue.creatorRevenue(other, address(assetA)), second);
        assertEq(revenue.creatorRevenue(poolId, address(assetB)), second);
        assertEq(pools.protocolPoolCreator(other), creator);
    }

    function _transfer(PoolId id, address from, address to) private {
        vm.prank(from);
        revenue.proposePoolCreator(id, to);
        vm.prank(to);
        revenue.acceptPoolCreator(id);
    }

    function _settlePool(PoolId id, PoolKey memory poolKey) private {
        pools.settleProtocolPoolRevenue(id, Currency.unwrap(poolKey.currency0));
        pools.settleProtocolPoolRevenue(id, Currency.unwrap(poolKey.currency1));
    }

    // Narrow accounting input; real swaps above prove the value-moving lifecycle separately.
    function _credit(PoolId id, address asset, uint256 amount) private {
        MockERC20(asset).mint(address(swapFeeHook), amount);
        vm.startPrank(address(swapFeeHook));
        IERC20(asset).approve(address(diamond), amount);
        revenue.routeProtocolSwapFees(id, asset, IStaticsProtocolRevenue.ProtocolFeeDistribution(0, 0, amount, 0));
        vm.stopPrank();
    }
}
