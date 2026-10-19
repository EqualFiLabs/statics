// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";
import {BasketConversionFacet} from "../../src/facets/BasketConversionFacet.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {LibBasketMarkets} from "../../src/libraries/LibBasketMarkets.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

/// @dev Registry/authority checks only. Shared-hook execution uses the real callback integration suite.
contract ConversionRegistrationHook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
}

contract BasketConversionFacetTest is StaticsTestBase {
    IStaticsBasketConversion private conversion;
    MockERC20 private quote;
    uint256 private basketId;
    address private basketToken;

    function setUp() public override {
        super.setUp();
        (IPoolManager pm,) = _localLiquidity();
        // A minimal initialization callback isolates facet registration from conversion execution.
        address hook = address(0x12000);
        vm.etch(hook, type(ConversionRegistrationHook).runtimeCode);
        BasketConversionFacet implementation = new BasketConversionFacet(hook, address(0x123), address(0x456), pm);
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(implementation), IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketConversion()
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        conversion = IStaticsBasketConversion(address(diamond));
        quote = new MockERC20("Quote", "Q", 18);
        (basketId, basketToken) = _createDefaultBasket(0, 0);
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0);
    }

    function testZeroFeeCreationIsOwnerOnlyAndDuplicateRejected() public {
        vm.prank(alice);
        vm.expectRevert(BasketConversionFacet.PermissionlessConversionCreationDisabled.selector);
        conversion.createBasketConversionMarket(basketId, address(quote), 0, block.timestamp);
        PoolId id = conversion.createBasketConversionMarket(basketId, address(quote), 0, block.timestamp);
        assertEq(conversion.basketConversionMarket(id).basketToken, basketToken);
        vm.expectRevert(abi.encodeWithSelector(LibBasketMarkets.BasketMarketAlreadyRegistered.selector, id));
        conversion.createBasketConversionMarket(basketId, address(quote), 0, block.timestamp);
    }

    function testPaidCreationUsesExistingFeeAndTreasury() public {
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0.1 ether);
        uint256 beforeBalance = treasury.balance;
        vm.prank(alice);
        conversion.createBasketConversionMarket{value: 0.1 ether}(basketId, address(quote), 0.1 ether, block.timestamp);
        assertEq(treasury.balance - beforeBalance, 0.1 ether);
    }

    function testRejectBasketQuoteExpiredAndWrongFee() public {
        vm.expectRevert(BasketConversionFacet.InvalidConversionMarket.selector);
        conversion.createBasketConversionMarket(basketId, basketToken, 0, block.timestamp);
        vm.warp(10);
        vm.expectRevert(BasketConversionFacet.InvalidConversionMarket.selector);
        conversion.createBasketConversionMarket(basketId, address(quote), 0, 9);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(BasketConversionFacet.IncorrectConversionCreationFee.selector);
        conversion.createBasketConversionMarket{value: 1}(basketId, address(quote), 0, block.timestamp);
    }

    function testDecommissionPreservesIdentityAndBlocksPublicCapabilities() public {
        PoolId id = conversion.createBasketConversionMarket(basketId, address(quote), 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert();
        conversion.decommissionBasketConversionMarket(id);
        conversion.decommissionBasketConversionMarket(id);
        assertFalse(conversion.basketConversionMarket(id).active);
        assertEq(conversion.basketConversionMarket(id).basketToken, basketToken);
        vm.prank(address(0x123)); // The configured zap must reject the retired market.
        vm.expectRevert(abi.encodeWithSelector(LibBasketMarkets.BasketMarketNotActive.selector, id));
        conversion.mintBasketConversion(id, 1 ether, alice, new uint256[](2));
    }
}
