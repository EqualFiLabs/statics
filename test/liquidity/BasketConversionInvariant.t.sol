// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {BasketConversionTestBase} from "../helpers/BasketConversionTestBase.sol";

/// @notice Stateful interleaving uses the real PoolManager, production adapters and custody.
contract BasketConversionInvariantTest is BasketConversionTestBase {
    bytes private first;
    bytes private second;
    uint256 private donated;

    function setUp() public override {
        super.setUp();
        first = abi.encode(_fixture(false));
        second = abi.encode(_fixture(true));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = this.buy.selector;
        selectors[1] = this.sell.selector;
        selectors[2] = this.donate.selector;
        targetSelector(FuzzSelector(address(this), selectors));
        targetContract(address(this));
    }

    function buy(uint256 pick, uint256 amount, bool zap) external {
        Fixture memory f = abi.decode(pick % 2 == 0 ? first : second, (Fixture));
        amount = bound(amount, 0.01 ether, 5 ether);
        if (zap) {
            vm.prank(alice);
            conversionZap.buy(f.poolId, amount, alice, _request(f, true, false));
        } else {
            _trade(f, true, amount, false, false);
        }
    }

    function sell(uint256 pick, uint256 amount, bool zap) external {
        Fixture memory f = abi.decode(pick % 2 == 0 ? first : second, (Fixture));
        uint256 balance = IERC20(f.token).balanceOf(alice);
        if (balance < 0.01 ether) return;
        amount = bound(amount, 0.01 ether, balance);
        if (zap) {
            vm.prank(alice);
            conversionZap.sell(f.poolId, amount, alice, _request(f, false, false));
        } else {
            _trade(f, false, amount, true, false);
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1 ether);
        assetA.mint(address(conversionHook), amount);
        assetA.mint(address(conversionZap), amount);
        assetA.mint(address(diamond), amount);
        donated += amount;
    }

    function invariantSharedCustodyAndPoolIsolation() public view {
        _assertBacking(abi.decode(first, (Fixture)));
        _assertBacking(abi.decode(second, (Fixture)));
        assertEq(assetA.balanceOf(address(conversionHook)), donated, "hook consumes donations");
        assertEq(assetA.balanceOf(address(conversionZap)), donated, "zap consumes donations");
        assertGe(
            IERC20(address(assetA)).balanceOf(address(diamond)),
            IStaticsCustody(address(diamond)).globalReservedByToken(address(assetA))
        );
        assertGe(
            IERC20(address(assetB)).balanceOf(address(diamond)),
            IStaticsCustody(address(diamond)).globalReservedByToken(address(assetB))
        );
        assertGe(
            IERC20(quoteToken).balanceOf(address(diamond)),
            IStaticsCustody(address(diamond)).globalReservedByToken(quoteToken)
        );
        assertEq(IERC20(abi.decode(first, (Fixture)).token).balanceOf(address(conversionZap)), 0);
        assertEq(IERC20(abi.decode(second, (Fixture)).token).balanceOf(address(conversionZap)), 0);
    }
}
