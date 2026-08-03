// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract StaticsLiquidityManagerTest is LiquidityManagerTestBase {
    function testOnlyDiamondCanRegisterOrOperate() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.registerCanonicalPool(999, address(assetA), canonicalKey);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.mintUserPosition(_request(1 ether, 2 ether, 2 ether), bob, bob);
        vm.stopPrank();
    }

    function testCanonicalPoolRegistrationCannotBeRepeated() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.CanonicalPoolAlreadyRegistered.selector, basketId, address(assetA)
            )
        );
        liquidityManager.registerCanonicalPool(basketId, address(assetA), canonicalKey);
    }

    function testCanonicalKeyCannotBeSubstituted() public {
        _transferUserInventory(6 ether, 6 ether);
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        request.poolKey.fee = 3_000;

        vm.expectPartialRevert(StaticsLiquidityManager.CanonicalPoolMismatch.selector);
        liquidityManager.mintUserPosition(request, bob, alice);

        assertEq(IERC20(Currency.unwrap(canonicalKey.currency0)).balanceOf(address(liquidityManager)), 6 ether);
        assertEq(IERC20(Currency.unwrap(canonicalKey.currency1)).balanceOf(address(liquidityManager)), 6 ether);
    }
}
