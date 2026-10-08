// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibNativeReceipt} from "../libraries/LibNativeReceipt.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPol} from "../libraries/LibProtocolPol.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

/// @notice Explicit, custody-constrained management of protocol-owned Uniswap v4 positions.
contract ProtocolPolFacet is ReentrancyGuard {
    error ActionPaused(uint256 action);
    error OnlyProtocolPolOperator(address caller);
    error InvalidProtocolPolOperator(address operator);
    error GeneralPoolRequired(PoolId poolId);
    error PublicProtocolPoolRequired(PoolId poolId);
    error OnlyPoolCreator(address caller, address creator);
    error ProtocolPolAlreadyActivated(PoolId poolId);
    error IncorrectProtocolPolActivationFee(uint256 expected, uint256 provided);
    error ProtocolPolActivationFeeTransferFailed(address treasury, uint256 amount);
    error InvalidProtocolPolShare(PoolId poolId, uint16 shareBps, uint16 maximum);
    error InvalidProtocolPolAsset(PoolId poolId, address asset);
    error ProtocolPolSettlementMismatch(address asset, uint256 reported, uint256 observed);

    error InvalidProtocolPolRebalanceLegs();
    error DuplicateProtocolPolClose(uint256 positionId);
    error ProtocolPolAggregateDebitExceeded(uint256 debit0, uint256 debit1);
    error ProtocolPolRebalanceExpired(uint256 deadline);

    /// @notice Seed or replace up to eight positions atomically within one PoolId custody book.
    /// @dev Opening maxima are gross debits; returned principal never offsets this bound.
    function rebalanceProtocolPolPositions(IStaticsProtocolPools.ProtocolPolRebalanceParams calldata params)
        external
        nonReentrant
        returns (uint256[] memory newPositionIds)
    {
        _enforcePolOperator();
        _enforceLiquidityActive();
        if (params.deadline < block.timestamp) revert ProtocolPolRebalanceExpired(params.deadline);
        if (params.closes.length > 8 || params.opens.length == 0 || params.opens.length > 8) {
            revert InvalidProtocolPolRebalanceLegs();
        }
        _enforcePublicPool(params.poolId);
        uint256 debit0;
        uint256 debit1;
        for (uint256 i; i < params.opens.length; ++i) {
            debit0 += params.opens[i].amount0Maximum;
            debit1 += params.opens[i].amount1Maximum;
        }
        if (debit0 > params.maximumCustodyDebit0 || debit1 > params.maximumCustodyDebit1) {
            revert ProtocolPolAggregateDebitExceeded(debit0, debit1);
        }
        // Validate every close identity before any external position mutation.
        for (uint256 i; i < params.closes.length; ++i) {
            uint256 id = params.closes[i].positionId;
            for (uint256 j; j < i; ++j) {
                if (params.closes[j].positionId == id) revert DuplicateProtocolPolClose(id);
            }
            LibProtocolPools.ProtocolPolPosition storage position =
                LibProtocolPools.protocolPoolStorage().polPositions[id];
            if (!position.active) revert LibProtocolPol.ProtocolPolPositionNotFound(id);
            if (PoolId.unwrap(position.poolId) != PoolId.unwrap(params.poolId)) {
                revert LibProtocolPol.ProtocolPolPositionPoolMismatch(id, params.poolId, position.poolId);
            }
        }
        for (uint256 i; i < params.closes.length; ++i) {
            _rebalanceClose(params.closes[i], params.deadline);
        }
        newPositionIds = new uint256[](params.opens.length);
        for (uint256 i; i < params.opens.length; ++i) {
            newPositionIds[i] = _rebalanceOpen(params.poolId, params.opens[i], params.deadline);
        }
    }

    function _rebalanceClose(IStaticsProtocolPools.ProtocolPolCloseLeg calldata leg, uint256 deadline) private {
        (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        ) = LibProtocolPol.close(leg.positionId, leg.amount0Minimum, leg.amount1Minimum, deadline);
        emit IStaticsProtocolPools.ProtocolPolPositionClosed(
            position.poolId, leg.positionId, movement.received0, movement.received1
        );
    }

    function _rebalanceOpen(PoolId poolId, IStaticsProtocolPools.ProtocolPolOpenLeg calldata leg, uint256 deadline)
        private
        returns (uint256 positionId)
    {
        IStaticsLiquidityManager.ManagedPositionMovement memory movement;
        (positionId, movement) = LibProtocolPol.open(
            IStaticsProtocolPools.ProtocolPolOpenParams({
                poolId: poolId,
                tickLower: leg.tickLower,
                tickUpper: leg.tickUpper,
                liquidity: leg.liquidity,
                amount0Maximum: leg.amount0Maximum,
                amount1Maximum: leg.amount1Maximum,
                deadline: deadline
            })
        );
        LibProtocolPools.ProtocolPolPosition storage position =
            LibProtocolPools.protocolPoolStorage().polPositions[positionId];
        emit IStaticsProtocolPools.ProtocolPolPositionOpened(
            poolId,
            positionId,
            position.manager,
            position.posmTokenId,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            movement.spent0,
            movement.spent1
        );
    }

    function setProtocolPolOperator(address operator) external {
        LibDiamond.enforceIsContractOwner();
        if (operator == address(this)) revert InvalidProtocolPolOperator(operator);
        LibProtocolPools.protocolPoolStorage().polOperator = operator;
        emit IStaticsProtocolPools.ProtocolPolOperatorSet(operator);
    }

    function setProtocolPolActivationFee(uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.protocolPoolStorage().polActivationFeeAmount = amount;
        emit IStaticsProtocolPools.ProtocolPolActivationFeeSet(amount);
    }

    function activateProtocolPoolPol(PoolId poolId) external payable nonReentrant {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = LibProtocolPools.enforceRegistered(poolId);
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.General) revert GeneralPoolRequired(poolId);
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        LibProtocolPools.PolFundingConfig storage config = ps.polFunding[poolId];
        if (config.activated) revert ProtocolPolAlreadyActivated(poolId);
        address creator = ps.generalPools[poolId].creator;
        if (msg.sender != creator) revert OnlyPoolCreator(msg.sender, creator);
        uint256 fee = ps.polActivationFeeAmount;
        if (msg.value != fee) revert IncorrectProtocolPolActivationFee(fee, msg.value);
        config.activated = true;
        _sendActivationFee(fee);
        emit IStaticsProtocolPools.ProtocolPolActivated(poolId, creator, fee);
    }

    function setProtocolPoolPolShare(PoolId poolId, uint16 shareBps) external {
        LibDiamond.enforceIsContractOwner();
        _setPolShare(poolId, shareBps, true);
    }

    function clearProtocolPoolPolShare(PoolId poolId) external {
        LibDiamond.enforceIsContractOwner();
        _setPolShare(poolId, 0, false);
    }

    function settleProtocolPoolPol(PoolId poolId, address asset, uint256 maximumAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        (, PoolKey memory key,,) = _enforcePublicPool(poolId);
        Currency currency;
        if (asset == Currency.unwrap(key.currency0)) currency = key.currency0;
        else if (asset == Currency.unwrap(key.currency1)) currency = key.currency1;
        else revert InvalidProtocolPolAsset(poolId, asset);

        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(LibBasketLiquidity.liquidityStorage().hook);
        uint256 pending = hook.pendingProtocolPol(poolId, currency);
        uint256 requested = maximumAmount == 0 || maximumAmount > pending ? pending : maximumAmount;
        uint256 beforeBalance = LibCurrency.balance(asset, address(this));
        if (asset == address(0)) LibNativeReceipt.expect(LibBasketLiquidity.liquidityStorage().poolManager);
        amount = hook.settleProtocolPol(key, currency, address(this), requested);
        LibNativeReceipt.clear();
        uint256 afterBalance = LibCurrency.balance(asset, address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != amount) revert ProtocolPolSettlementMismatch(asset, amount, observed);
        LibCustody.reserve(LibCustody.protocolPolAccount(PoolId.unwrap(poolId)), asset, amount);
        emit IStaticsProtocolPools.ProtocolPolInventorySettled(poolId, asset, amount);
    }

    function openProtocolPolPosition(IStaticsProtocolPools.ProtocolPolOpenParams calldata params)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        _enforcePolOperator();
        _enforceLiquidityActive();
        IStaticsLiquidityManager.ManagedPositionMovement memory movement;
        (positionId, movement) = LibProtocolPol.open(params);
        LibProtocolPools.ProtocolPolPosition storage position =
            LibProtocolPools.protocolPoolStorage().polPositions[positionId];
        emit IStaticsProtocolPools.ProtocolPolPositionOpened(
            params.poolId,
            positionId,
            position.manager,
            position.posmTokenId,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            movement.spent0,
            movement.spent1
        );
    }

    function increaseProtocolPolPosition(IStaticsProtocolPools.ProtocolPolLiquidityParams calldata params)
        external
        nonReentrant
    {
        _enforcePolOperator();
        _enforceLiquidityActive();
        (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        ) = LibProtocolPol.increase(params);
        emit IStaticsProtocolPools.ProtocolPolPositionIncreased(
            position.poolId, params.positionId, params.liquidity, movement.spent0, movement.spent1
        );
    }

    function decreaseProtocolPolPosition(IStaticsProtocolPools.ProtocolPolLiquidityParams calldata params)
        external
        nonReentrant
    {
        _enforcePolOperator();
        (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        ) = LibProtocolPol.decrease(params);
        emit IStaticsProtocolPools.ProtocolPolPositionDecreased(
            position.poolId, params.positionId, params.liquidity, movement.received0, movement.received1
        );
    }

    function collectProtocolPolFees(uint256 positionId, uint256 deadline) external nonReentrant {
        _enforcePolOperator();
        (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        ) = LibProtocolPol.harvest(positionId, deadline);
        emit IStaticsProtocolPools.ProtocolPolFeesCollected(
            position.poolId, positionId, movement.received0, movement.received1
        );
    }

    function closeProtocolPolPosition(
        uint256 positionId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external nonReentrant {
        _enforcePolOperator();
        (
            LibProtocolPools.ProtocolPolPosition storage position,
            IStaticsLiquidityManager.ManagedPositionMovement memory movement
        ) = LibProtocolPol.close(positionId, amount0Minimum, amount1Minimum, deadline);
        emit IStaticsProtocolPools.ProtocolPolPositionClosed(
            position.poolId, positionId, movement.received0, movement.received1
        );
    }

    function _setPolShare(PoolId poolId, uint16 shareBps, bool overridden) private {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = _enforcePublicPool(poolId);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(LibBasketLiquidity.liquidityStorage().hook);
        uint16 maximum;
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
            IStaticsSwapFeeHook.BasketFeeAllocation memory allocation = hook.basketFeeAllocation();
            maximum = allocation.polShareBps + allocation.treasuryShareBps;
        } else {
            IStaticsSwapFeeHook.GeneralFeeAllocation memory allocation = hook.generalFeeAllocation();
            maximum = allocation.polShareBps + allocation.treasuryShareBps;
        }
        if (shareBps > maximum) revert InvalidProtocolPolShare(poolId, shareBps, maximum);
        LibProtocolPools.PolFundingConfig storage config = LibProtocolPools.protocolPoolStorage().polFunding[poolId];
        config.overrideSet = overridden;
        config.shareBps = overridden ? shareBps : 0;
        emit IStaticsProtocolPools.ProtocolPolShareSet(poolId, shareBps, overridden);
    }

    function _enforcePublicPool(PoolId poolId)
        private
        view
        returns (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset)
    {
        (kind, key, basketId, basketAsset) = LibProtocolPools.enforceRegistered(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral) {
            revert PublicProtocolPoolRequired(poolId);
        }
    }

    function _enforcePolOperator() private view {
        address owner = LibDiamond.contractOwner();
        address operator = LibProtocolPools.protocolPoolStorage().polOperator;
        if (msg.sender != owner && msg.sender != operator) revert OnlyProtocolPolOperator(msg.sender);
    }

    function _enforceLiquidityActive() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }

    function _sendActivationFee(uint256 amount) private {
        if (amount == 0) return;
        address treasury = LibBasket.basketStorage().treasury;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert ProtocolPolActivationFeeTransferFailed(treasury, amount);
    }
}
