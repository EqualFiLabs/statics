// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

/// @notice Owner-only administration of protocol-pool creation fee, PoolId-local fee rate, global
/// basket/general allocation profiles, general-pool decommissioning, and liquidity-manager replacement.
contract ProtocolPoolAdminFacet is ReentrancyGuard {
    error LiquidityIntegrationNotInstalled();
    error PoolAlreadyDecommissioned(PoolId poolId);
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 observed);
    error InvalidLiquidityManager(address manager);
    error LiquidityManagerBindingMismatch(address manager, address expected, address actual);
    error LiquidityManagerUnchanged(address manager);
    error InvalidPermanentLiquidityHarvester(address harvester);
    error OnlyPermanentLiquidityHarvester(address caller, address expected);
    error ActionPaused(uint256 action);

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
        LibProtocolPools.enforceRegistered(poolId);
        IStaticsSwapFeeHook(_liquidityStorage().hook).setPoolFeeRate(poolId, feeRate.inputFeeBps, feeRate.outputFeeBps);
        emit IStaticsProtocolPools.ProtocolPoolFeeRateSet(poolId, feeRate.inputFeeBps, feeRate.outputFeeBps);
    }

    function clearProtocolPoolFeeRate(PoolId poolId) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.enforceRegistered(poolId);
        IStaticsSwapFeeHook(_liquidityStorage().hook).clearPoolFeeRate(poolId);
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

    function decommissionGeneralPool(PoolId poolId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.GeneralPool storage stored = LibProtocolPools.generalPool(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolDecommissioned(poolId)) revert PoolAlreadyDecommissioned(poolId);
        address currency0 = Currency.unwrap(stored.key.currency0);
        address currency1 = Currency.unwrap(stored.key.currency1);
        uint256 before0 = IERC20(currency0).balanceOf(address(this));
        uint256 before1 = IERC20(currency1).balanceOf(address(this));
        hook.decommissionPool(stored.key);
        IStaticsSwapFeeHook.PermanentLiquidityRelease memory released =
            hook.releasePermanentLiquidity(stored.key, address(this));
        amount0 = released.principal0 + released.pendingPol0;
        amount1 = released.principal1 + released.pendingPol1;
        _enforceReceived(currency0, before0, amount0 + _distributionTotal(released.distribution0));
        _enforceReceived(currency1, before1, amount1 + _distributionTotal(released.distribution1));
        _accrueDistribution(poolId, currency0, released.distribution0);
        _accrueDistribution(poolId, currency1, released.distribution1);
        _reserveTreasury(currency0, amount0);
        _reserveTreasury(currency1, amount1);
        emit IStaticsProtocolPools.GeneralPoolDecommissioned(poolId, currency0, currency1, amount0, amount1);
    }

    function setPermanentLiquidityHarvester(address newHarvester) external {
        LibDiamond.enforceIsContractOwner();
        if (newHarvester == address(0) || newHarvester == address(this)) {
            revert InvalidPermanentLiquidityHarvester(newHarvester);
        }
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        address previousHarvester = ps.permanentLiquidityHarvester;
        ps.permanentLiquidityHarvester = newHarvester;
        emit IStaticsProtocolPools.PermanentLiquidityHarvesterSet(previousHarvester, newHarvester);
    }

    function harvestPermanentLiquidityFees(PoolId poolId)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        address harvester = ps.permanentLiquidityHarvester;
        if (msg.sender != harvester) revert OnlyPermanentLiquidityHarvester(msg.sender, harvester);
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_TREASURY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_TREASURY);
        }
        (, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(poolId);
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        uint256 before0 = IERC20(currency0).balanceOf(address(this));
        uint256 before1 = IERC20(currency1).balanceOf(address(this));
        (
            IStaticsSwapFeeHook.FeeDistribution memory distribution0,
            IStaticsSwapFeeHook.FeeDistribution memory distribution1
        ) = IStaticsSwapFeeHook(_liquidityStorage().hook).harvestPermanentLiquidityFees(key);
        amount0 = _distributionTotal(distribution0);
        amount1 = _distributionTotal(distribution1);
        _enforceReceived(currency0, before0, amount0);
        _enforceReceived(currency1, before1, amount1);
        _accrueDistribution(poolId, currency0, distribution0);
        _accrueDistribution(poolId, currency1, distribution1);
        emit IStaticsProtocolPools.PermanentLiquidityFeesHarvested(poolId, msg.sender, amount0, amount1);
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

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }
}
