// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBasketPreparation} from "../../src/interfaces/IStaticsBasketPreparation.sol";
import {IStaticsBasketStaging} from "../../src/interfaces/IStaticsBasketStaging.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {BasketCreationFacet} from "../../src/facets/BasketCreationFacet.sol";
import {BasketMarketCreationFacet} from "../../src/facets/BasketMarketCreationFacet.sol";
import {ProtocolPolFacet} from "../../src/facets/ProtocolPolFacet.sol";
import {LibProtocolPol} from "../../src/libraries/LibProtocolPol.sol";
import {LibBasketDeployment} from "../../src/libraries/LibBasketDeployment.sol";
import {LibBasketMarkets} from "../../src/libraries/LibBasketMarkets.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract OptionalBasketPolTest is CanonicalPoolTestBase {
    using StateLibrary for IPoolManager;

    struct Launch {
        IStaticsBasket.CreateBasketParams params;
        IStaticsBasket.PoolLaunchParams[] pools;
        uint256[] maximums;
        uint256 id;
        address token;
    }

    IStaticsProtocolPools private protocol;
    IStaticsBasketStaging private staging;
    uint256 private constant ACTIVATION_FEE = 0.025 ether;

    function setUp() public override {
        super.setUp();
        vm.deal(bob, 100 ether);
        protocol = IStaticsProtocolPools(address(diamond));
        staging = IStaticsBasketStaging(address(diamond));
        protocol.setProtocolPolActivationFee(ACTIVATION_FEE);
    }

    function testDefaultLaunchRequiresNoBackingAllowanceOrPolSeed() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        assertEq(IERC20(f.token).totalSupply(), 0);
        for (uint256 i; i < 2; ++i) {
            PoolId id = basketLiquidity.canonicalPool(f.id, f.params.assets[i]).poolId;
            IStaticsProtocolPools.ProtocolPoolView memory p = protocol.protocolPool(id);
            assertFalse(p.polActivated);
            assertEq(p.polShareBps, 0);
            assertEq(p.activePolPositions, 0);
            assertEq(poolManager.getLiquidity(id), 0);
            assertEq(baskets.vaultBalance(f.id, f.params.assets[i]), 0);
            (bool active,,) = IStaticsProtocolRevenue(address(diamond)).protocolPolFundingConfig(id);
            assertFalse(active);
        }
        _fundAndApprove(alice, 10 ether, 20 ether);
        uint256[] memory quote = baskets.quoteMint(f.id, 2 ether);
        vm.startPrank(alice);
        baskets.mint(f.id, 2 ether, alice, quote);
        assertEq(IERC20(f.token).balanceOf(alice), 2 ether);
        baskets.redeem(f.id, 2 ether, alice, new uint256[](2));
        vm.stopPrank();
        assertEq(IERC20(f.token).totalSupply(), 0);
    }

    function testCreatorActivationIsPaidPermanentAndPoolSpecific() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        PoolId id = basketLiquidity.canonicalPool(f.id, address(assetA)).poolId;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.OnlyPoolCreator.selector, bob, alice));
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolPolFacet.IncorrectProtocolPolActivationFee.selector, ACTIVATION_FEE, 0)
        );
        protocol.activateProtocolPoolPol(id);
        uint256 before = treasury.balance;
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IStaticsProtocolPools.ProtocolPolActivated(id, alice, ACTIVATION_FEE);
        vm.prank(alice);
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
        assertEq(treasury.balance - before, ACTIVATION_FEE);
        assertTrue(protocol.protocolPool(id).polActivated);
        assertEq(protocol.protocolPool(id).activePolPositions, 0);
        assertFalse(protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetB)).poolId).polActivated);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.ProtocolPolAlreadyActivated.selector, id));
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
    }

    function testZeroActivationFeeAllowsCreatorToOptInWithoutSeed() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        protocol.setProtocolPolActivationFee(0);
        PoolId id = basketLiquidity.canonicalPool(f.id, address(assetA)).poolId;
        vm.prank(alice);
        protocol.activateProtocolPoolPol(id);
        assertTrue(protocol.protocolPool(id).polActivated);
    }

    function testCreationCanActivateWithoutSeedingAndRequiresExactFee() public {
        Launch memory f = _fixture();
        f.pools[0].activateManagedPol = true;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BasketCreationFacet.IncorrectCreationFee.selector, 1 ether + ACTIVATION_FEE, 1 ether)
        );
        baskets.createBasket{value: 1 ether}(f.params, f.pools, f.maximums, type(uint256).max);
        uint256 before = treasury.balance;
        _create(f, 1 ether + ACTIVATION_FEE);
        assertEq(treasury.balance - before, 1 ether + ACTIVATION_FEE);
        assertEq(IERC20(f.token).totalSupply(), 0);
        assertTrue(protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetA)).poolId).polActivated);
        assertFalse(protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetB)).poolId).polActivated);
    }

    function testSeedRequiresExplicitActivationAndRollsBackCreation() public {
        Launch memory f = _fixture();
        f.pools[0].pairedAssetAmount = 1 ether;
        uint256 before = treasury.balance;
        vm.prank(alice);
        vm.expectPartialRevert(LibProtocolPol.ProtocolPolNotActivated.selector);
        baskets.createBasket{value: 1 ether}(f.params, f.pools, f.maximums, type(uint256).max);
        assertEq(baskets.basketCount(), 0);
        assertEq(treasury.balance, before);
        assertEq(_localBasketFactory.nextAutomaticNonce(), 0);
    }

    function testMixedLaunchSeedsOnlyExplicitlyActivatedPool() public {
        Launch memory f = _fixture();
        f.pools[0].activateManagedPol = true;
        f.pools[0].pairedAssetAmount = 1 ether;
        f.maximums[0] = 100 ether;
        f.maximums[1] = 100 ether;
        _fundAndApprove(alice, 100 ether, 100 ether);
        _create(f, 1 ether + ACTIVATION_FEE);
        assertGt(IERC20(f.token).totalSupply(), 0);
        assertEq(
            protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetA)).poolId).activePolPositions, 1
        );
        PoolId unseeded = basketLiquidity.canonicalPool(f.id, address(assetB)).poolId;
        assertEq(protocol.protocolPool(unseeded).activePolPositions, 0);
        assertFalse(protocol.protocolPool(unseeded).polActivated);
        assertEq(poolManager.getLiquidity(unseeded), 0);
        // The unseeded constituent still backs the shares minted for the other pool.
        assertGt(baskets.vaultBalance(f.id, address(assetB)), 0);
        assertEq(IERC20(f.token).balanceOf(address(diamond)), 0);
    }

    function testOrdinaryLpAndFeesWorkBeforeActivationAndActivationIsProspective() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        PoolId id = basketLiquidity.canonicalPool(f.id, address(assetA)).poolId;
        PoolKey memory key = protocol.protocolPool(id).key;
        _addUserLiquidity(f, key);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        Currency currency = Currency.wrap(address(assetA));
        _swap(key);
        uint256 chargedBefore = hook.claimLiability(currency);
        uint256 treasuryBefore = hook.pendingFeeDistribution(id, currency).treasury;
        assertGt(chargedBefore, 0);
        assertEq(hook.pendingProtocolPol(id, currency), 0);
        assertEq(treasuryBefore, chargedBefore - chargedBefore * 500 / 10_000);
        vm.prank(alice);
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
        assertEq(hook.pendingFeeDistribution(id, currency).treasury, treasuryBefore);
        assertEq(hook.pendingProtocolPol(id, currency), 0);
        _swap(key);
        uint256 chargedAfter = hook.claimLiability(currency) - chargedBefore;
        // No eligible Basket/Statics stake: Basket share falls to POL only after activation.
        assertEq(hook.pendingProtocolPol(id, currency), chargedAfter * 1500 / 10_000 + chargedAfter * 3000 / 10_000);
        protocol.settleProtocolPoolPol(id, address(assetA), 0);
        protocol.settleProtocolPoolRevenue(id, address(assetA));
        assertEq(hook.claimLiability(currency), 0);
        assertLe(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testStagedLaunchChargesOnlyCurrentBatchActivation() public {
        Launch memory f = _fixture();
        f.pools[1].activateManagedPol = true;
        vm.prank(alice);
        (f.id, f.token) =
            staging.createBasketStaged{value: 1 ether}(f.params, f.pools, f.maximums, type(uint256).max, bytes32(0), 1);
        assertFalse(protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetA)).poolId).polActivated);
        protocol.setProtocolPolActivationFee(2 * ACTIVATION_FEE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketCreationFacet.IncorrectCreationFee.selector, 2 * ACTIVATION_FEE, ACTIVATION_FEE
            )
        );
        staging.continueBasketLaunch{value: ACTIVATION_FEE}(f.id, f.pools, f.maximums, type(uint256).max, 1);
        (uint256 count,,) = staging.basketLaunchProgress(f.id);
        assertEq(count, 1);
        uint256 before = treasury.balance;
        vm.prank(alice);
        staging.continueBasketLaunch{value: 2 * ACTIVATION_FEE}(f.id, f.pools, f.maximums, type(uint256).max, 1);
        assertEq(treasury.balance - before, 2 * ACTIVATION_FEE);
        assertTrue(protocol.protocolPool(basketLiquidity.canonicalPool(f.id, address(assetB)).poolId).polActivated);
        assertEq(uint256(baskets.basketStatus(f.id)), uint256(IStaticsBasket.BasketStatus.Active));
        assertEq(IERC20(f.token).totalSupply(), 0);
    }

    function testDistributionStakerAndPolSettlementKeepSeparateLiabilities() public {
        Launch memory f = _fixture();
        f.pools[0].activateManagedPol = true;
        _create(f, 1 ether + ACTIVATION_FEE);
        PoolId id = basketLiquidity.canonicalPool(f.id, address(assetA)).poolId;
        PoolKey memory key = protocol.protocolPool(id).key;
        _addUserLiquidity(f, key);

        address[] memory rewards = new address[](1);
        rewards[0] = address(assetA);
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        uint256 position = globalRewards.createAndStake(10 ether, alice, rewards);
        vm.stopPrank();
        vm.prank(alice);
        uint40 eligibleAt = globalRewards.rewardSelection(position, address(assetA)).eligibleAt;
        vm.warp(eligibleAt);
        globalRewards.checkpointRewardAssets(rewards);
        _swap(key);

        Currency currency = Currency.wrap(address(assetA));
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        uint256 staker = hook.pendingStakerRewards(currency);
        uint256 pol = hook.pendingProtocolPol(id, currency);
        uint256 treasuryPending = hook.pendingFeeDistribution(id, currency).treasury;
        assertGt(staker, 0);
        assertGt(pol, 0);
        assertGt(treasuryPending, 0);

        // Claim before funding any other fee-account liability so the complete
        // reward shortfall must redeem this hook's staker claims.
        uint256 before = assetA.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = globalRewards.claimRewards(position, rewards, alice, new uint256[](1))[0];
        assertGt(claimed, 0);
        assertEq(assetA.balanceOf(alice) - before, claimed);
        assertEq(hook.pendingStakerRewards(currency), staker - claimed);
        assertEq(hook.pendingProtocolPol(id, currency), pol);
        assertEq(hook.pendingFeeDistribution(id, currency).treasury, treasuryPending);

        protocol.settleProtocolPoolRevenue(id, address(assetA));
        assertEq(hook.pendingFeeDistribution(id, currency).treasury, 0);
        assertEq(hook.pendingStakerRewards(currency), staker - claimed);
        assertEq(hook.pendingProtocolPol(id, currency), pol);

        protocol.settleProtocolPoolPol(id, address(assetA), 0);
        assertEq(hook.pendingProtocolPol(id, currency), 0);
        assertEq(hook.claimLiability(currency), hook.pendingStakerRewards(currency));
        assertLe(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testIndependentMarketUnwindSettlesFeesAndRejectsReplay() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        protocol.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory params = _market(f.token);
        params.activateManagedPol = true;
        vm.prank(alice);
        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether + ACTIVATION_FEE}(params);
        PoolKey memory key = protocol.protocolPool(id).key;
        _addUserLiquidity(f, key);
        _swap(key);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        assertGt(hook.claimLiability(key.currency0), 0);
        assertGt(hook.claimLiability(key.currency1), 0);

        governance.decommissionBasket(f.id);
        basketLiquidity.unwindBasketMarket(id);
        assertTrue(hook.poolDecommissioned(id));
        assertEq(hook.claimLiability(key.currency0), 0);
        assertEq(hook.claimLiability(key.currency1), 0);
        assertGt(globalRewards.treasuryAccrued(address(assetA)), 0);
        assertFalse(basketLiquidity.basketLiquidityUnwound(f.id, address(assetA)));
        vm.expectRevert(abi.encodeWithSelector(LibBasketMarkets.BasketMarketNotActive.selector, id));
        basketLiquidity.unwindBasketMarket(id);

        uint256 before = IERC20(f.token).balanceOf(alice);
        vm.prank(alice);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), -int256(10 ether), bytes32(0))
        );
        assertGt(IERC20(f.token).balanceOf(alice), before);
        assertLe(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testOverrideCannotActivateOrOpenUnpaidPool() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        PoolId id = basketLiquidity.canonicalPool(f.id, address(assetA)).poolId;
        protocol.setProtocolPoolPolShare(id, 2500);
        assertFalse(protocol.protocolPool(id).polActivated);
        assertEq(protocol.protocolPool(id).polShareBps, 0);
        vm.expectRevert(abi.encodeWithSelector(LibProtocolPol.ProtocolPolNotActivated.selector, id));
        protocol.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams(id, -100, 100, 1, 1, 1, block.timestamp)
        );
    }

    function testPreparedTermsBindActivationChoice() public {
        Launch memory f = _fixture();
        vm.prank(alice);
        (bytes32 preparation,,) = IStaticsBasketPreparation(address(diamond))
            .prepareBasketToken(f.params, f.pools, f.maximums, type(uint256).max, 71);
        f.pools[0].activateManagedPol = true;
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        baskets.createBasketPrepared{value: 1 ether + ACTIVATION_FEE}(
            f.params, f.pools, f.maximums, type(uint256).max, preparation
        );
    }

    function testZeroCreationFeeStillRequiresOwnerWhenOptingIn() public {
        Launch memory f = _fixture();
        basketAdmin.setCreationFee(0);
        f.pools[0].activateManagedPol = true;
        vm.prank(alice);
        vm.expectRevert(BasketCreationFacet.PermissionlessBasketCreationDisabled.selector);
        baskets.createBasket{value: ACTIVATION_FEE}(f.params, f.pools, f.maximums, type(uint256).max);
    }

    function testAdditionalMarketDefaultsOffAndCreatorCanActivateLater() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        protocol.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory params = _market(f.token);
        vm.prank(bob);
        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(params);
        assertFalse(protocol.protocolPool(id).polActivated);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.OnlyPoolCreator.selector, bob, alice));
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
        vm.prank(alice);
        protocol.activateProtocolPoolPol{value: ACTIVATION_FEE}(id);
        assertTrue(protocol.protocolPool(id).polActivated);
    }

    function testZeroFeeAdditionalMarketCreationRemainsOwnerOnly() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        protocol.setPoolCreationFee(0);
        IStaticsBasketMarkets.MarketParams memory params = _market(f.token);
        vm.prank(alice);
        vm.expectRevert(BasketMarketCreationFacet.PermissionlessMarketCreationDisabled.selector);
        IStaticsBasketMarkets(address(diamond)).createBasketMarket(params);

        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket(params);
        assertEq(address(protocol.protocolPool(id).key.hooks), address(_localBasketHook));
        assertEq(protocol.protocolPoolCreator(id), alice);
        assertFalse(protocol.protocolPool(id).polActivated);
    }

    function testAdditionalMarketActivationRequiresCreatorAndExactPayment() public {
        Launch memory f = _fixture();
        _create(f, 1 ether);
        protocol.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory params = _market(f.token);
        params.activateManagedPol = true;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPolFacet.OnlyPoolCreator.selector, bob, alice));
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether + ACTIVATION_FEE}(params);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketMarketCreationFacet.IncorrectMarketCreationFee.selector, 1 ether + ACTIVATION_FEE, 1 ether
            )
        );
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(params);
        vm.prank(alice);
        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether + ACTIVATION_FEE}(params);
        assertTrue(protocol.protocolPool(id).polActivated);
        assertEq(protocol.protocolPool(id).activePolPositions, 0);
    }

    function testSixteenAssetUnseededLaunchGasAndNoBackingDebits() public {
        Launch memory f = _fixture();
        f.params.assets = new address[](16);
        f.params.bundleAmounts = new uint256[](16);
        f.pools = new IStaticsBasket.PoolLaunchParams[](16);
        f.maximums = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            f.params.assets[i] = address(new MockERC20("Asset", "AST", 18));
            f.params.bundleAmounts[i] = 1 ether;
            f.pools[i] = IStaticsBasket.PoolLaunchParams(3000, 10, SQRT_PRICE_1_1, 0, false);
        }
        uint256 before = gasleft();
        _create(f, 1 ether);
        uint256 used = before - gasleft();
        emit log_named_uint("sixteen-asset unseeded atomic launch gas", used);
        assertLt(used, uint256(16_777_216) * 9 / 10);
        assertEq(IERC20(f.token).totalSupply(), 0);
    }

    function _fixture() private view returns (Launch memory f) {
        f.params = _defaultParams(0, 0);
        f.pools = new IStaticsBasket.PoolLaunchParams[](2);
        f.maximums = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            f.pools[i] = IStaticsBasket.PoolLaunchParams(3000, 10, SQRT_PRICE_1_1, 0, false);
        }
    }

    function _create(Launch memory f, uint256 value) private {
        vm.prank(alice);
        (f.id, f.token) = baskets.createBasket{value: value}(f.params, f.pools, f.maximums, type(uint256).max);
    }

    function _market(address token) private view returns (IStaticsBasketMarkets.MarketParams memory) {
        return IStaticsBasketMarkets.MarketParams(
            token, address(assetA), 500, 10, SQRT_PRICE_1_1, 1 ether, type(uint256).max, false
        );
    }

    function _addUserLiquidity(Launch memory f, PoolKey memory key) private {
        _fundAndApprove(alice, 100 ether, 100 ether);
        uint256[] memory quote = baskets.quoteMint(f.id, 20 ether);
        vm.prank(alice);
        baskets.mint(f.id, 20 ether, alice, quote);
        _approveV4Router(alice, f.token);
        _approveV4Router(alice, address(assetA));
        vm.prank(alice);
        v4Router.modifyLiquidity(
            key, ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 10 ether, bytes32(0))
        );
    }

    function _swap(PoolKey memory key) private {
        bool asset0 = Currency.unwrap(key.currency0) == address(assetA);
        vm.prank(alice);
        v4Router.swap(
            key,
            SwapParams(asset0, -int256(0.01 ether), asset0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }
}
