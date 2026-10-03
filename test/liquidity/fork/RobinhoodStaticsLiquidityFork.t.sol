// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Permit2SignatureHelpers} from "@uniswap/v4-periphery/test/shared/Permit2SignatureHelpers.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketRewards} from "../../../src/interfaces/IStaticsBasketRewards.sol";
import {IStaticsBorrowLiquidity} from "../../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsProtocolPools} from "../../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsLiquidityManager} from "../../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";
import {StaticsTestBase} from "../../helpers/StaticsTestBase.sol";

interface IRobinhoodUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract RobinhoodStaticsLiquidityForkTest is StaticsTestBase, Permit2SignatureHelpers {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    bytes1 private constant PERMIT2_PERMIT_COMMAND = 0x0a;
    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    uint256 private constant FIRST_SWAPPER_KEY = 0x9045a44c309ea7e3e550ff4bf446b647ba985910dfce59f24c2fb8639480e659;
    uint256 private constant SECOND_SWAPPER_KEY = 0xc16276e2c1fcc6f2443e8e16b32aee83b00e6bb96d5bc34f647c71f41d31b274;

    // Robinhood's deployed Universal Router uses the later v4 single-hop
    // encoding that includes a per-hop minimum price after amountOutMinimum.
    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2Contract;
    IV4Quoter private quoter;
    IRobinhoodUniversalRouter private universalRouter;
    StaticsSwapFeeHook private hook;
    StaticsLiquidityManager private manager;

    event SwapGasMeasured(string venue, uint256 gasUsed);

    function setUp() public override {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        _selectFork(manifest);
        super.setUp();

        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2Contract = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        universalRouter = IRobinhoodUniversalRouter(vm.parseJsonAddress(manifest, ".contracts.universalRouter.address"));
        hook = _deployHook();
        manager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(address(manager));
        IStaticsProtocolPools(address(diamond))
            .setProtocolPoolMaintenanceConfig(IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({revenueTipBps: 500}));
    }

    function testCompletedStaticsLiquidityLifecycleUsesRobinhoodV4() public {
        (uint256 basketId, address basketToken, uint256 positionId) = _createFundedBasket();
        uint256 userTokenId = _provideCanonicalLiquidity(positionId, basketId);
        assertEq(IERC721(address(positionManager)).ownerOf(userTokenId), alice);

        vm.warp(block.timestamp + 25 hours);
        _swapCanonical(basketId, basketToken);
        vm.warp(block.timestamp + 31 minutes);
        _swapCanonical(basketId, basketToken);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(canonical.poolId, basketToken);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(canonical.poolId, address(assetA));
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolPol(canonical.poolId, basketToken, 0);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolPol(canonical.poolId, address(assetA), 0);
        IStaticsBasketRewards basketRewards = IStaticsBasketRewards(address(diamond));
        (, uint256[] memory pendingBasketRewards) = basketRewards.getBasketRewards(positionId, basketId);
        assertGt(pendingBasketRewards[0] + pendingBasketRewards[1], 0);
        vm.prank(alice);
        basketRewards.claimBasketRewards(positionId, basketId, alice);

        assertGt(IStaticsProtocolPools(address(diamond)).protocolPool(canonical.poolId).activePolPositions, 0);

        governance.decommissionBasket(basketId);
        uint256[] memory polPositions = IStaticsProtocolPools(address(diamond)).protocolPolPositionIds(canonical.poolId);
        IStaticsProtocolPools(address(diamond))
            .closeProtocolPolPosition(polPositions[0], 0, 0, block.timestamp + 1 days);
        basketLiquidity.unwindBasketLiquidity(basketId, address(assetA));
        assertTrue(basketLiquidity.basketLiquidityUnwound(basketId, address(assetA)));
        assertEq(IStaticsProtocolPools(address(diamond)).protocolPool(canonical.poolId).activePolPositions, 0);
        assertEq(IERC721(address(positionManager)).ownerOf(userTokenId), alice);
    }

    function testUniversalRouterQuotesAndSwapsCanonicalHookedPool() public {
        (uint256 basketId, address basketToken, uint256 positionId) = _createFundedBasket();
        _provideCanonicalLiquidity(positionId, basketId);

        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory key = _poolKey(configured);
        PoolId poolId = key.toId();
        bool basketIsCurrency0 = configured.currency0 == basketToken;

        uint256[] memory mintQuote = baskets.quoteMint(basketId, 1 ether);
        assetA.mint(alice, mintQuote[0] + 1 ether);
        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, mintQuote);

        uint256 basketTreasuryBefore = globalRewards.treasuryAccrued(basketToken);
        uint256 assetTreasuryBefore = globalRewards.treasuryAccrued(address(assetA));

        _quoteAndSwapThroughUniversalRouter(
            key, basketToken, address(assetA), basketIsCurrency0, FIRST_SWAPPER_KEY, 0.01 ether
        );
        vm.warp(block.timestamp + 31 minutes);
        _quoteAndSwapThroughUniversalRouter(
            key, address(assetA), basketToken, !basketIsCurrency0, SECOND_SWAPPER_KEY, 0.01 ether
        );

        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(poolId, basketToken);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(poolId, address(assetA));
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolPol(poolId, basketToken, 0);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolPol(poolId, address(assetA), 0);

        assertGt(globalRewards.treasuryAccrued(basketToken), basketTreasuryBefore);
        assertGt(globalRewards.treasuryAccrued(address(assetA)), assetTreasuryBefore);
        assertGt(IStaticsProtocolPools(address(diamond)).protocolPool(poolId).activePolPositions, 0);
    }

    function testGasCompareStaticsHookWithVanillaRobinhoodV4() public {
        (uint256 basketId, address basketToken, uint256 positionId) = _createFundedBasket();
        _provideCanonicalLiquidity(positionId, basketId);

        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory staticsKey = _poolKey(configured);
        PoolKey memory vanillaKey = PoolKey({
            currency0: staticsKey.currency0,
            currency1: staticsKey.currency1,
            fee: staticsKey.fee,
            tickSpacing: staticsKey.tickSpacing,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(vanillaKey, SQRT_PRICE_1_1);

        uint256[] memory quote = baskets.quoteMint(basketId, 20 ether);
        assetA.mint(alice, quote[0] + 20 ether);
        vm.prank(alice);
        baskets.mint(basketId, 20 ether, alice, quote);

        CanonicalV4Router vanillaRouter = new CanonicalV4Router(poolManager);
        CanonicalV4Router staticsRouter = new CanonicalV4Router(poolManager);
        vm.startPrank(alice);
        IERC20(basketToken).approve(address(vanillaRouter), type(uint256).max);
        IERC20(address(assetA)).approve(address(vanillaRouter), type(uint256).max);
        IERC20(basketToken).approve(address(staticsRouter), type(uint256).max);
        IERC20(address(assetA)).approve(address(staticsRouter), type(uint256).max);
        vanillaRouter.modifyLiquidity(
            vanillaKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(vanillaKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(vanillaKey.tickSpacing),
                liquidityDelta: int256(5 ether),
                salt: keccak256("robinhood-vanilla-gas")
            })
        );
        vm.stopPrank();

        bool zeroForOne = configured.currency0 == basketToken;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(0.01 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        emit SwapGasMeasured("vanilla-v4-first", _measureSwap(vanillaRouter, vanillaKey, params));
        emit SwapGasMeasured("statics-phase-one-first", _measureSwap(staticsRouter, staticsKey, params));
        emit SwapGasMeasured("vanilla-v4-mature", _measureSwap(vanillaRouter, vanillaKey, params));
        emit SwapGasMeasured("statics-phase-one-mature", _measureSwap(staticsRouter, staticsKey, params));

        vm.warp(block.timestamp + 31 minutes);
        _measureSwap(staticsRouter, staticsKey, params);
        PoolId poolId = staticsKey.toId();
        emit SwapGasMeasured(
            "statics-settle-currency0", _measureRevenueSettlement(poolId, Currency.unwrap(staticsKey.currency0))
        );
        emit SwapGasMeasured(
            "statics-settle-currency1", _measureRevenueSettlement(poolId, Currency.unwrap(staticsKey.currency1))
        );
        emit SwapGasMeasured("statics-settle-pol", _measurePolSettlement(poolId, basketToken));
    }

    function _measureSwap(CanonicalV4Router router, PoolKey memory key, SwapParams memory params)
        private
        returns (uint256 gasUsed)
    {
        _coolSwapPath(router, key);
        vm.prank(alice);
        uint256 startGas = gasleft();
        BalanceDelta delta = router.swap(key, params);
        gasUsed = startGas - gasleft();
        assertTrue(BalanceDelta.unwrap(delta) != 0);
    }

    function _coolSwapPath(CanonicalV4Router router, PoolKey memory key) private {
        vm.cool(address(router));
        vm.cool(address(poolManager));
        vm.cool(Currency.unwrap(key.currency0));
        vm.cool(Currency.unwrap(key.currency1));
        if (address(key.hooks) != address(0)) {
            vm.cool(address(key.hooks));
            vm.cool(address(diamond));
        }
    }

    function _measureRevenueSettlement(PoolId poolId, address asset) private returns (uint256 gasUsed) {
        vm.cool(address(diamond));
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        vm.cool(asset);
        uint256 startGas = gasleft();
        (uint256 grossAmount,) = IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(poolId, asset);
        gasUsed = startGas - gasleft();
        assertGt(grossAmount, 0);
    }

    function _measurePolSettlement(PoolId poolId, address asset) private returns (uint256 gasUsed) {
        vm.cool(address(diamond));
        vm.cool(address(hook));
        vm.cool(address(poolManager));
        uint256 startGas = gasleft();
        uint256 result = IStaticsProtocolPools(address(diamond)).settleProtocolPoolPol(poolId, asset, 0);
        gasUsed = startGas - gasleft();
        assertGt(result, 0);
    }

    function _createFundedBasket() private returns (uint256 basketId, address basketToken, uint256 positionId) {
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Robinhood Static Basket",
            symbol: "rhSTATIC",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: _singleFeeTier(0.2 ether),
            redemptionFeeTiers: _singleFeeTier(0.1 ether),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (basketId, basketToken) = _launchBasket(params, alice, basketAdmin.creationFee());
        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        assetA.mint(alice, quote[0] + 100 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 100 ether, alice, quote);
        vm.stopPrank();
    }

    function _swapCanonical(uint256 basketId, address basketToken) private {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory key = _poolKey(configured);
        PoolSwapTest router = new PoolSwapTest(poolManager);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        vm.startPrank(alice);
        baskets.mint(basketId, 10 ether, alice, quote);
        IERC20(basketToken).approve(address(router), type(uint256).max);
        assetA.approve(address(router), type(uint256).max);
        bool basketIsCurrency0 = configured.currency0 == basketToken;
        router.swap(
            key,
            SwapParams({
                zeroForOne: basketIsCurrency0,
                amountSpecified: -int256(0.01 ether),
                sqrtPriceLimitX96: basketIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _provideCanonicalLiquidity(uint256 positionId, uint256 basketId) private returns (uint256 tokenId) {
        IStaticsBorrowLiquidity.LiquidityParams[] memory pools = new IStaticsBorrowLiquidity.LiquidityParams[](1);
        pools[0] = IStaticsBorrowLiquidity.LiquidityParams({
            asset: address(assetA),
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidity: 5 ether,
            amount0Max: 100 ether,
            amount1Max: 100 ether,
            deadline: block.timestamp + 1 hours
        });
        vm.prank(alice);
        (, uint256[] memory tokenIds) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(positionId, basketId, 20 ether, pools, alice);
        tokenId = tokenIds[0];
    }

    function _quoteAndSwapThroughUniversalRouter(
        PoolKey memory key,
        address input,
        address output,
        bool zeroForOne,
        uint256 swapperKey,
        uint128 amountIn
    ) private {
        (uint256 quotedOutput, uint256 gasEstimate) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: ""
            })
        );
        assertGt(quotedOutput, 0, "hooked pool quote produced no output");
        assertGt(gasEstimate, 0, "hooked pool quote reported no gas");

        address swapper = vm.addr(swapperKey);
        assertEq(swapper.code.length, 0, "fork swapper must be an EOA");
        vm.prank(alice);
        IERC20(input).transfer(swapper, amountIn);
        vm.prank(swapper);
        IERC20(input).approve(address(permit2Contract), amountIn);

        (bytes memory encodedPermit, uint48 nonce) = _buildPermitApproval(swapper, swapperKey, input, amountIn);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = encodedPermit;
        inputs[1] = _encodeSwapPlan(key, input, output, zeroForOne, amountIn, uint128(quotedOutput));

        _executeRoutedSwap(swapper, inputs, input, output, amountIn, quotedOutput);
        _assertPermitNonceConsumed(swapper, input, nonce);
    }

    function _buildPermitApproval(address swapper, uint256 swapperKey, address input, uint128 amountIn)
        private
        returns (bytes memory encodedPermit, uint48 nonce)
    {
        (,, nonce) = permit2Contract.allowance(swapper, input, address(universalRouter));
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: input, amount: amountIn, expiration: uint48(block.timestamp + 20 minutes), nonce: nonce
            }),
            spender: address(universalRouter),
            sigDeadline: block.timestamp + 20 minutes
        });
        bytes memory signature = getPermitSignature(permitSingle, swapperKey, permit2Contract.DOMAIN_SEPARATOR());
        encodedPermit = abi.encode(permitSingle, signature);
    }

    function _encodeSwapPlan(
        PoolKey memory key,
        address input,
        address output,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) private pure returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                RouterExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(input), amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(output), amountOutMinimum));
        return plan.encode();
    }

    function _executeRoutedSwap(
        address swapper,
        bytes[] memory inputs,
        address input,
        address output,
        uint128 amountIn,
        uint256 quotedOutput
    ) private {
        uint256 inputBefore = IERC20(input).balanceOf(swapper);
        uint256 outputBefore = IERC20(output).balanceOf(swapper);
        vm.prank(swapper);
        universalRouter.execute(
            abi.encodePacked(PERMIT2_PERMIT_COMMAND, V4_SWAP_COMMAND), inputs, block.timestamp + 1 minutes
        );
        assertEq(inputBefore - IERC20(input).balanceOf(swapper), amountIn);
        assertEq(IERC20(output).balanceOf(swapper) - outputBefore, quotedOutput);
    }

    function _assertPermitNonceConsumed(address swapper, address input, uint48 spentNonce) private view {
        (uint160 remaining,, uint48 nextNonce) = permit2Contract.allowance(swapper, input, address(universalRouter));
        assertEq(remaining, 0);
        assertEq(nextNonce, spentNonce + 1);
    }

    function _poolKey(IStaticsBasketLiquidity.CanonicalPoolView memory configured)
        private
        pure
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(poolManager, address(diamond), uint16(25), uint16(25))
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 25, 25);
        assertEq(address(deployed), expected);
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }

    function _selectFork(string memory manifest) private {
        uint256 chainId = vm.parseJsonUint(manifest, ".chainId");
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        uint256 requestedBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", forkBlock);
        assertEq(requestedBlock, forkBlock, "fork block differs from manifest");
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }
        bytes32 expectedBlockHash = vm.parseJsonBytes32(manifest, ".forkBlockHash");
        string memory pinnedBlock =
            vm.rpcJson(rpcUrl, "eth_getBlockByHash", string.concat("[\"", vm.toString(expectedBlockHash), "\",false]"));
        assertEq(vm.parseJsonBytes32(pinnedBlock, ".hash"), expectedBlockHash, "fork block hash drift");
        assertEq(vm.parseJsonUint(pinnedBlock, ".number"), forkBlock, "fork block number drift");
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, chainId);
    }
}
