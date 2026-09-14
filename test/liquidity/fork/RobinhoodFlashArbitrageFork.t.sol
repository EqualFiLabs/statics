// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsFlashArbitrageReceiver} from "../../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsPermanentLiquidityMath} from "../../../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";
import {StaticsTestBase} from "../../helpers/StaticsTestBase.sol";
import {FlashArbitrageReceiver, ICanonicalV4SwapRouter} from "../../mocks/FlashArbitrageReceiver.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockLaunchLiquidityManager} from "../../mocks/MockLaunchLiquidityManager.sol";

contract RobinhoodFlashArbitrageForkTest is StaticsTestBase {
    using PoolIdLibrary for PoolKey;

    struct MultiAssetFixture {
        uint256 basketId;
        address basketToken;
        uint256 stakePositionId;
        address[] assets;
        PoolKey[] pools;
    }

    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    IPoolManager private poolManager;
    StaticsSwapFeeHook private hook;
    CanonicalV4Router private router;

    function setUp() public override {
        string memory manifest = vm.readFile(MANIFEST_PATH);
        _selectFork(manifest);
        super.setUp();
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        assertTrue(address(poolManager).code.length != 0, "PoolManager has no code");
        assertEq(
            address(poolManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            "PoolManager code hash drift"
        );
        hook = _deployHook();
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(
            address(new MockLaunchLiquidityManager(address(diamond), address(poolManager)))
        );
        router = new CanonicalV4Router(poolManager);
    }

    function testMintAndSellUsesPinnedRobinhoodPoolManager() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture(0.4 ether);
        FlashArbitrageReceiver mintReceiver = _newReceiver();
        (, uint256[] memory multiFlashAmounts, uint256[] memory multiFlashFees) =
            flashLoans.quoteFlashLoan(fixture.basketId, 1 ether);
        uint256[] memory mintMaximums = baskets.quoteMint(fixture.basketId, 1 ether);
        assetA.mint(address(mintReceiver), mintMaximums[0] - multiFlashAmounts[0] + multiFlashFees[0]);
        assetB.mint(address(mintReceiver), mintMaximums[1] - multiFlashAmounts[1] + multiFlashFees[1]);
        assertLt(assetA.balanceOf(address(mintReceiver)), multiFlashAmounts[0]);
        assertLt(assetB.balanceOf(address(mintReceiver)), multiFlashAmounts[1]);
        uint256[] memory basketAmountsIn = new uint256[](2);
        basketAmountsIn[0] = 0.5 ether;
        basketAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        minimumProfits[0] = 0.05 ether;
        minimumProfits[1] = 0.05 ether;
        mintReceiver.executeMintAndSell(fixture.basketId, 1 ether, fixture.pools, basketAmountsIn, minimumProfits);
        _harvestPermanentFees(fixture.pools);
        assertGe(mintReceiver.lastProfit(address(assetA)), minimumProfits[0]);
        assertGe(mintReceiver.lastProfit(address(assetB)), minimumProfits[1]);
        assertGt(hook.lockedLiquidity(fixture.pools[0].toId()), 0);
        assertGt(hook.lockedLiquidity(fixture.pools[1].toId()), 0);
        assertGt(globalRewards.treasuryAccrued(fixture.basketToken), 0);
        address[] memory multiRewardAssets = _rewardAssets(fixture.basketToken);
        vm.prank(alice);
        uint256[] memory multiPending = globalRewards.pendingRewards(fixture.stakePositionId, multiRewardAssets);
        assertGt(multiPending[0], 0);
        assertGt(multiPending[1], 0);
        assertGt(multiPending[2], 0);
    }

    function testProductionBuyAndRedeemUsesPinnedRobinhoodPoolManager() public {
        MultiAssetFixture memory fixture = _createMultiAssetFixture(1.5 ether);
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        uint256[] memory constituentAmountsIn = new uint256[](2);
        constituentAmountsIn[0] = 0.5 ether;
        constituentAmountsIn[1] = 0.5 ether;
        uint256[] memory minimumProfits = new uint256[](2);
        minimumProfits[0] = 0.2 ether;
        minimumProfits[1] = 0.2 ether;

        (, uint256[] memory profits) = receiver.executeBuyAndRedeem(
            fixture.basketId, 1 ether, fixture.pools, constituentAmountsIn, minimumProfits, block.timestamp
        );
        _harvestPermanentFees(fixture.pools);

        assertGe(profits[0], minimumProfits[0]);
        assertGe(profits[1], minimumProfits[1]);
        assertEq(assetA.balanceOf(address(receiver)), 0);
        assertEq(assetB.balanceOf(address(receiver)), 0);
        assertEq(IERC20(fixture.basketToken).balanceOf(address(receiver)), 0);
        assertGt(hook.lockedLiquidity(fixture.pools[0].toId()), 0);
        assertGt(hook.lockedLiquidity(fixture.pools[1].toId()), 0);
        assertGt(globalRewards.treasuryAccrued(fixture.basketToken), 0);
        address[] memory multiRewardAssets = _rewardAssets(fixture.basketToken);
        vm.prank(alice);
        uint256[] memory multiPending = globalRewards.pendingRewards(fixture.stakePositionId, multiRewardAssets);
        assertGt(multiPending[0], 0);
        assertGt(multiPending[1], 0);
        assertGt(multiPending[2], 0);
    }

    function _createMultiAssetFixture(uint256 bundleAmount) private returns (MultiAssetFixture memory fixture) {
        fixture.assets = new address[](2);
        fixture.assets[0] = address(assetA);
        fixture.assets[1] = address(assetB);
        uint256[] memory bundle = new uint256[](2);
        bundle[0] = bundleAmount;
        bundle[1] = bundleAmount;
        (fixture.basketId, fixture.basketToken) = _createBasket(fixture.assets, bundle);
        fixture.stakePositionId = _createStake(_rewardAssets(fixture.basketToken));
        _mintInitialSupply(fixture.basketId, fixture.basketToken, fixture.assets, 100 ether);
        fixture.pools = new PoolKey[](2);
        fixture.pools[0] = _initializeAndSeed(fixture.basketId, fixture.basketToken, fixture.assets[0]);
        fixture.pools[1] = _initializeAndSeed(fixture.basketId, fixture.basketToken, fixture.assets[1]);
    }

    function _rewardAssets(address basketToken) private view returns (address[] memory assets) {
        assets = new address[](3);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        assets[2] = basketToken;
    }

    function _createBasket(address[] memory assets, uint256[] memory bundleAmounts)
        private
        returns (uint256 basketId, address basketToken)
    {
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Robinhood Flash Arbitrage Basket",
            symbol: "rhARB",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0.01 ether),
            redemptionFeeTiers: _singleFeeTier(0.01 ether),
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        return _launchBasket(params, alice, basketAdmin.creationFee());
    }

    function _createStake(address[] memory rewardAssets) private returns (uint256 positionId) {
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        positionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.warp(globalRewards.rewardSelection(positionId, rewardAssets[0]).eligibleAt);
        vm.stopPrank();
    }

    function _mintInitialSupply(uint256 basketId, address basketToken, address[] memory assets, uint256 shares)
        private
    {
        uint256[] memory maximums = baskets.quoteMint(basketId, shares);
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            MockERC20(assets[i]).mint(alice, maximums[i] + 100 ether);
            // Supply independent physical slack for redemption while flash principal is out.
            MockERC20(assets[i]).mint(address(diamond), 100 ether);
            vm.startPrank(alice);
            IERC20(assets[i]).approve(address(diamond), type(uint256).max);
            IERC20(assets[i]).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(alice);
        baskets.mint(basketId, shares, alice, maximums);
        vm.prank(alice);
        IERC20(basketToken).approve(address(router), type(uint256).max);
    }

    function _initializeAndSeed(uint256 basketId, address basketToken, address asset)
        private
        returns (PoolKey memory key)
    {
        IStaticsBasketLiquidity.CanonicalPoolView memory configured = basketLiquidity.canonicalPool(basketId, asset);
        key = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
        assertTrue(configured.currency0 == basketToken || configured.currency1 == basketToken);
        vm.prank(alice);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(configured.tickSpacing),
                tickUpper: TickMath.maxUsableTick(configured.tickSpacing),
                liquidityDelta: 40 ether,
                salt: bytes32(0)
            })
        );
    }

    function _newReceiver() private returns (FlashArbitrageReceiver receiver) {
        receiver = new FlashArbitrageReceiver(address(diamond), ICanonicalV4SwapRouter(address(router)));
    }

    function _harvestPermanentFees(PoolKey[] memory pools) private {
        IStaticsProtocolPools protocolPools = IStaticsProtocolPools(address(diamond));
        protocolPools.setPermanentLiquidityHarvester(address(this));
        for (uint256 i; i < pools.length; ++i) {
            protocolPools.harvestPermanentLiquidityFees(pools[i].toId());
        }
    }

    function _deployHook() private returns (StaticsSwapFeeHook deployed) {
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(StaticsSwapFeeHook).creationCode,
            abi.encode(poolManager, address(diamond), uint16(25), uint16(25), permanentLiquidityMath)
        );
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 25, 25, permanentLiquidityMath);
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
        if (block.chainid == chainId && block.number == forkBlock) return;
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
