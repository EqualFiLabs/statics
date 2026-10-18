// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Disposable ordinary constituent used to exercise the sixteen-asset basket ceiling.
contract PhaseTwoRehearsalAsset is ERC20 {
    bool public frozen;
    error AssetFrozen();

    function freeze() external {
        frozen = true;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (frozen) revert AssetFrozen();
        return super.balanceOf(account);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (frozen) revert AssetFrozen();
        super._update(from, to, amount);
    }

    constructor(address receiver) ERC20("Phase Two Maximum Basket Asset", "P2MAX") {
        _mint(receiver, 1_000_000 ether);
    }
}

/// @dev Disposable fork actor. No privileged protocol storage access or cheatcodes.
contract PhaseTwoRehearsalActor {
    function execute(address target, bytes calldata data) external payable returns (bytes memory result) {
        bool success;
        (success, result) = target.call{value: msg.value}(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    receive() external payable {}
}

/// @dev Executed by the actual fork Safe using its normal delegatecall operation.
/// It has no storage writes and propagates a late failure to roll back every call.
contract PhaseTwoRehearsalBatch {
    function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads)
        external
        payable
    {
        require(targets.length == payloads.length && values.length == targets.length, "batch shape");
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory result) = targets[i].call{value: values[i]}(payloads[i]);
            if (!success) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }
}

/// @dev Real PoolManager swaps/liquidity and hostile boundary calls, driven by Cast.
contract PhaseTwoRehearsalRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    error OnlyManager();
    error RefundFailed();

    constructor(IPoolManager target) {
        manager = target;
    }

    function run(PoolKey calldata key, uint256 action, int256 amount, bool direction, uint160 limit) external payable {
        uint256 prior = address(this).balance - msg.value;
        manager.unlock(abi.encode(key, action, amount, direction, limit, msg.sender));
        if (action == 5) manager.unlock(abi.encode(key, uint256(4), int256(1), direction, limit, msg.sender));
        uint256 refund = address(this).balance - prior;
        if (refund != 0) {
            (bool success,) = msg.sender.call{value: refund}("");
            if (!success) revert RefundFailed();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (PoolKey memory key, uint256 action, int256 amount, bool direction, uint160 limit, address payer) =
            abi.decode(data, (PoolKey, uint256, int256, bool, uint160, address));
        if (action == 3) {
            Currency currency = direction ? key.currency0 : key.currency1;
            manager.burn(address(this), uint160(Currency.unwrap(currency)), uint256(amount));
            manager.take(currency, payer, uint256(amount));
            return "";
        }
        if (action == 4) {
            IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1)).transferFrom(payer, address(manager), 1);
            return "";
        }
        BalanceDelta delta;
        if (action == 0 || action == 5 || action == 6) {
            delta = manager.swap(key, SwapParams(direction, amount, limit), "");
        } else {
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, amount, bytes32(0)), "");
        }
        _settle(key.currency0, delta.amount0(), payer, action == 2 && direction);
        _settle(key.currency1, delta.amount1(), payer, action == 2 && !direction);
        if (action == 6) {
            IERC20(Currency.unwrap(direction ? key.currency0 : key.currency1)).transferFrom(payer, address(manager), 1);
        }
        return "";
    }

    function _settle(Currency currency, int128 delta, address payer, bool claim) private {
        if (delta > 0) {
            if (claim) manager.mint(address(this), uint160(Currency.unwrap(currency)), uint128(delta));
            else manager.take(currency, payer, uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint128(-delta);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
