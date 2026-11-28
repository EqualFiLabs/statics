// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";

/// @dev Models a compromised authorized adapter to exercise the Diamond's independent arrival checks.
contract ConversionDeliveryProbe {
    using SafeERC20 for IERC20;
    IStaticsBasket private immutable core;
    IPoolManager private immutable pm;
    uint256 private mode;
    bool public blockedReentry;

    constructor(IStaticsBasket core_, IPoolManager pm_) {
        core = core_;
        pm = pm_;
    }

    // 0 exact, 1 no arrival, 2 short arrival, 3 excess, 4 stale quote, 5 reentry, 6 reused arrival.
    function execute(PoolId id, uint256 shares, address receiver, uint256 mode_) external {
        pm.unlock(abi.encode(id, shares, receiver, mode_));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (PoolId id, uint256 shares, address receiver, uint256 selected) =
            abi.decode(data, (PoolId, uint256, address, uint256));
        mode = selected;
        IStaticsBasketConversion conversion = IStaticsBasketConversion(address(core));
        uint256 basketId = conversion.basketConversionMarket(id).basketId;
        uint256[] memory amounts = core.quoteMint(basketId, shares);
        if (mode == 4) amounts[0] += 1;
        conversion.mintBasketConversion(id, shares, receiver, amounts);
        if (mode == 6) {
            mode = 1;
            conversion.mintBasketConversion(id, shares, receiver, core.quoteMint(basketId, shares));
        }
        address[] memory assets = core.basket(basketId).assets;
        for (uint256 i; i < assets.length; ++i) {
            pm.sync(Currency.wrap(assets[i]));
            IERC20(assets[i]).safeTransfer(address(pm), amounts[i]);
            require(pm.settle() == amounts[i]);
        }
        return "";
    }

    function deliverBasketConversion(
        PoolId id,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata amounts
    ) external {
        require(msg.sender == address(core));
        if (mode == 1) return;
        if (mode == 5) {
            _expectSharedGuard(
                abi.encodeCall(IStaticsBasketConversion.mintBasketConversion, (id, shares, receiver, amounts))
            );
            _expectSharedGuard(abi.encodeCall(IStaticsBasket.mint, (basketId, shares, receiver, amounts)));
            _expectSharedGuard(abi.encodeCall(IStaticsBasket.redeem, (basketId, shares, receiver, amounts)));
            blockedReentry = true;
        }
        address[] memory assets = core.basket(basketId).assets;
        for (uint256 i; i < assets.length; ++i) {
            uint256 amount = amounts[i];
            if (i == 0 && mode == 2) amount -= 1;
            if (i == 0 && mode == 3) amount += 1;
            pm.take(Currency.wrap(assets[i]), address(core), amount);
        }
    }

    function _expectSharedGuard(bytes memory data) private {
        (bool ok, bytes memory reason) = address(core).call(data);
        require(!ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}
