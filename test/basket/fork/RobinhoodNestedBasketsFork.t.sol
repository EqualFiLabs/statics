// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Permit2SignatureHelpers} from "@uniswap/v4-periphery/test/shared/Permit2SignatureHelpers.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsPermanentLiquidityMath} from "../../../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "../../helpers/StaticsTestBase.sol";

interface IRobinhoodNestedBasketUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Shared Robinhood mainnet-fork fixture for the nested-basket demonstration.
///
/// The parent is ordinary ERC-20 composition, not recursive execution:
///
///   AI Infrastructure: NVDA + AMD + AVGO ---------\
///   Platforms:        AAPL + MSFT + META ----------> Composite Equity
///   Statics Growth:   STATICS + PLTR + COIN -------/
///
/// A parent mint transfers three leaf BasketTokens. A complete entry from the nine
/// base assets first mints the three leaves, then mints the parent. The reverse exit
/// first redeems the parent into leaves, then redeems each leaf into base assets.
/// Parent-layer fees are themselves leaf BasketTokens and remain backed until their
/// eventual owner redeems them.
///
/// The current branch's Diamond and permanent-liquidity hook are deployed into the
/// fork because they are not live yet. STATICS, Stock Tokens, PoolManager, Quoter,
/// Permit2, PositionManager, and Universal Router are the pinned mainnet contracts.
/// Every leaf and parent mint or redemption charges a fixed 0.001-share fee.
abstract contract RobinhoodNestedBasketsForkBase is StaticsTestBase, Permit2SignatureHelpers {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant CHAIN_MANIFEST = "deployments/robinhood-chain-4663.json";
    string internal constant GENESIS_MANIFEST = "deployments/robinhood-mainnet-genesis.json";

    address internal constant STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address internal constant AVGO = 0x156E175DD063a8cE274C50654eF40e0032b3fbcF;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address internal constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;

    uint256 internal constant FORK_BLOCK = 47_690_599;
    bytes32 internal constant FORK_BLOCK_HASH = 0x4ca3ce6b00d4603804be596b721c738caf54c2a08515f84a8ca020f33613837b;
    // Equal launch ratios make the mechanics deterministic. They are deliberately
    // not assertions about the market value of either Stock Tokens or BasketTokens.
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant POOL_SEED = 1 ether;
    uint256 internal constant MAX_LAUNCH_INPUT = 100_000 ether;
    uint256 internal constant USER_FUNDING = 1_000_000 ether;
    uint256 internal constant CURATOR_LEAF_SHARES = 20 ether;
    uint256 internal constant LEAF_USER_SHARES = 10 ether;
    uint256 internal constant PARENT_USER_SHARES = 5 ether;
    uint256 internal constant FIXED_FEE_SHARES = 0.001 ether;
    uint256 internal constant SHARE_SCALE = 1 ether;

    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    bytes1 internal constant PERMIT2_PERMIT_COMMAND = 0x0a;
    bytes1 internal constant V4_SWAP_COMMAND = 0x10;
    // Test-only keys sign fork-local Permit2 messages and never hold live funds.
    uint256 internal constant LEAF_SWAPPER_KEY = 0x9045a44c309ea7e3e550ff4bf446b647ba985910dfce59f24c2fb8639480e659;
    uint256 internal constant PARENT_SWAPPER_KEY = 0xc16276e2c1fcc6f2443e8e16b32aee83b00e6bb96d5bc34f647c71f41d31b274;

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

    struct SwapRequest {
        uint256 basketId;
        address asset;
        address input;
        address output;
        address source;
        uint256 swapperKey;
        uint128 amountIn;
    }

    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    IAllowanceTransfer internal permit2Contract;
    IV4Quoter internal quoter;
    IRobinhoodNestedBasketUniversalRouter internal universalRouter;
    StaticsSwapFeeHook internal hook;
    StaticsLiquidityManager internal liquidityManager;

    uint256[3] internal leafBasketIds;
    address[3] internal leafBasketTokens;
    uint256 internal parentBasketId;
    address internal parentBasketToken;

    function setUp() public virtual override {
        if (!_selectPinnedFork()) return;
        super.setUp();

        string memory chainManifest = vm.readFile(CHAIN_MANIFEST);
        poolManager = IPoolManager(vm.parseJsonAddress(chainManifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(chainManifest, ".contracts.positionManager.address"));
        permit2Contract = IAllowanceTransfer(vm.parseJsonAddress(chainManifest, ".contracts.permit2.address"));
        quoter = IV4Quoter(vm.parseJsonAddress(chainManifest, ".contracts.quoter.address"));
        universalRouter = IRobinhoodNestedBasketUniversalRouter(
            vm.parseJsonAddress(chainManifest, ".contracts.universalRouter.address")
        );
        _assertInfrastructureCode(chainManifest);
        _assertCanonicalAssets();

        hook = _deployHook();
        liquidityManager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(address(liquidityManager));

        _fundAndApproveBaseAssets(alice);
        _fundAndApproveBaseAssets(bob);
        _createNestedTopology();
    }

    function _createNestedTopology() internal {
        (leafBasketIds[0], leafBasketTokens[0]) =
            _launchBasket(_basketParams("AI Infrastructure", "sAI", _leafAssets(0), _leafBundles(0)), alice);
        (leafBasketIds[1], leafBasketTokens[1]) =
            _launchBasket(_basketParams("Platform Leaders", "sPLAT", _leafAssets(1), _leafBundles(1)), alice);
        (leafBasketIds[2], leafBasketTokens[2]) =
            _launchBasket(_basketParams("Statics Growth", "sGROW", _leafAssets(2), _leafBundles(2)), alice);

        for (uint256 i; i < leafBasketIds.length; ++i) {
            uint256[] memory quote = baskets.quoteMint(leafBasketIds[i], CURATOR_LEAF_SHARES);
            vm.prank(alice);
            baskets.mint(leafBasketIds[i], CURATOR_LEAF_SHARES, alice, quote);
            uint256 balance = IERC20(leafBasketTokens[i]).balanceOf(alice);
            vm.prank(alice);
            assertTrue(IERC20(leafBasketTokens[i]).approve(address(diamond), balance));
        }

        address[] memory parentAssets = new address[](3);
        uint256[] memory parentBundles = new uint256[](3);
        for (uint256 i; i < parentAssets.length; ++i) {
            parentAssets[i] = leafBasketTokens[i];
            parentBundles[i] = 1 ether;
        }
        (parentBasketId, parentBasketToken) =
            _launchBasket(_basketParams("Nested Composite", "sCOMP", parentAssets, parentBundles), alice);
    }

    function _basketParams(
        string memory name,
        string memory symbol,
        address[] memory assets,
        uint256[] memory bundleAmounts
    ) internal pure returns (IStaticsBasket.CreateBasketParams memory params) {
        params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(FIXED_FEE_SHARES),
            redemptionFeeTiers: _singleFeeTier(FIXED_FEE_SHARES),
            flashFeeBps: 5,
            originationFeeBps: 25,
            extensionFeeBps: 10,
            ltvBps: 9_000,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
    }

    function _launchBasket(IStaticsBasket.CreateBasketParams memory params, address payer)
        internal
        returns (uint256 basketId, address basketToken)
    {
        uint256 length = params.assets.length;
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](length);
        uint256[] memory maximums = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            pools[i] = IStaticsBasket.PoolLaunchParams({
                sqrtPriceAssetPerBasketX96: SQRT_PRICE_1_1, pairedAssetAmount: POOL_SEED
            });
            maximums[i] = MAX_LAUNCH_INPUT;
        }
        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(payer);
        return baskets.createBasket{value: creationFee}(params, pools, maximums, block.timestamp + 1 hours);
    }

    function _leafAssets(uint256 leaf) internal pure returns (address[] memory assets) {
        assets = new address[](3);
        if (leaf == 0) {
            assets[0] = NVDA;
            assets[1] = AMD;
            assets[2] = AVGO;
        } else if (leaf == 1) {
            assets[0] = AAPL;
            assets[1] = MSFT;
            assets[2] = META;
        } else {
            assets[0] = STATICS;
            assets[1] = PLTR;
            assets[2] = COIN;
        }
    }

    function _leafBundles(uint256 leaf) internal pure returns (uint256[] memory bundles) {
        bundles = new uint256[](3);
        if (leaf == 2) {
            bundles[0] = 100 ether;
            bundles[1] = 0.01 ether;
            bundles[2] = 0.01 ether;
        } else {
            bundles[0] = 0.01 ether;
            bundles[1] = 0.01 ether;
            bundles[2] = 0.01 ether;
        }
    }

    function _mintLeaves(address user, uint256 shares) internal returns (uint256[9] memory inputs) {
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            uint256[] memory quote = baskets.quoteMint(leafBasketIds[leaf], shares);
            uint256 tokenBefore = IERC20(leafBasketTokens[leaf]).balanceOf(user);
            uint256[3] memory balancesBefore;
            uint256[3] memory vaultsBefore;
            for (uint256 assetIndex; assetIndex < configured.assets.length; ++assetIndex) {
                balancesBefore[assetIndex] = IERC20(configured.assets[assetIndex]).balanceOf(user);
                vaultsBefore[assetIndex] = baskets.vaultBalance(leafBasketIds[leaf], configured.assets[assetIndex]);
            }

            vm.prank(user);
            baskets.mint(leafBasketIds[leaf], shares, user, quote);

            assertEq(IERC20(leafBasketTokens[leaf]).balanceOf(user) - tokenBefore, shares);
            for (uint256 assetIndex; assetIndex < configured.assets.length; ++assetIndex) {
                uint256 flatIndex = leaf * 3 + assetIndex;
                inputs[flatIndex] = quote[assetIndex];
                assertEq(
                    balancesBefore[assetIndex] - IERC20(configured.assets[assetIndex]).balanceOf(user),
                    quote[assetIndex]
                );
                assertEq(
                    baskets.vaultBalance(leafBasketIds[leaf], configured.assets[assetIndex]) - vaultsBefore[assetIndex],
                    configured.bundleAmounts[assetIndex] * shares / SHARE_SCALE
                );
            }
        }
    }

    function _approveLeafTokens(address user) internal {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            uint256 balance = IERC20(leafBasketTokens[i]).balanceOf(user);
            vm.prank(user);
            assertTrue(IERC20(leafBasketTokens[i]).approve(address(diamond), balance));
        }
    }

    function _mintParent(address user, uint256 shares) internal returns (uint256[] memory quote) {
        quote = baskets.quoteMint(parentBasketId, shares);
        vm.prank(user);
        baskets.mint(parentBasketId, shares, user, quote);
    }

    function _redeemParent(address user, uint256 shares) internal returns (uint256[] memory quote) {
        quote = baskets.quoteRedeem(parentBasketId, shares);
        vm.prank(user);
        baskets.redeem(parentBasketId, shares, user, quote);
    }

    function _redeemLeaves(address user) internal returns (uint256[9] memory outputs) {
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            uint256 shares = IERC20(leafBasketTokens[leaf]).balanceOf(user);
            uint256[] memory quote = baskets.quoteRedeem(leafBasketIds[leaf], shares);
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            uint256[3] memory balancesBefore;
            for (uint256 assetIndex; assetIndex < configured.assets.length; ++assetIndex) {
                balancesBefore[assetIndex] = IERC20(configured.assets[assetIndex]).balanceOf(user);
            }
            vm.prank(user);
            baskets.redeem(leafBasketIds[leaf], shares, user, quote);
            assertEq(IERC20(leafBasketTokens[leaf]).balanceOf(user), 0);
            for (uint256 assetIndex; assetIndex < configured.assets.length; ++assetIndex) {
                outputs[leaf * 3 + assetIndex] = quote[assetIndex];
                assertEq(
                    IERC20(configured.assets[assetIndex]).balanceOf(user) - balancesBefore[assetIndex],
                    quote[assetIndex]
                );
            }
        }
    }

    function _assertAllCanonicalPools() internal view {
        uint256 poolCount;
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            poolCount += _assertBasketPools(leafBasketIds[leaf], leafBasketTokens[leaf]);
        }
        poolCount += _assertBasketPools(parentBasketId, parentBasketToken);
        assertEq(poolCount, 12);
    }

    function _assertBasketPools(uint256 basketId, address basketToken) internal view returns (uint256 poolCount) {
        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        poolCount = configured.assets.length;
        for (uint256 i; i < configured.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
                basketLiquidity.canonicalPool(basketId, configured.assets[i]);
            assertEq(canonical.basketToken, basketToken);
            assertEq(canonical.asset, configured.assets[i]);
            assertEq(canonical.hook, address(hook));
            assertEq(PoolId.unwrap(_poolKey(canonical).toId()), PoolId.unwrap(canonical.poolId));
            assertGt(hook.lockedLiquidity(canonical.poolId), 0);
            assertGt(poolManager.getLiquidity(canonical.poolId), 0);
        }
    }

    function _quoteAndSwapThroughUniversalRouter(SwapRequest memory request) internal {
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(request.basketId, request.asset);
        PoolKey memory key = _poolKey(canonical);
        assertTrue(request.input == canonical.currency0 || request.input == canonical.currency1);
        assertTrue(request.output == canonical.currency0 || request.output == canonical.currency1);
        assertTrue(request.input != request.output);
        bool zeroForOne = canonical.currency0 == request.input;
        (uint256 quotedOutput, uint256 gasEstimate) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: request.amountIn, hookData: ""
            })
        );
        assertGt(quotedOutput, 0);
        assertLe(quotedOutput, type(uint128).max);
        assertGt(gasEstimate, 0);
        _executeUniversalRouterSwap(request, key, zeroForOne, uint128(quotedOutput));
    }

    function _executeUniversalRouterSwap(
        SwapRequest memory request,
        PoolKey memory key,
        bool zeroForOne,
        uint128 quotedOutput
    ) private {
        address swapper = vm.addr(request.swapperKey);
        assertEq(swapper.code.length, 0, "fork swapper must be an EOA");
        vm.prank(request.source);
        assertTrue(IERC20(request.input).transfer(swapper, request.amountIn));
        vm.prank(swapper);
        assertTrue(IERC20(request.input).approve(address(permit2Contract), request.amountIn));

        (bytes memory encodedPermit, uint48 nonce) =
            _buildPermitApproval(swapper, request.swapperKey, request.input, request.amountIn);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = encodedPermit;
        inputs[1] = _encodeSwapPlan(key, request.input, request.output, zeroForOne, request.amountIn, quotedOutput);

        uint256 inputBefore = IERC20(request.input).balanceOf(swapper);
        uint256 outputBefore = IERC20(request.output).balanceOf(swapper);
        vm.prank(swapper);
        universalRouter.execute(
            abi.encodePacked(PERMIT2_PERMIT_COMMAND, V4_SWAP_COMMAND), inputs, block.timestamp + 1 minutes
        );
        assertEq(inputBefore - IERC20(request.input).balanceOf(swapper), request.amountIn);
        assertEq(IERC20(request.output).balanceOf(swapper) - outputBefore, quotedOutput);
        _assertPermitNonceConsumed(swapper, request.input, nonce);
    }

    function _buildPermitApproval(address swapper, uint256 swapperKey, address input, uint128 amountIn)
        internal
        view
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
    ) internal pure returns (bytes memory) {
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

    function _assertPermitNonceConsumed(address swapper, address input, uint48 spentNonce) internal view {
        (uint160 remaining,, uint48 nextNonce) = permit2Contract.allowance(swapper, input, address(universalRouter));
        assertEq(remaining, 0);
        assertEq(nextNonce, spentNonce + 1);
    }

    function _poolKey(IStaticsBasketLiquidity.CanonicalPoolView memory configured)
        internal
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

    function _fundAndApproveBaseAssets(address user) internal {
        address[] memory assets = _allBaseAssets();
        for (uint256 i; i < assets.length; ++i) {
            // Stock Token primary issuance is permissioned and live holder balances drift.
            // Only funding is synthetic: subsequent approvals, transfers, custody, fees,
            // mints, redemptions, pool launches, quotes, and swaps use deployed code.
            deal(assets[i], user, USER_FUNDING, true);
            vm.prank(user);
            assertTrue(IERC20(assets[i]).approve(address(diamond), USER_FUNDING));
        }
    }

    function _allBaseAssets() internal pure returns (address[] memory assets) {
        assets = new address[](9);
        assets[0] = NVDA;
        assets[1] = AMD;
        assets[2] = AVGO;
        assets[3] = AAPL;
        assets[4] = MSFT;
        assets[5] = META;
        assets[6] = STATICS;
        assets[7] = PLTR;
        assets[8] = COIN;
    }

    function _assertInfrastructureCode(string memory manifest) internal view {
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2Contract).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        assertEq(address(quoter).codehash, vm.parseJsonBytes32(manifest, ".contracts.quoter.runtimeCodeHash"));
        assertEq(
            address(universalRouter).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.universalRouter.runtimeCodeHash")
        );
    }

    function _assertCanonicalAssets() internal view {
        _assertAsset(NVDA, "NVDA");
        _assertAsset(AMD, "AMD");
        _assertAsset(AVGO, "AVGO");
        _assertAsset(AAPL, "AAPL");
        _assertAsset(MSFT, "MSFT");
        _assertAsset(META, "META");
        _assertAsset(PLTR, "PLTR");
        _assertAsset(COIN, "COIN");
        _assertAsset(STATICS, "STATICS");
        string memory genesisManifest = vm.readFile(GENESIS_MANIFEST);
        assertEq(STATICS.codehash, vm.parseJsonBytes32(genesisManifest, ".contracts.staticsToken.runtimeCodeHash"));
    }

    function _assertAsset(address asset, string memory expectedSymbol) internal view {
        assertGt(asset.code.length, 0);
        assertEq(IERC20Metadata(asset).decimals(), 18);
        assertEq(keccak256(bytes(IERC20Metadata(asset).symbol())), keccak256(bytes(expectedSymbol)));
    }

    function _deployHook() internal returns (StaticsSwapFeeHook deployed) {
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        bytes memory constructorArgs =
            abi.encode(poolManager, address(diamond), uint24(3_000), uint16(25), uint16(25), permanentLiquidityMath);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed =
            new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 3_000, 25, 25, permanentLiquidityMath);
        assertEq(address(deployed), expected);
    }

    function _selectPinnedFork() internal returns (bool selected) {
        if (block.chainid == 4_663 && block.number == FORK_BLOCK) return true;
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return false;
        }
        uint256 forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "fork block hash drift");
        vm.rollFork(forkId, FORK_BLOCK);
        assertEq(block.chainid, 4_663);
        assertEq(block.number, FORK_BLOCK);
        return true;
    }

    function _installLocalLiquidityIntegration() internal pure virtual override returns (bool) {
        return false;
    }
}

contract RobinhoodNestedBasketsForkTest is RobinhoodNestedBasketsForkBase {
    struct AccountingSnapshot {
        uint256[9] userBalances;
        uint256[9] treasuryAccruals;
        uint256[9] feeReserves;
        uint256[9] leafVaults;
        uint256[3] leafSupplies;
        uint256[3] leafTreasuryAccruals;
        uint256[3] leafFeeReserves;
        uint256[3] parentVaults;
        uint256 parentSupply;
    }

    function testNestedBasketsComposeAndUnwindWithFees() public {
        _assertNestedDefinitions();
        AccountingSnapshot memory beforeAction = _takeAccountingSnapshot(bob);

        uint256[9] memory mintInputs = _mintLeaves(bob, LEAF_USER_SHARES);
        _approveLeafTokens(bob);

        uint256[] memory parentMintQuote = _mintParent(bob, PARENT_USER_SHARES);
        assertEq(IERC20(parentBasketToken).balanceOf(bob), PARENT_USER_SHARES);
        _assertParentMintAccounting(parentMintQuote, beforeAction);

        uint256[] memory parentRedeemQuote = _redeemParent(bob, PARENT_USER_SHARES);
        assertEq(IERC20(parentBasketToken).balanceOf(bob), 0);
        assertEq(IERC20(parentBasketToken).totalSupply(), beforeAction.parentSupply);
        _assertParentRedemptionAccounting(parentRedeemQuote, beforeAction);

        uint256[9] memory redemptionOutputs = _redeemLeaves(bob);
        _assertFinalNestedAccounting(beforeAction, mintInputs, redemptionOutputs);
    }

    function testAllTwelvePoolsAndRepresentativeProductionRoutes() public {
        _assertAllCanonicalPools();
        _mintLeaves(bob, 2 ether);
        _approveLeafTokens(bob);
        _mintParent(bob, 1 ether);

        _quoteAndSwapThroughUniversalRouter(
            SwapRequest({
                basketId: leafBasketIds[0],
                asset: NVDA,
                input: leafBasketTokens[0],
                output: NVDA,
                source: bob,
                swapperKey: LEAF_SWAPPER_KEY,
                amountIn: 0.01 ether
            })
        );
        _quoteAndSwapThroughUniversalRouter(
            SwapRequest({
                basketId: parentBasketId,
                asset: leafBasketTokens[2],
                input: parentBasketToken,
                output: leafBasketTokens[2],
                source: bob,
                swapperKey: PARENT_SWAPPER_KEY,
                amountIn: 0.01 ether
            })
        );
    }

    function _assertNestedDefinitions() private view {
        assertEq(baskets.basketCount(), 4);
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            address[] memory expectedAssets = _leafAssets(leaf);
            uint256[] memory expectedBundles = _leafBundles(leaf);
            assertEq(configured.token, leafBasketTokens[leaf]);
            for (uint256 i; i < expectedAssets.length; ++i) {
                assertEq(configured.assets[i], expectedAssets[i]);
                assertEq(configured.bundleAmounts[i], expectedBundles[i]);
            }
            assertEq(configured.mintFeeTiers[0].feeShares, FIXED_FEE_SHARES);
            assertEq(configured.redemptionFeeTiers[0].feeShares, FIXED_FEE_SHARES);
        }

        IStaticsBasket.BasketView memory parent = baskets.basket(parentBasketId);
        assertEq(parent.token, parentBasketToken);
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            assertEq(parent.assets[i], leafBasketTokens[i]);
            assertEq(parent.bundleAmounts[i], 1 ether);
        }
        assertEq(parent.mintFeeTiers[0].feeShares, FIXED_FEE_SHARES);
        assertEq(parent.redemptionFeeTiers[0].feeShares, FIXED_FEE_SHARES);
    }

    function _assertParentMintAccounting(uint256[] memory quote, AccountingSnapshot memory beforeAction) private view {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            assertEq(quote[i], PARENT_USER_SHARES + FIXED_FEE_SHARES);
            assertEq(
                baskets.vaultBalance(parentBasketId, leafBasketTokens[i]) - beforeAction.parentVaults[i],
                PARENT_USER_SHARES
            );
            assertEq(
                globalRewards.treasuryAccrued(leafBasketTokens[i]) - beforeAction.leafTreasuryAccruals[i],
                FIXED_FEE_SHARES
            );
        }
    }

    function _assertParentRedemptionAccounting(uint256[] memory quote, AccountingSnapshot memory beforeAction)
        private
        view
    {
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            assertEq(quote[i], PARENT_USER_SHARES - FIXED_FEE_SHARES);
            assertEq(baskets.vaultBalance(parentBasketId, leafBasketTokens[i]), beforeAction.parentVaults[i]);
            assertEq(
                globalRewards.treasuryAccrued(leafBasketTokens[i]) - beforeAction.leafTreasuryAccruals[i],
                2 * FIXED_FEE_SHARES
            );
            assertEq(
                custody.reservedByAccount(feeAccount, leafBasketTokens[i]) - beforeAction.leafFeeReserves[i],
                2 * FIXED_FEE_SHARES
            );
            assertEq(IERC20(leafBasketTokens[i]).balanceOf(bob), LEAF_USER_SHARES - 2 * FIXED_FEE_SHARES);
        }
    }

    function _assertFinalNestedAccounting(
        AccountingSnapshot memory beforeAction,
        uint256[9] memory mintInputs,
        uint256[9] memory redemptionOutputs
    ) private view {
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            assertEq(
                IERC20(leafBasketTokens[leaf]).totalSupply() - beforeAction.leafSupplies[leaf], 2 * FIXED_FEE_SHARES
            );
            for (uint256 assetIndex; assetIndex < configured.assets.length; ++assetIndex) {
                uint256 flatIndex = leaf * 3 + assetIndex;
                uint256 actionFee = _feeAmount(configured.bundleAmounts[assetIndex]);
                uint256 residualBacking = configured.bundleAmounts[assetIndex] * 2 * FIXED_FEE_SHARES / SHARE_SCALE;
                address asset = configured.assets[assetIndex];
                assertEq(
                    IERC20(asset).balanceOf(bob),
                    beforeAction.userBalances[flatIndex] - mintInputs[flatIndex] + redemptionOutputs[flatIndex]
                );
                assertEq(globalRewards.treasuryAccrued(asset) - beforeAction.treasuryAccruals[flatIndex], 2 * actionFee);
                assertEq(
                    custody.reservedByAccount(custody.feeCustodyAccount(), asset) - beforeAction.feeReserves[flatIndex],
                    2 * actionFee
                );
                assertEq(
                    baskets.vaultBalance(leafBasketIds[leaf], asset) - beforeAction.leafVaults[flatIndex],
                    residualBacking
                );
                assertEq(IERC20(asset).balanceOf(address(diamond)), custody.globalReservedByToken(asset));
            }
            assertEq(
                IERC20(leafBasketTokens[leaf]).balanceOf(address(diamond)),
                custody.globalReservedByToken(leafBasketTokens[leaf])
            );
        }
    }

    function _takeAccountingSnapshot(address user) private view returns (AccountingSnapshot memory beforeAction) {
        beforeAction.userBalances = _baseBalances(user);
        beforeAction.treasuryAccruals = _baseTreasuryAccruals();
        beforeAction.feeReserves = _baseFeeReserves();
        beforeAction.leafVaults = _leafVaultBalances();
        beforeAction.leafSupplies = _leafSupplies();
        beforeAction.leafTreasuryAccruals = _leafTreasuryAccruals();
        beforeAction.leafFeeReserves = _leafFeeReserves();
        beforeAction.parentVaults = _parentVaultBalances();
        beforeAction.parentSupply = IERC20(parentBasketToken).totalSupply();
    }

    function _feeAmount(uint256 bundleAmount) private pure returns (uint256) {
        return Math.mulDiv(bundleAmount, FIXED_FEE_SHARES, SHARE_SCALE, Math.Rounding.Ceil);
    }

    function _baseBalances(address user) private view returns (uint256[9] memory values) {
        address[] memory assets = _allBaseAssets();
        for (uint256 i; i < assets.length; ++i) {
            values[i] = IERC20(assets[i]).balanceOf(user);
        }
    }

    function _baseTreasuryAccruals() private view returns (uint256[9] memory values) {
        address[] memory assets = _allBaseAssets();
        for (uint256 i; i < assets.length; ++i) {
            values[i] = globalRewards.treasuryAccrued(assets[i]);
        }
    }

    function _baseFeeReserves() private view returns (uint256[9] memory values) {
        address[] memory assets = _allBaseAssets();
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < assets.length; ++i) {
            values[i] = custody.reservedByAccount(feeAccount, assets[i]);
        }
    }

    function _leafVaultBalances() private view returns (uint256[9] memory values) {
        for (uint256 leaf; leaf < leafBasketIds.length; ++leaf) {
            IStaticsBasket.BasketView memory configured = baskets.basket(leafBasketIds[leaf]);
            for (uint256 i; i < configured.assets.length; ++i) {
                values[leaf * 3 + i] = baskets.vaultBalance(leafBasketIds[leaf], configured.assets[i]);
            }
        }
    }

    function _leafSupplies() private view returns (uint256[3] memory values) {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            values[i] = IERC20(leafBasketTokens[i]).totalSupply();
        }
    }

    function _leafTreasuryAccruals() private view returns (uint256[3] memory values) {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            values[i] = globalRewards.treasuryAccrued(leafBasketTokens[i]);
        }
    }

    function _leafFeeReserves() private view returns (uint256[3] memory values) {
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            values[i] = custody.reservedByAccount(feeAccount, leafBasketTokens[i]);
        }
    }

    function _parentVaultBalances() private view returns (uint256[3] memory values) {
        for (uint256 i; i < leafBasketTokens.length; ++i) {
            values[i] = baskets.vaultBalance(parentBasketId, leafBasketTokens[i]);
        }
    }
}

contract RobinhoodNestedBasketGasForkTest is RobinhoodNestedBasketsForkBase {
    event GasMeasured(string operation, uint256 gasUsed, uint256 ceiling);

    // Pinned-fork measurements plus at least 15% headroom, rounded up to 10k.
    uint256 private constant LEAF_MINT_GAS_CEILING = 410_000;
    uint256 private constant PARENT_MINT_GAS_CEILING = 330_000;
    uint256 private constant PARENT_REDEEM_GAS_CEILING = 320_000;
    uint256 private constant LEAF_REDEEM_GAS_CEILING = 400_000;

    uint256[] private leafMintQuote;
    uint256[] private parentMintQuote;
    uint256[] private parentRedeemQuote;
    uint256[] private leafRedeemQuote;

    function setUp() public override {
        super.setUp();
        _mintLeaves(bob, 20 ether);
        _approveLeafTokens(bob);
        _mintParent(bob, 5 ether);

        leafMintQuote = baskets.quoteMint(leafBasketIds[0], 1 ether);
        parentMintQuote = baskets.quoteMint(parentBasketId, 1 ether);
        parentRedeemQuote = baskets.quoteRedeem(parentBasketId, 1 ether);
        leafRedeemQuote = baskets.quoteRedeem(leafBasketIds[2], 1 ether);
    }

    function testGas_LeafMint() public {
        vm.prank(bob);
        baskets.mint(leafBasketIds[0], 1 ether, bob, leafMintQuote);
        _recordGas("leaf mint: three Stock Tokens", vm.lastCallGas().gasTotalUsed, LEAF_MINT_GAS_CEILING);
    }

    function testGas_ParentMint() public {
        vm.prank(bob);
        baskets.mint(parentBasketId, 1 ether, bob, parentMintQuote);
        _recordGas("parent mint: three leaf BasketTokens", vm.lastCallGas().gasTotalUsed, PARENT_MINT_GAS_CEILING);
    }

    function testGas_ParentRedemption() public {
        vm.prank(bob);
        baskets.redeem(parentBasketId, 1 ether, bob, parentRedeemQuote);
        _recordGas(
            "parent redemption: three leaf BasketTokens", vm.lastCallGas().gasTotalUsed, PARENT_REDEEM_GAS_CEILING
        );
    }

    function testGas_LeafRedemption() public {
        vm.prank(bob);
        baskets.redeem(leafBasketIds[2], 1 ether, bob, leafRedeemQuote);
        _recordGas(
            "leaf redemption: STATICS plus two Stock Tokens", vm.lastCallGas().gasTotalUsed, LEAF_REDEEM_GAS_CEILING
        );
    }

    function _recordGas(string memory operation, uint256 gasUsed, uint256 ceiling) private {
        emit GasMeasured(operation, gasUsed, ceiling);
        emit log_named_uint(operation, gasUsed);
        assertLe(gasUsed, ceiling);
    }
}
