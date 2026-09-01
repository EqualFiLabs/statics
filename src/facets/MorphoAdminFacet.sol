// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMorphoBlue, MorphoMarketId, MorphoMarketParams} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../libraries/LibGenesisRewards.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";

contract MorphoAdminFacet {
    error InvalidCollateralKind();
    error InvalidCollateralToken(address expected, address actual);
    error InvalidLoanToken(address expected, address actual);
    error InvalidMarketParameters(bytes32 marketId);
    error GenesisIntegrationNotInitialized();

    function initializeMorphoIntegration(address morpho_, address usdStx_, uint16 syncBountyBps_) external {
        LibDiamond.enforceIsContractOwner();
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        if (ms.initialized) revert LibMorpho.MorphoAlreadyInitialized();
        if (morpho_ == address(0) || morpho_.code.length == 0) revert LibMorpho.InvalidMorphoContract(morpho_);
        if (usdStx_ == address(0) || usdStx_.code.length == 0) revert LibMorpho.InvalidUsdStx(usdStx_);
        if (syncBountyBps_ > LibMorpho.MAX_SYNC_BOUNTY_BPS) revert LibMorpho.InvalidSyncBounty(syncBountyBps_);
        ms.morpho = morpho_;
        ms.usdStx = usdStx_;
        ms.syncBountyBps = syncBountyBps_;
        ms.initialized = true;
        emit IStaticsMorpho.MorphoIntegrationInitialized(morpho_, usdStx_, syncBountyBps_);
    }

    function registerMorphoMarket(
        MorphoMarketParams calldata params,
        IStaticsMorpho.CollateralKind kind,
        uint256 basketId,
        IStaticsMorpho.MarketMode mode
    ) external returns (bytes32 id) {
        LibDiamond.enforceIsContractOwner();
        LibMorpho.MorphoStorage storage ms = _storage();
        if (kind == IStaticsMorpho.CollateralKind.None) revert InvalidCollateralKind();
        if (mode == IStaticsMorpho.MarketMode.Disabled) revert LibMorpho.InvalidMarketMode();
        if (params.loanToken != ms.usdStx) revert InvalidLoanToken(ms.usdStx, params.loanToken);
        address expectedCollateral;
        if (kind == IStaticsMorpho.CollateralKind.Basket) {
            expectedCollateral = LibBasket.basketStorage().baskets[basketId].token;
            if (expectedCollateral == address(0)) revert InvalidCollateralToken(address(0), params.collateralToken);
        } else {
            expectedCollateral = LibGlobalRewards.rewardStorage().stakingToken;
            if (basketId != 0) revert InvalidCollateralKind();
        }
        if (params.collateralToken != expectedCollateral) {
            revert InvalidCollateralToken(expectedCollateral, params.collateralToken);
        }
        id = LibMorpho.marketId(params);
        if (ms.markets[id].registered) revert LibMorpho.MarketAlreadyRegistered(id);
        MorphoMarketParams memory canonical = IMorphoBlue(ms.morpho).idToMarketParams(MorphoMarketId.wrap(id));
        if (
            canonical.loanToken != params.loanToken || canonical.collateralToken != params.collateralToken
                || canonical.oracle != params.oracle || canonical.irm != params.irm || canonical.lltv != params.lltv
                || IMorphoBlue(ms.morpho).market(MorphoMarketId.wrap(id)).lastUpdate == 0
        ) revert InvalidMarketParameters(id);
        ms.markets[id] = LibMorpho.MarketConfig(params, kind, mode, basketId, true);
        emit IStaticsMorpho.MorphoMarketRegistered(id, params.collateralToken, kind, basketId, mode);
    }

    function setMorphoMarketMode(bytes32 marketId_, IStaticsMorpho.MarketMode mode) external {
        LibDiamond.enforceIsContractOwner();
        if (mode == IStaticsMorpho.MarketMode.Disabled) revert LibMorpho.InvalidMarketMode();
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        IStaticsMorpho.MarketMode previous = config.mode;
        config.mode = mode;
        emit IStaticsMorpho.MorphoMarketModeChanged(marketId_, previous, mode);
    }

    function setMorphoSyncBountyBps(uint16 bountyBps) external {
        LibDiamond.enforceIsContractOwner();
        if (bountyBps > LibMorpho.MAX_SYNC_BOUNTY_BPS) revert LibMorpho.InvalidSyncBounty(bountyBps);
        LibMorpho.MorphoStorage storage ms = _storage();
        uint16 previous = ms.syncBountyBps;
        ms.syncBountyBps = bountyBps;
        emit IStaticsMorpho.MorphoSyncBountyUpdated(previous, bountyBps);
    }

    function setMorphoPerformanceFeeConfig(address router, uint16 feeBps, uint16 operatorShareBps) external {
        LibDiamond.enforceIsContractOwner();
        if (feeBps > LibMorpho.MAX_PERFORMANCE_FEE_BPS) revert LibMorpho.InvalidPerformanceFee(feeBps);
        if (operatorShareBps > LibBasket.BPS) revert LibMorpho.InvalidOperatorShare(operatorShareBps);
        LibMorpho.MorphoStorage storage ms = _storage();
        if (router != address(0)) {
            if (!LibGenesisIntegration.genesisStorage().initialized) revert GenesisIntegrationNotInitialized();
            LibGenesisRewards.configureLenderRewardAsset(ms.usdStx);
        }
        ms.performanceFeeRouter = router;
        ms.performanceFeeBps = feeBps;
        ms.operatorShareBps = operatorShareBps;
        emit IStaticsMorpho.MorphoPerformanceFeeConfigured(router, feeBps, operatorShareBps, ms.usdStx);
    }

    function _storage() private view returns (LibMorpho.MorphoStorage storage ms) {
        ms = LibMorpho.morphoStorage();
        if (!ms.initialized) revert LibMorpho.MorphoNotInitialized();
    }
}

