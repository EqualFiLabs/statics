// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {StaticsLiquidityManager} from "../../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "../../helpers/StaticsTestBase.sol";

contract RobinhoodStaticsLiquidityForkTest is StaticsTestBase {
    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS =
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2Contract;
    StaticsSwapFeeHook private hook;
    StaticsLiquidityManager private manager;

    function setUp() public override {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        _selectFork(manifest);
        super.setUp();

        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2Contract = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        hook = _deployHook();
        manager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(address(manager));
    }

    function testCompletedStaticsLiquidityLifecycleUsesRobinhoodV4() public {
        (uint256 basketId, address basketToken, uint256 positionId) = _createFundedBasket();
        basketLiquidity.initializeCanonicalPool(basketId, address(assetA), SQRT_PRICE_1_1);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(basketId, address(assetA));

        uint256 sharesCompounded = basketLiquidity.compoundBasketLiquidity(basketId);
        assertGt(sharesCompounded, 0);
        uint256 protocolTokenId = manager.protocolPositionId(basketId, address(assetA));
        assertGt(protocolTokenId, 0);
        assertEq(IERC721(address(positionManager)).ownerOf(protocolTokenId), address(manager));

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
        (, uint256[] memory userTokenIds) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(positionId, basketId, 20 ether, pools, bob);
        assertEq(userTokenIds.length, 1);
        assertEq(IERC721(address(positionManager)).ownerOf(userTokenIds[0]), bob);
        assertNotEq(userTokenIds[0], protocolTokenId);

        _swapCanonical(basketId, basketToken);
        (uint256 pendingBasketToken, uint256 pendingConstituent) =
            basketLiquidity.pendingCanonicalHookFees(basketId, address(assetA));
        assertGt(pendingBasketToken + pendingConstituent, 0);
        basketLiquidity.settleCanonicalHookFees(basketId, address(assetA));
        assertGt(basketLiquidity.cumulativeHookRevenue(basketId, address(assetA)), 0);

        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory lpFees =
            basketLiquidity.collectProtocolLpFees(basketId, address(assetA));
        assertGt(lpFees.constituentCollected + lpFees.basketTokenCollected, 0);

        governance.decommissionBasket(basketId);
        basketLiquidity.unwindBasketLiquidity(basketId, address(assetA));
        assertTrue(basketLiquidity.basketLiquidityUnwound(basketId, address(assetA)));
        assertEq(manager.protocolPositionId(basketId, address(assetA)), 0);
        assertEq(IERC721(address(positionManager)).ownerOf(userTokenIds[0]), bob);
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
            loanDuration: 30 days
        });
        vm.prank(alice);
        (basketId, basketToken) = baskets.createBasket{value: basketAdmin.creationFee()}(params);
        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        assetA.mint(alice, quote[0] + 100 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), type(uint256).max);
        (positionId,) = basketRewards.createAndMintBasket(basketId, 100 ether, alice, quote);
        vm.stopPrank();
    }

    function _swapCanonical(uint256 basketId, address basketToken) private {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
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

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(poolManager, address(diamond), uint16(1))
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 1);
        assertEq(address(deployed), expected);
    }

    function _selectFork(string memory manifest) private {
        uint256 chainId = vm.parseJsonUint(manifest, ".chainId");
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        uint256 requestedBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", forkBlock);
        assertEq(requestedBlock, forkBlock, "fork block differs from manifest");
        if (block.chainid == chainId) {
            assertEq(block.number, forkBlock, "selected fork is not pinned");
            return;
        }
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_RPC_URL is not configured");
            return;
        }
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, chainId);
        assertEq(block.number, forkBlock);
    }
}
