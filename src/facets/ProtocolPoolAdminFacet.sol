// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

/// @notice Owner-only administration of protocol-pool creation fee, PoolId-local fee rate, global
/// basket/general allocation profiles, general-pool decommissioning, and liquidity-manager replacement.
contract ProtocolPoolAdminFacet is ReentrancyGuard {
    using StateLibrary for IPoolManager;

    error LiquidityIntegrationNotInstalled();
    error PoolAlreadyDecommissioned(PoolId poolId);
    error PoolNotDecommissioned(PoolId poolId);
    error PoolDecommissionAlreadyFinalized(PoolId poolId);
    error ActiveProtocolPolPositions(PoolId poolId, uint256 count);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 observed);
    error InvalidLiquidityManager(address manager);
    error LiquidityManagerBindingMismatch(address manager, address expected, address actual);
    error LiquidityManagerUnchanged(address manager);
    error PublicProtocolPoolRequired(PoolId poolId);

    function setPoolCreationFee(uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount = amount;
        emit IStaticsProtocolPools.PoolCreationFeeSet(amount);
    }

    function setDefaultProtocolPoolFeeRate(IStaticsProtocolPools.PoolSwapFeeRate calldata feeRate) external {
        LibDiamond.enforceIsContractOwner();
        IStaticsSwapFeeHook(_liquidityStorage().hook).setDefaultFeeRate(feeRate.inputFeeBps, feeRate.outputFeeBps);
        emit IStaticsProtocolPools.DefaultProtocolPoolFeeRateSet(feeRate.inputFeeBps, feeRate.outputFeeBps);
    }

    function setProtocolPoolFeeRate(PoolId poolId, IStaticsProtocolPools.PoolSwapFeeRate calldata feeRate) external {
        LibDiamond.enforceIsContractOwner();
        _enforcePublicProtocolPool(poolId);
        IStaticsSwapFeeHook(LibProtocolPools.publicHook(poolId))
            .setPoolFeeRate(poolId, feeRate.inputFeeBps, feeRate.outputFeeBps);
        emit IStaticsProtocolPools.ProtocolPoolFeeRateSet(poolId, feeRate.inputFeeBps, feeRate.outputFeeBps);
    }

    function clearProtocolPoolFeeRate(PoolId poolId) external {
        LibDiamond.enforceIsContractOwner();
        _enforcePublicProtocolPool(poolId);
        IStaticsSwapFeeHook(LibProtocolPools.publicHook(poolId)).clearPoolFeeRate(poolId);
        emit IStaticsProtocolPools.ProtocolPoolFeeRateCleared(poolId);
    }

    function setBasketFeeAllocation(IStaticsProtocolPools.BasketFeeAllocation calldata allocation) external {
        LibDiamond.enforceIsContractOwner();
        IStaticsSwapFeeHook(_liquidityStorage().hook)
            .setBasketFeeAllocation(
                IStaticsSwapFeeHook.BasketFeeAllocation({
                    polShareBps: allocation.polShareBps,
                    basketStakerShareBps: allocation.basketStakerShareBps,
                    staticsStakerShareBps: allocation.staticsStakerShareBps,
                    treasuryShareBps: allocation.treasuryShareBps
                })
            );
        emit IStaticsProtocolPools.BasketFeeAllocationSet(
            allocation.polShareBps,
            allocation.basketStakerShareBps,
            allocation.staticsStakerShareBps,
            allocation.treasuryShareBps
        );
    }

    function setGeneralFeeAllocation(IStaticsProtocolPools.GeneralFeeAllocation calldata allocation) external {
        LibDiamond.enforceIsContractOwner();
        IStaticsSwapFeeHook(_liquidityStorage().hook)
            .setGeneralFeeAllocation(
                IStaticsSwapFeeHook.GeneralFeeAllocation({
                    polShareBps: allocation.polShareBps,
                    staticsStakerShareBps: allocation.staticsStakerShareBps,
                    treasuryShareBps: allocation.treasuryShareBps
                })
            );
        emit IStaticsProtocolPools.GeneralFeeAllocationSet(
            allocation.polShareBps, allocation.staticsStakerShareBps, allocation.treasuryShareBps
        );
    }

    function beginGeneralPoolDecommission(PoolId poolId) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.GeneralPool storage stored = LibProtocolPools.generalPool(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolDecommissioned(poolId)) revert PoolAlreadyDecommissioned(poolId);
        _stopRangeGauge(ls, stored.key, poolId);
        hook.decommissionPool(stored.key);
        emit IStaticsProtocolPools.GeneralPoolDecommissionStarted(poolId);
    }

    function finalizeGeneralPoolDecommission(PoolId poolId)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.GeneralPool storage stored = LibProtocolPools.generalPool(poolId);
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(_liquidityStorage().hook);
        if (!hook.poolDecommissioned(poolId)) revert PoolNotDecommissioned(poolId);
        if (ps.polDecommissionFinalized[poolId]) revert PoolDecommissionAlreadyFinalized(poolId);
        uint256 activePositions = ps.activePolPositionCount[poolId];
        if (activePositions != 0) revert ActiveProtocolPolPositions(poolId, activePositions);

        _settleDecommissionAsset(hook, stored.key, poolId, stored.key.currency0);
        _settleDecommissionAsset(hook, stored.key, poolId, stored.key.currency1);
        bytes32 polAccount = LibCustody.protocolPolAccount(PoolId.unwrap(poolId));
        address currency0 = Currency.unwrap(stored.key.currency0);
        address currency1 = Currency.unwrap(stored.key.currency1);
        amount0 = LibCustody.accountReserved(polAccount, currency0);
        amount1 = LibCustody.accountReserved(polAccount, currency1);
        _movePolToTreasury(polAccount, currency0, amount0);
        _movePolToTreasury(polAccount, currency1, amount1);
        ps.polDecommissionFinalized[poolId] = true;
        emit IStaticsProtocolPools.GeneralPoolDecommissionFinalized(poolId, currency0, currency1, amount0, amount1);
    }

    function replaceLiquidityManager(address newManager) external {
        LibDiamond.enforceIsContractOwner();
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        address oldManager = ls.manager;
        if (!ls.managerInstalled || oldManager.code.length == 0 || newManager.code.length == 0) {
            revert InvalidLiquidityManager(newManager);
        }
        if (newManager == oldManager) revert LiquidityManagerUnchanged(newManager);
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(oldManager);
        IStaticsLiquidityManager newBinding = IStaticsLiquidityManager(newManager);
        address positionManager = oldBinding.positionManager();
        _enforceManagerBinding(newManager, address(this), newBinding.staticsDiamond());
        _enforceManagerBinding(newManager, ls.poolManager, newBinding.poolManager());
        _enforceManagerBinding(newManager, positionManager, newBinding.positionManager());
        _enforceManagerBinding(newManager, oldBinding.permit2(), newBinding.permit2());

        ls.manager = newManager;
        emit IStaticsProtocolPools.LiquidityManagerReplaced(oldManager, newManager);
    }

    function _reserveTreasury(address token, uint256 amount) private {
        if (amount == 0) return;
        LibCustody.reserve(LibCustody.feeAccount(), token, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(token, amount);
    }

    function _settleDecommissionAsset(IStaticsSwapFeeHook hook, PoolKey storage key, PoolId poolId, Currency currency)
        private
    {
        address asset = Currency.unwrap(currency);
        uint256 pending = hook.pendingProtocolPol(poolId, currency);
        if (pending != 0) {
            uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
            uint256 settled = hook.settleProtocolPol(key, currency, address(this), pending);
            _enforceReceived(asset, beforeBalance, settled);
            LibCustody.reserve(LibCustody.protocolPolAccount(PoolId.unwrap(poolId)), asset, settled);
        }
        uint256 revenueBefore = IERC20(asset).balanceOf(address(this));
        IStaticsSwapFeeHook.FeeDistribution memory distribution =
            hook.settleFeeDistribution(key, currency, address(this));
        _enforceReceived(asset, revenueBefore, _distributionTotal(distribution));
        _accrueDistribution(poolId, asset, distribution);
    }

    function _movePolToTreasury(bytes32 polAccount, address asset, uint256 amount) private {
        if (amount == 0) return;
        LibCustody.moveReservation(polAccount, LibCustody.feeAccount(), asset, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
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

    function _enforceReceived(address token, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert IncompatibleTokenTransfer(token, reported, observed);
    }

    function _enforceManagerBinding(address manager, address expected, address actual) private pure {
        if (expected != actual) revert LiquidityManagerBindingMismatch(manager, expected, actual);
    }

    function _stopRangeGauge(LibBasketLiquidity.LiquidityStorage storage ls, PoolKey storage key, PoolId poolId)
        private
    {
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        LibRangeGauge.stopGauge(poolId, key.tickSpacing, liveTick, currentTime);
        IStaticsGaugeIncentives(address(this)).checkpointGaugePool(poolId);
        emit IStaticsRangeGauge.PoolGaugeStopped(poolId);
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
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
