// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMoshSwarm, IMoshClaimMarket} from "../../src/interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {MoshShareRevenueAdapter} from "../../src/bootstrap/MoshShareRevenueAdapter.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {MoshForkFeeHook} from "./RobinhoodMoshClaimFork.t.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {RejectingRevenueWeth} from "./NativeCampaignRevenue.t.sol";

/// @dev Local real Statics launch fixtures plus runtime-pinned deployed Mosh/market/hook/v4 execution.
/// The local CreateX fixture affects Statics setup only; no Mosh contract/manager is etched or replaced.
contract RobinhoodMoshShareAdapterForkTest is CampaignTestBase, IUnlockCallback {
    IMoshSwarm private constant SWARM = IMoshSwarm(0x6A3800dD7b3F1e03e29BEfE2A9238549a9642Ac8);
    IMoshClaimMarket private constant MARKET = IMoshClaimMarket(0xA8C83951eE2431106f0aAea6ae79F97A530521aA);
    address private constant HOLDER = 0x8B86B1C726F7a1c09f7c4c31e53621a27e4C8AdC;
    address private constant TOKEN = 0xD68f57B08CD9732e4Ddd1a04bA4d26629DC44B8E;
    address private constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPoolManager private constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    WETH private wrapped;
    MoshShareRevenueAdapter private adapter;
    BasketBootstrapCampaign private destination;
    address private second;
    PoolKey private sourceKey;

    function setUp() public override {
        string memory rpc = vm.envOr("MOSH_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "Robinhood RPC not configured");
            return;
        }
        vm.createSelectFork(rpc, 80_155_273);
        super.setUp();
        wrapped = new WETH();
        second = makeAddr("second depositor");
        vm.deal(HOLDER, 100 ether);
        vm.deal(second, 100 ether);
        adapter = new MoshShareRevenueAdapter(
            vm.addr(CREATOR_KEY),
            address(wrapped),
            address(wrapped).codehash,
            campaignFactory,
            SWARM,
            _pins(),
            LibMoshValidation.MarketPins(
                address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
            )
        );
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.projectToken = TOKEN;
        terms.basket.assets[0] = address(wrapped);
        terms.adapters = new address[](1);
        terms.adapters[0] = address(adapter);
        destination = _campaign(terms, keccak256("Mosh shares"));
        vm.prank(vm.addr(CREATOR_KEY));
        adapter.bindCampaign(destination, 0);
        sourceKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0, 200, IHooks(HOOK));
    }

    function _pins() private pure returns (LibMoshValidation.SourcePins memory) {
        return LibMoshValidation.SourcePins(
            4663,
            0x9073cb17846398fB8B379Ab06C2B840dEA7f0069,
            0x82edd64be0bedd5f9462e948447c6416adad6c77c71945e1cba585387f553423,
            0x71BDDCfee17b718c92f0Be80910D2f06542ff379,
            0x93f0f1391a76bb2aa72c310f33636f9049002ef16584a9b0370e199edb26702e,
            0x42B0b14C6e6bCAa2e9B29F87aA3DE19290a5c572,
            0x210393a615dd4a801aaa9449b8e65d6b0ba7b98d6ef5ed9f2400833643fd44ac
        );
    }

    function _giveSecondClaims(uint256 amount) private {
        vm.prank(HOLDER);
        uint256 id = MARKET.list(address(SWARM), amount, 1, second, uint64(block.timestamp + 1 hours));
        vm.prank(second);
        MARKET.fill{value: 1}(id);
    }

    function _deposit(address owner, uint256 amount) private {
        vm.prank(owner);
        uint256 id = MARKET.list(address(SWARM), amount, 1, address(adapter), uint64(block.timestamp + 1 hours));
        uint256 beforeOwner = SWARM.claim(owner);
        vm.prank(owner);
        adapter.deposit{value: 1}(id, amount);
        assertEq(beforeOwner - SWARM.claim(owner), amount);
        assertEq(SWARM.claim(address(adapter)), adapter.totalShares());
    }

    function _return(address owner, uint256 amount) private {
        vm.prank(owner);
        uint256 id = adapter.withdraw(amount, block.timestamp + 1 hours);
        uint256 beforeOwner = SWARM.claim(owner);
        vm.prank(owner);
        MARKET.fill{value: 1}(id);
        assertEq(SWARM.claim(owner) - beforeOwner, amount);
        assertEq(adapter.unreconciledShares(), amount);
        vm.prank(makeAddr("permissionless reconciler"));
        adapter.checkpointWithdrawal(owner);
        assertEq(adapter.unreconciledShares(), 0);
        assertEq(SWARM.claim(address(adapter)), adapter.totalShares());
    }

    function _swap() private {
        MANAGER.unlock(abi.encode(0.01 ether));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER));
        BalanceDelta delta = MANAGER.swap(
            sourceKey, SwapParams(true, -int256(abi.decode(data, (uint256))), TickMath.MIN_SQRT_PRICE + 1), ""
        );
        MANAGER.settle{value: uint256(-int256(delta.amount0()))}();
        MANAGER.take(sourceKey.currency1, address(this), uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }

    function _realize() private {
        // Existing upstream operator impersonation is diagnostic fork input only, never Statics authority.
        vm.prank(MoshForkFeeHook(HOOK).feeSweepOperator());
        MoshForkFeeHook(HOOK).sweepPoolFees(keccak256(abi.encode(sourceKey)), 1, 1);
        assertGt(SWARM.syncFees(), 0);
    }

    function testRealOverlappingCustodyFundsOnlyMeasuredCampaignRevenue() public {
        _giveSecondClaims(0.02 ether);
        _deposit(HOLDER, 0.01 ether);
        _swap();
        assertEq(adapter.sync(), 0);
        _deposit(second, 0.02 ether);
        _realize();
        uint256 expected = SWARM.claimable(address(adapter));
        assertGt(expected, 0);
        vm.prank(makeAddr("sync caller"));
        assertEq(adapter.sync(), expected);
        assertEq(adapter.totalMeasured(), expected);
        assertEq(adapter.campaignNativeReserved(), expected);
        assertEq(adapter.userNativeReserved(), 0);
        assertEq(adapter.sync(), 0);
        adapter.flushCampaignRevenue();
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, expected);
        assertEq(wrapped.balanceOf(address(destination)), expected);
        assertEq(wrapped.allowance(address(adapter), address(destination)), 0);
        assertFalse(destination.ready());
    }

    function testExpiryBeforeSyncAssignsUsersAndPreservesOldCampaignReserve() public {
        _giveSecondClaims(0.02 ether);
        _deposit(HOLDER, 0.01 ether);
        _deposit(second, 0.02 ether);
        _swap();
        _realize();
        uint256 oldCampaign = adapter.sync();
        vm.warp(destination.deadline());
        _swap();
        _realize();
        uint256 newUsers = adapter.sync();
        assertGt(newUsers, 0);
        assertEq(adapter.campaignNativeReserved(), oldCampaign);
        assertEq(adapter.userNativeReserved(), newUsers);
        assertApproxEqAbs(adapter.rewards(HOLDER), newUsers / 3, 1);
        assertApproxEqAbs(adapter.rewards(second), newUsers * 2 / 3, 1);
        adapter.flushCampaignRevenue();
        assertEq(wrapped.balanceOf(bob), oldCampaign);
        vm.prank(HOLDER);
        uint256 firstClaim = adapter.claimRewards();
        vm.prank(second);
        uint256 secondClaim = adapter.claimRewards();
        assertApproxEqAbs(firstClaim + secondClaim, newUsers, 2);
        assertEq(wrapped.balanceOf(HOLDER), firstClaim);
        assertEq(wrapped.balanceOf(second), secondClaim);
        assertEq(adapter.campaignNativeReserved(), 0);
    }

    function testActualReturnAutoPayoutUsesOldDistributionAndKeepsProceedsSeparate() public {
        _giveSecondClaims(0.01 ether);
        _deposit(HOLDER, 0.01 ether);
        _deposit(second, 0.01 ether);
        vm.warp(destination.deadline());
        vm.prank(HOLDER);
        uint256 id = adapter.withdraw(0.004 ether, block.timestamp + 1 hours);
        _swap();
        _realize();
        uint256 expected = SWARM.claimable(address(adapter));
        uint256 beforeOwner = SWARM.claim(HOLDER);
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(id);
        assertEq(SWARM.claim(HOLDER) - beforeOwner, 0.004 ether);
        assertEq(adapter.totalMeasured(), expected);
        assertEq(adapter.returnProceeds(), 1);
        assertEq(adapter.userNativeReserved(), expected);
        assertApproxEqAbs(adapter.rewards(HOLDER), expected / 2, 1);
        assertApproxEqAbs(adapter.rewards(second), expected / 2, 1);
        vm.expectRevert(MoshShareRevenueAdapter.UnreconciledReturn.selector);
        adapter.sync();
        vm.expectRevert(MoshShareRevenueAdapter.InvalidMoshCustody.selector);
        adapter.checkpointWithdrawal(second);
        adapter.checkpointWithdrawal(HOLDER);
        assertEq(adapter.shares(HOLDER), 0.006 ether);
        assertEq(adapter.userNativeReserved(), expected + 1);
        assertEq(adapter.totalMeasured(), expected);
        _return(HOLDER, 0.006 ether);
        _return(second, 0.01 ether);
        assertEq(adapter.totalShares(), 0);
        assertEq(adapter.sync(), 0);
    }

    function testConcurrentEqualReturnsReconcileWithoutOwnerPrivilege() public {
        _giveSecondClaims(0.01 ether);
        _deposit(HOLDER, 0.01 ether);
        _deposit(second, 0.01 ether);
        vm.prank(HOLDER);
        uint256 first = adapter.withdraw(0.01 ether, block.timestamp + 1 hours);
        vm.prank(second);
        uint256 next = adapter.withdraw(0.01 ether, block.timestamp + 1 hours);
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(first);
        vm.expectRevert();
        vm.prank(second);
        MARKET.fill{value: 1}(next);
        vm.expectRevert(MoshShareRevenueAdapter.InvalidMoshCustody.selector);
        adapter.checkpointWithdrawal(second);
        adapter.checkpointWithdrawal(HOLDER);
        vm.prank(second);
        MARKET.fill{value: 1}(next);
        adapter.checkpointWithdrawal(second);
        assertEq(adapter.totalShares(), 0);
        assertEq(adapter.userNativeReserved(), 2);
        assertEq(adapter.totalMeasured(), 0);
    }

    function testExpiredListingCancelsAndRecoversWithoutConversionOrForwarding() public {
        _deposit(HOLDER, 0.01 ether);
        uint256 end = block.timestamp + 1 hours;
        vm.prank(HOLDER);
        uint256 id = adapter.withdraw(0.01 ether, end);
        vm.warp(end);
        vm.expectRevert();
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(id);
        vm.prank(HOLDER);
        adapter.cancelWithdrawal();
        _return(HOLDER, 0.01 ether);
        assertEq(adapter.totalShares(), 0);
        vm.prank(HOLDER);
        assertEq(adapter.claimRewards(), 1);
        assertEq(wrapped.balanceOf(HOLDER), 1);
    }

    function testDelayedConversionAfterExitDoesNotCreateAdapterDebt() public {
        _deposit(HOLDER, 0.01 ether);
        _swap();
        assertEq(adapter.sync(), 0);
        _return(HOLDER, 0.01 ether);
        vm.warp(block.timestamp + 1 days);
        _realize();
        assertEq(adapter.sync(), 0);
        assertEq(adapter.totalMeasured(), 0);
        assertGt(SWARM.claimable(HOLDER), 0);
    }

    function testPreexistingBalancesCannotBecomeCampaignOrUserRewards() public {
        wrapped.deposit{value: 7 ether}();
        wrapped.transfer(address(adapter), 7 ether);
        vm.deal(address(adapter), 5 ether);
        _deposit(HOLDER, 0.01 ether);
        _swap();
        _realize();
        uint256 receipt = adapter.sync();
        adapter.flushCampaignRevenue();
        assertEq(address(adapter).balance, 5 ether);
        assertEq(wrapped.balanceOf(address(adapter)), 7 ether);
        assertEq(adapter.totalDelivered(), receipt);
        (bool sent,) = address(adapter).call{value: 1}("");
        assertFalse(sent);
    }

    function testFundedFinalizationIsIndependentAndLaterReceiptsAreUserOwned() public {
        _deposit(HOLDER, 0.01 ether);
        (, uint256 target,,) = destination.inventory(0);
        wrapped.deposit{value: target}();
        wrapped.approve(address(destination), target);
        destination.fund(0, target);
        (, uint256 otherTarget,,) = destination.inventory(1);
        assetB.mint(address(this), otherTarget);
        assetB.approve(address(destination), otherTarget);
        destination.fund(1, otherTarget);
        destination.fundNative{value: destination.nativeRequired()}();
        // Only this failure branch is synthetic: mandatory finalization must not call the source.
        vm.mockCallRevert(address(SWARM), abi.encodeCall(IMoshSwarm.syncFees, ()), hex"deadbeef");
        (uint256 id,) = destination.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        vm.clearMockedCalls();
        _swap();
        _realize();
        uint256 receipt = adapter.sync();
        assertGt(receipt, 0);
        assertEq(adapter.campaignNativeReserved(), 0);
        assertEq(adapter.userNativeReserved(), receipt);
        _return(HOLDER, 0.01 ether);
        vm.prank(HOLDER);
        uint256 claimed = adapter.claimRewards();
        assertApproxEqAbs(claimed, receipt + 1, 1);
    }

    function testRealForwardingFailureKeepsReserveAndDoesNotBlockPrincipal() public {
        RejectingRevenueWeth bad = new RejectingRevenueWeth();
        wrapped = bad;
        adapter = new MoshShareRevenueAdapter(
            vm.addr(CREATOR_KEY),
            address(bad),
            address(bad).codehash,
            campaignFactory,
            SWARM,
            _pins(),
            LibMoshValidation.MarketPins(
                address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
            )
        );
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.projectToken = TOKEN;
        terms.basket.assets[0] = address(bad);
        terms.adapters = new address[](1);
        terms.adapters[0] = address(adapter);
        destination = _campaign(terms, keccak256("failed forwarding"));
        vm.prank(vm.addr(CREATOR_KEY));
        adapter.bindCampaign(destination, 0);
        _deposit(HOLDER, 0.01 ether);
        _swap();
        _realize();
        uint256 receipt = adapter.sync();
        vm.expectRevert(RejectingRevenueWeth.DeliveryBlocked.selector);
        adapter.flushCampaignRevenue();
        assertEq(adapter.campaignNativeReserved(), receipt);
        assertEq(address(adapter).balance, receipt);
        assertEq(bad.balanceOf(address(adapter)), 0);
        assertEq(bad.allowance(address(adapter), address(destination)), 0);
        _return(HOLDER, 0.01 ether);
        assertEq(adapter.totalShares(), 0);
        assertEq(adapter.campaignNativeReserved(), receipt);
        vm.warp(destination.deadline());
        assertEq(adapter.flushCampaignRevenue(), receipt);
        assertEq(bad.balanceOf(bob), receipt);
        assertEq(adapter.campaignNativeReserved(), 0);
    }
}
