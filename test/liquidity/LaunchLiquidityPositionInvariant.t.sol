// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchLiquidityPositionHandler is Test, LiquidityOperations {
    IAllowanceTransfer private immutable permit2;
    PoolSwapTest private immutable router;
    StaticsLaunchLiquidityHook private immutable hook;
    PoolKey private key;
    PositionConfig[2] private configs;
    uint256[2] private tokenIds;
    uint128[2] private expectedLiquidity;

    uint256 public successfulSwaps;
    bool public seeded;

    constructor(
        IPositionManager positionManager,
        IAllowanceTransfer permit2_,
        PoolSwapTest router_,
        StaticsLaunchLiquidityHook hook_,
        PoolKey memory key_
    ) {
        lpm = positionManager;
        permit2 = permit2_;
        router = router_;
        hook = hook_;
        key = key_;
        configs[0] = PositionConfig({poolKey: key_, tickLower: -120, tickUpper: 120});
        configs[1] = PositionConfig({poolKey: key_, tickLower: 60, tickUpper: 600});
        _approve(key_.currency0);
        _approve(key_.currency1);
        IERC20(Currency.unwrap(key_.currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency1)).approve(address(router_), type(uint256).max);
    }

    function seed() external {
        require(!seeded);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = lpm.nextTokenId();
            uint128 liquidity = uint128(1e18 + i * 1e17);
            mint(configs[i], liquidity, address(this), "");
            tokenIds[i] = tokenId;
            expectedLiquidity[i] = liquidity;
        }
        seeded = true;
    }

    function increase(uint256 rawIndex, uint256 rawLiquidity) external {
        uint256 index = bound(rawIndex, 0, tokenIds.length - 1);
        uint128 amount = uint128(bound(rawLiquidity, 1, 1e16));
        increaseLiquidity(tokenIds[index], configs[index], amount, "");
        expectedLiquidity[index] += amount;
    }

    function decrease(uint256 rawIndex, uint256 rawLiquidity) external {
        uint256 index = bound(rawIndex, 0, tokenIds.length - 1);
        uint128 current = expectedLiquidity[index];
        if (current == 0) return;
        uint128 amount = uint128(bound(rawLiquidity, 1, current));
        decreaseLiquidity(tokenIds[index], configs[index], amount, "");
        expectedLiquidity[index] = current - amount;
    }

    function collectFees(uint256 rawIndex) external {
        uint256 index = bound(rawIndex, 0, tokenIds.length - 1);
        if (expectedLiquidity[index] == 0) return;
        collect(tokenIds[index], configs[index], "");
    }

    function swapExactInput(bool zeroForOne, uint256 rawAmount) external {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(bound(rawAmount, 1_000, 0.0002 ether)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        successfulSwaps++;
    }

    function positionId(uint256 index) external view returns (uint256) {
        return tokenIds[index];
    }

    function expectedPositionLiquidity(uint256 index) external view returns (uint128) {
        return expectedLiquidity[index];
    }

    function _approve(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }
}

contract LaunchLiquidityPositionInvariantTest is StdInvariant, Test, Deployers, DeployPermit2, LiquidityOperations {
    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address private feeReceiver = makeAddr("positionInvariantReceiver");
    address private externalLp = makeAddr("positionInvariantExternalLp");
    PositionManager private positionManager;
    StaticsLaunchLiquidityHook private hook;
    LaunchLiquidityPositionHandler private handler;
    uint256 private externalPositionId;
    uint128 private externalPositionLiquidity;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        positionManager =
            new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        lpm = IPositionManager(address(positionManager));
        hook = _deployHook();
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        hook.registerPool(key, SQRT_PRICE_1_1, 50, 50);
        positionManager.initializePool(key, SQRT_PRICE_1_1);
        _approvePositionManager(currency0, permit2);
        _approvePositionManager(currency1, permit2);

        externalPositionId = lpm.nextTokenId();
        externalPositionLiquidity = 2e18;
        mint(
            PositionConfig({
                poolKey: key, tickLower: TickMath.minUsableTick(60), tickUpper: TickMath.maxUsableTick(60)
            }),
            externalPositionLiquidity,
            externalLp,
            ""
        );

        handler = new LaunchLiquidityPositionHandler(lpm, permit2, swapRouter, hook, key);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 1_000_000 ether);
        handler.seed();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.increase.selector;
        selectors[1] = handler.decrease.selector;
        selectors[2] = handler.collectFees.selector;
        selectors[3] = handler.swapExactInput.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantManagedPositionsMatchShadowLiquidity() public view {
        for (uint256 i; i < 2; ++i) {
            uint256 tokenId = handler.positionId(i);
            assertEq(positionManager.ownerOf(tokenId), address(handler));
            assertEq(lpm.getPositionLiquidity(tokenId), handler.expectedPositionLiquidity(i));
            assertTrue(positionManager.ownerOf(tokenId) != address(hook));
        }
    }

    function invariantIndependentLpPositionNeverChanges() public view {
        assertEq(positionManager.ownerOf(externalPositionId), externalLp);
        assertEq(lpm.getPositionLiquidity(externalPositionId), externalPositionLiquidity);
    }

    function invariantHookDoesNotCustodyLiquidityAssets() public view {
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function _approvePositionManager(Currency currency, IAllowanceTransfer permit2) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(lpm), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        IPositionManager positionManager_ = IPositionManager(address(positionManager));
        bytes memory args = abi.encode(manager, positionManager_, address(this), feeReceiver);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(manager), positionManager_, address(this), feeReceiver
        );
        assertEq(address(deployed), expected);
    }
}
