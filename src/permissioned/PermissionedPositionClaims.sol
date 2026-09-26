// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IVenueController} from "../interfaces/IVenueController.sol";

interface IPermissionedPositionManagerClaims {
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory key, PositionInfo info);
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function executeForceUnwind(uint256 tokenId, bytes calldata unlockData) external;
}

/// @notice PoolManager-claim-backed owner credits for permissioned forced-unwind proceeds.
contract PermissionedPositionClaims is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint8 private constant DEPOSIT = 1;
    uint8 private constant WITHDRAW = 2;
    uint256 private constant LIQUIDITY_ALLOWED = 1 << 1;

    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    IStaticsPermissionedSwapFeeHook public immutable permissionedHook;

    mapping(PoolId poolId => mapping(address owner => mapping(Currency currency => uint256 amount))) private credits;

    error OnlyVenueOperator(address caller, address operator);
    error PoolNotHalted(PoolId poolId);
    error InvalidPermissionedPool(address hook);
    error OnlyPoolManager(address caller);
    error InvalidReceiver(address receiver);
    error InsufficientCredit(uint256 requested, uint256 available);
    error ReceiverNotEligible(PoolId poolId, address receiver);
    error IncompatibleTokenTransfer(Currency currency, uint256 expected, uint256 observed);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 observed);
    error InvalidUnlockAction(uint8 action);

    event PositionProceedsCredited(
        PoolId indexed poolId, address indexed owner, Currency indexed currency, uint256 amount
    );
    event PositionProceedsClaimed(
        PoolId indexed poolId, address indexed owner, Currency indexed currency, address receiver, uint256 amount
    );

    constructor(IPoolManager manager, address positionManager_, IStaticsPermissionedSwapFeeHook hook) {
        poolManager = manager;
        positionManager = positionManager_;
        permissionedHook = hook;
    }

    /// @notice Closes a position after its venue operator has halted the pool.
    /// @dev Every nonzero payout becomes owner-bound credit so recipient execution cannot veto forced cleanup.
    function forceUnwind(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        nonReentrant
    {
        IPermissionedPositionManagerClaims manager = IPermissionedPositionManagerClaims(positionManager);
        (PoolKey memory key,) = manager.getPoolAndPositionInfo(tokenId);
        if (address(key.hooks) != address(permissionedHook)) revert InvalidPermissionedPool(address(key.hooks));
        PoolId poolId = key.toId();
        _enforceForceUnwind(poolId, msg.sender);

        address owner = manager.ownerOf(tokenId);
        uint256 balance0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        manager.executeForceUnwind(tokenId, abi.encode(actions, params));

        uint256 amount0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)) - balance0Before;
        uint256 amount1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) - balance1Before;
        _creditProceeds(poolId, owner, key.currency0, amount0);
        _creditProceeds(poolId, owner, key.currency1, amount1);
    }

    function _enforceForceUnwind(PoolId poolId, address caller) private view {
        IStaticsPermissionedSwapFeeHook.PoolRegistration memory registration = permissionedHook.poolRegistration(poolId);
        IVenueController controller = IVenueController(registration.controller);
        address operator = controller.operator();
        if (caller != operator) revert OnlyVenueOperator(caller, operator);
        if (controller.poolStatus(poolId) != IVenueController.TradingStatus.Halted) revert PoolNotHalted(poolId);
    }

    function _creditProceeds(PoolId poolId, address owner, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.unlock(abi.encode(DEPOSIT, poolId, owner, currency, amount));
    }

    function claim(PoolId poolId, Currency currency, address receiver, uint256 amount) external nonReentrant {
        if (receiver == address(0)) revert InvalidReceiver(receiver);
        uint256 available = credits[poolId][msg.sender][currency];
        if (amount == 0 || amount > available) revert InsufficientCredit(amount, available);
        IStaticsPermissionedSwapFeeHook.PoolRegistration memory registration = permissionedHook.poolRegistration(poolId);
        if (
            receiver != msg.sender
                && IVenueController(registration.controller).permissions(poolId, receiver) & LIQUIDITY_ALLOWED == 0
        ) revert ReceiverNotEligible(poolId, receiver);
        credits[poolId][msg.sender][currency] = available - amount;
        poolManager.unlock(abi.encode(WITHDRAW, poolId, msg.sender, currency, receiver, amount));
    }

    function creditOf(PoolId poolId, address owner, Currency currency) external view returns (uint256 amount) {
        return credits[poolId][owner][currency];
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
        uint8 action = abi.decode(data, (uint8));
        if (action == DEPOSIT) {
            (, PoolId poolId, address owner, Currency currency, uint256 amount) =
                abi.decode(data, (uint8, PoolId, address, Currency, uint256));
            _depositClaims(poolId, owner, currency, amount);
            return "";
        }
        if (action == WITHDRAW) {
            (, PoolId poolId, address owner, Currency currency, address receiver, uint256 amount) =
                abi.decode(data, (uint8, PoolId, address, Currency, address, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, receiver, amount);
            emit PositionProceedsClaimed(poolId, owner, currency, receiver, amount);
            return "";
        }
        revert InvalidUnlockAction(action);
    }

    function _depositClaims(PoolId poolId, address owner, Currency currency, uint256 amount) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 managerBefore = token.balanceOf(address(poolManager));
        poolManager.sync(currency);
        token.safeTransfer(address(poolManager), amount);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 managerAfter = token.balanceOf(address(poolManager));
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = managerAfter >= managerBefore ? managerAfter - managerBefore : 0;
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(currency, amount, received);
        poolManager.mint(address(this), currency.toId(), amount);
        credits[poolId][owner][currency] += amount;
        emit PositionProceedsCredited(poolId, owner, currency, amount);
    }
}
