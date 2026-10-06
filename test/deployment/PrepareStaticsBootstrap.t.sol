// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {PrepareStaticsBootstrap} from "../../script/PrepareStaticsBootstrap.s.sol";
import {BasketBootstrapFactory} from "../../src/bootstrap/BasketBootstrapFactory.sol";
import {StaticsAssetZap} from "../../src/periphery/StaticsAssetZap.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";

contract PrepareStaticsBootstrapTest is PreparedBasketTestBase {
    function testHelperBindsPeripheryToInstalledProtocolAndVerifiedWeth() public {
        WETH weth = new WETH();
        (BasketBootstrapFactory campaigns, StaticsAssetZap zap) =
            new PrepareStaticsBootstrap().deployPeriphery(address(diamond), address(weth), address(weth).codehash);
        assertEq(campaigns.diamond(), address(diamond));
        assertEq(zap.diamond(), address(diamond));
        assertEq(address(zap.poolManager()), address(poolManager));
        assertEq(address(zap.weth()), address(weth));
        assertEq(address(zap.campaignFactory()), address(campaigns));
    }

    function testHelperRejectsWrongWrappedNativeCommitmentBeforeDeployment() public {
        WETH weth = new WETH();
        PrepareStaticsBootstrap helper = new PrepareStaticsBootstrap();
        vm.expectRevert(PrepareStaticsBootstrap.InvalidBootstrapConfiguration.selector);
        helper.deployPeriphery(address(diamond), address(weth), bytes32(uint256(1)));
    }
}
