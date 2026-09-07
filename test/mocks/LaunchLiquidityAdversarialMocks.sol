// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract AdversarialLaunchToken is IERC20 {
    enum Behavior {
        Exact,
        ShortReceipt,
        ExtraDebit,
        RevertTransfer,
        RevertZeroTransfer,
        Reenter
    }

    mapping(address account => uint256 amount) private balances;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;
    uint256 public override totalSupply;
    Behavior public behavior;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;

    string public name = "Adversarial Launch Token";
    string public symbol = "ALT";
    uint8 public decimals = 18;

    function setBehavior(Behavior next) external {
        behavior = next;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
        reentrySucceeded = false;
    }

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
        totalSupply += amount;
        emit Transfer(address(0), account, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        Behavior current = behavior;
        if (current == Behavior.RevertTransfer || (current == Behavior.RevertZeroTransfer && amount == 0)) revert();

        if (current == Behavior.Reenter && reentryTarget != address(0)) {
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }

        uint256 debit = current == Behavior.ExtraDebit && amount != 0 ? amount + 1 : amount;
        uint256 credit = current == Behavior.ShortReceipt && amount != 0 ? amount - 1 : amount;
        balances[from] -= debit;
        balances[to] += credit;
        totalSupply -= debit - credit;
        emit Transfer(from, to, credit);
    }
}

    contract AdversarialPoolManager {
        function take(Currency currency, address to, uint256 amount) external {
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }

        function callAfterInitialize(
            IHooks hook,
            address sender,
            PoolKey calldata key,
            uint160 sqrtPriceX96,
            int24 tick
        ) external returns (bytes4) {
            return hook.afterInitialize(sender, key, sqrtPriceX96, tick);
        }

        function callBeforeSwap(IHooks hook, PoolKey calldata key, SwapParams calldata params)
            external
            returns (bytes4, BeforeSwapDelta, uint24)
        {
            return hook.beforeSwap(address(this), key, params, "");
        }

        function callAfterSwap(IHooks hook, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
            external
            returns (bytes4, int128)
        {
            return hook.afterSwap(address(this), key, params, delta, "");
        }
    }

    contract AdversarialPositionManager {
        IPoolManager public immutable poolManager;

        constructor(IPoolManager manager) {
            poolManager = manager;
        }
    }
