// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IStaticsHookController, RevenueChannel} from "../interfaces/IStaticsHookController.sol";
import {IStaticsV4Hook} from "../interfaces/IStaticsV4Hook.sol";

/// @notice Permanent standalone authority and pull-based fee-liability ledger for the Statics launch hook.
contract StaticsHookController is IStaticsHookController, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    address public override hook;
    address public hookBinder;
    IPoolManager public poolManager;
    mapping(
        PoolId poolId => mapping(Currency currency => mapping(RevenueChannel channel => mapping(address => uint256)))
    ) private liabilities;
    mapping(Currency currency => uint256 amount) private totalLiabilities;

    error InvalidHook();
    error InvalidHookBinder();
    error HookAlreadyBound();
    error OnlyHook(address caller);
    error InvalidRecipient();
    error EmptyClaim();
    error RevenueInsolvent(Currency currency, uint256 available, uint256 required);
    error InvalidUnlockCaller(address caller);
    error IncompatibleClaimTransfer(Currency currency, uint256 expected, uint256 actual);

    constructor(address initialOwner, address hookBinder_) Ownable(initialOwner) {
        if (hookBinder_ == address(0)) revert InvalidHookBinder();
        hookBinder = hookBinder_;
    }

    function bindHook(address hook_) external override {
        if (msg.sender != hookBinder) revert InvalidHookBinder();
        if (hook != address(0)) revert HookAlreadyBound();
        if (hook_ == address(0) || hook_.code.length == 0) revert InvalidHook();
        address reportedController;
        try IStaticsV4Hook(hook_).controller() returns (address controller_) {
            reportedController = controller_;
        } catch {
            revert InvalidHook();
        }
        if (reportedController != address(this)) revert InvalidHook();
        IPoolManager manager = IStaticsV4HookManager(hook_).poolManager();
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidHook();
        hook = hook_;
        delete hookBinder;
        poolManager = manager;
        emit HookBound(hook_);
    }

    function accrueRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address recipient, uint256 amount)
        external
        override
    {
        _enforceHook();
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) return;
        liabilities[poolId][currency][channel][recipient] += amount;
        totalLiabilities[currency] += amount;
        _enforceSolvency(currency);
        emit RevenueAccrued(poolId, currency, channel, recipient, amount);
    }

    function claimRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address receiver)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (receiver == address(0)) revert InvalidRecipient();
        amount = liabilities[poolId][currency][channel][msg.sender];
        if (amount == 0) revert EmptyClaim();
        liabilities[poolId][currency][channel][msg.sender] = 0;
        totalLiabilities[currency] -= amount;
        poolManager.unlock(abi.encode(currency, receiver, amount));
        _enforceSolvency(currency);
        emit RevenueClaimed(poolId, currency, channel, msg.sender, receiver, amount);
    }

    function claimableRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address recipient)
        external
        view
        override
        returns (uint256 amount)
    {
        return liabilities[poolId][currency][channel][recipient];
    }

    function totalRevenueLiability(Currency currency) external view override returns (uint256 amount) {
        return totalLiabilities[currency];
    }

    function configurePool(
        PoolId poolId,
        IStaticsV4Hook.FeeConfiguration calldata fees,
        IStaticsV4Hook.RevenueRecipients calldata recipients
    ) external onlyOwner {
        IStaticsV4Hook(_boundHook()).setPoolConfiguration(poolId, fees, recipients);
    }

    function registerPool(
        PoolKey calldata key,
        uint160 expectedSqrtPriceX96,
        address initializer,
        IStaticsV4Hook.FeeConfiguration calldata fees,
        IStaticsV4Hook.RevenueRecipients calldata recipients
    ) external onlyOwner returns (PoolId poolId) {
        poolId = IStaticsV4Hook(_boundHook()).registerPool(key, expectedSqrtPriceX96, initializer, fees, recipients);
    }

    function activateExternalLiquidity(
        PoolId poolId,
        IStaticsV4Hook.FeeConfiguration calldata fees,
        IStaticsV4Hook.RevenueRecipients calldata recipients
    ) external onlyOwner {
        IStaticsV4Hook(_boundHook()).activateExternalLiquidity(poolId, fees, recipients);
    }

    function initializeCanonicalPool() external onlyOwner nonReentrant returns (PoolId poolId) {
        IStaticsV4Hook hook_ = IStaticsV4Hook(_boundHook());
        IStaticsV4Hook.PoolConfigurationView memory configuration = hook_.poolConfiguration(hook_.canonicalPoolId());
        poolId = hook_.canonicalPoolId();
        IPoolManager(IStaticsV4HookManager(address(hook_)).poolManager())
            .initialize(hook_.canonicalPoolKey(), configuration.expectedSqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (Currency currency, address receiver, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        uint256 receiverBefore = currency.balanceOf(receiver);
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, receiver, amount);
        uint256 receiverAfter = currency.balanceOf(receiver);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatibleClaimTransfer(currency, amount, received);
        return "";
    }

    function _boundHook() private view returns (address hook_) {
        hook_ = hook;
        if (hook_ == address(0)) revert InvalidHook();
    }

    function _enforceHook() private view {
        if (msg.sender != hook) revert OnlyHook(msg.sender);
    }

    function _enforceSolvency(Currency currency) private view {
        uint256 available = poolManager.balanceOf(address(this), currency.toId());
        uint256 required = totalLiabilities[currency];
        if (available < required) revert RevenueInsolvent(currency, available, required);
    }
}

    interface IStaticsV4HookManager {
        function poolManager() external view returns (IPoolManager);
    }
