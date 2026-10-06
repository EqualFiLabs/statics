// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract StaticsLiquidityManagerTest is LiquidityManagerTestBase {
    function testOnlyDiamondCanOperate() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.mintUserPosition(_request(1 ether, 2 ether, 2 ether), bob, bob);
        vm.stopPrank();
    }

    function testCanonicalKeyCannotBeSubstituted() public {
        _mintManagerInventory(6 ether, 6 ether);
        uint256 basketBefore = IERC20(basketToken).balanceOf(address(diamond));
        uint256 assetBefore = assetA.balanceOf(address(diamond));
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        request.poolKey.fee = 500;

        vm.expectPartialRevert(StaticsLiquidityManager.ProtocolPoolNotRegistered.selector);
        _mintUserPosition(request, bob, alice);

        assertEq(IERC20(basketToken).balanceOf(address(diamond)), basketBefore);
        assertEq(assetA.balanceOf(address(diamond)), assetBefore);
    }
}
