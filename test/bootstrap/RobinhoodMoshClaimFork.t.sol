// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMoshSwarm, IMoshFactory, IMoshRegistry, IMoshClaimMarket} from "../../src/interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {MoshValidationHarness} from "./MoshValidation.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface MoshForkFeeHook {
    function feeSweepOperator() external view returns (address);
    function sweepPoolFees(bytes32 id, uint256 amount0Minimum, uint256 amount1Minimum) external;
    function pendingCreatorTax(bytes32 id, address asset) external view returns (uint256);
}

/// @dev Contract-controlled probe only, NOT the production adapter or its accounting implementation.
/// It has no direct transferClaim privilege and never accesses Swarm principal.
contract MoshClaimCustodyProbe is ReentrancyGuard {
    IMoshSwarm public immutable swarm;
    IMoshClaimMarket public immutable market;
    address public immutable depositor;
    uint256 public received;
    uint256 public saleProceeds;
    uint256 public claimsAtLastRewardReceipt;

    constructor(IMoshSwarm source, IMoshClaimMarket venue, address owner) {
        swarm = source;
        market = venue;
        depositor = owner;
    }

    receive() external payable {
        if (msg.sender == address(swarm)) {
            claimsAtLastRewardReceipt = swarm.claim(address(this));
            received += msg.value;
        } else if (msg.sender == address(market)) {
            saleProceeds += msg.value;
        } else {
            revert("unknown native source");
        }
    }

    function enter(uint256 offerId) external payable nonReentrant {
        require(msg.sender == depositor, "only depositor");
        LibMoshValidation.Offer memory offer = LibMoshValidation.readOffer(market, offerId);
        LibMoshValidation.validateCustodyOffer(
            market, offerId, address(swarm), depositor, address(this), offer.amount, market.feeBps()
        );
        require(msg.value == 1, "only custody price");
        uint256 beforeSeller = swarm.claim(depositor);
        uint256 beforeBuyer = swarm.claim(address(this));
        market.fill{value: msg.value}(offerId);
        require(swarm.claim(depositor) + offer.amount == beforeSeller, "inexact debit");
        require(swarm.claim(address(this)) == beforeBuyer + offer.amount, "inexact receipt");
    }

    function listReturn(uint256 amount, uint256 deadline) external nonReentrant returns (uint256) {
        require(msg.sender == depositor && deadline <= type(uint64).max, "invalid return");
        return market.list(address(swarm), amount, 1, depositor, uint64(deadline));
    }

    function sync() external nonReentrant returns (uint256 amount) {
        swarm.syncFees();
        if (swarm.claimable(address(this)) == 0) return 0;
        amount = swarm.collectFees();
    }

    function cancelReturn(uint256 offerId) external nonReentrant {
        require(msg.sender == depositor, "only depositor");
        market.cancel(offerId);
    }
}

/// @dev Forks deployed contracts without etching code or impersonating the custody probe.
contract RobinhoodMoshClaimForkTest is Test, IUnlockCallback {
    uint256 private constant FORK_BLOCK = 80_155_273;
    IMoshSwarm private constant SWARM = IMoshSwarm(0x6A3800dD7b3F1e03e29BEfE2A9238549a9642Ac8);
    IMoshClaimMarket private constant MARKET = IMoshClaimMarket(0xA8C83951eE2431106f0aAea6ae79F97A530521aA);
    address private constant IMPLEMENTATION = 0x42B0b14C6e6bCAa2e9B29F87aA3DE19290a5c572;
    address private constant FACTORY = 0x9073cb17846398fB8B379Ab06C2B840dEA7f0069;
    address private constant REGISTRY = 0x71BDDCfee17b718c92f0Be80910D2f06542ff379;
    address private constant HOLDER = 0x8B86B1C726F7a1c09f7c4c31e53621a27e4C8AdC;
    address private constant TOKEN = 0xD68f57B08CD9732e4Ddd1a04bA4d26629DC44B8E;
    address private constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPoolManager private constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    MoshClaimCustodyProbe private custody;
    PoolKey private key;

    function setUp() public {
        // Never pass a private endpoint as an envOr fallback: verbose traces render fallback arguments.
        string memory rpc = vm.envOr("MOSH_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "Robinhood RPC not configured");
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 4663);
        // Robinhood's header pins the L2 block; its l1BlockNumber can be used for EVM NUMBER.
        // The existing Anvil node instead exposes the L2 number. Do not conflate those counters.
        assertEq(IMPLEMENTATION.codehash, 0x210393a615dd4a801aaa9449b8e65d6b0ba7b98d6ef5ed9f2400833643fd44ac);
        assertEq(address(MARKET).codehash, 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e);
        assertEq(FACTORY.codehash, 0x82edd64be0bedd5f9462e948447c6416adad6c77c71945e1cba585387f553423);
        assertEq(REGISTRY.codehash, 0x93f0f1391a76bb2aa72c310f33636f9049002ef16584a9b0370e199edb26702e);
        assertEq(HOOK.codehash, 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db);
        assertEq(
            address(SWARM).code,
            abi.encodePacked(hex"363d3d373d3d3d363d73", IMPLEMENTATION, hex"5af43d82803e903d91602b57fd5bf3")
        );
        assertEq(SWARM.factory(), FACTORY);
        assertEq(SWARM.registry(), REGISTRY);
        assertEq(SWARM.memecoin(), TOKEN);
        assertTrue(SWARM.counterIsNative());
        assertEq(SWARM.counterAsset(), address(0));
        assertTrue(IMoshFactory(FACTORY).isSwarm(address(SWARM)));
        assertEq(IMoshFactory(FACTORY).swarmImplementation(), IMPLEMENTATION);
        assertEq(IMoshFactory(FACTORY).registry(), REGISTRY);
        assertEq(IMoshFactory(FACTORY).pairToken(), address(0));
        assertTrue(IMoshRegistry(REGISTRY).isClaimMarket(address(MARKET)));
        assertEq(MARKET.feeBps(), 1000);
        custody = new MoshClaimCustodyProbe(SWARM, MARKET, HOLDER);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(TOKEN), 0, 200, IHooks(HOOK));
        vm.deal(address(this), 10 ether);
        vm.deal(HOLDER, HOLDER.balance + 1 ether);
    }

    function _enter(uint256 amount) private {
        uint256 beforeClaims = SWARM.claim(HOLDER);
        vm.prank(HOLDER);
        uint256 offer = MARKET.list(address(SWARM), amount, 1, address(custody), uint64(block.timestamp + 1 hours));
        vm.prank(HOLDER);
        custody.enter{value: 1}(offer);
        assertEq(SWARM.claim(HOLDER), beforeClaims - amount);
        assertEq(SWARM.claim(address(custody)), amount);
    }

    function _return(uint256 amount) private {
        uint256 beforeCustody = SWARM.claim(address(custody));
        uint256 beforeHolder = SWARM.claim(HOLDER);
        vm.prank(HOLDER);
        uint256 offer = custody.listReturn(amount, block.timestamp + 1 hours);
        // A listing does not escrow or release claims. The designated buyer fills it separately.
        assertEq(SWARM.claim(address(custody)), beforeCustody);
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), beforeCustody - amount);
        assertEq(SWARM.claim(HOLDER), beforeHolder + amount);
    }

    function _swap() private {
        MANAGER.unlock(abi.encode(0.01 ether));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "only manager");
        uint256 amount = abi.decode(data, (uint256));
        BalanceDelta delta = MANAGER.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        MANAGER.settle{value: uint256(-int256(delta.amount0()))}();
        MANAGER.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }

    function _externalOperatorRealizesFees() private {
        // Model the EXISTING upstream conversion operator, not adapter authority.
        // Production Statics cannot invoke this operator-only conversion itself.
        address operator = MoshForkFeeHook(HOOK).feeSweepOperator();
        assertTrue(operator != address(0));
        vm.prank(operator);
        MoshForkFeeHook(HOOK).sweepPoolFees(keccak256(abi.encode(key)), 1, 1);
        assertGt(SWARM.syncFees(), 0);
    }

    function testContractControlsEntryAndPartialThenFullReturn() public {
        uint256 original = SWARM.claim(HOLDER);
        _enter(0.01 ether);
        vm.warp(block.timestamp + 1 days);
        _return(0.004 ether);
        _return(0.006 ether);
        assertEq(SWARM.claim(HOLDER), original);
        assertEq(SWARM.claim(address(custody)), 0);
        assertEq(custody.saleProceeds(), 2, "return prices are principal-side proceeds, not rewards");
    }

    function testReturnListingIsBuyerBoundAndCustodyHasNoDirectTransferPrivilege() public {
        _enter(0.01 ether);
        vm.expectRevert();
        vm.prank(address(custody)); // Negative permission check only, never the successful entry/return flow.
        SWARM.transferClaim(address(custody), HOLDER, 0.01 ether);
        vm.prank(HOLDER);
        uint256 offer = custody.listReturn(0.01 ether, block.timestamp + 1 hours);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.expectRevert();
        vm.prank(stranger);
        MARKET.fill{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), 0.01 ether);
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), 0);
    }

    function testPermissionlessContractCollectionIsMeasuredAndIdempotent() public {
        _enter(0.01 ether);
        _swap();
        assertEq(custody.sync(), 0, "no operator conversion means no realized payout");
        vm.warp(block.timestamp + 1 days);
        _externalOperatorRealizesFees();
        uint256 expected = SWARM.claimable(address(custody));
        assertGt(expected, 0);
        uint256 beforeNative = address(custody).balance;
        vm.prank(makeAddr("permissionless sync caller"));
        assertEq(custody.sync(), expected);
        assertEq(address(custody).balance - beforeNative, expected);
        assertEq(custody.received(), expected);
        assertEq(custody.sync(), 0);
        assertEq(custody.received(), expected);
    }

    function testMarketReturnPaysOldCustodianBeforeClaimBalanceChanges() public {
        _enter(0.01 ether);
        _swap();
        _externalOperatorRealizesFees();
        uint256 earned = SWARM.claimable(address(custody));
        assertGt(earned, 0);
        _return(0.01 ether);
        assertEq(custody.received(), earned, "transfer automatically settles old owner");
        assertEq(custody.claimsAtLastRewardReceipt(), 0.01 ether, "callback precedes old claim balance removal");
        assertEq(custody.saleProceeds(), 1, "sale proceeds must not be counted as fees");
        assertEq(SWARM.claimable(address(custody)), 0);
        assertEq(custody.sync(), 0, "automatic payout must not be claimed twice");
    }

    function testDelayedConversionFollowsReturnedClaimWithoutBlockingRecovery() public {
        uint256 original = SWARM.claim(HOLDER);
        _enter(0.01 ether);
        _swap();
        assertGt(MoshForkFeeHook(HOOK).pendingCreatorTax(keccak256(abi.encode(key)), TOKEN), 0);
        assertEq(custody.sync(), 0);
        _return(0.01 ether);
        assertEq(SWARM.claim(HOLDER), original);
        vm.warp(block.timestamp + 1 days);
        _externalOperatorRealizesFees();
        assertEq(custody.sync(), 0);
        assertGt(SWARM.claimable(HOLDER), 0);
    }

    function testExpiredReturnListingCanBeReplacedWithoutLockingClaims() public {
        _enter(0.01 ether);
        vm.prank(HOLDER);
        uint256 offer = custody.listReturn(0.01 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert();
        vm.prank(HOLDER);
        MARKET.fill{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), 0.01 ether);
        // Expiry does not release the market's listed-amount accounting automatically.
        vm.expectRevert();
        vm.prank(HOLDER);
        custody.listReturn(0.01 ether, block.timestamp + 1 hours);
        vm.prank(HOLDER);
        custody.cancelReturn(offer);
        _return(0.01 ether);
        assertEq(SWARM.claim(address(custody)), 0);
    }

    function testZeroPriceAndFilledOfferReplayAreRejected() public {
        vm.expectRevert();
        vm.prank(HOLDER);
        MARKET.list(address(SWARM), 0.01 ether, 0, address(custody), uint64(block.timestamp + 1 hours));
        vm.prank(HOLDER);
        uint256 offer = MARKET.list(address(SWARM), 0.01 ether, 1, address(custody), uint64(block.timestamp + 1 hours));
        vm.prank(HOLDER);
        custody.enter{value: 1}(offer);
        vm.expectRevert();
        vm.prank(HOLDER);
        custody.enter{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), 0.01 ether);
        assertEq(custody.received(), 0);
    }

    function testMarketOfferMetadataBindsAndClearsExactMovement() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.prank(HOLDER);
        uint256 offer = MARKET.list(address(SWARM), 0.01 ether, 1, address(custody), deadline);
        _assertOffer(offer, HOLDER, address(custody), 0.01 ether, deadline);
        vm.prank(HOLDER);
        custody.enter{value: 1}(offer);
        _assertCleared(offer);
        vm.prank(HOLDER);
        uint256 returning = custody.listReturn(0.01 ether, deadline);
        _assertOffer(returning, address(custody), HOLDER, 0.01 ether, deadline);
        vm.prank(HOLDER);
        custody.cancelReturn(returning);
        _assertCleared(returning);
    }

    function _sourcePins() private pure returns (LibMoshValidation.SourcePins memory) {
        return LibMoshValidation.SourcePins(
            4663,
            FACTORY,
            0x82edd64be0bedd5f9462e948447c6416adad6c77c71945e1cba585387f553423,
            REGISTRY,
            0x93f0f1391a76bb2aa72c310f33636f9049002ef16584a9b0370e199edb26702e,
            IMPLEMENTATION,
            0x210393a615dd4a801aaa9449b8e65d6b0ba7b98d6ef5ed9f2400833643fd44ac
        );
    }

    function testPinnedSourceAndMarketPassProductionValidation() public {
        MoshValidationHarness gate = new MoshValidationHarness();
        gate.validateSource(address(SWARM), TOKEN, _sourcePins());
        gate.validateMarket(
            REGISTRY,
            LibMoshValidation.MarketPins(
                address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
            )
        );
    }

    function testMismatchedChainTokenAndRuntimePinsAreRejected() public {
        MoshValidationHarness gate = new MoshValidationHarness();
        LibMoshValidation.SourcePins memory pins = _sourcePins();
        pins.chainId = 1;
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), TOKEN, pins);
        pins = _sourcePins();
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), address(MARKET), pins);
        pins.implementationRuntimeHash = bytes32(uint256(1));
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), TOKEN, pins);
        pins = _sourcePins();
        pins.factoryRuntimeHash = bytes32(0);
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), TOKEN, pins);
        pins = _sourcePins();
        pins.registryRuntimeHash = bytes32(uint256(1));
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), TOKEN, pins);
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(custody), TOKEN, _sourcePins());
    }

    function testMismatchedMarketPinAndFeeAreRejected() public {
        MoshValidationHarness gate = new MoshValidationHarness();
        LibMoshValidation.MarketPins memory pins = LibMoshValidation.MarketPins(
            address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 999
        );
        vm.expectRevert(LibMoshValidation.InvalidMoshMarket.selector);
        gate.validateMarket(REGISTRY, pins);
        pins.feeBps = 1000;
        pins.runtimeHash = bytes32(uint256(1));
        vm.expectRevert(LibMoshValidation.InvalidMoshMarket.selector);
        gate.validateMarket(REGISTRY, pins);
    }

    function testUnsupportedCounterAndRevokedMarketFailValidation() public {
        MoshValidationHarness gate = new MoshValidationHarness();
        // Narrow guard-branch checks; mocked metadata is not claimed as external behavior evidence.
        vm.mockCall(address(SWARM), abi.encodeCall(IMoshSwarm.counterIsNative, ()), abi.encode(false));
        vm.expectRevert(LibMoshValidation.InvalidMoshSource.selector);
        gate.validateSource(address(SWARM), TOKEN, _sourcePins());
        vm.clearMockedCalls();
        vm.mockCall(REGISTRY, abi.encodeCall(IMoshRegistry.isClaimMarket, (address(MARKET))), abi.encode(false));
        vm.expectRevert(LibMoshValidation.InvalidMoshMarket.selector);
        gate.validateMarket(
            REGISTRY,
            LibMoshValidation.MarketPins(
                address(MARKET), 0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e, 1000
            )
        );
    }

    function testCustodyOfferAtExactDeadlineMatchesMarket() public {
        uint64 end = uint64(block.timestamp + 1 hours);
        vm.prank(HOLDER);
        uint256 offer = MARKET.list(address(SWARM), 0.01 ether, 1, address(custody), end);
        vm.warp(end);
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        vm.prank(HOLDER);
        custody.enter{value: 1}(offer);
        // Negative raw-market boundary probe only; no successful custody-address impersonation.
        vm.deal(address(custody), 1);
        vm.expectRevert(bytes4(0x9cb13087));
        vm.prank(address(custody));
        MARKET.fill{value: 1}(offer);
        assertEq(SWARM.claim(address(custody)), 0);
    }

    function _assertOffer(uint256 id, address seller, address buyer, uint256 amount, uint64 deadline) private view {
        (address source, address owner, address receiver, uint256 size, uint256 price, uint64 end, uint16 fee) =
            MARKET.offers(id);
        assertEq(source, address(SWARM));
        assertEq(owner, seller);
        assertEq(receiver, buyer);
        assertEq(size, amount);
        assertEq(price, 1);
        assertEq(end, deadline);
        assertEq(fee, 1000);
    }

    function _assertCleared(uint256 id) private view {
        (address source, address seller, address buyer, uint256 amount, uint256 price, uint64 end, uint16 fee) =
            MARKET.offers(id);
        assertEq(source, address(0));
        assertEq(seller, address(0));
        assertEq(buyer, address(0));
        assertEq(amount, 0);
        assertEq(price, 0);
        assertEq(end, 0);
        assertEq(fee, 0);
    }
}
