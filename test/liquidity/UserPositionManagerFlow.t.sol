// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract UserPositionManagerFlowTest is LiquidityManagerTestBase {
    function testUserPositionMintsDirectlyToRecipientAndRefundsWithoutPersistentBook() public {
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        _transferUserInventory(6 ether, 6 ether);

        uint256 alice0Before = IERC20(token0).balanceOf(alice);
        uint256 alice1Before = IERC20(token1).balanceOf(alice);
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        (IStaticsLiquidityManager.PositionMovement memory movement, uint256 refund0, uint256 refund1) =
            liquidityManager.mintUserPosition(request, bob, alice);

        assertEq(IERC721(address(positionManagerContract)).ownerOf(movement.tokenId), bob);
        assertEq(IERC20(token0).balanceOf(alice) - alice0Before, refund0);
        assertEq(IERC20(token1).balanceOf(alice) - alice1Before, refund1);
        assertEq(IERC20(token0).balanceOf(address(liquidityManager)), 0);
        assertEq(IERC20(token1).balanceOf(address(liquidityManager)), 0);
        assertEq(IERC20(token0).allowance(address(liquidityManager), address(permit2Contract)), 0);
        assertEq(IERC20(token1).allowance(address(liquidityManager), address(permit2Contract)), 0);
    }

    function testUserPathRejectsInventoryNotPhysicallyReceived() public {
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        vm.expectRevert();
        liquidityManager.mintUserPosition(request, bob, alice);
        assertEq(positionManagerContract.nextTokenId(), 1);
    }

    function testUserPathRejectsZeroRecipientAndKeepsInventoryUnchanged() public {
        _transferUserInventory(6 ether, 6 ether);
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        vm.expectRevert(StaticsLiquidityManager.InvalidRecipient.selector);
        liquidityManager.mintUserPosition(request, address(0), alice);
        assertEq(positionManagerContract.nextTokenId(), 1);
    }

    function testUserPositionCannotBeTransferredIntoProtocolManagerCustody() public {
        _transferUserInventory(6 ether, 6 ether);
        (IStaticsLiquidityManager.PositionMovement memory movement,,) =
            liquidityManager.mintUserPosition(_request(5 ether, 6 ether, 6 ether), bob, alice);

        vm.prank(bob);
        vm.expectRevert();
        IERC721(address(positionManagerContract)).safeTransferFrom(bob, address(liquidityManager), movement.tokenId);

        assertEq(IERC721(address(positionManagerContract)).ownerOf(movement.tokenId), bob);
    }
}
