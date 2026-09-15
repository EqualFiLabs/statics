// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IBlendBasket, IBlendHook, RobinhoodBlendBasketForkBase} from "../../basket/fork/RobinhoodBlendBasketFork.t.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";

interface IBlendSelfFundingBasket is IBlendBasket {
    function previewMint(uint256 shares)
        external
        view
        returns (address[] memory tokens, uint256[] memory required, uint256[] memory fees);
    function flashMint(uint256 shares, bytes calldata data) external;
    function stateChangeActive() external view returns (bool);
    function protocolFees(address token) external view returns (uint256);
}

interface IBlendSelfFundingCallback {
    function onFlashMint(
        uint256 shares,
        address[] calldata tokens,
        uint256[] calldata required,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}

/// @notice Test-only executor that finances Blend's stock settlement inside its flash-mint callback.
contract BlendStaticsSelfFundingFlashReceiver is IBlendSelfFundingCallback {
    using SafeERC20 for IERC20;

    error InvalidCallback();
    error InvalidRoute();
    error InsufficientMintInput(uint256 available, uint256 fee);
    error MinimumProfitNotMet(uint256 minimum, uint256 actual);

    IBlendSelfFundingBasket public immutable blendBasket;
    IStaticsBasket public immutable staticsBasket;
    CanonicalV4Router public immutable router;
    address public immutable usdg;
    uint256 public immutable basketId;
    address public immutable outerBasket;

    PoolKey private _blendPool;
    PoolKey private _staticsPool;
    bool private _active;
    uint256 private _activeShares;

    bool public observedTransientBlendState;
    uint256 public mintedOuterShares;

    constructor(
        IBlendSelfFundingBasket blendBasket_,
        IStaticsBasket staticsBasket_,
        CanonicalV4Router router_,
        address usdg_,
        uint256 basketId_,
        address outerBasket_,
        PoolKey memory blendPool_,
        PoolKey memory staticsPool_
    ) {
        blendBasket = blendBasket_;
        staticsBasket = staticsBasket_;
        router = router_;
        usdg = usdg_;
        basketId = basketId_;
        outerBasket = outerBasket_;
        _blendPool = blendPool_;
        _staticsPool = staticsPool_;
    }

    function execute(uint256 shares) external {
        if (_active || IERC20(usdg).balanceOf(address(this)) != 0) revert InvalidCallback();
        _active = true;
        _activeShares = shares;
        blendBasket.flashMint(shares, "");
        _active = false;
    }

    function onFlashMint(
        uint256 shares,
        address[] calldata tokens,
        uint256[] calldata required,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        if (
            msg.sender != address(blendBasket) || !_active || shares != _activeShares || data.length != 0
                || tokens.length != required.length || tokens.length != fees.length
        ) revert InvalidCallback();
        if (!blendBasket.stateChangeActive()) revert InvalidCallback();
        observedTransientBlendState = true;

        uint256 fixedMintFee = staticsBasket.quoteMint(basketId, 1)[0] - 1;
        if (shares <= fixedMintFee) revert InsufficientMintInput(shares, fixedMintFee);
        mintedOuterShares = shares - fixedMintFee;
        uint256[] memory mintQuote = staticsBasket.quoteMint(basketId, mintedOuterShares);
        IERC20(address(blendBasket)).forceApprove(address(staticsBasket), mintQuote[0]);
        staticsBasket.mint(basketId, mintedOuterShares, address(this), mintQuote);
        IERC20(address(blendBasket)).forceApprove(address(staticsBasket), 0);

        uint256 recoveredBlend = _swapExactInput(_staticsPool, outerBasket, address(blendBasket), mintedOuterShares);
        // The only live AI/USDG market at the pinned block uses BlendHook. Blend's
        // state-change lock rejects this nested sale while flashMint is active.
        _swapExactInput(_blendPool, address(blendBasket), usdg, recoveredBlend);
    }

    function _swapExactInput(PoolKey memory pool, address input, address output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne = _direction(pool, input, output);
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(address(router), amountIn);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        IERC20(input).forceApprove(address(router), 0);
        amountOut = IERC20(output).balanceOf(address(this)) - outputBefore;
    }

    function _direction(PoolKey memory pool, address input, address output) private pure returns (bool zeroForOne) {
        if (Currency.unwrap(pool.currency0) == input && Currency.unwrap(pool.currency1) == output) return true;
        if (Currency.unwrap(pool.currency1) == input && Currency.unwrap(pool.currency0) == output) return false;
        revert InvalidRoute();
    }
}

contract RobinhoodBlendSelfFundingFlashForkTest is RobinhoodBlendBasketForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant FLASH_SHARES = 0.25 ether;
    uint256 private constant DISTORTION_INPUT = 0.3 ether;

    CanonicalV4Router private router;

    function setUp() public override {
        super.setUp();
        router = new CanonicalV4Router(poolManager);
    }

    function testBlendFlashMintNestedSaleRevertsAndRollsBackBothProtocols() public {
        _makeOuterBasketExpensive();
        IBlendSelfFundingBasket blend = IBlendSelfFundingBasket(BLEND_AI);
        BlendStaticsSelfFundingFlashReceiver receiver = _receiver(blend);
        _assertReceiverStartsEmpty(blend, receiver);

        PoolKey memory blendPool = IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG);
        PoolKey memory outerPool = _outerBasketPool();
        bytes32 stateBefore = _rollbackStateHash(blendPool, outerPool);

        vm.expectRevert(_nestedBlendHookRevert());
        receiver.execute(FLASH_SHARES);

        assertFalse(blend.stateChangeActive());
        assertFalse(receiver.observedTransientBlendState());
        assertEq(receiver.mintedOuterShares(), 0);
        assertEq(_rollbackStateHash(blendPool, outerPool), stateBefore);
        _assertReceiverStartsEmpty(blend, receiver);
        _assertBlendBooksReconcile(blend);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), custody.globalReservedByToken(BLEND_AI));

        emit log("Blend flashMint lock rejects nested BlendHook sale and rolls back Statics atomically");
    }

    function _makeOuterBasketExpensive() private {
        PoolKey memory pool = _outerBasketPool();
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).approve(address(router), DISTORTION_INPUT));
        bool zeroForOne = Currency.unwrap(pool.currency0) == BLEND_AI;
        vm.prank(alice);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(DISTORTION_INPUT),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _receiver(IBlendSelfFundingBasket blend) private returns (BlendStaticsSelfFundingFlashReceiver receiver) {
        receiver = new BlendStaticsSelfFundingFlashReceiver(
            blend,
            baskets,
            router,
            USDG,
            staticsBasketId,
            staticsBasketToken,
            IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG),
            _outerBasketPool()
        );
    }

    function _assertReceiverStartsEmpty(IBlendSelfFundingBasket blend, BlendStaticsSelfFundingFlashReceiver receiver)
        private
        view
    {
        assertEq(IERC20(USDG).balanceOf(address(receiver)), 0);
        assertEq(blend.balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(receiver)), 0);
        address[] memory tokens = blend.constituents();
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(receiver)), 0);
        }
    }

    function _assertBlendBooksReconcile(IBlendSelfFundingBasket blend) private view {
        address[] memory tokens = blend.constituents();
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(BLEND_AI), blend.backing(tokens[i]) + blend.protocolFees(tokens[i]));
        }
    }

    function _outerBasketPool() private view returns (PoolKey memory pool) {
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        pool = PoolKey({
            currency0: Currency.wrap(canonical.currency0),
            currency1: Currency.wrap(canonical.currency1),
            fee: canonical.lpFee,
            tickSpacing: canonical.tickSpacing,
            hooks: staticsHook
        });
    }

    function _nestedBlendHookRevert() private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            BLEND_HOOK,
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _rollbackStateHash(PoolKey memory blendPool, PoolKey memory outerPool) private view returns (bytes32) {
        (uint160 blendPrice, int24 blendTick,,) = poolManager.getSlot0(blendPool.toId());
        (uint160 outerPrice, int24 outerTick,,) = poolManager.getSlot0(outerPool.toId());
        return keccak256(
            abi.encode(
                IERC20(staticsBasketToken).totalSupply(),
                IERC20(BLEND_AI).balanceOf(address(diamond)),
                custody.globalReservedByToken(BLEND_AI),
                globalRewards.treasuryAccrued(BLEND_AI),
                blendPrice,
                blendTick,
                outerPrice,
                outerTick
            )
        );
    }
}
