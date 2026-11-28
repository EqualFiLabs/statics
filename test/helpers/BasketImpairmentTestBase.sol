// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {MockImpairableERC20} from "../mocks/MockImpairableERC20.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";

abstract contract BasketImpairmentTestBase is StaticsTestBase {
    IStaticsBasketImpairment internal impairment;
    MockImpairableERC20 internal bad;
    uint256 internal id;
    address internal token;

    function setUp() public virtual override {
        super.setUp();
        bad = new MockImpairableERC20();
        assetB = bad;
        impairment = IStaticsBasketImpairment(address(diamond));
        (id, token) = _createDefaultBasket(0, 0);
        _mintTestShares(id, 10 ether);
    }

    function _mintTestShares(uint256 basketId, uint256 shares) internal {
        uint256[] memory amounts = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, amounts[0], amounts[1]);
        vm.prank(alice);
        baskets.mint(basketId, shares, alice, amounts);
    }

    function _impair() internal {
        impairment.markBasketAssetImpaired(id, address(bad));
        bad.setFailures(true, true);
    }
}
