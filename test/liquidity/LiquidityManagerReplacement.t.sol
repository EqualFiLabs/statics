// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {ProtocolPoolFacet} from "../../src/facets/ProtocolPoolFacet.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract LiquidityManagerReplacementTest is BorrowLiquidityTestBase {
    IStaticsProtocolPools private protocolPools;

    function setUp() public override {
        super.setUp();
        protocolPools = IStaticsProtocolPools(address(diamond));
    }

    function testOwnerReplacesManagerAndRotatesPositionOperatorApproval() public {
        StaticsLiquidityManager replacement = _replacement(address(diamond));
        assertTrue(
            IERC721(address(positionManagerContract))
                .isApprovedForAll(address(diamond), address(liquidityManagerContract))
        );
        assertFalse(IERC721(address(positionManagerContract)).isApprovedForAll(address(diamond), address(replacement)));

        protocolPools.replaceLiquidityManager(address(replacement));

        (address installed, bool configured) = IStaticsBasketLiquidity(address(diamond)).liquidityManager();
        assertTrue(configured);
        assertEq(installed, address(replacement));
        assertFalse(
            IERC721(address(positionManagerContract))
                .isApprovedForAll(address(diamond), address(liquidityManagerContract))
        );
        assertTrue(IERC721(address(positionManagerContract)).isApprovedForAll(address(diamond), address(replacement)));
    }

    function testReplacementRejectsMismatchedImmutableBindingWithoutChangingApproval() public {
        address wrongDiamond = makeAddr("wrongDiamond");
        StaticsLiquidityManager replacement = _replacement(wrongDiamond);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolFacet.LiquidityManagerBindingMismatch.selector,
                address(replacement),
                address(diamond),
                wrongDiamond
            )
        );
        protocolPools.replaceLiquidityManager(address(replacement));

        (address installed,) = IStaticsBasketLiquidity(address(diamond)).liquidityManager();
        assertEq(installed, address(liquidityManagerContract));
        assertTrue(
            IERC721(address(positionManagerContract))
                .isApprovedForAll(address(diamond), address(liquidityManagerContract))
        );
        assertFalse(IERC721(address(positionManagerContract)).isApprovedForAll(address(diamond), address(replacement)));
    }

    function testNonOwnerCannotReplaceManager() public {
        StaticsLiquidityManager replacement = _replacement(address(diamond));
        vm.prank(bob);
        vm.expectRevert();
        protocolPools.replaceLiquidityManager(address(replacement));
    }

    function _replacement(address boundDiamond) private returns (StaticsLiquidityManager manager) {
        manager = new StaticsLiquidityManager(
            boundDiamond, address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
    }
}
