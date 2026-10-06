// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLaunchModule} from "../interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsBasketDelegation} from "../interfaces/IStaticsBasketDelegation.sol";
import {LibBasketDelegation} from "../libraries/LibBasketDelegation.sol";
import {LibBasketDeployment} from "../libraries/LibBasketDeployment.sol";
import {LibBasketDefinition} from "../libraries/LibBasketDefinition.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {IStaticsRestrictedBasketToken} from "../interfaces/IStaticsRestrictedBasketToken.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";

contract BasketCreationFacet is ReentrancyGuard {
    struct DeploymentContext {
        uint256 deadline;
        bytes32 preparationId;
        uint256 basketId;
        address creator;
    }
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
        return _createBasket(params, pools, maxAmountsIn, launchDeadline, bytes32(0), msg.sender);
    }

    function createBasketPrepared(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline,
        bytes32 preparationId
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        if (preparationId == bytes32(0)) revert LibBasketDeployment.PreparationIntentMismatch();
        return _createBasket(params, pools, maxAmountsIn, launchDeadline, preparationId, msg.sender);
    }

    function createBasketFor(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        IStaticsBasketDelegation.Authorization calldata authorization,
        bytes calldata signature
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        LibBasketDelegation.validate(
            authorization,
            signature,
            LibBasketDeployment.configurationHash(params, pools, maximums, authorization.deadline),
            true
        );
        return _createBasket(
            params, pools, maximums, authorization.deadline, authorization.preparationId, authorization.creator
        );
    }

    function _createBasket(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline,
        bytes32 preparationId,
        address creator
    ) private returns (uint256 basketId, address token) {
        if (block.timestamp > launchDeadline) {
            revert LaunchDeadlineExpired(launchDeadline, block.timestamp);
        }
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
        _collectCreationFee(bs);

        basketId = bs.basketCount;
        bs.basketCount = basketId + 1;
        token = _deployBasket(
            params, pools, maxAmountsIn, DeploymentContext(launchDeadline, preparationId, basketId, creator)
        );

        {
            LibBasket.Basket storage created = bs.baskets[basketId];
            created.token = token;
            created.creator = creator;
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
        bs.basketIds[token] = basketId + 1;

        _emitBasketCreated(basketId, token, params, creator);

        uint256 basketShares =
            IStaticsBasketLaunchModule(address(this)).launchBasketPools(basketId, msg.sender, pools, maxAmountsIn);
        delete LibBasketDeployment.deploymentStorage().launching[basketId];
        emit IStaticsBasket.BasketLaunched(basketId, token, creator, basketShares, assetCount);
    }

    function _deployBasket(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        DeploymentContext memory context
    ) private returns (address token) {
        bytes32 configuration = LibBasketDeployment.configurationHash(params, pools, maxAmountsIn, context.deadline);
        bytes32 prepared = LibBasketDeployment.begin(
            context.preparationId, configuration, context.deadline, params.assets.length, msg.sender, context.creator
        );
        token = LibBasketDeployment.factory().deployBasketToken(prepared, params.name, params.symbol, context.basketId);
        LibRestrictedBasket.register(token, context.basketId);
        LibBasketDeployment.deploymentStorage().launching[context.basketId] = prepared;
        address morpho = LibMorpho.morphoStorage().morpho;
        if (morpho != address(0)) IStaticsRestrictedBasketToken(token).configureMorpho(morpho);
    }

    function _emitBasketCreated(
        uint256 basketId,
        address token,
        IStaticsBasket.CreateBasketParams calldata params,
        address creator
    ) private {
        emit IStaticsBasket.BasketCreated(basketId, token, creator, params.name, params.symbol);
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
        LibBasketDefinition.validate(params);
    }

    function _collectCreationFee(LibBasket.BasketStorage storage bs) private {
        uint256 amount = bs.creationFeeAmount;
        if (amount == 0) {
            if (msg.sender != LibDiamond.contractOwner()) revert PermissionlessBasketCreationDisabled();
            if (msg.value != 0) revert IncorrectCreationFee(0, msg.value);
            return;
        }
        if (msg.value != amount) revert IncorrectCreationFee(amount, msg.value);
        address treasury_ = bs.treasury;
        (bool success,) = payable(treasury_).call{value: amount}("");
        if (!success) revert CreationFeeTransferFailed(treasury_, amount);
        emit IStaticsBasketAdmin.CreationFeePaid(msg.sender, treasury_, amount);
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
