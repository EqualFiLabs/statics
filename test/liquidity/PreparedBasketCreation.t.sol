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
import {BasketMarketCreationFacet} from "../../src/facets/BasketMarketCreationFacet.sol";
import {BasketPreparationFacet} from "../../src/facets/BasketPreparationFacet.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract PreparedBasketCreationTest is CanonicalPoolTestBase {
    BasketPreparationFacet private preparation;
    StaticsBasketFactory private factory;
    bytes32 private tokenSalt;
    bytes32[] private hookSalts;

    function setUp() public override {
        super.setUp();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](3);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BasketPreparationFacet.installBasketFactory.selector;
        selectors[1] = BasketPreparationFacet.basketFactory.selector;
        selectors[2] = BasketPreparationFacet.basketCreationConfigurationHash.selector;
        selectors[3] = BasketPreparationFacet.prepareBasketCreation.selector;
        cut[0] = IDiamondCut.FacetCut(address(new BasketPreparationFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        selectors = new bytes4[](5);
        selectors[0] = BasketSettlementFacet.validateBasketPool.selector;
        selectors[1] = BasketSettlementFacet.authorizeBasketPoolSettlement.selector;
        selectors[2] = BasketSettlementFacet.authorizeBasketPoolClaim.selector;
        selectors[3] = BasketSettlementFacet.isRestrictedBasketToken.selector;
        selectors[4] = BasketSettlementFacet.settleBasketManagerDelivery.selector;
        cut[1] = IDiamondCut.FacetCut(address(new BasketSettlementFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        selectors = new bytes4[](2);
        selectors[0] = IStaticsBasketMarkets.prepareBasketMarket.selector;
        selectors[1] = IStaticsBasketMarkets.createBasketMarket.selector;
        cut[2] =
            IDiamondCut.FacetCut(address(new BasketMarketCreationFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        preparation = BasketPreparationFacet(address(diamond));
        vm.etch(
            0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed,
            vm.parseJsonBytes(vm.readFile("test/fixtures/createx-v1.json"), ".runtime")
        );
        factory = StaticsBasketFactory(
            deployCode(
                "out/StaticsBasketFactory.sol/StaticsBasketFactory.json",
                abi.encode(address(diamond), poolManager, swapFeeHook)
            )
        );
        preparation.installBasketFactory(address(factory));
        tokenSalt = factory.saltFor(0);
        hookSalts.push(_mine(1));
        hookSalts.push(_mine(uint88(uint256(hookSalts[0])) + 1));
    }

    function testPreparedCreationUsesReservedIdentitiesAndCreatesActualProtocolPol() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        (bytes32 id, address predicted) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, tokenSalt, hookSalts);
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
        vm.prank(alice);
        (bytes32 id,) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, tokenSalt, hookSalts);
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
        tokens[0] = factory.saltFor(type(uint88).max);
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
        bytes32 firstSalt = _mine(uint88(uint256(hookSalts[1])) + 1);
        (PoolId firstId, bytes32 first) = _createAdditional(params, firstSalt);
        (PoolId secondId,) = _createAdditional(params, _mine(uint88(uint256(firstSalt)) + 1));
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
    }

    function testTwoBasketCurrenciesUseTheRestrictedMarketCreationPath() public {
        _queueFirst();
        (uint256 firstBasket, address firstToken) = _createDefaultBasket(0, 0);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = factory.saltFor(type(uint88).max);
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
        (PoolId id,) = _createAdditional(params, _mine(uint88(uint256(nextHooks[1])) + 1));
        PoolKey memory key = pools.protocolPool(id).key;
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

    function _createAdditional(IStaticsBasketMarkets.MarketParams memory params, bytes32 salt)
        private
        returns (PoolId id, bytes32 prepared)
    {
        IStaticsBasketMarkets markets = IStaticsBasketMarkets(address(diamond));
        vm.prank(alice);
        (prepared,) = markets.prepareBasketMarket(params, salt);
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

    function _queueFirst() private {
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = tokenSalt;
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(hookSalts, true);
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

    /// @dev Test-only equivalent of offchain mining over the effective guarded CreateX salt.
    function _mine(uint88 start) private view returns (bytes32 salt) {
        uint256 prefix = uint256(factory.saltFor(0));
        address createX = factory.CREATE_X();
        bytes32 proxyHash = factory.CREATE3_PROXY_HASH();
        for (uint256 i = start; i < uint256(start) + 1_000_000; ++i) {
            salt = bytes32(prefix | i);
            bytes32 effective = keccak256(abi.encode(address(factory), block.chainid, salt));
            address proxy =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", createX, effective, proxyHash)))));
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
            if (uint160(predicted) & ((1 << 14) - 1) == 0x1fec) return salt;
        }
        revert("test salt search exhausted");
    }
}
