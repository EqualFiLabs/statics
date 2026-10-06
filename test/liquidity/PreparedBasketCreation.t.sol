// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {BasketMarketCreationFacet} from "../../src/facets/BasketMarketCreationFacet.sol";
import {BasketPreparationFacet} from "../../src/facets/BasketPreparationFacet.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

abstract contract PreparedBasketTestBase is CanonicalPoolTestBase {
    BasketPreparationFacet internal preparation;
    StaticsBasketFactory internal factory;
    bytes32 internal tokenSalt;
    bytes32[] internal hookSalts;

    function setUp() public virtual override {
        super.setUp();
        preparation = BasketPreparationFacet(address(diamond));
        factory = _localBasketFactory;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory views = new bytes4[](1);
        views[0] = IStaticsRangeGauge.gaugePool.selector;
        cut[0] = IDiamondCut.FacetCut(address(new RangeGaugeViewFacet()), IDiamondCut.FacetCutAction.Add, views);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        tokenSalt = factory.saltFor(0);
        hookSalts.push(_mine(1));
        hookSalts.push(_mine(uint88(uint256(hookSalts[0])) + 1));
    }

    function _automaticallyQueueBasketSalts() internal pure override returns (bool) {
        return false;
    }

    function _queueFirst() internal {
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = tokenSalt;
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(hookSalts, true);
    }

    /// @dev Test-only equivalent of offchain mining over the effective guarded CreateX salt.
    function _mine(uint88 start) internal view returns (bytes32 salt) {
        (salt,) = _mineTestHook(factory, start);
    }
}

contract PreparedBasketCreationTest is PreparedBasketTestBase {
    uint256 private additionalNonce;

    function _ownedNonces(
        IStaticsBasket.CreateBasketParams memory params,
        IStaticsBasket.PoolLaunchParams[] memory pools,
        uint256[] memory maximums
    ) private returns (uint256[] memory nonces) {
        StaticsBasketFactory.Intent memory intent = StaticsBasketFactory.Intent(
            alice,
            alice,
            preparation.basketCreationConfigurationHash(params, pools, maximums, type(uint256).max),
            type(uint256).max,
            1
        );
        tokenSalt = factory.preparedSaltFor(intent, 0);
        nonces = new uint256[](pools.length);
        delete hookSalts;
        uint256 start = 1;
        for (uint256 i; i < pools.length; ++i) {
            bytes32 salt;
            (nonces[i], salt) = _minePreparedTestHook(factory, intent, start);
            hookSalts.push(salt);
            start = nonces[i] + 1;
        }
    }

    function testPreparedCreationUsesReservedIdentitiesAndCreatesActualProtocolPol() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256[] memory nonces = _ownedNonces(params, pools, maximums);
        vm.prank(alice);
        (bytes32 id, address predicted) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, 0, nonces);
        vm.prank(alice);
        (uint256 basketId, address token) =
            baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertEq(token, predicted);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
        assertEq(baskets.basket(basketId).creator, alice);
        for (uint256 i; i < params.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                basketLiquidity.canonicalPool(basketId, params.assets[i]);
            (address predictedHook,) = factory.predict(hookSalts[i]);
            assertEq(pool.hook, predictedHook);
            assertEq(StaticsBasketHook(pool.hook).boundCreator(), alice);
            IStaticsProtocolPools.ProtocolPoolView memory market =
                IStaticsProtocolPools(address(diamond)).protocolPool(pool.poolId);
            assertEq(uint256(market.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
            assertEq(market.creator, alice);
            assertTrue(market.polActivated);
        }
        assertEq(IERC20(token).balanceOf(alice), 0); // Launch inventory belongs to POL, not the payer.
        assertGt(IERC20(token).totalSupply(), 0);
    }

    function testLegacySelectorConsumesQueueAndDoesNotDeployTransferableTokens() public {
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = tokenSalt;
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(hookSalts, true);
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
        (address predicted,) = factory.predict(tokenSalt);
        assertEq(token, predicted);
        (uint256 availableTokens, uint256 availableHooks) = factory.queueAvailability();
        assertEq(availableTokens + availableHooks, 0);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, false));
        baskets.createBasket{value: 1 ether}(params, pools, maximums, type(uint256).max);
    }

    function testChangedPreparedEconomicsFailAndPreserveReservedIdentity() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256[] memory nonces = _ownedNonces(params, pools, maximums);
        vm.prank(alice);
        (bytes32 id,) = preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, 0, nonces);
        params.name = "Changed";
        vm.prank(alice);
        vm.expectRevert();
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertFalse(factory.preparation(id).tokenDeployed);
        assertEq(baskets.basketCount(), 0);
        params.name = "Static A-B";
        basketAdmin.setCreationFee(2 ether);
        vm.prank(alice);
        vm.expectRevert();
        baskets.createBasketPrepared{value: 2 ether}(params, pools, maximums, type(uint256).max, id);
        assertFalse(factory.preparation(id).tokenDeployed);
    }

    function testPublicPreparationAndQueueCannotSquatAnotherPayersIdentities() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256[] memory nonces = _ownedNonces(params, pools, maximums);
        bytes32[] memory stolen = new bytes32[](1);
        stolen[0] = tokenSalt;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.InvalidSalt.selector, tokenSalt));
        factory.enqueueSalts(stolen, false);
        stolen[0] = hookSalts[0];
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.InvalidSalt.selector, hookSalts[0]));
        factory.enqueueSalts(stolen, true);
        // Replaying the visible nonce proofs under Bob's intent cannot reserve Alice's addresses.
        vm.prank(bob);
        (bool attacked,) = address(diamond)
            .call(
                abi.encodeCall(
                    preparation.prepareBasketCreation, (params, pools, maximums, type(uint256).max, 0, nonces)
                )
            );
        attacked; // Whether Bob's different addresses have valid hook bits is irrelevant to ownership.
        assertTrue(factory.saltAvailable(tokenSalt));
        assertTrue(factory.saltAvailable(hookSalts[0]));
        assertTrue(factory.saltAvailable(hookSalts[1]));
        vm.prank(alice);
        (bytes32 id, address token) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, 0, nonces);
        (address predicted,) = factory.predict(tokenSalt);
        assertEq(token, predicted);
        vm.prank(alice);
        (uint256 basketId, address created) =
            baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertEq(created, predicted);
        assertEq(baskets.basket(basketId).creator, alice);
    }

    function testPoolLocalFeesRevenueAndPolResolveTheImmutableHook() public {
        _queueFirst();
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        IStaticsBasketLiquidity.CanonicalPoolView memory market =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        pools.setProtocolPoolFeeRate(market.poolId, IStaticsProtocolPools.PoolSwapFeeRate(90, 10));
        assertEq(StaticsBasketHook(market.hook).poolFeeRate(market.poolId).inputFeeBps, 90);
        assertEq(pools.protocolPoolFeeRate(market.poolId).inputFeeBps, 90);
        (uint16 defaultInput,) = swapFeeHook.defaultFeeRate();
        assertEq(defaultInput, 25);
        _swapAssetIntoBasket(basketId, bob);
        uint256 pending =
            StaticsBasketHook(market.hook).pendingProtocolPol(market.poolId, Currency.wrap(address(assetA)));
        assertGt(pending, 0);
        assertEq(pools.settleProtocolPoolPol(market.poolId, address(assetA), 0), pending);
        assertEq(StaticsBasketHook(market.hook).pendingProtocolPol(market.poolId, Currency.wrap(address(assetA))), 0);
        pools.settleProtocolPoolRevenue(market.poolId, token);
        vm.prank(alice);
        IStaticsProtocolRevenue(address(diamond)).claimCreatorRevenue(market.poolId, token, alice, 0);
        assertGt(IERC20(token).balanceOf(alice), 0);
    }

    function testDelayedStakerFundingSpansHooksWithoutChangingGenerationOwnership() public {
        _queueFirst();
        (uint256 firstBasket,) = _createDefaultBasket(0, 0);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = factory.saltFor((uint88(1) << 87) - 1);
        bytes32[] memory nextHooks = new bytes32[](2);
        nextHooks[0] = _mine(uint88(uint256(hookSalts[1])) + 1);
        nextHooks[1] = _mine(uint88(uint256(nextHooks[0])) + 1);
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(nextHooks, true);
        (uint256 secondBasket,) = _createDefaultBasket(0, 0);
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        uint256 positionId = globalRewards.createAndStake(10 ether, alice, assets);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        _swapAssetIntoBasket(firstBasket, bob);
        _swapAssetIntoBasket(secondBasket, bob);
        uint256 unfunded = globalRewards.unfundedSwapRewards(address(assetA));
        assertGt(unfunded, 0);
        assertEq(swapFeeHook.pendingStakerRewards(Currency.wrap(address(assetA))), 0);
        vm.prank(alice);
        uint256[] memory entitlement = globalRewards.pendingRewards(positionId, assets);
        vm.prank(alice);
        globalRewards.unstake(positionId, 10 ether, alice);
        stakingAsset.mint(bob, 10 ether);
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), 10 ether);
        uint256 laterPosition = globalRewards.createAndStake(10 ether, bob, assets);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        assertEq(globalRewards.settlePublicSwapRewards(address(assetA), unfunded), unfunded);
        assertEq(globalRewards.unfundedSwapRewards(address(assetA)), 0);
        vm.prank(bob);
        assertEq(globalRewards.pendingRewards(laterPosition, assets)[0], 0);
        vm.prank(alice);
        uint256[] memory paid = globalRewards.claimRewards(positionId, assets, alice, new uint256[](1));
        assertEq(paid[0], entitlement[0]);
    }

    function testRestrictedCurrencyCannotEnterGeneralHookCreation() public {
        _queueFirst();
        (, address token) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams(
            token,
            address(assetA),
            3000,
            10,
            uint160(1 << 96),
            IStaticsProtocolPools.PoolSwapFeeRate(25, 25),
            alice,
            false,
            0,
            type(uint256).max
        );
        vm.expectRevert(abi.encodeWithSignature("RestrictedBasketRequiresBasketHook(address)", token));
        IStaticsProtocolPools(address(diamond)).quotePool(params);
    }

    function testAdditionalIdenticalMarketsHaveDistinctIdsAndKeepTheCanonicalPointer() public {
        _queueFirst();
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        PoolId canonicalId = basketLiquidity.canonicalPool(basketId, address(assetA)).poolId;
        IStaticsBasketMarkets.MarketParams memory params = IStaticsBasketMarkets.MarketParams(
            token, address(assetA), 3000, 10, uint160(1 << 96), 1 ether, type(uint256).max
        );
        (PoolId firstId, bytes32 first) = _createAdditional(params);
        (PoolId secondId,) = _createAdditional(params);
        assertNotEq(PoolId.unwrap(firstId), PoolId.unwrap(secondId));
        assertEq(
            PoolId.unwrap(basketLiquidity.canonicalPool(basketId, address(assetA)).poolId), PoolId.unwrap(canonicalId)
        );
        assertEq(pools.protocolPoolCreator(firstId), alice);
        PoolKey memory key = pools.protocolPool(firstId).key;
        _provideBasketLiquidity(basketId, token, key);
        vm.prank(bob);
        v4Router.swap(key, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        vm.prank(alice);
        vm.expectRevert();
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(params, first);
        _retireIndependent(basketId, firstId);
    }

    function testTwoBasketCurrenciesUseTheRestrictedMarketCreationPath() public {
        _queueFirst();
        (uint256 firstBasket, address firstToken) = _createDefaultBasket(0, 0);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = factory.saltFor((uint88(1) << 87) - 1);
        bytes32[] memory nextHooks = new bytes32[](2);
        nextHooks[0] = _mine(uint88(uint256(hookSalts[1])) + 1);
        nextHooks[1] = _mine(uint88(uint256(nextHooks[0])) + 1);
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(nextHooks, true);
        (uint256 secondBasket, address secondToken) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory params = IStaticsBasketMarkets.MarketParams(
            firstToken, secondToken, 3000, 10, uint160(1 << 96), 1 ether, type(uint256).max
        );
        (PoolId id,) = _createAdditional(params);
        PoolKey memory key = pools.protocolPool(id).key;
        _mintFor(alice, firstBasket);
        vm.startPrank(alice);
        IERC20(firstToken).approve(address(diamond), 0.5 ether);
        basketCollateral.createAndDepositBasketCollateral(firstBasket, 0.5 ether, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        assertTrue(IStaticsProtocolRevenue(address(diamond)).canAccrueBasketRewards(id));
        _mintFor(bob, firstBasket);
        _mintFor(bob, secondBasket);
        _approveV4Router(bob, firstToken);
        _approveV4Router(bob, secondToken);
        vm.prank(bob);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                int256(0.2 ether),
                bytes32(0)
            )
        );
        vm.prank(bob);
        v4Router.swap(key, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        IStaticsSwapFeeHook marketHook = IStaticsSwapFeeHook(address(key.hooks));
        assertGt(marketHook.pendingFeeDistribution(id, Currency.wrap(firstToken)).basketStaker, 0);
        assertEq(marketHook.pendingFeeDistribution(id, Currency.wrap(secondToken)).basketStaker, 0);
        assertGt(marketHook.pendingProtocolPol(id, Currency.wrap(secondToken)), 0);
        pools.settleProtocolPoolRevenue(id, firstToken);
        pools.settleProtocolPoolRevenue(id, secondToken);
        vm.prank(alice);
        (uint256 creatorPaid,) =
            IStaticsProtocolRevenue(address(diamond)).claimCreatorRevenue(id, secondToken, alice, 0);
        assertGt(creatorPaid, 0);
        uint256 supplyBefore0 = IERC20(firstToken).totalSupply();
        uint256 supplyBefore1 = IERC20(secondToken).totalSupply();
        _retireIndependent(firstBasket, id);
        assertLt(IERC20(firstToken).totalSupply(), supplyBefore0);
        assertLt(IERC20(secondToken).totalSupply(), supplyBefore1);
        // Historical user LP remains removable even after terminal POL recovery.
        vm.prank(bob);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(10), TickMath.maxUsableTick(10), -int256(0.2 ether), bytes32(0)
            )
        );
    }

    function _retireIndependent(uint256 basketId, PoolId id) private {
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        PoolKey memory key = pools.protocolPool(id).key;
        IStaticsBasketLiquidity markets = IStaticsBasketLiquidity(address(diamond));
        vm.expectRevert(abi.encodeWithSignature("BasketMarketNotExitOnly(bytes32)", PoolId.unwrap(id)));
        markets.unwindBasketMarket(id);
        pools.settleProtocolPoolPol(id, Currency.unwrap(key.currency0), 0);
        pools.settleProtocolPoolPol(id, Currency.unwrap(key.currency1), 0);
        bytes32 account = LibCustody.protocolPolAccount(PoolId.unwrap(id));
        pools.openProtocolPolPosition(
            IStaticsProtocolPools.ProtocolPolOpenParams(
                id,
                -600,
                600,
                1e9,
                custody.reservedByAccount(account, Currency.unwrap(key.currency0)),
                custody.reservedByAccount(account, Currency.unwrap(key.currency1)),
                block.timestamp
            )
        );
        governance.decommissionBasket(basketId);
        uint256[] memory positions = pools.protocolPolPositionIds(id);
        assertGt(positions.length, 0); // Real fee-funded POL is closed before recovery.
        if (positions.length != 0) {
            vm.expectRevert();
            markets.unwindBasketMarket(id);
        }
        for (uint256 i; i < positions.length; ++i) {
            pools.closeProtocolPolPosition(positions[i], 0, 0, block.timestamp);
        }
        pools.settleProtocolPoolPol(id, Currency.unwrap(key.currency0), 0);
        pools.settleProtocolPoolPol(id, Currency.unwrap(key.currency1), 0);
        assertGt(custody.reservedByAccount(account, Currency.unwrap(key.currency0)), 0);
        assertGt(custody.reservedByAccount(account, Currency.unwrap(key.currency1)), 0);
        markets.unwindBasketMarket(id);
        assertTrue(pools.protocolPool(id).decommissioned);
        assertTrue(IStaticsRangeGauge(address(diamond)).gaugePool(id).stopped);
        assertEq(custody.reservedByAccount(account, Currency.unwrap(key.currency0)), 0);
        assertEq(custody.reservedByAccount(account, Currency.unwrap(key.currency1)), 0);
        vm.expectRevert();
        markets.unwindBasketMarket(id);
    }

    function _mintFor(address user, uint256 basketId) private {
        _fundAndApprove(user, 10 ether, 30 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(user);
        baskets.mint(basketId, 1 ether, user, quote);
    }

    function testExitOnlyClosesActualPolAndUnwindsWithoutHelperTransferExemptions() public {
        _queueFirst();
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintFor(bob, basketId);
        _swapAssetIntoBasket(basketId, bob);
        governance.decommissionBasket(basketId);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        address[] memory assets = baskets.basket(basketId).assets;
        for (uint256 i; i < assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory market = basketLiquidity.canonicalPool(basketId, assets[i]);
            uint256[] memory positions = pools.protocolPolPositionIds(market.poolId);
            for (uint256 j; j < positions.length; ++j) {
                pools.closeProtocolPolPosition(positions[j], 0, 0, block.timestamp);
            }
            basketLiquidity.unwindBasketLiquidity(basketId, assets[i]);
            assertTrue(basketLiquidity.basketLiquidityUnwound(basketId, assets[i]));
            assertTrue(pools.protocolPool(market.poolId).decommissioned);
        }
        assertGt(IERC20(token).balanceOf(bob), 0);
        vm.prank(bob);
        IERC20(token).approve(address(v4Router), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        IERC20(token).transfer(alice, 1);
        uint256 shares = IERC20(token).balanceOf(bob);
        vm.prank(bob);
        baskets.redeem(basketId, shares, bob, new uint256[](2));
        assertEq(IERC20(token).balanceOf(bob), 0);
    }

    function testBorrowAndProvideLiquidityPreservesUserLpOwnership() public {
        _queueFirst();
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 100 ether, alice, quote);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = new IStaticsBorrowLiquidity.LiquidityParams[](2);
        params[0] = IStaticsBorrowLiquidity.LiquidityParams(
            address(assetA),
            TickMath.minUsableTick(10),
            TickMath.maxUsableTick(10),
            5 ether,
            100 ether,
            100 ether,
            block.timestamp + 1 hours
        );
        params[1] = IStaticsBorrowLiquidity.LiquidityParams(
            address(assetB),
            TickMath.minUsableTick(10),
            TickMath.maxUsableTick(10),
            5 ether,
            100 ether,
            100 ether,
            block.timestamp + 1 hours
        );
        vm.prank(alice);
        (uint256 loanId, uint256[] memory tokenIds) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(positionId, basketId, 20 ether, params, bob);
        assertEq(lending.loan(loanId).basketId, basketId);
        assertEq(tokenIds.length, 2);
        (address helper,) = basketLiquidity.liquidityManager();
        address posm = IStaticsLiquidityManager(helper).positionManager();
        assertEq(IERC721(posm).ownerOf(tokenIds[0]), bob);
        assertEq(IERC721(posm).ownerOf(tokenIds[1]), bob);
        assertEq(IERC20(token).balanceOf(helper), 0);
        vm.prank(helper);
        vm.expectRevert();
        BasketSettlementFacet(address(diamond)).settleBasketManagerDelivery(token, bob, 1);
    }

    function testRestrictedPolAtomicRebalanceRetainsCustodyAndRollsBackFailedOpening() public {
        _queueFirst();
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _swapAssetIntoBasket(basketId, bob);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        IStaticsBasketLiquidity.CanonicalPoolView memory market =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        uint256 oldId = pools.protocolPolPositionIds(market.poolId)[0];
        IStaticsProtocolPools.ProtocolPolRebalanceParams memory params;
        params.poolId = market.poolId;
        params.deadline = block.timestamp;
        params.maximumCustodyDebit0 = 0.5 ether;
        params.maximumCustodyDebit1 = 0.5 ether;
        params.closes = new IStaticsProtocolPools.ProtocolPolCloseLeg[](1);
        params.closes[0] = IStaticsProtocolPools.ProtocolPolCloseLeg(oldId, 0, 0);
        params.opens = new IStaticsProtocolPools.ProtocolPolOpenLeg[](1);
        params.opens[0] = IStaticsProtocolPools.ProtocolPolOpenLeg(-600, 600, 1e16, 0.5 ether, 0.5 ether);
        pools.setProtocolPolOperator(alice);
        vm.prank(alice);
        uint256[] memory opened = pools.rebalanceProtocolPolPositions(params);
        assertEq(opened.length, 1);
        assertFalse(pools.protocolPolPosition(oldId).active);
        IStaticsProtocolPools.ProtocolPolPositionView memory position = pools.protocolPolPosition(opened[0]);
        assertTrue(position.active);
        assertEq(pools.protocolPool(market.poolId).activePolPositions, 1);
        address posm = IStaticsLiquidityManager(position.manager).positionManager();
        assertEq(IERC721(posm).ownerOf(position.posmTokenId), position.manager);
        assertEq(IERC20(token).balanceOf(position.manager), 0);
        assertEq(assetA.balanceOf(position.manager), 0);
        assertGe(IERC20(token).balanceOf(address(diamond)), custody.globalReservedByToken(token));
        params.closes[0].positionId = opened[0];
        params.opens[0].tickUpper = params.opens[0].tickLower;
        vm.prank(alice);
        vm.expectRevert();
        pools.rebalanceProtocolPolPositions(params);
        assertTrue(pools.protocolPolPosition(opened[0]).active);
        assertEq(IERC721(posm).ownerOf(position.posmTokenId), position.manager);
        assertEq(pools.protocolPool(market.poolId).activePolPositions, 1);
    }

    function _createAdditional(IStaticsBasketMarkets.MarketParams memory params)
        private
        returns (PoolId id, bytes32 prepared)
    {
        IStaticsBasketMarkets markets = IStaticsBasketMarkets(address(diamond));
        bytes32 configuration = markets.basketMarketConfigurationHash(params);
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(alice, alice, configuration, params.deadline, 1);
        (uint256 nonce,) = _minePreparedTestHook(factory, intent, additionalNonce);
        additionalNonce = nonce + 1;
        vm.prank(alice);
        (prepared,) = markets.prepareBasketMarket(params, nonce);
        vm.prank(alice);
        id = markets.createBasketMarket{value: 1 ether}(params, prepared);
    }

    function _provideBasketLiquidity(uint256 basketId, address token, PoolKey memory key) private {
        _fundAndApprove(bob, 10 ether, 30 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(bob);
        baskets.mint(basketId, 1 ether, bob, quote);
        _approveV4Router(bob, token);
        _approveV4Router(bob, address(assetA));
        vm.prank(bob);
        v4Router.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                int256(0.2 ether),
                bytes32(0)
            )
        );
    }

    function _swapAssetIntoBasket(uint256 basketId, address user) private {
        IStaticsBasketLiquidity.CanonicalPoolView memory market =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory key = IStaticsProtocolPools(address(diamond)).protocolPool(market.poolId).key;
        assetA.mint(user, 1 ether);
        _approveV4Router(user, address(assetA));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(assetA);
        vm.prank(user);
        v4Router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(0.1 ether), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }
}
