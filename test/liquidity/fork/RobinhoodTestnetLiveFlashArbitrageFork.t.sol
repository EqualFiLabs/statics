// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsFlashLoan} from "../../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsSwapFeeHook} from "../../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsFlashArbitrageReceiver} from "../../../src/periphery/StaticsFlashArbitrageReceiver.sol";

/// @notice Replays the observed TPA1/PLTR distortion without broadcasting a testnet transaction.
contract RobinhoodTestnetLiveFlashArbitrageForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string private constant BASKET_CONFIG_PATH = "script/config/robinhood-testnet-tpa1.json";
    uint256 private constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint256 private constant DISTORTED_STATE_BLOCK = 95_711_656;
    bytes32 private constant DISTORTED_STATE_BLOCK_HASH =
        0xb10619351ec96f14099ea771ca6eaff4e76542e813fcf6a4358114272376b410;
    address private constant HISTORICAL_DIAMOND = 0x69Af9C58e9E283032AE0087c38EF5E27c28E8345;
    address private constant HISTORICAL_EXECUTOR = 0xD31e75a901149ba6c615B257624D349c2D001318;

    IStaticsBasket private baskets;
    IStaticsBasketLiquidity private liquidity;
    IStaticsFlashLoan private flashLoans;
    IStaticsSwapFeeHook private hook;
    IPoolManager private poolManager;
    address private executor;
    uint256 private basketId;
    address[] private basketAssets;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_TESTNET_FORK", false)) fail("Robinhood testnet fork required");
            vm.skip(true, "ROBINHOOD_TESTNET is not configured");
            return;
        }
        uint256 forkId = vm.createSelectFork(rpcUrl, DISTORTED_STATE_BLOCK + 1);
        assertEq(blockhash(DISTORTED_STATE_BLOCK), DISTORTED_STATE_BLOCK_HASH, "fork block hash drift");
        vm.rollFork(forkId, DISTORTED_STATE_BLOCK);

        string memory basketConfig = vm.readFile(BASKET_CONFIG_PATH);
        assertEq(block.chainid, ROBINHOOD_TESTNET_CHAIN_ID);

        executor = HISTORICAL_EXECUTOR;
        basketId = vm.parseJsonUint(basketConfig, ".expectedBasketId");
        basketAssets.push(vm.parseJsonAddress(basketConfig, ".assets[0]"));
        basketAssets.push(vm.parseJsonAddress(basketConfig, ".assets[1]"));
        basketAssets.push(vm.parseJsonAddress(basketConfig, ".assets[2]"));

        baskets = IStaticsBasket(HISTORICAL_DIAMOND);
        liquidity = IStaticsBasketLiquidity(HISTORICAL_DIAMOND);
        flashLoans = IStaticsFlashLoan(HISTORICAL_DIAMOND);
        (address manager, address hookAddress, bool installed) = liquidity.liquidityIntegration();
        assertTrue(installed);
        assertTrue(manager.code.length != 0);
        assertTrue(hookAddress.code.length != 0);
        poolManager = IPoolManager(manager);
        hook = IStaticsSwapFeeHook(hookAddress);
    }

    function testProductionReceiverCorrectsObservedTpa1PltrDistortion() public {
        uint256 shares = 127 ether;
        PoolKey[] memory pools = _canonicalPools();
        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 53.164 ether;
        allocations[1] = 4.136 ether;
        allocations[2] = 69.7 ether;
        uint256[] memory minimumProfits = new uint256[](3);
        minimumProfits[0] = 1;
        minimumProfits[1] = 10 ether;
        minimumProfits[2] = 1;

        (, int24 pltrTickBefore,,) = poolManager.getSlot0(pools[1].toId());
        uint128 lockedLiquidityBefore = hook.lockedLiquidity(pools[1].toId());
        uint256 vaultBefore = baskets.vaultBalance(basketId, basketAssets[1]);
        uint256[] memory executorBalancesBefore = _balances(executor);
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(baskets));
        (, uint256[] memory flashAmounts,) = flashLoans.quoteFlashLoan(basketId, shares);
        uint256[] memory mintMaximums = baskets.quoteMint(basketId, shares);

        vm.startPrank(executor);
        for (uint256 i; i < basketAssets.length; ++i) {
            uint256 topUp = mintMaximums[i] - flashAmounts[i];
            assertGe(IERC20(basketAssets[i]).balanceOf(executor), topUp);
            IERC20(basketAssets[i]).approve(address(receiver), topUp);
        }
        (, uint256[] memory profits) =
            receiver.executeMintAndSell(basketId, shares, pools, allocations, minimumProfits, block.timestamp);
        vm.stopPrank();

        (, int24 pltrTickAfter,,) = poolManager.getSlot0(pools[1].toId());
        assertGt(pltrTickAfter, pltrTickBefore, "PLTR pool did not move toward launch price");
        assertEq(
            baskets.vaultBalance(basketId, basketAssets[1]),
            vaultBefore + flashAmounts[1],
            "mint backing or flash principal not recorded"
        );
        assertGt(hook.lockedLiquidity(pools[1].toId()), lockedLiquidityBefore, "route did not compound POL");
        for (uint256 i; i < basketAssets.length; ++i) {
            assertGe(profits[i], minimumProfits[i]);
            assertEq(IERC20(basketAssets[i]).balanceOf(executor), executorBalancesBefore[i] + profits[i]);
            assertEq(IERC20(basketAssets[i]).balanceOf(address(receiver)), 0);
        }
        assertEq(IERC20(baskets.basket(basketId).token).balanceOf(address(receiver)), 0);
    }

    function _canonicalPools() private view returns (PoolKey[] memory pools) {
        pools = new PoolKey[](basketAssets.length);
        for (uint256 i; i < basketAssets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory configured =
                liquidity.canonicalPool(basketId, basketAssets[i]);
            pools[i] = PoolKey({
                currency0: Currency.wrap(configured.currency0),
                currency1: Currency.wrap(configured.currency1),
                fee: configured.lpFee,
                tickSpacing: configured.tickSpacing,
                hooks: IHooks(configured.hook)
            });
        }
    }

    function _balances(address account) private view returns (uint256[] memory balances) {
        balances = new uint256[](basketAssets.length);
        for (uint256 i; i < basketAssets.length; ++i) {
            balances[i] = IERC20(basketAssets[i]).balanceOf(account);
        }
    }
}
