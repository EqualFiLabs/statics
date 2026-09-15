// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsPermanentLiquidityMath} from "../../../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "../../helpers/StaticsTestBase.sol";

interface IBlendBasketFactory {
    function deployed(uint256 index) external view returns (address);
    function deployedCount() external view returns (uint256);
    function isBasket(address basket) external view returns (bool);
}

interface IBlendBasket is IERC20Metadata {
    function constituents() external view returns (address[] memory);
    function units(address token) external view returns (uint256);
    function backing(address token) external view returns (uint256);
}

interface IBlendHook {
    function poolKeyFor(address vault, address quote) external view returns (PoolKey memory);
}

/// @notice Robinhood mainnet-fork proof that a live IndexFi Blend share is an ordinary Statics constituent.
///
/// Live Blend AI is backed by fixed NVDA, GOOGL, and MSFT units. Statics deliberately does not
/// recurse into that composition. It escrows the Blend ERC-20 exactly like any other constituent:
///
///   NVDA + GOOGL + MSFT -> Blend AI -> Statics Blend AI
///
/// The tests prove discovery, canonical-pool launch, fee-bearing mint/redemption, and optional
/// look-through reads without adding any Blend-specific production logic to Statics.
contract RobinhoodBlendBasketForkTest is StaticsTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string private constant CHAIN_MANIFEST = "deployments/robinhood-chain-4663.json";

    address private constant BLEND_FACTORY = 0x40bd43B7ff1D673e03B129dCE371761a6E81E305;
    address private constant BLEND_HOOK = 0x219B93D7c067f3cCc9E25aecDbecf1279D1Fc888;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant SHARED_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    uint256 private constant BLEND_REGISTRY_INDEX = 1;
    address private constant BLEND_AI = 0x425031AD34E45D9A35f903f0369466Ea529F6A81;
    address private constant BLEND_AI_HOLDER = 0x914AadaBE98d9fc4293EC67cF28537acb3117822;
    address private constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address private constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    uint256 private constant FORK_BLOCK = 63_211_853;
    bytes32 private constant FORK_BLOCK_HASH = 0xbe73a3e0b16be6199ff78bea03c50b3ad3006a4ed5ae20f7844369629b311ff8;
    uint256 private constant HOLDER_FUNDING = 50 ether;
    uint256 private constant BUNDLE_AMOUNT = 1 ether;
    uint256 private constant POOL_SEED = 1 ether;
    uint256 private constant MINT_FEE_SHARES = 0.01 ether;
    uint256 private constant REDEMPTION_FEE_SHARES = 0.005 ether;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    StaticsSwapFeeHook private staticsHook;
    StaticsLiquidityManager private liquidityManager;
    uint256 private staticsBasketId;
    address private staticsBasketToken;

    struct LifecycleSnapshot {
        uint256 userBlend;
        uint256 supply;
        uint256 vault;
        uint256 basketReserve;
        uint256 feeReserve;
        uint256 globalReserve;
        uint256 treasuryAccrued;
        uint256 diamondBalance;
    }

    function setUp() public override {
        if (!_selectPinnedFork()) return;
        super.setUp();

        string memory manifest = vm.readFile(CHAIN_MANIFEST);
        poolManager = IPoolManager(vm.parseJsonAddress(manifest, ".contracts.poolManager.address"));
        positionManager = IPositionManager(vm.parseJsonAddress(manifest, ".contracts.positionManager.address"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(manifest, ".contracts.permit2.address"));
        _assertInfrastructure(manifest);
        _assertLiveBlendBasket();

        staticsHook = _deployStaticsHook();
        liquidityManager = new StaticsLiquidityManager(
            address(diamond), address(positionManager), address(poolManager), address(permit2)
        );
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(staticsHook));
        basketLiquidity.installLiquidityManager(address(liquidityManager));

        _fundAliceWithLiveBlendShares();
        (staticsBasketId, staticsBasketToken) = _launchStaticsBlendBasket();
    }

    function testLiveBlendShareCreatesCanonicalStaticsPool() public view {
        IStaticsBasket.BasketView memory configured = baskets.basket(staticsBasketId);
        assertEq(configured.assets.length, 1);
        assertEq(configured.assets[0], BLEND_AI);
        assertEq(configured.bundleAmounts[0], BUNDLE_AMOUNT);
        assertEq(configured.token, staticsBasketToken);

        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        assertEq(canonical.basketToken, staticsBasketToken);
        assertEq(canonical.asset, BLEND_AI);
        assertEq(canonical.hook, address(staticsHook));
        assertNotEq(canonical.hook, BLEND_HOOK);
        assertGt(poolManager.getLiquidity(canonical.poolId), 0);
        assertGt(staticsHook.lockedLiquidity(canonical.poolId), 0);

        PoolKey memory blendKey = IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG);
        (uint160 blendSqrtPrice,,,) = poolManager.getSlot0(blendKey.toId());
        assertEq(address(blendKey.hooks), BLEND_HOOK);
        assertGt(uint256(blendSqrtPrice), 0);
        assertNotEq(PoolId.unwrap(canonical.poolId), PoolId.unwrap(blendKey.toId()));
    }

    function testLiveBlendShareMintsAndRedeemsThroughGenericCustody() public {
        uint256 shares = 2 ether;
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, shares);
        assertEq(mintQuote.length, 1);
        assertEq(mintQuote[0], shares + MINT_FEE_SHARES);

        LifecycleSnapshot memory beforeAction = _takeLifecycleSnapshot();
        uint256 mintGas = _mintOuterBasket(shares, mintQuote);
        _assertMintAccounting(beforeAction, shares, mintQuote[0]);

        uint256[] memory redeemQuote = baskets.quoteRedeem(staticsBasketId, shares);
        assertEq(redeemQuote.length, 1);
        assertEq(redeemQuote[0], shares - REDEMPTION_FEE_SHARES);
        uint256 redeemGas = _redeemOuterBasket(shares, redeemQuote);
        _assertRoundTripAccounting(beforeAction);

        emit log_named_uint("Statics outer-basket mint gas", mintGas);
        emit log_named_uint("Statics outer-basket redeem gas", redeemGas);
    }

    function _takeLifecycleSnapshot() private view returns (LifecycleSnapshot memory snapshot) {
        snapshot.userBlend = IERC20(BLEND_AI).balanceOf(alice);
        snapshot.supply = IERC20(staticsBasketToken).totalSupply();
        snapshot.vault = baskets.vaultBalance(staticsBasketId, BLEND_AI);
        snapshot.basketReserve = custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI);
        snapshot.feeReserve = custody.reservedByAccount(custody.feeCustodyAccount(), BLEND_AI);
        snapshot.globalReserve = custody.globalReservedByToken(BLEND_AI);
        snapshot.treasuryAccrued = globalRewards.treasuryAccrued(BLEND_AI);
        snapshot.diamondBalance = IERC20(BLEND_AI).balanceOf(address(diamond));
    }

    function _mintOuterBasket(uint256 shares, uint256[] memory mintQuote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.mint(staticsBasketId, shares, alice, mintQuote);
        executionGas = gasBefore - gasleft();
    }

    function _redeemOuterBasket(uint256 shares, uint256[] memory redeemQuote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        baskets.redeem(staticsBasketId, shares, alice, redeemQuote);
        executionGas = gasBefore - gasleft();
    }

    function _assertMintAccounting(LifecycleSnapshot memory beforeAction, uint256 shares, uint256 amountIn)
        private
        view
    {
        assertEq(IERC20(BLEND_AI).balanceOf(alice), beforeAction.userBlend - amountIn);
        assertEq(IERC20(staticsBasketToken).balanceOf(alice), shares);
        assertEq(IERC20(staticsBasketToken).totalSupply(), beforeAction.supply + shares);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeAction.vault + shares);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI),
            beforeAction.basketReserve + shares
        );
        assertEq(
            custody.reservedByAccount(custody.feeCustodyAccount(), BLEND_AI), beforeAction.feeReserve + MINT_FEE_SHARES
        );
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeAction.globalReserve + amountIn);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeAction.treasuryAccrued + MINT_FEE_SHARES);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeAction.diamondBalance + amountIn);
    }

    function _assertRoundTripAccounting(LifecycleSnapshot memory beforeAction) private view {
        uint256 totalFees = MINT_FEE_SHARES + REDEMPTION_FEE_SHARES;
        assertEq(IERC20(BLEND_AI).balanceOf(alice), beforeAction.userBlend - totalFees);
        assertEq(IERC20(staticsBasketToken).balanceOf(alice), 0);
        assertEq(IERC20(staticsBasketToken).totalSupply(), beforeAction.supply);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeAction.vault);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI),
            beforeAction.basketReserve
        );
        assertEq(custody.reservedByAccount(custody.feeCustodyAccount(), BLEND_AI), beforeAction.feeReserve + totalFees);
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeAction.globalReserve + totalFees);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeAction.treasuryAccrued + totalFees);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeAction.diamondBalance + totalFees);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), custody.globalReservedByToken(BLEND_AI));
    }

    function testLiveBlendCompositionRemainsReadableOutsideStaticsCore() public {
        IBlendBasket blend = IBlendBasket(BLEND_AI);
        address[] memory constituents = blend.constituents();
        assertEq(constituents.length, 3);
        assertEq(constituents[0], NVDA);
        assertEq(constituents[1], GOOGL);
        assertEq(constituents[2], MSFT);

        uint256 supply = blend.totalSupply();
        emit log_named_address("Statics constituent: Blend BasketVault", BLEND_AI);
        emit log("Blend underlying composition (raw units per 1e18 share):");
        for (uint256 i; i < constituents.length; ++i) {
            address constituent = constituents[i];
            uint256 unitsPerShare = blend.units(constituent);
            uint256 minimumBacking = Math.mulDiv(supply, unitsPerShare, 1 ether, Math.Rounding.Ceil);
            assertGt(unitsPerShare, 0);
            assertGe(blend.backing(constituent), minimumBacking);
            emit log_named_address(IERC20Metadata(constituent).symbol(), constituent);
            emit log_named_uint("units", unitsPerShare);
        }
    }

    function _launchStaticsBlendBasket() private returns (uint256 basketId, address basketToken) {
        address[] memory assets = new address[](1);
        assets[0] = BLEND_AI;
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = BUNDLE_AMOUNT;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Statics Blend AI",
            symbol: "sBAI",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(MINT_FEE_SHARES),
            redemptionFeeTiers: _singleFeeTier(REDEMPTION_FEE_SHARES),
            flashFeeBps: 5,
            originationFeeBps: 25,
            extensionFeeBps: 10,
            ltvBps: 9_000,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });

        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](1);
        pools[0] = IStaticsBasket.PoolLaunchParams({
            lpFee: 3_000, tickSpacing: 10, sqrtPriceAssetPerBasketX96: SQRT_PRICE_1_1, pairedAssetAmount: POOL_SEED
        });
        uint256[] memory maximums = new uint256[](1);
        maximums[0] = 10 ether;

        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(alice);
        return baskets.createBasket{value: creationFee}(params, pools, maximums, block.timestamp + 1 hours);
    }

    function _assertLiveBlendBasket() private {
        IBlendBasketFactory factory = IBlendBasketFactory(BLEND_FACTORY);
        assertEq(factory.deployedCount(), 65);
        assertEq(factory.deployed(BLEND_REGISTRY_INDEX), BLEND_AI);
        assertTrue(factory.isBasket(BLEND_AI));
        assertEq(keccak256(bytes(IBlendBasket(BLEND_AI).name())), keccak256("Blend AI"));
        assertEq(keccak256(bytes(IBlendBasket(BLEND_AI).symbol())), keccak256("AI"));
        assertEq(IBlendBasket(BLEND_AI).decimals(), 18);
        assertGt(IBlendBasket(BLEND_AI).totalSupply(), HOLDER_FUNDING);
        assertGe(IERC20(BLEND_AI).balanceOf(BLEND_AI_HOLDER), HOLDER_FUNDING);

        emit log_named_uint("Robinhood fork block", FORK_BLOCK);
        emit log_named_address("Blend factory", BLEND_FACTORY);
        emit log_named_address("Discovered Blend BasketVault", BLEND_AI);
        emit log_named_address("Impersonated Blend holder", BLEND_AI_HOLDER);
    }

    function _fundAliceWithLiveBlendShares() private {
        uint256 holderBefore = IERC20(BLEND_AI).balanceOf(BLEND_AI_HOLDER);
        vm.prank(BLEND_AI_HOLDER);
        assertTrue(IERC20(BLEND_AI).transfer(alice, HOLDER_FUNDING));
        assertEq(IERC20(BLEND_AI).balanceOf(BLEND_AI_HOLDER), holderBefore - HOLDER_FUNDING);
        assertEq(IERC20(BLEND_AI).balanceOf(alice), HOLDER_FUNDING);
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).approve(address(diamond), type(uint256).max));
    }

    function _assertInfrastructure(string memory manifest) private view {
        assertEq(address(poolManager), SHARED_POOL_MANAGER);
        assertEq(address(poolManager).codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        assertEq(
            address(positionManager).codehash,
            vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash")
        );
        assertEq(address(permit2).codehash, vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"));
        assertGt(BLEND_FACTORY.code.length, 0);
        assertGt(BLEND_HOOK.code.length, 0);
        assertGt(BLEND_AI.code.length, 0);
    }

    function _deployStaticsHook() private returns (StaticsSwapFeeHook deployed) {
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        bytes memory constructorArgs =
            abi.encode(poolManager, address(diamond), uint16(25), uint16(25), permanentLiquidityMath);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(poolManager, address(diamond), 25, 25, permanentLiquidityMath);
        assertEq(address(deployed), expected);
    }

    function _selectPinnedFork() private returns (bool selected) {
        if (block.chainid == 4_663) return true;
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_RPC_URL is not configured");
            return false;
        }
        string memory pinnedBlock =
            vm.rpcJson(rpcUrl, "eth_getBlockByHash", string.concat("[\"", vm.toString(FORK_BLOCK_HASH), "\",false]"));
        assertEq(vm.parseJsonBytes32(pinnedBlock, ".hash"), FORK_BLOCK_HASH, "fork block hash drift");
        assertEq(vm.parseJsonUint(pinnedBlock, ".number"), FORK_BLOCK, "fork block number drift");
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(block.chainid, 4_663, "fork chain id drift");
        return true;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }
}
