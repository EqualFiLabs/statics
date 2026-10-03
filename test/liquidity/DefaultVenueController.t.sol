// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IVenueController} from "../../src/interfaces/IVenueController.sol";
import {DefaultVenueController} from "../../src/permissioned/DefaultVenueController.sol";
import {DefaultVenueControllerFactory} from "../../src/permissioned/DefaultVenueControllerFactory.sol";

contract DefaultVenueControllerTest is Test {
    address private operator = makeAddr("operator");
    address private nextOperator = makeAddr("nextOperator");
    address private trader = makeAddr("trader");
    address private asset = makeAddr("asset");
    PoolId private poolId = PoolId.wrap(keccak256("pool"));
    DefaultVenueController private controller;

    function setUp() public {
        controller = new DefaultVenueController(operator);
    }

    function testOperatorControlsIndependentSwapAndLiquidityPermissions() external {
        address[] memory accounts = new address[](1);
        accounts[0] = trader;
        uint256[] memory flags = new uint256[](1);
        flags[0] = controller.SWAP_ALLOWED();

        vm.prank(operator);
        controller.setPermissions(poolId, accounts, flags);
        assertEq(controller.permissions(poolId, trader), controller.SWAP_ALLOWED());
        assertEq(controller.permissions(PoolId.wrap(bytes32(0)), trader), 0);

        flags[0] = controller.SWAP_ALLOWED() | controller.LIQUIDITY_ALLOWED();
        vm.prank(operator);
        controller.setPermissions(poolId, accounts, flags);
        assertEq(controller.permissions(poolId, trader), controller.ALL_PERMISSIONS());
    }

    function testHaltAndOperatorRotationAreReversibleAndTwoStep() external {
        vm.startPrank(operator);
        controller.setAssetStatus(asset, IVenueController.TradingStatus.Halted);
        controller.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        controller.startOperatorTransfer(nextOperator);
        vm.stopPrank();

        assertEq(uint256(controller.assetStatus(asset)), uint256(IVenueController.TradingStatus.Halted));
        assertEq(uint256(controller.poolStatus(poolId)), uint256(IVenueController.TradingStatus.Halted));

        vm.prank(nextOperator);
        controller.acceptOperator();
        assertEq(controller.operator(), nextOperator);

        vm.startPrank(nextOperator);
        controller.setAssetStatus(asset, IVenueController.TradingStatus.Active);
        controller.setPoolStatus(poolId, IVenueController.TradingStatus.Active);
        vm.stopPrank();
    }

    function testFactoryAssignsCallerAsOperator() external {
        DefaultVenueControllerFactory factory = new DefaultVenueControllerFactory();
        vm.prank(operator);
        DefaultVenueController created = DefaultVenueController(factory.createController());
        assertEq(created.operator(), operator);
    }
}
