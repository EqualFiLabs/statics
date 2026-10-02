// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";
import {LibPermissionedPools} from "../libraries/LibPermissionedPools.sol";

/// @notice Hook-only protocol swap-fee routing and pull-based creator revenue claims. The complete
/// non-POL distribution is pulled from the hook and reserved once under the shared fee account. Creator
/// credit is one liability within that reservation, tracked separately from basket-staker,
/// Statics-staker, and treasury liabilities.
contract ProtocolRevenueFacet is IStaticsProtocolRevenue, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    error OnlySwapFeeHook(address caller, address expected);
    error OnlyPoolCreator(address caller, address creator);
    error InvalidRewardAsset(PoolId poolId, address asset);
    error GeneralPoolBasketReward(PoolId poolId, uint256 amount);
    error IncompatibleRevenueAsset(address asset, uint256 expected, uint256 actual);
    error InvalidReceiver();
    error NoCreatorRevenue(address creator, address asset);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error UnsupportedCreatorPool(PoolId poolId);
    error InvalidPoolCreator(address creator);
    error OnlyPendingPoolCreator(address caller, address pendingCreator);
    error UnexpectedRevenueRecipient(address receiver, address expected);

    function proposePoolCreator(PoolId poolId, address newCreator) external nonReentrant {
        _enforceCreatorPool(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (msg.sender != creator) revert OnlyPoolCreator(msg.sender, creator);
        if (newCreator == creator || newCreator == address(this)) revert InvalidPoolCreator(newCreator);
        LibProtocolRevenue.ProtocolRevenueStorage storage rs = LibProtocolRevenue.protocolRevenueStorage();
        address previous = rs.pendingCreator[poolId];
        rs.pendingCreator[poolId] = newCreator;
        if (newCreator == address(0)) {
            emit PoolCreatorProposalCancelled(poolId, creator, previous);
        } else {
            emit PoolCreatorProposed(poolId, creator, newCreator);
        }
    }

    function acceptPoolCreator(PoolId poolId) external nonReentrant {
        IStaticsProtocolPools.ProtocolPoolKind kind = _enforceCreatorPool(poolId);
        LibProtocolRevenue.ProtocolRevenueStorage storage rs = LibProtocolRevenue.protocolRevenueStorage();
        address next = rs.pendingCreator[poolId];
        if (next == address(0) || msg.sender != next) revert OnlyPendingPoolCreator(msg.sender, next);
        address previous = LibProtocolPools.creatorOf(poolId);
        delete rs.pendingCreator[poolId];
        delete rs.revenueRecipient[poolId];
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.General) {
            LibProtocolPools.protocolPoolStorage().generalPools[poolId].creator = next;
        } else {
            LibPermissionedPools.PermissionedPool storage pool = LibPermissionedPools.enforceRegistered(poolId);
            pool.creator = next;
            // Invalidate old approvals even if authority later returns to the same address.
            uint256 previousNonce = pool.configurationNonce++;
            emit IStaticsPermissionedPools.PermissionedConfigurationNonceInvalidated(
                poolId, previousNonce, pool.configurationNonce
            );
        }
        emit PoolCreatorTransferred(poolId, previous, next);
        emit CreatorRevenueRecipientSet(poolId, next, next);
    }

    function setCreatorRevenueRecipient(PoolId poolId, address recipient) external nonReentrant {
        _enforceCreatorPool(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (msg.sender != creator) revert OnlyPoolCreator(msg.sender, creator);
        if (recipient == address(this)) revert InvalidReceiver();
        LibProtocolRevenue.protocolRevenueStorage().revenueRecipient[poolId] = recipient;
        emit CreatorRevenueRecipientSet(poolId, creator, recipient == address(0) ? creator : recipient);
    }

    function poolCreatorConfiguration(PoolId poolId)
        external
        view
        returns (address creator, address pendingCreator, address revenueRecipient)
    {
        _enforceCreatorPool(poolId);
        creator = LibProtocolPools.creatorOf(poolId);
        LibProtocolRevenue.ProtocolRevenueStorage storage rs = LibProtocolRevenue.protocolRevenueStorage();
        pendingCreator = rs.pendingCreator[poolId];
        revenueRecipient = _revenueRecipient(poolId, creator);
    }

    function _enforceCreatorPool(PoolId poolId) private view returns (IStaticsProtocolPools.ProtocolPoolKind kind) {
        (kind,,,) = LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral
        ) revert UnsupportedCreatorPool(poolId);
    }

    function _revenueRecipient(PoolId poolId, address creator) private view returns (address recipient) {
        recipient = LibProtocolRevenue.protocolRevenueStorage().revenueRecipient[poolId];
        if (recipient == address(0)) recipient = creator;
    }

    function routeProtocolSwapFees(PoolId poolId, address asset, ProtocolFeeDistribution calldata distribution)
        external
        nonReentrant
    {
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(poolId);
        address expectedHook = address(key.hooks);
        if (msg.sender != expectedHook) revert OnlySwapFeeHook(msg.sender, expectedHook);
        uint256 total =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        if (total == 0) return;
        uint256 received = LibCustody.pull(asset, msg.sender, total);
        if (received != total) revert IncompatibleRevenueAsset(asset, total, received);
        LibProtocolRevenue.accrueReceived(poolId, asset, distribution);
    }

    function claimCreatorRevenue(PoolId poolId, address asset, address receiver, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 amount, uint256 received)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.enforceRegistered(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
            if (msg.sender != creator) revert OnlyPoolCreator(msg.sender, creator);
        } else {
            address expected = _revenueRecipient(poolId, creator);
            if (receiver != expected) revert UnexpectedRevenueRecipient(receiver, expected);
        }
        amount = LibProtocolRevenue.clear(poolId, asset);
        if (amount == 0) revert NoCreatorRevenue(creator, asset);
        (, received) = LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
        if (received < minReceived) revert MinimumOutputNotMet(asset, received, minReceived);
        emit CreatorRevenueClaimed(poolId, creator, asset, receiver, amount, received);
    }

    function creatorRevenue(PoolId poolId, address asset) external view returns (uint256 amount) {
        LibProtocolPools.enforceRegistered(poolId);
        return LibProtocolRevenue.creditOf(poolId, asset);
    }

    function totalCreatorRevenue(address asset) external view returns (uint256 amount) {
        return LibProtocolRevenue.totalOf(asset);
    }

    function canAccrueBasketRewards(PoolId poolId) external view returns (bool eligible) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,, uint256 basketId,) = LibProtocolPools.resolve(poolId);
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) return false;
        return LibBasketRewards.canAccrue(basketId);
    }

    function protocolPolFundingConfig(PoolId poolId)
        external
        view
        returns (bool activated, bool overridden, uint16 shareBps)
    {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.enforceRegistered(poolId);
        LibProtocolPools.PolFundingConfig storage config = LibProtocolPools.protocolPoolStorage().polFunding[poolId];
        activated = kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical || config.activated;
        overridden = config.overrideSet;
        shareBps = config.shareBps;
    }
}
