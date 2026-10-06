// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {LibRestrictedBasket} from "../../src/libraries/LibRestrictedBasket.sol";
import {LibBasketManagerSettlement} from "../../src/libraries/LibBasketManagerSettlement.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SettlementHelper {
    function deliver(
        BasketSettlementFacet protocol,
        StaticsRestrictedBasketToken token,
        address receiver,
        uint256 amount
    ) external {
        token.approve(address(protocol), amount);
        protocol.settleBasketManagerDelivery(address(token), receiver, amount);
        token.approve(address(protocol), 0);
    }
}

/// @dev Narrow context harness; transfers, balances, and consumable token tickets are real.
contract ManagerSettlementProtocol is BasketSettlementFacet {
    StaticsRestrictedBasketToken public token;
    MockERC20 private asset;

    constructor() {
        token = new StaticsRestrictedBasketToken("Basket", "B", address(this), 0, IPoolManager(address(1)));
        LibRestrictedBasket.register(address(token), 0);
        asset = new MockERC20("Underlying", "U", 18);
    }

    function mint(address receiver, uint256 amount) external {
        token.mint(receiver, amount);
    }

    function exercise(
        SettlementHelper helper,
        address receiver,
        address requestedReceiver,
        uint256 funded,
        uint256 first,
        uint256 second
    ) external {
        address a = address(token);
        address b = address(asset);
        PoolKey memory key =
            PoolKey(Currency.wrap(a < b ? a : b), Currency.wrap(a < b ? b : a), 3000, 10, IHooks(address(0)));
        LibBasketManagerSettlement.begin(key, address(helper), receiver);
        LibCustody.pushUnreserved(a, address(helper), funded, funded);
        helper.deliver(this, token, requestedReceiver, first);
        if (second != 0) helper.deliver(this, token, requestedReceiver, second);
        LibBasketManagerSettlement.end();
    }
}

contract BasketManagerSettlementTest is Test {
    ManagerSettlementProtocol private protocol;
    SettlementHelper private helper;
    StaticsRestrictedBasketToken private token;
    address private receiver = address(0xCAFE);

    function setUp() public {
        protocol = new ManagerSettlementProtocol();
        helper = new SettlementHelper();
        token = protocol.token();
        protocol.mint(address(helper), 77);
        protocol.mint(address(protocol), 10);
    }

    function testReturnsOnlyActionAttributableInventoryThroughDiamond() public {
        protocol.exercise(helper, receiver, receiver, 10, 4, 6);
        assertEq(token.balanceOf(receiver), 10);
        assertEq(token.balanceOf(address(helper)), 77);
        assertEq(token.allowance(address(helper), address(protocol)), 0);
        vm.expectRevert(LibBasketManagerSettlement.InvalidManagerSettlement.selector);
        helper.deliver(protocol, token, receiver, 1);
    }

    function testCannotUsePreexistingHelperBalanceOrExhaustedBudget() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasketManagerSettlement.ManagerReturnExceedsMovement.selector, address(token), 11, 10
            )
        );
        protocol.exercise(helper, receiver, receiver, 10, 11, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasketManagerSettlement.ManagerReturnExceedsMovement.selector, address(token), 7, 6
            )
        );
        protocol.exercise(helper, receiver, receiver, 10, 4, 7);
        assertEq(token.balanceOf(address(helper)), 77);
        assertEq(token.balanceOf(receiver), 0);
    }

    function testReceiverAndCallerMismatchCannotCreateTransferAuthority() public {
        vm.expectRevert(LibBasketManagerSettlement.InvalidManagerSettlement.selector);
        protocol.exercise(helper, receiver, address(0xBAD), 10, 1, 0);
        vm.prank(address(helper));
        vm.expectRevert();
        token.transfer(receiver, 1);
        vm.expectRevert(LibBasketManagerSettlement.InvalidManagerSettlement.selector);
        protocol.settleBasketManagerDelivery(address(token), receiver, 1);
    }
}
