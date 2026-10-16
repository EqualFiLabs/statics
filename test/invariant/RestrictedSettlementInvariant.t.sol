// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../../src/libraries/LibBasketLiquidity.sol";
import {LibBasketMarkets} from "../../src/libraries/LibBasketMarkets.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {LibRestrictedBasket} from "../../src/libraries/LibRestrictedBasket.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract InvariantRestrictedMarketProtocol is BasketSettlementFacet, RangeGaugeCallbackFacet {
    using PoolIdLibrary for PoolKey;

    address public constant weth = address(0xBEEF);
    uint16 private inputFee = 25;
    uint16 private outputFee = 25;
    mapping(address account => bool allowed) private distributors;

    constructor(IPoolManager manager) {
        LibGlobalRewards.rewardStorage().stakingToken = address(new MockERC20("Statics", "STATICS", 18));
        LibBasketLiquidity.LiquidityStorage storage liquidity = LibBasketLiquidity.liquidityStorage();
        liquidity.poolManager = address(manager);
        liquidity.hook = address(0xBAD);
        liquidity.integrationInstalled = true;
    }

    // These focused settlement harnesses model an already active basket.
    function basketStatus(uint256) external pure returns (uint8) {
        return 0;
    }

    function isBasketDistributor(address account) external view returns (bool) {
        return distributors[account];
    }

    function setDistributor(address account, bool allowed) external {
        distributors[account] = allowed;
    }

    function deployToken(IPoolManager manager, uint256 basketId) external returns (StaticsRestrictedBasketToken token) {
        token = new StaticsRestrictedBasketToken("Basket", "B", address(this), basketId, manager);
        LibRestrictedBasket.register(address(token), basketId);
        LibBasket.basketStorage().baskets[basketId].token = address(token);
        LibBasket.basketStorage().basketIds[address(token)] = basketId + 1;
    }

    function mint(StaticsRestrictedBasketToken token, address receiver, uint256 amount) external {
        token.mint(receiver, amount);
    }

    function register(PoolKey calldata key, address creator) external {
        LibBasketMarkets.register(key, creator, 0, address(1), 1);
        LibRangeGauge.initializePool(key.toId(), 0);
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

    function defaultFeeRate() external view returns (uint16, uint16) {
        return (inputFee, outputFee);
    }

    function setRate(IStaticsSwapFeeHook target, uint256 input, uint256 output) external {
        require(input + output <= 200);
        target.setDefaultFeeRate(uint16(input), uint16(output));
    }

    function basketFeeAllocation() external pure returns (IStaticsSwapFeeHook.BasketFeeAllocation memory) {
        return IStaticsSwapFeeHook.BasketFeeAllocation(1500, 3000, 3000, 2000);
    }

    function generalFeeAllocation() external pure returns (IStaticsSwapFeeHook.GeneralFeeAllocation memory) {
        return IStaticsSwapFeeHook.GeneralFeeAllocation(4000, 3500, 2000);
    }

    function harvest(IStaticsSwapFeeHook hook, PoolKey calldata key) external {
        hook.settleFeeDistribution(key, key.currency0, address(this));
        hook.settleFeeDistribution(key, key.currency1, address(this));
    }
}

contract RestrictedInvariantDistributor {
    function pull(IERC20 token, address owner, uint256 amount) external {
        token.transferFrom(owner, address(this), amount);
    }

    function push(IERC20 token, address receiver, uint256 amount) external {
        token.transfer(receiver, amount);
    }
}

contract RestrictedSettlementInvariantHandler is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager private immutable manager;
    InvariantRestrictedMarketProtocol private immutable protocol;
    CanonicalV4Router private immutable router;
    RestrictedInvariantDistributor private immutable distributor;
    StaticsRestrictedBasketToken[] private tokens;
    StaticsBasketHook[] private hooks;
    PoolKey[] private keys;

    uint256 public unauthorizedTransfers;
    uint256 public unexpectedFailures;
    uint256 public successfulSwaps;
    uint256 public successfulLiquidityAdds;
    uint256 public successfulLiquidityRemoves;
    uint256 public successfulSettlements;
    uint256 public successfulDistributorOutboundTransfers;
    uint256 public successfulDistributorInboundTransfers;
    uint256 public expectedUnauthorizedRejections;

    constructor(
        IPoolManager manager_,
        InvariantRestrictedMarketProtocol protocol_,
        CanonicalV4Router router_,
        StaticsRestrictedBasketToken[] memory tokens_,
        StaticsBasketHook[] memory hooks_,
        PoolKey[] memory keys_
    ) {
        manager = manager_;
        protocol = protocol_;
        router = router_;
        distributor = new RestrictedInvariantDistributor();
        for (uint256 i; i < tokens_.length; ++i) {
            tokens.push(tokens_[i]);
            tokens_[i].approve(address(router_), type(uint256).max);
            tokens_[i].approve(address(distributor), type(uint256).max);
        }
        for (uint256 i; i < hooks_.length; ++i) {
            hooks.push(hooks_[i]);
        }
        for (uint256 i; i < keys_.length; ++i) {
            keys.push(keys_[i]);
        }
    }

    function swap(uint256 rawPool, uint256 rawAmount, bool zeroForOne, bool exactOutput) public {
        PoolKey memory key = keys[rawPool % keys.length];
        uint256 amount = bound(rawAmount, 1e8, exactOutput ? 1e10 : 1e11);
        int256 specified = exactOutput ? int256(amount) : -int256(amount);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 firstBefore = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 secondBefore = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        try router.swap(key, SwapParams(zeroForOne, specified, limit)) {
            if (
                firstBefore == IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this))
                    && secondBefore == IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this))
            ) {
                ++unexpectedFailures;
            } else {
                ++successfulSwaps;
            }
        } catch {
            ++unexpectedFailures;
        }
    }

    function churnLiquidity(uint256 rawPool, uint256 rawAmount, bool removeFirst) public {
        PoolKey memory key = keys[rawPool % keys.length];
        uint256 amount = bound(rawAmount, 1e8, 1e12);
        if (removeFirst) {
            _modifyLiquidity(key, -int256(amount), false);
            _modifyLiquidity(key, int256(amount), true);
        } else {
            _modifyLiquidity(key, int256(amount), true);
            _modifyLiquidity(key, -int256(amount), false);
        }
    }

    function _modifyLiquidity(PoolKey memory key, int256 liquidity, bool adding) private {
        try router.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), liquidity, bytes32(0)
            )
        ) {
            if (adding) ++successfulLiquidityAdds;
            else ++successfulLiquidityRemoves;
        } catch {
            ++unexpectedFailures;
        }
    }

    function settleOneHook(uint256 rawPool) public {
        uint256 selected = rawPool % hooks.length;
        try protocol.harvest(IStaticsSwapFeeHook(address(hooks[selected])), keys[selected]) {
            ++successfulSettlements;
        } catch {
            ++unexpectedFailures;
        }
    }

    function setPolicy(uint256 rawInput, uint256 rawOutput) public {
        uint256 input = bound(rawInput, 1, 100);
        uint256 output = bound(rawOutput, 1, 200 - input);
        protocol.setRate(IStaticsSwapFeeHook(address(hooks[0])), input, output);
    }

    function distributorTransfer(uint256 rawToken, uint256 rawAmount, bool approveSender, bool approveReceiver) public {
        StaticsRestrictedBasketToken token = tokens[rawToken % tokens.length];
        uint256 amount = bound(rawAmount, 1, 1e15);
        if (!approveSender && !approveReceiver) approveSender = true;
        protocol.setDistributor(address(this), approveSender);
        protocol.setDistributor(address(distributor), approveReceiver);
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(address(distributor));
        try token.transfer(address(distributor), amount) returns (bool moved) {
            if (
                !moved || token.balanceOf(address(this)) != senderBefore - amount
                    || token.balanceOf(address(distributor)) != receiverBefore + amount
            ) {
                ++unexpectedFailures;
                return;
            }
            ++successfulDistributorOutboundTransfers;
            try distributor.push(token, address(this), amount) {
                if (
                    token.balanceOf(address(this)) != senderBefore
                        || token.balanceOf(address(distributor)) != receiverBefore
                ) ++unexpectedFailures;
                else ++successfulDistributorInboundTransfers;
            } catch {
                ++unexpectedFailures;
            }
        } catch {
            ++unexpectedFailures;
        }
    }

    function spenderOnlyCannotTransfer(uint256 rawToken, uint256 rawAmount) public {
        StaticsRestrictedBasketToken token = tokens[rawToken % tokens.length];
        uint256 amount = bound(rawAmount, 1, 1e15);
        protocol.setDistributor(address(this), false);
        protocol.setDistributor(address(distributor), false);
        try distributor.pull(token, address(this), amount) {
            ++unauthorizedTransfers;
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == StaticsRestrictedBasketToken.TransferNotAuthorized.selector) {
                ++expectedUnauthorizedRejections;
            } else {
                ++unexpectedFailures;
            }
        }
    }

    /// @dev Every stateful step reaches each meaningful operation; random selector choice cannot make coverage vacuous.
    function exercise(uint256 seed) external {
        swap(seed, uint256(keccak256(abi.encode(seed, uint256(1)))), seed & 1 == 0, seed & 2 == 0);
        churnLiquidity(seed >> 8, uint256(keccak256(abi.encode(seed, uint256(2)))), seed & 4 == 0);
        settleOneHook(seed >> 16);
        setPolicy(seed >> 24, seed >> 32);
        distributorTransfer(seed >> 40, uint256(keccak256(abi.encode(seed, uint256(3)))), seed & 8 == 0, seed & 16 == 0);
        spenderOnlyCannotTransfer(seed >> 48, uint256(keccak256(abi.encode(seed, uint256(4)))));
    }

    function tokenAt(uint256 index) external view returns (StaticsRestrictedBasketToken) {
        return tokens[index];
    }

    function hookAt(uint256 index) external view returns (StaticsBasketHook) {
        return hooks[index];
    }

    function keyAt(uint256 index) external view returns (PoolKey memory) {
        return keys[index];
    }

    function poolCount() external view returns (uint256) {
        return keys.length;
    }
}

/// @notice Random interleavings use the real v4 PoolManager, immutable hooks and restricted tokens.
contract RestrictedSettlementInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    uint160 private constant MASK = 0x1fec;
    IPoolManager private manager;
    InvariantRestrictedMarketProtocol private protocol;
    CanonicalV4Router private router;
    RestrictedSettlementInvariantHandler private handler;

    function setUp() public {
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        protocol = new InvariantRestrictedMarketProtocol(manager);
        router = new CanonicalV4Router(manager);
        StaticsRestrictedBasketToken[] memory tokens = new StaticsRestrictedBasketToken[](2);
        tokens[0] = protocol.deployToken(manager, 0);
        tokens[1] = protocol.deployToken(manager, 1);
        StaticsBasketHook[] memory hooks = new StaticsBasketHook[](1);
        PoolKey[] memory keys = new PoolKey[](1);
        (hooks[0], keys[0]) = _deployMarket(address(tokens[0]), address(tokens[1]));
        for (uint256 i; i < keys.length; ++i) {
            protocol.register(keys[i], address(this));
            vm.prank(address(protocol));
            manager.initialize(keys[i], uint160(1 << 96));
        }
        for (uint256 i; i < tokens.length; ++i) {
            protocol.mint(tokens[i], address(this), 1_000_000 ether);
            tokens[i].approve(address(router), type(uint256).max);
        }
        for (uint256 i; i < keys.length; ++i) {
            router.modifyLiquidity(
                keys[i],
                ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 10 ether, bytes32(0))
            );
        }
        handler = new RestrictedSettlementInvariantHandler(manager, protocol, router, tokens, hooks, keys);
        for (uint256 i; i < tokens.length; ++i) {
            protocol.mint(tokens[i], address(handler), 1_000_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.exercise.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantPoolBudgetsNeverEscapeAnAction() public view {
        for (uint256 i; i < 2; ++i) {
            (uint256 inbound, uint256 outbound) = handler.tokenAt(i).settlementBudgets();
            assertEq(inbound + outbound, 0);
        }
    }

    function invariantPoolManagerClaimsCoverEachHookLiability() public view {
        for (uint256 i; i < handler.poolCount(); ++i) {
            StaticsBasketHook hook = handler.hookAt(i);
            PoolKey memory key = handler.keyAt(i);
            _assertLiability(hook, key.currency0);
            _assertLiability(hook, key.currency1);
            assertTrue(hook.poolRegistration(key.toId()).registered);
        }
    }

    function invariantDistributorAuthorityHolds() public view {
        assertEq(handler.unauthorizedTransfers(), 0);
        assertEq(handler.unexpectedFailures(), 0);
    }

    function afterInvariant() public view {
        assertGt(handler.successfulSwaps(), 0);
        assertGt(handler.successfulLiquidityAdds(), 0);
        assertGt(handler.successfulLiquidityRemoves(), 0);
        assertGt(handler.successfulSettlements(), 0);
        assertGt(handler.successfulDistributorOutboundTransfers(), 0);
        assertGt(handler.successfulDistributorInboundTransfers(), 0);
        assertGt(handler.expectedUnauthorizedRejections(), 0);
    }

    function _assertLiability(StaticsBasketHook hook, Currency currency) private view {
        uint256 liability = hook.claimLiability(currency);
        uint256 claims = manager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(currency))));
        assertEq(claims, liability);
    }

    function _deployMarket(address first, address second)
        private
        returns (StaticsBasketHook deployed, PoolKey memory key)
    {
        (Currency c0, Currency c1) = first < second
            ? (Currency.wrap(first), Currency.wrap(second))
            : (Currency.wrap(second), Currency.wrap(first));
        bytes memory args = abi.encode(manager, address(protocol), uint16(25), uint16(25), address(0xBEEF));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), MASK, type(StaticsBasketHook).creationCode, args);
        deployed =
            new StaticsBasketHook{salt: salt}(manager, address(protocol), uint16(25), uint16(25), address(0xBEEF));
        assertEq(address(deployed), expected);
        key = PoolKey(c0, c1, 3000, 10, IHooks(deployed));
        vm.prank(address(protocol));
        deployed.registerPool(key, StaticsBasketHook.PoolKind.BasketCanonical, address(this));
    }
}
