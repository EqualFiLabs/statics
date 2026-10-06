// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMoshSwarm, IMoshClaimMarket} from "../../src/interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {MoshTeamRevenueAdapter} from "../../src/bootstrap/MoshTeamRevenueAdapter.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {MoshForkFeeHook} from "./RobinhoodMoshClaimFork.t.sol";
import {RejectingRevenueWeth} from "./NativeCampaignRevenue.t.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";

/// @dev Real historical team seller transfers fee claims to the actual deployed adapter through the
/// deployed claim market. No successful adapter call is impersonated, and Mosh code/storage is not etched.
/// New-launch direct teamRecipient binding is implemented but not proven by this existing-launch fixture.
contract RobinhoodMoshTeamAdapterForkTest is CampaignTestBase, IUnlockCallback {
    IMoshSwarm private constant SWARM = IMoshSwarm(0x6A3800dD7b3F1e03e29BEfE2A9238549a9642Ac8);
    IMoshClaimMarket private constant MARKET = IMoshClaimMarket(0xA8C83951eE2431106f0aAea6ae79F97A530521aA);
    address private constant TEAM = 0x8B86B1C726F7a1c09f7c4c31e53621a27e4C8AdC;
    address private constant TOKEN = 0xD68f57B08CD9732e4Ddd1a04bA4d26629DC44B8E;
    address private constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPoolManager private constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    WETH private wrapped;
    MoshTeamRevenueAdapter private adapter;
    BasketBootstrapCampaign private destination;
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
        vm.deal(vm.addr(CREATOR_KEY), 100 ether);
        (adapter, destination) = _bound(wrapped, 1000, keccak256("Mosh team"));
        sourceKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0, 200, IHooks(HOOK));
        assertEq(SWARM.teamRecipient(), TEAM);
        assertEq(SWARM.teamShareBps(), 1000);
        assertTrue(destination.creator() != TEAM, "campaign creator is not fabricated team authority");
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

    function _bound(WETH wrapper, uint256 teamShare, bytes32 salt)
        private
        returns (MoshTeamRevenueAdapter delivery, BasketBootstrapCampaign campaign)
    {
        delivery = new MoshTeamRevenueAdapter(
            vm.addr(CREATOR_KEY),
            address(wrapper),
            address(wrapper).codehash,
            campaignFactory,
            _pins(),
            LibMoshValidation.MarketPins(
                address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
            ),
            teamShare
        );
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.projectToken = TOKEN;
        terms.basket.assets[0] = address(wrapper);
        terms.adapters = new address[](1);
        terms.adapters[0] = address(delivery);
        campaign = _campaign(terms, salt);
        vm.prank(vm.addr(CREATOR_KEY));
        delivery.bindCampaign(campaign, 0);
    }

    function _bind(MoshTeamRevenueAdapter delivery) private {
        vm.prank(vm.addr(CREATOR_KEY));
        delivery.bindSource(SWARM);
    }

    function _offer(MoshTeamRevenueAdapter delivery, uint256 amount) private returns (uint256 id) {
        vm.prank(TEAM);
        id = MARKET.list(address(SWARM), amount, 1, address(delivery), uint64(block.timestamp + 1 hours));
    }

    function _handoff(MoshTeamRevenueAdapter delivery, uint256 amount) private {
        SWARM.syncFees();
        uint256 beforeTeam = SWARM.claim(TEAM);
        uint256 beforeSwarmNative = address(SWARM).balance;
        uint256 preHandoffFees = SWARM.claimable(TEAM);
        uint256 totalClaims = IMoshTeamCollection(address(SWARM)).totalClaims();
        bytes32 principal = _vaultHoldingsHash();
        uint256 id = _offer(delivery, amount);
        vm.prank(TEAM);
        delivery.acceptTeamHandoff{value: 1}(id, amount);
        assertEq(SWARM.claim(TEAM) + amount, beforeTeam);
        assertEq(SWARM.claim(address(delivery)), amount);
        assertEq(delivery.teamClaims(), amount);
        assertTrue(delivery.rightsBound());
        assertEq(address(SWARM).balance + preHandoffFees, beforeSwarmNative, "only seller fee entitlement leaves");
        assertEq(IMoshTeamCollection(address(SWARM)).totalClaims(), totalClaims);
        assertEq(_vaultHoldingsHash(), principal, "fee-right handoff does not move agent principal");
    }

    function _vaultHoldingsHash() private view returns (bytes32 commitment) {
        IMoshTeamCollection source = IMoshTeamCollection(address(SWARM));
        uint256 count = source.vaultCount();
        for (uint256 i; i < count; ++i) {
            address vault = source.vaults(i);
            commitment = keccak256(abi.encode(commitment, vault, vault.balance, IERC20(TOKEN).balanceOf(vault)));
        }
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
        // Existing upstream fee operator is a diagnostic fork input, not Statics-owned authority.
        vm.prank(MoshForkFeeHook(HOOK).feeSweepOperator());
        MoshForkFeeHook(HOOK).sweepPoolFees(keccak256(abi.encode(sourceKey)), 1, 1);
        assertGt(SWARM.syncFees(), 0);
    }

    function testActualTeamHandoffAndMeasuredCampaignRevenue() public {
        _bind(adapter);
        assertFalse(adapter.rightsBound());
        _handoff(adapter, 0.01 ether);
        _swap();
        assertEq(adapter.sync(), 0, "unconverted source fees are not funding");
        _realize();
        uint256 expected = SWARM.claimable(address(adapter));
        assertGt(expected, 0);
        vm.prank(makeAddr("permissionless collector"));
        assertEq(adapter.sync(), expected);
        assertEq(adapter.nativeReserved(), expected);
        assertEq(adapter.totalMeasured(), expected);
        assertEq(adapter.sync(), 0);
        adapter.flushTeamRevenue();
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, expected);
        assertEq(wrapped.balanceOf(address(destination)), expected);
        assertEq(wrapped.allowance(address(adapter), address(destination)), 0);
        assertEq(adapter.nativeReserved(), 0);
        assertEq(SWARM.teamRecipient(), TEAM, "historical recipient has not been replaced");
        assertEq(SWARM.claim(address(adapter)), 0.01 ether, "permanent fee rights are retained");
    }

    function testActualTeamSellerKeepsPreHandoffFeeEntitlement() public {
        _bind(adapter);
        _swap();
        _realize();
        uint256 oldEntitlement = SWARM.claimable(TEAM);
        assertGt(oldEntitlement, 0);
        uint256 sellerBefore = TEAM.balance;
        uint256 id = _offer(adapter, 0.01 ether);
        vm.prank(TEAM);
        adapter.acceptTeamHandoff{value: 1}(id, 0.01 ether);
        assertEq(TEAM.balance - sellerBefore, oldEntitlement, "one-wei sale price offsets seller payment");
        assertEq(adapter.totalMeasured(), 0);
        assertEq(SWARM.claimable(address(adapter)), 0);
        _swap();
        _realize();
        assertGt(adapter.sync(), 0);
    }

    function testHistoricalTeamAuthorityCannotBeSubstitutedByCampaignCreator() public {
        _bind(adapter);
        uint256 id = _offer(adapter, 0.01 ether);
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        vm.prank(vm.addr(CREATOR_KEY));
        adapter.acceptTeamHandoff{value: 1}(id, 0.01 ether);
        vm.prank(TEAM);
        adapter.acceptTeamHandoff{value: 1}(id, 0.01 ether);
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        vm.prank(TEAM);
        adapter.acceptTeamHandoff{value: 1}(id, 0.01 ether);
        assertEq(SWARM.claim(address(adapter)), 0.01 ether);
    }

    function testSourceAndOfferBindingFailuresLeaveClaimsUntouched() public {
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        vm.prank(alice);
        adapter.bindSource(SWARM);
        (MoshTeamRevenueAdapter wrongShare,) = _bound(wrapped, 500, keccak256("wrong team terms"));
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        _bind(wrongShare);
        _bind(adapter);
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        _bind(adapter);
        uint256 id = _offer(adapter, 0.01 ether);
        uint256 beforeTeam = SWARM.claim(TEAM);
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        vm.prank(TEAM);
        adapter.acceptTeamHandoff{value: 1}(id, 0.02 ether);
        assertEq(SWARM.claim(TEAM), beforeTeam);
        assertEq(SWARM.claim(address(adapter)), 0);
        vm.expectRevert(MoshTeamRevenueAdapter.InvalidMoshTeamIntegration.selector);
        adapter.sync();
    }

    function testTerminalRevenueGoesToBeneficiaryAndPreservesUnsolicitedBalances() public {
        _bind(adapter);
        _handoff(adapter, 0.01 ether);
        wrapped.deposit{value: 7 ether}();
        wrapped.transfer(address(adapter), 7 ether);
        vm.deal(address(adapter), 5 ether);
        _swap();
        _realize();
        uint256 amount = adapter.sync();
        vm.warp(destination.deadline());
        assertEq(adapter.flushTeamRevenue(), amount);
        assertEq(wrapped.balanceOf(bob), amount);
        assertEq(wrapped.balanceOf(address(adapter)), 7 ether);
        assertEq(address(adapter).balance, 5 ether);
        _swap();
        _realize();
        uint256 later = adapter.sync();
        adapter.flushTeamRevenue();
        assertEq(wrapped.balanceOf(bob), amount + later);
        assertEq(adapter.totalDelivered(), amount + later);
    }

    function testActualLaunchedPolAndPostLaunchTeamRevenue() public {
        _bind(adapter);
        _handoff(adapter, 0.01 ether);
        (, uint256 target,,) = destination.inventory(0);
        wrapped.deposit{value: target}();
        wrapped.approve(address(destination), target);
        destination.fund(0, target);
        (, uint256 otherTarget,,) = destination.inventory(1);
        assetB.mint(alice, otherTarget);
        vm.startPrank(alice);
        assetB.approve(address(destination), otherTarget);
        destination.fund(1, otherTarget);
        vm.stopPrank();
        destination.fundNative{value: destination.nativeRequired()}();
        (uint256 id,) = destination.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        for (uint256 i; i < 2; ++i) {
            (address asset,,,) = destination.inventory(i);
            assertEq(
                IStaticsProtocolPools(address(diamond))
                .protocolPool(basketLiquidity.canonicalPool(id, asset).poolId)
                .activePolPositions,
                1
            );
        }
        _swap();
        _realize();
        uint256 amount = adapter.sync();
        assertGt(amount, 0);
        adapter.flushTeamRevenue();
        assertEq(wrapped.balanceOf(bob), amount);
        assertEq(adapter.recipient(), bob);
    }

    function testDeliveryFailureDoesNotUndoRightsOrMeasuredCollection() public {
        RejectingRevenueWeth blocked = new RejectingRevenueWeth();
        (MoshTeamRevenueAdapter retryable,) = _bound(blocked, 1000, keccak256("blocked team delivery"));
        _bind(retryable);
        _handoff(retryable, 0.01 ether);
        _swap();
        _realize();
        uint256 amount = retryable.sync();
        assertGt(amount, 0);
        vm.expectRevert(RejectingRevenueWeth.DeliveryBlocked.selector);
        retryable.flushTeamRevenue();
        assertEq(retryable.nativeReserved(), amount);
        assertEq(address(retryable).balance, amount);
        assertEq(blocked.balanceOf(address(retryable)), 0);
        assertEq(SWARM.claim(address(retryable)), 0.01 ether);
        assertEq(retryable.sync(), 0);
    }

    function testUnsolicitedAndRedirectedNativeCallbacksAreRejected() public {
        _bind(adapter);
        _handoff(adapter, 0.01 ether);
        (bool accepted,) = address(adapter).call{value: 1}("");
        assertFalse(accepted);
        _swap();
        _realize();
        uint256 teamBefore = SWARM.claimable(TEAM);
        assertGt(teamBefore, 0);
        vm.expectRevert();
        vm.prank(TEAM);
        IMoshTeamCollection(address(SWARM)).collectFees(address(adapter));
        assertEq(SWARM.claimable(TEAM), teamBefore);
        assertEq(adapter.totalMeasured(), 0);
        assertGt(adapter.sync(), 0);
    }
}

interface IMoshTeamCollection {
    function collectFees(address recipient) external returns (uint256);
    function totalClaims() external view returns (uint256);
    function vaultCount() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
}
