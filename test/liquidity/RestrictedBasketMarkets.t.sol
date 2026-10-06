// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {LibBasketMarkets} from "../../src/libraries/LibBasketMarkets.sol";
import {LibRestrictedBasket} from "../../src/libraries/LibRestrictedBasket.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../../src/libraries/LibBasketLiquidity.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";

/// @dev Narrow registry/callback harness. Real v4 pools and boundary transfers execute below;
/// full Diamond creation, gauges, lending, and POL are covered at the creation integration gate.
contract RestrictedMarketProtocol is BasketSettlementFacet, RangeGaugeCallbackFacet {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager manager) {
        LibGlobalRewards.rewardStorage().stakingToken = address(new MockERC20("Statics", "STATICS", 18));
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.poolManager = address(manager);
        ls.hook = address(0xBAD); // Must not authenticate per-pool callbacks through this legacy pointer.
        ls.integrationInstalled = true;
    }

    function deployToken(IPoolManager manager, uint256 basketId) external returns (StaticsRestrictedBasketToken token) {
        token = new StaticsRestrictedBasketToken("Basket", "B", address(this), basketId, manager);
        LibRestrictedBasket.register(address(token), basketId);
        LibBasket.basketStorage().baskets[basketId].token = address(token);
    }

    function mint(StaticsRestrictedBasketToken token, address receiver, uint256 amount) external {
        token.mint(receiver, amount);
    }

    function register(PoolKey calldata key, address creator) external {
        LibBasketMarkets.register(key, creator, 0, address(1), 1);
        LibRangeGauge.initializePool(key.toId(), 0);
    }

    function lifecycle(PoolId id, uint256 next) external {
        require(next <= uint256(LibBasketMarkets.Lifecycle.Decommissioned));
        LibBasketMarkets.transition(id, LibBasketMarkets.Lifecycle(next));
    }

    function basketStatus(uint256 basketId, uint256 status) external {
        require(status <= uint256(IStaticsBasket.BasketStatus.ExitOnly));
        LibBasket.basketStorage().baskets[basketId].status = IStaticsBasket.BasketStatus(status);
    }

    function market(PoolId id) external view returns (LibBasketMarkets.Market memory) {
        return LibBasketMarkets.requireMarket(id);
    }

    function sequence(PoolId id) external view returns (uint256) {
        return LibMarketTape.marketTapeStorage().canonical[id].sequence;
    }

    function protocolPolFundingConfig(PoolId) external pure returns (bool, bool, uint16) {
        return (true, false, 0);
    }

    function canAccrueBasketRewards(PoolId) external pure returns (bool) {
        return false;
    }

    function canAccrueStakerRewards(address) external pure returns (bool) {
        return false;
    }

    function protocolPoolSwapsBlocked(PoolId) external pure returns (bool) {
        return false;
    }

    function harvest(IStaticsSwapFeeHook hook, PoolKey calldata key) external {
        hook.settleFeeDistribution(key, key.currency0, address(this));
        hook.settleFeeDistribution(key, key.currency1, address(this));
    }

    function feeRate(IStaticsSwapFeeHook hook, PoolId id, uint256 input, uint256 output) external {
        require(input <= type(uint16).max && output <= type(uint16).max);
        hook.setPoolFeeRate(id, uint16(input), uint16(output));
    }

    function decommission(IStaticsSwapFeeHook hook, PoolKey calldata key) external {
        hook.decommissionPool(key);
    }
}

contract BasketMarketPolicy {
    address public immutable staticsDiamond;
    uint16 private inputFee = 25;
    uint16 private outputFee = 25;

    constructor(address diamond) {
        staticsDiamond = diamond;
    }

    function defaultFeeRate() external view returns (uint16, uint16) {
        return (inputFee, outputFee);
    }

    function setRate(uint256 input, uint256 output) external {
        require(input + output <= 200);
        inputFee = uint16(input);
        outputFee = uint16(output);
    }

    function basketFeeAllocation() external pure returns (IStaticsSwapFeeHook.BasketFeeAllocation memory) {
        return IStaticsSwapFeeHook.BasketFeeAllocation(1500, 3000, 3000, 2000);
    }

    function generalFeeAllocation() external pure returns (IStaticsSwapFeeHook.GeneralFeeAllocation memory) {
        return IStaticsSwapFeeHook.GeneralFeeAllocation(4000, 3500, 2000);
    }
}

contract RestrictedBasketMarketsTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    uint160 private constant MASK = 0x1fec;
    IPoolManager private manager;
    RestrictedMarketProtocol private protocol;
    BasketMarketPolicy private policy;
    CanonicalV4Router private router;
    StaticsRestrictedBasketToken private token;
    MockERC20 private asset;
    StaticsBasketHook private hook;
    PoolKey private key;

    function setUp() public {
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        protocol = new RestrictedMarketProtocol(manager);
        policy = new BasketMarketPolicy(address(protocol));
        router = new CanonicalV4Router(manager);
        token = protocol.deployToken(manager, 0);
        asset = new MockERC20("Underlying", "U", 18);
        (hook, key) = _deployMarket(address(token), address(asset));
        protocol.register(key, address(this));
        manager.initialize(key, uint160(1 << 96));
        protocol.mint(token, address(this), 100 ether);
        asset.mint(address(this), 100 ether);
        token.approve(address(router), 100 ether);
        asset.approve(address(router), 100 ether);
        _liquidity(10 ether);
    }

    function testRealSwapsInBothDirectionsSettleFinalFeeAdjustedDeltas() public {
        _swap(true, -int256(0.1 ether));
        _swap(false, -int256(0.1 ether));
        _swap(true, int256(0.05 ether));
        _swap(false, int256(0.05 ether));
        assertEq(protocol.sequence(key.toId()), 4);
        (uint256 inbound, uint256 outbound) = token.settlementBudgets();
        assertEq(inbound, 0);
        assertEq(outbound, 0);
        assertGt(hook.claimLiability(Currency.wrap(address(token))), 0);
        uint256 beforeClaims = token.balanceOf(address(protocol));
        protocol.harvest(hook, key);
        assertGt(token.balanceOf(address(protocol)), beforeClaims);
        assertLe(
            hook.claimLiability(Currency.wrap(address(token))),
            hook.pendingProtocolPol(key.toId(), Currency.wrap(address(token)))
        );
    }

    function testExitOnlyAllowsActualRemovalAndCollectionButBlocksSwapAndIngress() public {
        _swap(true, -int256(0.1 ether));
        protocol.lifecycle(key.toId(), uint256(LibBasketMarkets.Lifecycle.ExitOnly));
        vm.expectRevert();
        _swap(false, -int256(0.1 ether));
        vm.expectRevert();
        _liquidity(1 ether);
        BalanceDelta collected = _liquidity(0);
        assertTrue(collected.amount0() >= 0 && collected.amount1() >= 0);
        BalanceDelta removed = _liquidity(-int256(10 ether));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        protocol.lifecycle(key.toId(), uint256(LibBasketMarkets.Lifecycle.Decommissioned));
        protocol.decommission(hook, key);
        protocol.harvest(hook, key);
        assertEq(address(protocol.market(key.toId()).key.hooks), address(hook));
        vm.expectRevert();
        protocol.lifecycle(key.toId(), uint256(LibBasketMarkets.Lifecycle.Active));
    }

    function testIndependentPoolsWithIdenticalConfigurationKeepPermanentRecords() public {
        (StaticsBasketHook second, PoolKey memory secondKey) = _deployMarket(address(token), address(asset));
        protocol.register(secondKey, address(this));
        manager.initialize(secondKey, uint160(1 << 96));
        assertNotEq(address(second), address(hook));
        assertNotEq(PoolId.unwrap(secondKey.toId()), PoolId.unwrap(key.toId()));
        assertEq(address(protocol.market(key.toId()).key.hooks), address(hook));
        assertEq(address(protocol.market(secondKey.toId()).key.hooks), address(second));
        vm.expectRevert();
        protocol.register(key, address(this));
    }

    function testBothRestrictedCurrenciesAndLifecycleRelationships() public {
        StaticsRestrictedBasketToken other = protocol.deployToken(manager, 1);
        (StaticsBasketHook both, PoolKey memory bothKey) = _deployMarket(address(token), address(other));
        protocol.register(bothKey, address(this));
        manager.initialize(bothKey, uint160(1 << 96));
        protocol.mint(other, address(this), 100 ether);
        other.approve(address(router), 100 ether);
        router.modifyLiquidity(bothKey, _params(2 ether));
        router.swap(bothKey, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        assertTrue(protocol.market(bothKey.toId()).restricted0);
        assertTrue(protocol.market(bothKey.toId()).restricted1);
        protocol.basketStatus(1, uint256(IStaticsBasket.BasketStatus.ExitOnly));
        vm.expectRevert();
        router.swap(bothKey, SwapParams(false, -int256(0.01 ether), TickMath.MAX_SQRT_PRICE - 1));
        router.modifyLiquidity(bothKey, _params(-int256(2 ether)));
        protocol.harvest(both, bothKey);
    }

    function testNoRebindingWrongPoolCallbackOrUnregisteredAuthority() public {
        vm.expectRevert();
        hook.registerPool(key, IStaticsSwapFeeHook.PoolKind.BasketCanonical, address(this));
        vm.expectRevert();
        protocol.authorizeBasketPoolSettlement(key.toId(), BalanceDelta.wrap(0), 0);
        PoolKey memory different = key;
        different.fee = 500;
        vm.expectRevert();
        manager.initialize(different, uint160(1 << 96));
        vm.prank(address(hook));
        vm.expectRevert();
        protocol.authorizeBasketPoolClaim(key.toId(), Currency.wrap(address(1234)), address(this), 1);
        vm.prank(address(hook));
        vm.expectRevert();
        protocol.authorizeBasketPoolSettlement(key.toId(), BalanceDelta.wrap(0), 3);
    }

    function testDonationsAndInitializationBeforeRegistryBindingAreRejected() public {
        vm.expectRevert();
        manager.unlock("");
        (, PoolKey memory unregistered) = _deployMarket(address(token), address(asset));
        vm.expectRevert();
        manager.initialize(unregistered, uint160(1 << 96));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        manager.donate(key, 1, 1, "");
        return "";
    }

    function testLiveDefaultPolicyAndPoolOverrideWithoutHookIteration() public {
        policy.setRate(10, 15);
        IStaticsSwapFeeHook.PoolFeeRate memory rate = hook.poolFeeRate(key.toId());
        assertEq(rate.inputFeeBps, 10);
        assertEq(rate.outputFeeBps, 15);
        assertFalse(rate.overridden);
        protocol.feeRate(hook, key.toId(), 20, 30);
        policy.setRate(5, 5);
        rate = hook.poolFeeRate(key.toId());
        assertEq(rate.inputFeeBps, 20);
        assertEq(rate.outputFeeBps, 30);
        _swap(true, -int256(0.1 ether));
    }

    function testBasketHookRuntimeHasEip170Headroom() public view {
        assertLt(address(hook).code.length, 24_576);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), MASK);
    }

    function _deployMarket(address first, address second)
        private
        returns (StaticsBasketHook deployed, PoolKey memory poolKey)
    {
        (Currency c0, Currency c1) = first < second
            ? (Currency.wrap(first), Currency.wrap(second))
            : (Currency.wrap(second), Currency.wrap(first));
        StaticsBasketHook.Binding memory binding = StaticsBasketHook.Binding(c0, c1, 3000, 10, address(this), 1);
        bytes memory args = abi.encode(manager, address(protocol), address(policy), binding);
        // Real CREATE2 deployment for the hook-only slice. Production CREATE3 is tested with the factory slice.
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), MASK, type(StaticsBasketHook).creationCode, args);
        deployed = new StaticsBasketHook{salt: salt}(
            manager, address(protocol), IStaticsSwapFeeHook(address(policy)), binding
        );
        assertEq(address(deployed), expected);
        poolKey = PoolKey(c0, c1, 3000, 10, IHooks(deployed));
        assertEq(PoolId.unwrap(deployed.boundPoolId()), PoolId.unwrap(poolKey.toId()));
        assertEq(deployed.boundCreator(), address(this));
    }

    function _params(int256 liquidity) private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), liquidity, bytes32(0));
    }

    function _liquidity(int256 liquidity) private returns (BalanceDelta) {
        return router.modifyLiquidity(key, _params(liquidity));
    }

    function _swap(bool direction, int256 specified) private returns (BalanceDelta) {
        return router.swap(
            key, SwapParams(direction, specified, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }
}
