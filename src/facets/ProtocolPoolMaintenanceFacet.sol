// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibPoolRewards} from "../libraries/LibPoolRewards.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

/// @notice Permissionless, treasury-tipped revenue settlement for public protocol pools.
contract ProtocolPoolMaintenanceFacet is ReentrancyGuard {
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 observed);
    error InvalidMaintenanceConfig();
    error ActionPaused(uint256 action);
    error PublicProtocolPoolRequired(PoolId poolId);

    function setProtocolPoolMaintenanceConfig(IStaticsProtocolPools.ProtocolPoolMaintenanceConfig calldata config)
        external
    {
        LibDiamond.enforceIsContractOwner();
        if (config.revenueTipBps > LibProtocolPoolFee.MAX_REVENUE_TIP_BPS) revert InvalidMaintenanceConfig();

        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        ps.revenueTipBps = config.revenueTipBps;
        emit IStaticsProtocolPools.ProtocolPoolMaintenanceConfigSet(config.revenueTipBps);
    }

    function settleProtocolPoolRevenue(PoolId poolId, address asset)
        external
        nonReentrant
        returns (uint256 grossAmount, uint256 callerTip)
    {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_TREASURY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_TREASURY);
        }
        (, PoolKey memory key,,) = _enforcePublicProtocolPool(poolId);
        Currency currency = asset == Currency.unwrap(key.currency0) ? key.currency0 : key.currency1;
        if (asset != Currency.unwrap(currency)) revert LibProtocolRevenue.InvalidRewardAsset(poolId, asset);

        (IStaticsSwapFeeHook.FeeDistribution memory distribution, address rewardAsset) =
            LibPoolRewards.settleDistribution(key, currency);
        grossAmount = _distributionTotal(distribution);
        callerTip = Math.mulDiv(distribution.treasury, LibProtocolPools.protocolPoolStorage().revenueTipBps, 10_000);
        if (callerTip != 0) {
            distribution.treasury -= callerTip;
            _pushExactUnreserved(rewardAsset, msg.sender, callerTip);
        }
        _accrueDistribution(poolId, rewardAsset, distribution);
        emit IStaticsProtocolPools.ProtocolPoolRevenueSettled(poolId, asset, msg.sender, grossAmount, callerTip);
    }

    function _accrueDistribution(PoolId poolId, address token, IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
    {
        LibProtocolRevenue.accrueReceived(
            poolId,
            token,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                basketStaker: distribution.basketStaker,
                staticsStaker: distribution.staticsStaker,
                creator: distribution.creator,
                treasury: distribution.treasury
            })
        );
    }

    function _distributionTotal(IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
        pure
        returns (uint256)
    {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }

    function _pushExactUnreserved(address token, address receiver, uint256 amount) private {
        if (amount == 0) return;
        (uint256 spent, uint256 received) = LibCustody.pushUnreserved(token, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }

    function _enforcePublicProtocolPool(PoolId poolId)
        private
        view
        returns (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset)
    {
        (kind, key, basketId, basketAsset) = LibProtocolPools.enforceRegistered(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral) {
            revert PublicProtocolPoolRequired(poolId);
        }
    }
}
