// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StaticsLaunchLiquidityHook} from "../../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract FormalLaunchToken is IERC20 {
    mapping(address account => uint256 amount) private balances;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;
    uint256 public override totalSupply;

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
        totalSupply += amount;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }
}

    contract FormalLaunchAccessController {
        bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

        mapping(address account => bool enabled) private proposers;

        function setProposer(address account, bool enabled) external {
            proposers[account] = enabled;
        }

        function hasRole(bytes32 role, address account) external view returns (bool) {
            return role == PROPOSER_ROLE && proposers[account];
        }
    }

    contract FormalLaunchPoolManager {
        mapping(address owner => mapping(uint256 id => uint256 amount)) public balanceOf;
        address public lastMintReceiver;
        uint256 public lastMintId;
        uint256 public lastMintAmount;
        uint256 public mintCount;

        function take(Currency currency, address to, uint256 amount) external {
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }

        function mint(address to, uint256 id, uint256 amount) external {
            balanceOf[to][id] += amount;
            lastMintReceiver = to;
            lastMintId = id;
            lastMintAmount = amount;
            mintCount++;
        }

        function callAfterInitialize(IHooks hook, address sender, PoolKey calldata key, uint160 sqrtPriceX96)
            external
            returns (bytes4)
        {
            return hook.afterInitialize(sender, key, sqrtPriceX96, 0);
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

        function callSwapHooks(IHooks hook, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
            external
        {
            hook.beforeSwap(address(this), key, params, "");
            hook.afterSwap(address(this), key, params, delta, "");
        }
    }

    contract FormalLaunchPositionManager {
        IPoolManager public immutable poolManager;

        constructor(IPoolManager manager) {
            poolManager = manager;
        }
    }

    contract FormalStaticsLaunchLiquidityHook is StaticsLaunchLiquidityHook {
        constructor(IPoolManager manager, IPositionManager positionManager_, address initialOwner, address receiver)
            StaticsLaunchLiquidityHook(manager, positionManager_, initialOwner, receiver)
        {}

        /// @dev Symbolic tests exercise hook behavior without constraining the CREATE address bits.
        function validateHookAddress(BaseHook) internal pure override {}
    }
