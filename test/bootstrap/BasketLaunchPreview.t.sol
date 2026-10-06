// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibBasketLaunchMath} from "../../src/libraries/LibBasketLaunchMath.sol";
import {LibBasketDeployment} from "../../src/libraries/LibBasketDeployment.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BasketLaunchPreviewTest is PreparedBasketTestBase {
    function testExactPreviewMatchesActualLaunchAcrossDecimalsAndSpacing() public {
        _previewAndLaunch(1, 6);
        _previewAndLaunch(60, 18);
        _previewAndLaunch(200, 8);
    }

    function _prepare(
        IStaticsBasket.CreateBasketParams memory params,
        IStaticsBasket.PoolLaunchParams[] memory pools,
        uint256[] memory maximums
    ) private returns (bytes32 id, address token) {
        StaticsBasketFactory.Intent memory intent = StaticsBasketFactory.Intent(
            alice,
            alice,
            preparation.basketCreationConfigurationHash(params, pools, maximums, type(uint256).max),
            type(uint256).max,
            1
        );
        uint256[] memory nonces = new uint256[](pools.length);
        uint256 start;
        for (uint256 i; i < pools.length; ++i) {
            (nonces[i],) = _minePreparedTestHook(factory, intent, start);
            start = nonces[i] + 1;
        }
        vm.prank(alice);
        return preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, 0, nonces);
    }

    function _previewAndLaunch(int24 spacing, uint8 decimals) private {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        MockERC20 asset = new MockERC20("Decimal asset", "DEC", decimals);
        params.assets[0] = address(asset);
        params.bundleAmounts[0] = 10 ** decimals + 7;
        params.mintFeeTiers[0].feeShares = 12345678901234567;
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        pools[0].tickSpacing = spacing;
        pools[1].tickSpacing = spacing;
        (bytes32 id, address predicted) = _prepare(params, pools, maximums);
        (, LibBasketLaunchMath.Requirements memory requirement) =
            preparation.previewBasketLaunch(id, params, pools, maximums, type(uint256).max);
        uint256[] memory beforeBalances = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            beforeBalances[i] = IERC20(params.assets[i]).balanceOf(alice);
        }
        vm.prank(alice);
        (uint256 basketId, address token) = baskets.createBasketPrepared{value: requirement.nativeCreationFee}(
            params, pools, maximums, type(uint256).max, id
        );
        assertEq(token, predicted);
        assertEq(IERC20(token).totalSupply(), requirement.basketShares);
        _assertLaunch(params.assets, basketId, spacing, beforeBalances, requirement);
    }

    function _assertLaunch(
        address[] memory assets,
        uint256 basketId,
        int24 spacing,
        uint256[] memory beforeBalances,
        LibBasketLaunchMath.Requirements memory requirement
    ) private view {
        for (uint256 i; i < 2; ++i) {
            assertEq(beforeBalances[i] - IERC20(assets[i]).balanceOf(alice), requirement.totalAmounts[i]);
            assertEq(baskets.vaultBalance(basketId, assets[i]), requirement.backing[i]);
            assertEq(basketLiquidity.canonicalPool(basketId, assets[i]).tickSpacing, spacing);
            assertEq(
                IStaticsProtocolPools(address(diamond))
                .protocolPool(basketLiquidity.canonicalPool(basketId, assets[i]).poolId)
                .activePolPositions,
                1
            );
        }
    }

    function testPreviewRejectsChangedCommittedConfiguration() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        (bytes32 id,) = _prepare(params, pools, maximums);
        pools[0].tickSpacing = 60;
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        preparation.previewBasketLaunch(id, params, pools, maximums, type(uint256).max);
    }
}
