// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {Permit2SignatureHelpers} from "@uniswap/v4-periphery/test/shared/Permit2SignatureHelpers.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IBlendHook, RobinhoodBlendBasketForkBase} from "../../basket/fork/RobinhoodBlendBasketFork.t.sol";

interface IBlendStaticsUniversalRouter {
    function poolManager() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Atomic multi-hop proof across the live BlendHook and a fork-deployed Statics hook.
///
/// Forward: USDG -> live Blend AI -> Statics Blend AI (sBAI)
/// Reverse: sBAI -> live Blend AI -> USDG
///
/// Both hops execute in one Universal Router v4 plan against the shared deployed PoolManager.
contract RobinhoodBlendCrossHookForkTest is RobinhoodBlendBasketForkBase, Permit2SignatureHelpers {
    using Planner for Plan;

    bytes1 private constant PERMIT2_PERMIT_COMMAND = 0x0a;
    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    uint256 private constant SWAPPER_KEY = 0x788c3e49a761183d9fbf6c994e1e270031bc288744885f66e3cf25b99d17cfd7;
    uint128 private constant FORWARD_USDG_INPUT = 1_000_000;
    uint128 private constant EXACT_OUTPUT_SHARES = 0.001 ether;

    IV4Quoter private quoter;
    IBlendStaticsUniversalRouter private universalRouter;

    struct StaticsPoolAccounting {
        uint128 lockedLiquidity;
    }

    struct ExactInputRequest {
        address swapper;
        uint256 swapperKey;
        address input;
        address output;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOut;
    }

    struct ExactOutputRequest {
        address swapper;
        uint256 swapperKey;
        address input;
        address output;
        PathKey[] path;
        uint128 amountOut;
        uint128 amountIn;
    }

    function setUp() public override {
        super.setUp();
        string memory manifest = vm.readFile(CHAIN_MANIFEST);
        quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        universalRouter =
            IBlendStaticsUniversalRouter(vm.parseJsonAddress(manifest, ".contracts.universalRouter.address"));

        assertEq(address(quoter.poolManager()), address(poolManager));
        assertEq(universalRouter.poolManager(), address(poolManager));
    }

    function testAtomicExactInputRoundTripTraversesBothHooks() public {
        address swapper = vm.addr(SWAPPER_KEY);
        PathKey[] memory forward = _crossHookPath(true);
        _assertCrossHookPath(forward, true);

        _fundFromLiveHolder(USDG, swapper, FORWARD_USDG_INPUT);
        StaticsPoolAccounting memory beforeForward = _takeStaticsPoolAccounting();
        (uint256 quotedShares, uint256 forwardQuoteGas) = quoter.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(USDG), path: forward, exactAmount: FORWARD_USDG_INPUT
            })
        );
        assertGt(quotedShares, 0);
        uint256 forwardExecutionGas = _executeExactInput(
            ExactInputRequest({
                swapper: swapper,
                swapperKey: SWAPPER_KEY,
                input: USDG,
                output: staticsBasketToken,
                path: forward,
                amountIn: FORWARD_USDG_INPUT,
                amountOut: uint128(quotedShares)
            })
        );
        _assertStaticsPoolAccountingAdvanced(beforeForward);

        PathKey[] memory reverse = _crossHookPath(false);
        _assertCrossHookPath(reverse, false);
        StaticsPoolAccounting memory beforeReverse = _takeStaticsPoolAccounting();
        (uint256 quotedUsdg, uint256 reverseQuoteGas) = quoter.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(staticsBasketToken), path: reverse, exactAmount: uint128(quotedShares)
            })
        );
        assertGt(quotedUsdg, 0);
        uint256 reverseExecutionGas = _executeExactInput(
            ExactInputRequest({
                swapper: swapper,
                swapperKey: SWAPPER_KEY,
                input: staticsBasketToken,
                output: USDG,
                path: reverse,
                amountIn: uint128(quotedShares),
                amountOut: uint128(quotedUsdg)
            })
        );
        _assertStaticsPoolAccountingAdvanced(beforeReverse);

        assertEq(IERC20(BLEND_AI).balanceOf(swapper), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(swapper), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(address(universalRouter)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(universalRouter)), 0);

        emit log("Atomic exact-input route: USDG -> BlendHook AI -> StaticsHook sBAI -> AI -> USDG");
        emit log_named_uint("Forward quote gas", forwardQuoteGas);
        emit log_named_uint("Forward execution gas", forwardExecutionGas);
        emit log_named_uint("Reverse quote gas", reverseQuoteGas);
        emit log_named_uint("Reverse execution gas", reverseExecutionGas);
        emit log_named_uint("Round-trip USDG output", quotedUsdg);
    }

    function testAtomicExactOutputRouteTraversesBothHooks() public {
        address swapper = vm.addr(SWAPPER_KEY);
        PathKey[] memory path = _crossHookExactOutputPath();
        _assertExactOutputCrossHookPath(path);

        (uint256 quotedUsdg, uint256 quoteGas) = quoter.quoteExactOutput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: Currency.wrap(staticsBasketToken), path: path, exactAmount: EXACT_OUTPUT_SHARES
            })
        );
        assertGt(quotedUsdg, 0);
        assertLe(quotedUsdg, type(uint128).max);
        _fundFromLiveHolder(USDG, swapper, quotedUsdg);

        StaticsPoolAccounting memory beforeAction = _takeStaticsPoolAccounting();
        uint256 executionGas = _executeExactOutput(
            ExactOutputRequest({
                swapper: swapper,
                swapperKey: SWAPPER_KEY,
                input: USDG,
                output: staticsBasketToken,
                path: path,
                amountOut: EXACT_OUTPUT_SHARES,
                amountIn: uint128(quotedUsdg)
            })
        );
        _assertStaticsPoolAccountingAdvanced(beforeAction);

        assertEq(IERC20(staticsBasketToken).balanceOf(swapper), EXACT_OUTPUT_SHARES);
        assertEq(IERC20(USDG).balanceOf(swapper), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(swapper), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(address(universalRouter)), 0);

        emit log("Atomic exact-output route: exact sBAI through BlendHook and StaticsHook");
        emit log_named_uint("Exact-output USDG input", quotedUsdg);
        emit log_named_uint("Exact-output quote gas", quoteGas);
        emit log_named_uint("Exact-output execution gas", executionGas);
    }

    function _executeExactInput(ExactInputRequest memory request) private returns (uint256 executionGas) {
        _approvePermit2(request.swapper, request.input, request.amountIn);
        (bytes[] memory inputs, uint48 nonce) = _exactInputRouterCall(request);
        uint256 inputBefore = IERC20(request.input).balanceOf(request.swapper);
        uint256 outputBefore = IERC20(request.output).balanceOf(request.swapper);
        executionGas = _executeRouterCall(request.swapper, inputs);

        assertEq(inputBefore - IERC20(request.input).balanceOf(request.swapper), request.amountIn);
        assertEq(IERC20(request.output).balanceOf(request.swapper) - outputBefore, request.amountOut);
        _assertPermitConsumed(request.swapper, request.input, nonce);
    }

    function _exactInputRouterCall(ExactInputRequest memory request)
        private
        view
        returns (bytes[] memory inputs, uint48 nonce)
    {
        bytes memory encodedPermit;
        (encodedPermit, nonce) = _buildPermit(request.swapper, request.swapperKey, request.input, request.amountIn);
        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_IN,
            abi.encode(
                IV4Router.ExactInputParams({
                    currencyIn: Currency.wrap(request.input),
                    path: request.path,
                    maxHopSlippage: new uint256[](0),
                    amountIn: request.amountIn,
                    amountOutMinimum: request.amountOut
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(request.input), request.amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(request.output), request.amountOut));

        inputs = new bytes[](2);
        inputs[0] = encodedPermit;
        inputs[1] = plan.encode();
    }

    function _executeExactOutput(ExactOutputRequest memory request) private returns (uint256 executionGas) {
        _approvePermit2(request.swapper, request.input, request.amountIn);
        (bytes[] memory inputs, uint48 nonce) = _exactOutputRouterCall(request);
        uint256 inputBefore = IERC20(request.input).balanceOf(request.swapper);
        uint256 outputBefore = IERC20(request.output).balanceOf(request.swapper);
        executionGas = _executeRouterCall(request.swapper, inputs);

        assertEq(inputBefore - IERC20(request.input).balanceOf(request.swapper), request.amountIn);
        assertEq(IERC20(request.output).balanceOf(request.swapper) - outputBefore, request.amountOut);
        _assertPermitConsumed(request.swapper, request.input, nonce);
    }

    function _exactOutputRouterCall(ExactOutputRequest memory request)
        private
        view
        returns (bytes[] memory inputs, uint48 nonce)
    {
        bytes memory encodedPermit;
        (encodedPermit, nonce) = _buildPermit(request.swapper, request.swapperKey, request.input, request.amountIn);
        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_OUT,
            abi.encode(
                IV4Router.ExactOutputParams({
                    currencyOut: Currency.wrap(request.output),
                    path: request.path,
                    maxHopSlippage: new uint256[](0),
                    amountOut: request.amountOut,
                    amountInMaximum: request.amountIn
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(request.input), request.amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(request.output), request.amountOut));

        inputs = new bytes[](2);
        inputs[0] = encodedPermit;
        inputs[1] = plan.encode();
    }

    function _executeRouterCall(address swapper, bytes[] memory inputs) private returns (uint256 executionGas) {
        vm.prank(swapper);
        universalRouter.execute(
            abi.encodePacked(PERMIT2_PERMIT_COMMAND, V4_SWAP_COMMAND), inputs, block.timestamp + 1 minutes
        );
        executionGas = vm.lastFrameGas().gasTotalUsed;
    }

    function _crossHookPath(bool forward) private view returns (PathKey[] memory path) {
        PoolKey memory blendPool = IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG);
        IStaticsBasketLiquidity.CanonicalPoolView memory staticsPool =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        path = new PathKey[](2);
        if (forward) {
            path[0] = PathKey({
                intermediateCurrency: Currency.wrap(BLEND_AI),
                fee: blendPool.fee,
                tickSpacing: blendPool.tickSpacing,
                hooks: blendPool.hooks,
                hookData: ""
            });
            path[1] = PathKey({
                intermediateCurrency: Currency.wrap(staticsBasketToken),
                fee: staticsPool.lpFee,
                tickSpacing: staticsPool.tickSpacing,
                hooks: IHooks(staticsPool.hook),
                hookData: ""
            });
        } else {
            path[0] = PathKey({
                intermediateCurrency: Currency.wrap(BLEND_AI),
                fee: staticsPool.lpFee,
                tickSpacing: staticsPool.tickSpacing,
                hooks: IHooks(staticsPool.hook),
                hookData: ""
            });
            path[1] = PathKey({
                intermediateCurrency: Currency.wrap(USDG),
                fee: blendPool.fee,
                tickSpacing: blendPool.tickSpacing,
                hooks: blendPool.hooks,
                hookData: ""
            });
        }
    }

    function _crossHookExactOutputPath() private view returns (PathKey[] memory path) {
        PoolKey memory blendPool = IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG);
        IStaticsBasketLiquidity.CanonicalPoolView memory staticsPool =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(USDG),
            fee: blendPool.fee,
            tickSpacing: blendPool.tickSpacing,
            hooks: blendPool.hooks,
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(BLEND_AI),
            fee: staticsPool.lpFee,
            tickSpacing: staticsPool.tickSpacing,
            hooks: IHooks(staticsPool.hook),
            hookData: ""
        });
    }

    function _assertCrossHookPath(PathKey[] memory path, bool forward) private view {
        assertEq(path.length, 2);
        assertEq(address(path[forward ? 0 : 1].hooks), BLEND_HOOK);
        assertEq(address(path[forward ? 1 : 0].hooks), address(staticsHook));
        assertNotEq(address(path[0].hooks), address(path[1].hooks));
        assertEq(Currency.unwrap(path[0].intermediateCurrency), BLEND_AI);
        assertEq(Currency.unwrap(path[1].intermediateCurrency), forward ? staticsBasketToken : USDG);
    }

    function _assertExactOutputCrossHookPath(PathKey[] memory path) private view {
        assertEq(path.length, 2);
        assertEq(address(path[0].hooks), BLEND_HOOK);
        assertEq(address(path[1].hooks), address(staticsHook));
        assertEq(Currency.unwrap(path[0].intermediateCurrency), USDG);
        assertEq(Currency.unwrap(path[1].intermediateCurrency), BLEND_AI);
    }

    function _fundFromLiveHolder(address token, address receiver, uint256 amount) private {
        assertGe(IERC20(token).balanceOf(BLEND_AI_HOLDER), amount);
        vm.prank(BLEND_AI_HOLDER);
        assertTrue(IERC20(token).transfer(receiver, amount));
        assertEq(IERC20(token).balanceOf(receiver), amount);
    }

    function _approvePermit2(address swapper, address token, uint160 amount) private {
        vm.prank(swapper);
        assertTrue(IERC20(token).approve(address(permit2), amount));
    }

    function _buildPermit(address swapper, uint256 swapperKey, address token, uint160 amount)
        private
        view
        returns (bytes memory encodedPermit, uint48 nonce)
    {
        (,, nonce) = permit2.allowance(swapper, token, address(universalRouter));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token, amount: amount, expiration: uint48(block.timestamp + 20 minutes), nonce: nonce
            }),
            spender: address(universalRouter),
            sigDeadline: block.timestamp + 20 minutes
        });
        bytes memory signature = getPermitSignature(permitSingle, swapperKey, permit2.DOMAIN_SEPARATOR());
        encodedPermit = abi.encode(permitSingle, signature);
    }

    function _assertPermitConsumed(address swapper, address token, uint48 spentNonce) private view {
        (uint160 remaining,, uint48 nextNonce) = permit2.allowance(swapper, token, address(universalRouter));
        assertEq(remaining, 0);
        assertEq(nextNonce, spentNonce + 1);
    }

    function _takeStaticsPoolAccounting() private view returns (StaticsPoolAccounting memory snapshot) {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        snapshot.lockedLiquidity = staticsHook.lockedLiquidity(configured.poolId);
    }

    function _assertStaticsPoolAccountingAdvanced(StaticsPoolAccounting memory beforeAction) private view {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        assertGt(staticsHook.lockedLiquidity(configured.poolId), beforeAction.lockedLiquidity);
        assertGt(_pendingDistributionTotal(configured.poolId, configured.currency0, configured.currency1), 0);
        _assertHookClaimsReconcile(Currency.wrap(configured.currency0));
        _assertHookClaimsReconcile(Currency.wrap(configured.currency1));
    }

    function _assertHookClaimsReconcile(Currency currency) private view {
        assertEq(poolManager.balanceOf(address(staticsHook), currency.toId()), staticsHook.claimLiability(currency));
    }

    function _pendingDistributionTotal(PoolId poolId, address first, address second)
        private
        view
        returns (uint256 total)
    {
        IStaticsSwapFeeHook.FeeDistribution memory firstDistribution =
            staticsHook.pendingFeeDistribution(poolId, Currency.wrap(first));
        IStaticsSwapFeeHook.FeeDistribution memory secondDistribution =
            staticsHook.pendingFeeDistribution(poolId, Currency.wrap(second));
        total = _distributionTotal(firstDistribution) + _distributionTotal(secondDistribution);
    }

    function _distributionTotal(IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
        pure
        returns (uint256)
    {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }
}
