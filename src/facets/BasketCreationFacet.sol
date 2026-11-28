// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLaunchModule} from "../interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBasketStaging} from "../interfaces/IStaticsBasketStaging.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLending} from "../libraries/LibLending.sol";

contract BasketCreationFacet is ReentrancyGuard, IStaticsBasketStaging {
    error InvalidBasketLaunchState();
    error OnlyBasketLaunchCreator();
    error InvalidBasketDefinition();
    error FeeExceedsCap(uint16 feeBps);
    error LtvExceedsMaximum(uint16 ltvBps);
    error InvalidRecoveryParameters(uint16 ltvBps, uint16 recoveryPenaltyBps);
    error ActionPaused(uint256 action);
    error PermissionlessBasketCreationDisabled();
    error IncorrectCreationFee(uint256 expected, uint256 actual);
    error CreationFeeTransferFailed(address treasury, uint256 amount);
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidPoolLaunchParameters();
    error LaunchDeadlineExpired(uint256 deadline, uint256 timestamp);

    function createBasket(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        return _createBasket(params, pools, maxAmountsIn, launchDeadline, bytes32(0), 0);
    }

    function createBasketPrepared(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline,
        bytes32 preparationId
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        if (preparationId == bytes32(0)) revert LibBasketDeployment.PreparationIntentMismatch();
        return _createBasket(params, pools, maxAmountsIn, launchDeadline, preparationId, 0);
    }

    function createBasketStaged(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        bytes32 preparationId,
        uint256 poolCount
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        if (poolCount == 0 || poolCount > pools.length) revert InvalidPoolLaunchParameters();
        return _createBasket(params, pools, maxAmountsIn, deadline, preparationId, poolCount);
    }

    function continueBasketLaunch(
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 poolCount
    ) external payable nonReentrant {
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.status != IStaticsBasket.BasketStatus.Pending) revert InvalidBasketLaunchState();
        if (msg.sender != configured.creator) revert OnlyBasketLaunchCreator();
        if (block.timestamp > deadline) revert LaunchDeadlineExpired(deadline, block.timestamp);
        _enforceNotPaused(LibGovernance.PAUSE_LIQUIDITY);
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        if (LibBasket.basketStorage().creationFeeAmount == 0) LibDiamond.enforceIsContractOwner();
        if (
            LibBasketDeployment.deploymentStorage().staged[basketId].terms
                != _launchTerms(pools, maxAmountsIn, deadline)
        ) {
            revert LibBasketDeployment.PreparationIntentMismatch();
        }
        uint256 first = LibBasketDeployment.deploymentStorage().staged[basketId].nextPool;
        if (poolCount == 0 || poolCount > pools.length - first) revert InvalidPoolLaunchParameters();
        _collectFees(0, _activationFees(pools, first, poolCount));
        _stage(basketId, pools, maxAmountsIn, poolCount);
    }

    function cancelBasketLaunch(uint256 basketId) external nonReentrant {
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.status != IStaticsBasket.BasketStatus.Pending) revert InvalidBasketLaunchState();
        if (msg.sender != configured.creator && msg.sender != LibDiamond.contractOwner()) {
            revert OnlyBasketLaunchCreator();
        }
        configured.status = IStaticsBasket.BasketStatus.ExitOnly;
        emit BasketLaunchCancelled(basketId);
    }

    function basketLaunchProgress(uint256 basketId)
        external
        view
        returns (uint256 completedPools, uint256 basketShares, uint256[] memory assetDebits)
    {
        LibBasketDeployment.StagedLaunch storage launch = LibBasketDeployment.deploymentStorage().staged[basketId];
        return (launch.nextPool, launch.basketShares, launch.assetDebits);
    }

    function _launchTerms(
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 deadline
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(pools, maximums, deadline));
    }

    function _stage(
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 count
    ) private {
        LibBasketDeployment.StagedLaunch storage launch = LibBasketDeployment.deploymentStorage().staged[basketId];
        uint256 length = pools.length;
        uint256[] memory remaining = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            remaining[i] = maximums[i] - launch.assetDebits[i];
        }
        (uint256 shares, uint256[] memory debits) = IStaticsBasketLaunchModule(address(this))
            .launchBasketPoolBatch(
                IStaticsBasketLaunchModule.PoolBatch(basketId, msg.sender, launch.nextPool, count), pools, remaining
            );
        for (uint256 i; i < length; ++i) {
            launch.assetDebits[i] += debits[i];
        }
        launch.nextPool += count;
        launch.basketShares += shares;
        emit BasketLaunchProgress(basketId, launch.nextPool, length);
        if (launch.nextPool == length) {
            LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[basketId];
            configured.status = IStaticsBasket.BasketStatus.Active;
            emit IStaticsBasket.BasketLaunched(basketId, configured.token, msg.sender, launch.basketShares, length);
        }
    }

    function _createBasket(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline,
        bytes32 preparationId,
        uint256 firstBatch
    ) private returns (uint256 basketId, address token) {
        if (block.timestamp > launchDeadline) {
            revert LaunchDeadlineExpired(launchDeadline, block.timestamp);
        }
        LibProtocolPools.enforcePoolCreationAllowed(msg.sender);
        _validateDefinition(params);
        _enforceNotPaused(LibGovernance.PAUSE_LIQUIDITY);
        uint256 assetCount = params.assets.length;
        if (pools.length != assetCount || maxAmountsIn.length != assetCount) {
            revert InvalidPoolLaunchParameters();
        }
        {
            LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
            if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
            if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        }
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        _collectCreationFees(pools, firstBatch);

        uint256 reservedId = LibBasketDeployment.deploymentStorage().deployed[preparationId].basketIdPlusOne;
        if (reservedId != 0) {
            basketId = reservedId - 1;
        } else {
            basketId = bs.basketCount;
            bs.basketCount = basketId + 1;
        }
        token = _deployBasket(params, pools, maxAmountsIn, launchDeadline, preparationId, basketId);

        {
            LibBasket.Basket storage created = bs.baskets[basketId];
            created.token = token;
            created.creator = msg.sender;
            created.assets = params.assets;
            created.bundleAmounts = params.bundleAmounts;
            _copyFeeTiers(created.mintFeeTiers, params.mintFeeTiers);
            _copyFeeTiers(created.redemptionFeeTiers, params.redemptionFeeTiers);
            created.flashFeeBps = params.flashFeeBps;
            created.originationFeeBps = params.originationFeeBps;
            created.extensionFeeBps = params.extensionFeeBps;
            created.ltvBps = params.ltvBps;
            created.recoveryPenaltyBps = params.recoveryPenaltyBps;
            created.loanDuration = params.loanDuration;
        }

        _emitBasketCreated(basketId, token, params);

        _launchCreatedBasket(basketId, pools, maxAmountsIn, launchDeadline, firstBatch);
    }

    function _launchCreatedBasket(
        uint256 basketId,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 firstBatch
    ) private {
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[basketId];
        if (firstBatch == 0) {
            uint256 shares =
                IStaticsBasketLaunchModule(address(this)).launchBasketPools(basketId, msg.sender, pools, maxAmountsIn);
            emit IStaticsBasket.BasketLaunched(basketId, configured.token, msg.sender, shares, pools.length);
        } else {
            configured.status = IStaticsBasket.BasketStatus.Pending;
            LibBasketDeployment.StagedLaunch storage launch = LibBasketDeployment.deploymentStorage().staged[basketId];
            launch.terms = _launchTerms(pools, maxAmountsIn, deadline);
            launch.assetDebits = new uint256[](pools.length);
            _stage(basketId, pools, maxAmountsIn, firstBatch);
        }
    }

    function _deployBasket(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        bytes32 preparationId,
        uint256 basketId
    ) private returns (address token) {
        if (preparationId == bytes32(0)) {
            token = LibBasketDeployment.factory().deployNextBasketToken(params.name, params.symbol, basketId);
            LibBasket.registerToken(token, basketId);
        } else {
            LibBasketDeployment.PreparedContracts storage prepared =
                LibBasketDeployment.deploymentStorage().deployed[preparationId];
            if (
                prepared.token == address(0) || prepared.finalized || prepared.creator != msg.sender
                    || prepared.configurationHash
                        != LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, deadline)
            ) revert LibBasketDeployment.PreparationIntentMismatch();
            prepared.finalized = true;
            token = prepared.token;
        }
    }

    function _emitBasketCreated(uint256 basketId, address token, IStaticsBasket.CreateBasketParams calldata params)
        private
    {
        emit IStaticsBasket.BasketCreated(basketId, token, msg.sender, params.name, params.symbol);
        emit IStaticsBasket.BasketConfigured(
            basketId,
            params.assets,
            params.bundleAmounts,
            params.flashFeeBps,
            params.originationFeeBps,
            params.extensionFeeBps,
            params.ltvBps,
            params.recoveryPenaltyBps,
            params.loanDuration
        );
        _emitFeeTiers(basketId, true, params.mintFeeTiers);
        _emitFeeTiers(basketId, false, params.redemptionFeeTiers);
    }

    function _validateDefinition(IStaticsBasket.CreateBasketParams calldata params) private pure {
        uint256 length = params.assets.length;
        if (length == 0 || length > LibBasket.MAX_ASSETS || length != params.bundleAmounts.length) {
            revert InvalidBasketDefinition();
        }
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0 || params.loanDuration == 0) {
            revert InvalidBasketDefinition();
        }
        _validateFee(params.flashFeeBps);
        _validateFee(params.originationFeeBps);
        _validateFee(params.extensionFeeBps);
        _validateFee(params.recoveryPenaltyBps);
        if (params.ltvBps > LibLending.MAX_LTV_BPS) revert LtvExceedsMaximum(params.ltvBps);
        uint256 maximumRecoverySharesBps = uint256(params.ltvBps)
            + Math.mulDiv(params.ltvBps, params.recoveryPenaltyBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (maximumRecoverySharesBps > LibBasket.BPS) {
            revert InvalidRecoveryParameters(params.ltvBps, params.recoveryPenaltyBps);
        }

        for (uint256 i; i < length; ++i) {
            address asset = params.assets[i];
            if (asset == address(0) || params.bundleAmounts[i] == 0) revert InvalidBasketDefinition();
            for (uint256 j = i + 1; j < length; ++j) {
                if (asset == params.assets[j]) revert InvalidBasketDefinition();
            }
        }
    }

    function _validateFee(uint16 feeBps) private pure {
        if (feeBps > LibBasket.MAX_FEE_BPS) revert FeeExceedsCap(feeBps);
    }

    function _collectCreationFees(IStaticsBasket.PoolLaunchParams[] calldata pools, uint256 firstBatch) private {
        uint256 creationFee = LibBasket.basketStorage().creationFeeAmount;
        if (creationFee == 0 && msg.sender != LibDiamond.contractOwner()) {
            revert PermissionlessBasketCreationDisabled();
        }
        _collectFees(creationFee, _activationFees(pools, 0, firstBatch == 0 ? pools.length : firstBatch));
    }

    function _activationFees(IStaticsBasket.PoolLaunchParams[] calldata pools, uint256 first, uint256 count)
        private
        view
        returns (uint256 total)
    {
        uint256 fee = LibProtocolPools.protocolPoolStorage().polActivationFeeAmount;
        for (uint256 i = first; i < first + count; ++i) {
            total += pools[i].activateManagedPol ? fee : 0;
        }
    }

    function _collectFees(uint256 creationFee, uint256 activationFees) private {
        uint256 total = creationFee + activationFees;
        if (msg.value != total) revert IncorrectCreationFee(total, msg.value);
        if (total == 0) return;
        address treasury_ = LibBasket.basketStorage().treasury;
        (bool success,) = payable(treasury_).call{value: total}("");
        if (!success) revert CreationFeeTransferFailed(treasury_, total);
        if (creationFee != 0) emit IStaticsBasketAdmin.CreationFeePaid(msg.sender, treasury_, creationFee);
    }

    function _copyFeeTiers(IStaticsBasket.FeeTier[] storage destination, IStaticsBasket.FeeTier[] calldata source)
        private
    {
        uint256 length = source.length;
        for (uint256 i; i < length; ++i) {
            destination.push(source[i]);
        }
    }

    function _emitFeeTiers(uint256 basketId, bool mintAction, IStaticsBasket.FeeTier[] calldata tiers) private {
        uint256 length = tiers.length;
        uint256[] memory thresholds = new uint256[](length);
        uint256[] memory fees = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            thresholds[i] = tiers[i].minActionShares;
            fees[i] = tiers[i].feeShares;
        }
        emit IStaticsBasket.BasketFeeTiersConfigured(basketId, mintAction, thresholds, fees);
    }

    function _enforceNotPaused(uint256 action) private view {
        if (LibGovernance.governanceStorage().pausedActions & action != 0) revert ActionPaused(action);
    }
}
