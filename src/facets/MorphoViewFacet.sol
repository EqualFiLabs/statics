// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";

contract MorphoViewFacet {
    function morpho() external view returns (address) {
        return LibMorpho.morphoStorage().morpho;
    }

    function morphoUsdStx() external view returns (address) {
        return LibMorpho.morphoStorage().usdStx;
    }

    function morphoAccount(uint256 positionId) external view returns (address account, bool deployed) {
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        account = LibMorpho.accountAddress(positionId);
        deployed = ms.accounts[positionId] != address(0);
    }

    function morphoMarket(bytes32 marketId_) external view returns (IStaticsMorpho.MarketConfigView memory view_) {
        LibMorpho.MarketConfig storage config = LibMorpho.requireMarket(marketId_);
        view_ = IStaticsMorpho.MarketConfigView(config.params, config.kind, config.mode, config.basketId);
    }

    function morphoPositionMarket(uint256 positionId, bytes32 marketId_)
        external
        view
        returns (IStaticsMorpho.PositionMarketView memory view_)
    {
        LibMorpho.requireMarket(marketId_);
        LibMorpho.PositionMarket storage tracked = LibMorpho.morphoStorage().positions[positionId].positions[marketId_];
        MorphoPosition memory actual = LibMorpho.actualPosition(positionId, marketId_);
        uint256 surplus = uint256(actual.collateral) > tracked.trackedCollateral
            ? uint256(actual.collateral) - tracked.trackedCollateral
            : 0;
        view_ = IStaticsMorpho.PositionMarketView(
            tracked.trackedCollateral, actual.collateral, surplus, actual.borrowShares, tracked.debtActive
        );
    }

    function enforceMorphoAccountEmpty(uint256 positionId) external view {
        LibMorpho.enforceAccountEmpty(positionId);
    }

    function morphoSyncBountyBps() external view returns (uint16) {
        return LibMorpho.morphoStorage().syncBountyBps;
    }

    function morphoSyncBounty(address keeper, address asset) external view returns (uint256) {
        return LibMorpho.morphoStorage().syncBounties[keeper][asset];
    }

    function quoteMorphoPerformanceFee(uint256 realizedYield)
        external
        view
        returns (uint256 feeAmount, uint256 operatorAmount, uint256 treasuryAmount)
    {
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        if (ms.performanceFeeRouter == address(0)) return (0, 0, 0);
        feeAmount = realizedYield * ms.performanceFeeBps / LibBasket.BPS;
        operatorAmount = feeAmount * ms.operatorShareBps / LibBasket.BPS;
        treasuryAmount = feeAmount - operatorAmount;
        if (LibGenesisIntegration.genesisStorage().totalWeight == 0) {
            treasuryAmount += operatorAmount;
            operatorAmount = 0;
        }
    }

    function morphoPerformanceFeeConfig()
        external
        view
        returns (address router, uint16 feeBps, uint16 operatorShareBps)
    {
        LibMorpho.MorphoStorage storage ms = LibMorpho.morphoStorage();
        return (ms.performanceFeeRouter, ms.performanceFeeBps, ms.operatorShareBps);
    }
}
