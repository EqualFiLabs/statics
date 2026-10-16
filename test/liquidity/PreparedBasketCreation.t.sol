// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibBasketDeployment} from "../../src/libraries/LibBasketDeployment.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {BasketPreparationFacet} from "../../src/facets/BasketPreparationFacet.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract PreparedBasketCreationTest is CanonicalPoolTestBase {
    BasketPreparationFacet private preparation;
    StaticsBasketTokenFactory private factory;

    function setUp() public override {
        super.setUp();
        preparation = BasketPreparationFacet(address(diamond));
        factory = _localBasketFactory;
    }

    function testPreparedDeploymentCreatesOnlyTheRestrictedToken() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256 balanceBefore = assetA.balanceOf(alice);
        (bytes32 id, uint256 basketId, address token) = _prepare(alice, params, pools, maximums, 0);

        assertEq(assetA.balanceOf(alice), balanceBefore);
        assertEq(StaticsRestrictedBasketToken(token).totalSupply(), 0);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
        vm.expectRevert();
        baskets.basket(basketId);

        vm.prank(alice);
        (uint256 finalizedId, address finalizedToken) =
            baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertEq(finalizedId, basketId);
        assertEq(finalizedToken, token);
        assertGt(IERC20(token).totalSupply(), 0);
        (,, bool finalized) = preparation.preparedBasketContracts(id);
        assertTrue(finalized);

        for (uint256 i; i < params.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory market =
                basketLiquidity.canonicalPool(basketId, params.assets[i]);
            assertEq(market.hook, address(_localBasketHook));
            assertEq(
                uint256(StaticsBasketHook(payable(market.hook)).poolRegistration(market.poolId).kind),
                uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical)
            );
        }
    }

    function testPreparedIntentRejectsChangedEconomicsAndReplay() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        (bytes32 id,, address token) = _prepare(alice, params, pools, maximums, 0);

        params.name = "Changed";
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertGt(token.code.length, 0);
        params.name = "Static A-B";

        vm.prank(alice);
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
    }

    function testPreparedIntentCannotBypassClosedCreationGate() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        (bytes32 id,, address token) = _prepare(alice, params, pools, maximums, 0);

        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0);
        vm.prank(alice);
        vm.expectRevert(LibProtocolPools.PermissionlessPoolCreationDisabled.selector);
        baskets.createBasketPrepared(params, pools, maximums, type(uint256).max, id);
        assertGt(token.code.length, 0);
    }

    function testZeroFeeCreationRemainsOwnerOnlyForPreparedBaskets() public {
        basketAdmin.setCreationFee(0);
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        vm.expectRevert(LibProtocolPools.PermissionlessPoolCreationDisabled.selector);
        preparation.prepareBasketToken(params, pools, maximums, type(uint256).max, 0);

        (pools, maximums) = _fundDefaultLaunch(params.assets, address(this));
        (bytes32 id,,) = preparation.prepareBasketToken(params, pools, maximums, type(uint256).max, 0);
        (uint256 basketId,) = baskets.createBasketPrepared(params, pools, maximums, type(uint256).max, id);
        assertEq(baskets.basket(basketId).creator, address(this));
    }

    function testAtomicCreationDerivesOneAutomaticTokenSalt() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256 deadline = type(uint256).max;
        bytes32 salt = factory.automaticSaltFor(factory.nextAutomaticNonce());
        (address predicted,) = factory.predict(salt);

        uint256 basketFee = basketAdmin.creationFee();
        vm.deal(alice, basketFee);
        vm.prank(alice);
        (uint256 basketId, address token) = baskets.createBasket{value: basketFee}(params, pools, maximums, deadline);
        assertEq(token, predicted);
        assertEq(factory.nextAutomaticNonce(), 1);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
    }

    function testIndependentMarketUsesSharedHookAndRejectsDuplicatePoolKey() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory params = IStaticsBasketMarkets.MarketParams(
            token, address(assetA), 500, 10, uint160(1 << 96), 1 ether, type(uint256).max
        );

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(params);
        assertEq(address(pools.protocolPool(id).key.hooks), address(_localBasketHook));
        assertEq(pools.protocolPoolCreator(id), alice);
        assertTrue(PoolId.unwrap(basketLiquidity.canonicalPool(basketId, address(assetA)).poolId) != PoolId.unwrap(id));

        vm.prank(bob);
        vm.expectRevert();
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(params);
    }

    function testRestrictedPairAttributionUsesSortedFirstRestrictedCurrency() public {
        (uint256 firstBasketId, address firstToken) = _createDefaultBasket(0, 0);

        IStaticsBasket.CreateBasketParams memory secondParams = _defaultParams(0, 0);
        secondParams.name = "Static Second";
        secondParams.symbol = "sSECOND";
        (IStaticsBasket.PoolLaunchParams[] memory launch, uint256[] memory maximums) =
            _fundDefaultLaunch(secondParams.assets, bob);
        uint256 basketFee = basketAdmin.creationFee();
        vm.deal(bob, basketFee);
        vm.prank(bob);
        (uint256 secondBasketId, address secondToken) =
            baskets.createBasket{value: basketFee}(secondParams, launch, maximums, type(uint256).max);

        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory market = IStaticsBasketMarkets.MarketParams(
            secondToken, firstToken, 500, 10, uint160(1 << 96), 1 ether, type(uint256).max
        );
        address caller = makeAddr("independent-market-caller");
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        PoolId id = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(market);

        bool firstSortsFirst = firstToken < secondToken;
        uint256 expectedBasketId = firstSortsFirst ? firstBasketId : secondBasketId;
        address expectedCreator = firstSortsFirst ? alice : bob;
        IStaticsProtocolPools.ProtocolPoolView memory view_ = pools.protocolPool(id);
        assertEq(view_.basketId, expectedBasketId);
        assertEq(view_.creator, expectedCreator);
        assertTrue(view_.creator != caller);
    }

    function testSamePairMayUseDifferentCompletePoolKey() public {
        (, address token) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets.MarketParams memory first = IStaticsBasketMarkets.MarketParams(
            token, address(assetA), 500, 10, uint160(1 << 96), 1 ether, type(uint256).max
        );
        IStaticsBasketMarkets.MarketParams memory second = IStaticsBasketMarkets.MarketParams(
            token, address(assetA), 3000, 60, uint160(1 << 96), 1 ether, type(uint256).max
        );
        vm.startPrank(alice);
        PoolId firstId = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(first);
        PoolId secondId = IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1 ether}(second);
        vm.stopPrank();
        assertNotEq(PoolId.unwrap(firstId), PoolId.unwrap(secondId));
        assertEq(address(pools.protocolPool(firstId).key.hooks), address(_localBasketHook));
        assertEq(address(pools.protocolPool(secondId).key.hooks), address(_localBasketHook));
    }

    function testMaximumBasketFinalizesAllPoolsInOneTransaction() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets = new address[](16);
        params.bundleAmounts = new uint256[](16);
        for (uint256 i; i < 16; ++i) {
            params.assets[i] = address(new MockERC20("Asset", "ASSET", 18));
            params.bundleAmounts[i] = 1 ether;
        }
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        (bytes32 id, uint256 basketId, address token) = _prepare(alice, params, pools, maximums, 39);
        uint256 beforeBalance = IERC20(params.assets[0]).balanceOf(alice);
        assertEq(IERC20(token).totalSupply(), 0);
        for (uint256 i; i < 16; ++i) {
            address asset = params.assets[i];
            PoolKey memory key = PoolKey(
                Currency.wrap(token < asset ? token : asset),
                Currency.wrap(token < asset ? asset : token),
                3000,
                10,
                IHooks(address(_localBasketHook))
            );
            assertFalse(_localBasketHook.poolRegistration(PoolIdLibrary.toId(key)).registered);
        }
        vm.expectRevert();
        baskets.basket(basketId);
        assertEq(IERC20(params.assets[0]).balanceOf(alice), beforeBalance);
        vm.prank(alice);
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertGt(IERC20(token).totalSupply(), 0);
        for (uint256 i; i < 16; ++i) {
            assertEq(basketLiquidity.canonicalPool(basketId, params.assets[i]).hook, address(_localBasketHook));
        }
        vm.expectRevert();
        vm.prank(alice);
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
    }

    function _prepare(
        address caller,
        IStaticsBasket.CreateBasketParams memory params,
        IStaticsBasket.PoolLaunchParams[] memory pools,
        uint256[] memory maximums,
        uint256 nonce
    ) private returns (bytes32 id, uint256 basketId, address token) {
        vm.prank(caller);
        return preparation.prepareBasketToken(params, pools, maximums, type(uint256).max, nonce);
    }
}
