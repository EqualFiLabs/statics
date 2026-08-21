// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {Permit2SignatureHelpers} from "@uniswap/v4-periphery/test/shared/Permit2SignatureHelpers.sol";

interface IPositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function tokenDescriptor() external view returns (address);
    function WETH9() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniversalRouter {
    function poolManager() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract RobinhoodV4DeploymentForkTest is Test, LiquidityOperations, Permit2SignatureHelpers {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    uint24 private constant LP_FEE = 500;
    int24 private constant TICK_SPACING = 10;
    uint128 private constant INITIAL_LIQUIDITY = 100 ether;
    uint128 private constant ADDED_LIQUIDITY = 25 ether;
    uint160 private constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    bytes private constant EMPTY = "";
    bytes1 private constant PERMIT2_PERMIT_COMMAND = 0x0a;
    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    uint256 private constant SWAPPER_KEY = 0xA11CE;

    struct Deployment {
        uint256 chainId;
        uint256 forkBlock;
        address poolManager;
        address positionManager;
        address positionDescriptor;
        address quoter;
        address stateView;
        address reservesLens;
        address universalRouter;
        address permit2;
        address weth;
    }

    // Robinhood's verified Universal Router uses the later v4 single-hop
    // encoding that adds a per-hop minimum price after amountOutMinimum.
    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    Deployment private deployment;
    string private manifest;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
        deployment = _readDeployment(manifest);
        _selectFork();
        _deadline = block.timestamp + 1;
    }

    function test_deploymentCodeAndBindingsMatchManifest() public view {
        assertEq(block.chainid, deployment.chainId);
        assertEq(block.number, deployment.forkBlock);

        _assertCodeHash("poolManager", deployment.poolManager);
        _assertCodeHash("positionManager", deployment.positionManager);
        _assertCodeHash("positionDescriptor", deployment.positionDescriptor);
        _assertCodeHash("quoter", deployment.quoter);
        _assertCodeHash("stateView", deployment.stateView);
        _assertCodeHash("reservesLens", deployment.reservesLens);
        _assertCodeHash("universalRouter", deployment.universalRouter);
        _assertCodeHash("permit2", deployment.permit2);

        IPositionManagerBindings positionManager = IPositionManagerBindings(deployment.positionManager);
        assertEq(positionManager.poolManager(), deployment.poolManager);
        assertEq(positionManager.permit2(), deployment.permit2);
        assertEq(positionManager.tokenDescriptor(), deployment.positionDescriptor);
        assertEq(positionManager.WETH9(), deployment.weth);
        assertEq(address(IV4Quoter(deployment.quoter).poolManager()), deployment.poolManager);
        assertEq(address(IStateView(deployment.stateView).poolManager()), deployment.poolManager);
        assertEq(address(IPositionDescriptor(deployment.positionDescriptor).poolManager()), deployment.poolManager);
        assertEq(IPositionDescriptor(deployment.positionDescriptor).wrappedNative(), deployment.weth);
        assertEq(IUniversalRouter(deployment.universalRouter).poolManager(), deployment.poolManager);
    }

    struct LiveV4Flow {
        IPoolManager poolManager;
        IAllowanceTransfer permit2;
        PoolSwapTest directRouter;
        PoolKey key;
        PoolId poolId;
        PositionConfig position;
        uint256 tokenId;
    }

    function test_livePoolPositionQuoteRouterAndRemovalFlow() public {
        LiveV4Flow memory flow = _launchLivePool();

        BalanceDelta exactInput = _swap(flow.directRouter, flow.key, true, -int256(1 ether));
        BalanceDelta exactOutput = _swap(flow.directRouter, flow.key, false, int256(0.25 ether));
        assertLt(exactInput.amount0(), 0);
        assertGt(exactInput.amount1(), 0);
        assertEq(uint256(uint128(exactOutput.amount0())), 0.25 ether);

        _quoteAndVerifySlot0(flow);
        _swapThroughUniversalRouter(flow.key, flow.key.currency0, flow.key.currency1, flow.permit2);

        uint256 balance0Before = flow.key.currency0.balanceOfSelf();
        uint256 balance1Before = flow.key.currency1.balanceOfSelf();
        collect(flow.tokenId, flow.position, EMPTY);
        assertTrue(
            flow.key.currency0.balanceOfSelf() > balance0Before || flow.key.currency1.balanceOfSelf() > balance1Before,
            "live position earns no fees"
        );

        decreaseLiquidity(flow.tokenId, flow.position, INITIAL_LIQUIDITY + ADDED_LIQUIDITY, EMPTY);
        assertEq(lpm.getPositionLiquidity(flow.tokenId), 0);
        assertEq(flow.poolManager.balanceOf(deployment.positionManager, flow.key.currency0.toId()), 0);
        assertEq(flow.poolManager.balanceOf(deployment.positionManager, flow.key.currency1.toId()), 0);
    }

    function _launchLivePool() private returns (LiveV4Flow memory flow) {
        flow.poolManager = IPoolManager(deployment.poolManager);
        flow.permit2 = IAllowanceTransfer(deployment.permit2);
        lpm = IPositionManager(deployment.positionManager);

        flow.directRouter = new PoolSwapTest(flow.poolManager);
        MockERC20 tokenA = new MockERC20("Robinhood Fork A", "rhA", 18);
        MockERC20 tokenB = new MockERC20("Robinhood Fork B", "rhB", 18);
        tokenA.mint(address(this), 1_000_000 ether);
        tokenB.mint(address(this), 1_000_000 ether);

        (Currency currency0, Currency currency1) = SortTokens.sort(tokenA, tokenB);
        flow.key = PoolKey(currency0, currency1, LP_FEE, TICK_SPACING, IHooks(address(0)));
        flow.poolId = flow.key.toId();
        flow.poolManager.initialize(flow.key, SQRT_PRICE_1_1);

        _approve(flow.key.currency0, flow.directRouter, flow.permit2);
        _approve(flow.key.currency1, flow.directRouter, flow.permit2);

        flow.position = PositionConfig({
            poolKey: flow.key,
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING)
        });
        flow.tokenId = lpm.nextTokenId();
        mint(flow.position, INITIAL_LIQUIDITY, address(this), EMPTY);
        increaseLiquidity(flow.tokenId, flow.position, ADDED_LIQUIDITY, EMPTY);

        assertEq(lpm.getPositionLiquidity(flow.tokenId), INITIAL_LIQUIDITY + ADDED_LIQUIDITY);
        assertEq(IPositionManagerBindings(deployment.positionManager).ownerOf(flow.tokenId), address(this));
    }

    function _quoteAndVerifySlot0(LiveV4Flow memory flow) private {
        (uint256 quoteOut,) =
            IV4Quoter(deployment.quoter).quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: flow.key, zeroForOne: true, exactAmount: 0.1 ether, hookData: EMPTY
                })
            );
        assertGt(quoteOut, 0);

        (uint160 managerPrice,,,) = flow.poolManager.getSlot0(flow.poolId);
        (uint160 viewPrice,,, uint24 observedFee) = IStateView(deployment.stateView).getSlot0(flow.poolId);
        assertEq(viewPrice, managerPrice);
        assertEq(observedFee, LP_FEE);
    }

    function _selectFork() private {
        uint256 requestedBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", deployment.forkBlock);
        assertEq(requestedBlock, deployment.forkBlock, "fork block differs from manifest");

        if (block.chainid == deployment.chainId) {
            assertEq(block.number, deployment.forkBlock, "selected fork is not pinned");
            return;
        }

        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }

        vm.createSelectFork(rpcUrl, deployment.forkBlock);
        assertEq(block.chainid, deployment.chainId);
        assertEq(block.number, deployment.forkBlock);
    }

    function _readDeployment(string memory json) private pure returns (Deployment memory config) {
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.forkBlock = vm.parseJsonUint(json, ".forkBlock");
        config.poolManager = vm.parseJsonAddress(json, ".contracts.poolManager.address");
        config.positionManager = vm.parseJsonAddress(json, ".contracts.positionManager.address");
        config.positionDescriptor = vm.parseJsonAddress(json, ".contracts.positionDescriptor.address");
        config.quoter = vm.parseJsonAddress(json, ".contracts.quoter.address");
        config.stateView = vm.parseJsonAddress(json, ".contracts.stateView.address");
        config.reservesLens = vm.parseJsonAddress(json, ".contracts.reservesLens.address");
        config.universalRouter = vm.parseJsonAddress(json, ".contracts.universalRouter.address");
        config.permit2 = vm.parseJsonAddress(json, ".contracts.permit2.address");
        config.weth = vm.parseJsonAddress(json, ".contracts.weth.address");
    }

    function _assertCodeHash(string memory name, address target) private view {
        bytes32 expected = vm.parseJsonBytes32(manifest, string.concat(".contracts.", name, ".runtimeCodeHash"));
        assertTrue(target.code.length != 0, string.concat(name, " has no code"));
        assertEq(target.codehash, expected, string.concat(name, " code hash drift"));
    }

    function _approve(Currency currency, PoolSwapTest directRouter, IAllowanceTransfer permit2) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(directRouter), type(uint256).max);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, deployment.positionManager, type(uint160).max, type(uint48).max);
    }

    function _swap(PoolSwapTest directRouter, PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        private
        returns (BalanceDelta delta)
    {
        delta = directRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            EMPTY
        );
    }

    function _swapThroughUniversalRouter(
        PoolKey memory key,
        Currency currency0,
        Currency currency1,
        IAllowanceTransfer permit2
    ) private {
        uint128 amountIn = 0.1 ether;
        address swapper = vm.addr(SWAPPER_KEY);
        IERC20 inputToken = IERC20(Currency.unwrap(currency0));
        IERC20 outputToken = IERC20(Currency.unwrap(currency1));
        inputToken.transfer(swapper, amountIn);
        vm.prank(swapper);
        inputToken.approve(deployment.permit2, amountIn);

        (,, uint48 nonce) = permit2.allowance(swapper, address(inputToken), deployment.universalRouter);
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(inputToken),
                amount: amountIn,
                expiration: uint48(block.timestamp + 20 minutes),
                nonce: nonce
            }),
            spender: deployment.universalRouter,
            sigDeadline: block.timestamp + 20 minutes
        });
        bytes memory signature = getPermitSignature(permitSingle, SWAPPER_KEY, permit2.DOMAIN_SEPARATOR());

        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                RouterExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: true,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    minHopPriceX36: 0,
                    hookData: EMPTY
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(currency0, amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(currency1, 0));

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(permitSingle, signature);
        inputs[1] = plan.encode();
        uint256 outputBefore = outputToken.balanceOf(swapper);
        vm.prank(swapper);
        IUniversalRouter(deployment.universalRouter)
            .execute(abi.encodePacked(PERMIT2_PERMIT_COMMAND, V4_SWAP_COMMAND), inputs, block.timestamp + 1);
        assertGt(outputToken.balanceOf(swapper), outputBefore, "signed Universal Router swap produced no output");
        (uint160 remaining,, uint48 nextNonce) =
            permit2.allowance(swapper, address(inputToken), deployment.universalRouter);
        assertEq(remaining, 0);
        assertEq(nextNonce, nonce + 1);
    }
}
