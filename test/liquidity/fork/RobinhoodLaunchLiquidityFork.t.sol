// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {StaticsLaunchLiquidityHook} from "../../../src/liquidity/StaticsLaunchLiquidityHook.sol";

/// @notice Pinned-fork proof against the deployed Robinhood v4 core, PositionManager, and Permit2.
/// Local tokens avoid depending on whale balances while exercising the deployed dependency revisions.
contract RobinhoodLaunchLiquidityForkTest is Test, LiquidityOperations {
    using PoolIdLibrary for PoolKey;

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    StaticsLaunchLiquidityHook private hook;
    PoolSwapTest private swapRouter;
    PoolKey private key;
    PoolId private poolId;
    Currency private currency0;
    Currency private currency1;
    PositionConfig private externalPosition;
    uint256 private externalTokenId;

    function setUp() public {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        _selectFork(manifest);
        _deadline = block.timestamp + 1 hours;
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        lpm = positionManager;
        swapRouter = new PoolSwapTest(poolManager);

        MockERC20 tokenA = new MockERC20("Launch A", "LA", 18);
        MockERC20 tokenB = new MockERC20("Launch B", "LB", 18);
        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 1_000 ether);
        (currency0, currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        hook = _deployHook();
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = hook.registerAndInitialize(key, SQRT_PRICE_1_1);
        _approvePositionManager(currency0);
        _approvePositionManager(currency1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        externalPosition = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});
        externalTokenId = lpm.nextTokenId();
        mint(externalPosition, 2 ether, address(this), "");
        hook.seedPOL(key, 1 ether, type(uint256).max, type(uint256).max);
    }

    function testPinnedRobinhoodDependenciesSupportFullLaunchLifecycle() public {
        assertEq(IERC721(address(positionManager)).ownerOf(externalTokenId), address(this));
        assertEq(lpm.getPositionLiquidity(externalTokenId), 2 ether);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.001 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 receiver0Before = currency0.balanceOf(address(this));
        uint256 receiver1Before = currency1.balanceOf(address(this));
        collect(externalTokenId, externalPosition, "");
        assertTrue(
            currency0.balanceOf(address(this)) > receiver0Before
                || currency1.balanceOf(address(this)) > receiver1Before,
            "external PositionManager NFT earned no native fees"
        );

        hook.harvestPOLFees(key);
        hook.retireAndReleasePOL(key);
        assertEq(hook.polLiquidity(poolId), 0);
        assertEq(hook.pendingPOL(poolId, currency0), 0);
        assertEq(hook.pendingPOL(poolId, currency1), 0);

        decreaseLiquidity(externalTokenId, externalPosition, 2 ether, "");
        burn(externalTokenId, externalPosition, "");
    }

    function _approvePositionManager(Currency currency) private {
        address token = Currency.unwrap(currency);
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _deployHook() private returns (StaticsLaunchLiquidityHook deployed) {
        bytes memory args = abi.encode(poolManager, address(this), address(this), address(this), address(this));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployed = new StaticsLaunchLiquidityHook{salt: salt}(
            poolManager, address(this), address(this), address(this), address(this)
        );
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
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }
        if (vm.envOr("ROBINHOOD_FORK_LATEST", false)) {
            vm.createSelectFork(rpcUrl);
            assertEq(block.chainid, chainId);
            return;
        }
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, chainId);
        assertEq(block.number, forkBlock);
    }
}
