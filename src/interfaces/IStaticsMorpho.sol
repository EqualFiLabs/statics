// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MorphoMarketParams} from "./IMorphoBlue.sol";

interface IStaticsMorpho {
    enum CollateralKind {
        None,
        Basket,
        StakedStatics
    }

    enum MarketMode {
        Disabled,
        Active,
        ExitOnly
    }

    struct MarketConfigView {
        MorphoMarketParams params;
        CollateralKind kind;
        MarketMode mode;
        uint256 basketId;
    }

    struct PositionMarketView {
        uint256 trackedCollateral;
        uint256 actualCollateral;
        uint256 untrackedSurplus;
        uint256 borrowShares;
        bool debtActive;
    }

    event MorphoIntegrationInitialized(address indexed morpho, address indexed usdStx, uint16 syncBountyBps);
    event MorphoMarketRegistered(
        bytes32 indexed marketId,
        address indexed collateralToken,
        CollateralKind kind,
        uint256 basketId,
        MarketMode mode
    );
    event MorphoMarketModeChanged(bytes32 indexed marketId, MarketMode previousMode, MarketMode newMode);
    event MorphoAccountDeployed(uint256 indexed positionId, address indexed account);
    event MorphoAccountTokenRecovered(
        uint256 indexed positionId, address indexed token, address indexed receiver, uint256 amount, uint256 received
    );
    event MorphoCollateralDeployed(uint256 indexed positionId, bytes32 indexed marketId, uint256 assets);
    event MorphoCollateralRecalled(uint256 indexed positionId, bytes32 indexed marketId, uint256 assets);
    event MorphoSurplusWithdrawn(
        uint256 indexed positionId, bytes32 indexed marketId, address indexed receiver, uint256 assets
    );
    event MorphoBorrowed(
        uint256 indexed positionId, bytes32 indexed marketId, address indexed receiver, uint256 assets, uint256 shares
    );
    event MorphoRepaid(uint256 indexed positionId, bytes32 indexed marketId, uint256 assets, uint256 shares);
    event MorphoSynchronized(
        uint256 indexed positionId,
        bytes32 indexed marketId,
        address indexed keeper,
        uint256 previousTracked,
        uint256 actualCollateral,
        uint256 trackedLoss
    );
    event MorphoLiquidatedAndSynchronized(
        uint256 indexed positionId,
        bytes32 indexed marketId,
        address indexed liquidator,
        uint256 assetsSeized,
        uint256 assetsRepaid
    );
    event MorphoSyncBountyUpdated(uint16 previousBps, uint16 newBps);
    event MorphoSyncBountyClaimed(
        address indexed keeper, address indexed asset, address indexed receiver, uint256 amount
    );
    event MorphoPerformanceFeeConfigured(
        address indexed router, uint16 feeBps, uint16 operatorShareBps, address indexed rewardAsset
    );
    event MorphoPerformanceFeeRouted(
        address indexed router, uint256 realizedYield, uint256 feeAmount, uint256 operatorAmount, uint256 treasuryAmount
    );

    function initializeMorphoIntegration(address morpho, address usdStx, uint16 syncBountyBps) external;
    function registerMorphoMarket(
        MorphoMarketParams calldata params,
        CollateralKind kind,
        uint256 basketId,
        MarketMode mode
    ) external returns (bytes32 marketId);
    function setMorphoMarketMode(bytes32 marketId, MarketMode mode) external;
    function setMorphoSyncBountyBps(uint16 bountyBps) external;
    function setMorphoPerformanceFeeConfig(address router, uint16 feeBps, uint16 operatorShareBps) external;

    function deployMorphoCollateral(uint256 positionId, bytes32 marketId, uint256 assets) external;
    function recallMorphoCollateral(uint256 positionId, bytes32 marketId, uint256 assets) external;
    function withdrawUntrackedMorphoCollateral(uint256 positionId, bytes32 marketId, uint256 assets, address receiver)
        external;
    function borrowMorphoUsd(
        uint256 positionId,
        bytes32 marketId,
        uint256 assets,
        uint256 maxBorrowShares,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repayMorphoUsd(uint256 positionId, bytes32 marketId, uint256 assets, uint256 shares, uint256 maxAssets)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function syncMorpho(uint256 positionId, bytes32 marketId) external returns (uint256 trackedLoss);
    function syncMorphoForModule(uint256 positionId, address keeper) external;
    function liquidateMorphoAndSync(
        uint256 positionId,
        bytes32 marketId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 maxRepayAssets,
        uint256 minSeizedAssets,
        address receiver
    ) external returns (uint256 assetsSeized, uint256 assetsRepaid);
    function claimMorphoSyncBounties(address[] calldata assets, address receiver)
        external
        returns (uint256[] memory amounts);
    function recoverMorphoAccountToken(
        uint256 positionId,
        address token,
        uint256 amount,
        address receiver,
        uint256 minReceived
    ) external returns (uint256 received);
    function routeMorphoPerformanceFee(uint256 realizedYield) external returns (uint256 feeAmount);
    function quoteMorphoPerformanceFee(uint256 realizedYield)
        external
        view
        returns (uint256 feeAmount, uint256 operatorAmount, uint256 treasuryAmount);

    function morpho() external view returns (address);
    function morphoUsdStx() external view returns (address);
    function morphoAccount(uint256 positionId) external view returns (address account, bool deployed);
    function morphoMarket(bytes32 marketId) external view returns (MarketConfigView memory config);
    function morphoPositionMarket(uint256 positionId, bytes32 marketId)
        external
        view
        returns (PositionMarketView memory position);
    function morphoMarketIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (bytes32[] memory marketIds, uint256 nextCursor);
    function enforceMorphoAccountEmpty(uint256 positionId) external view;
    function morphoSyncBountyBps() external view returns (uint16);
    function morphoSyncBounty(address keeper, address asset) external view returns (uint256);
    function morphoPerformanceFeeConfig() external view returns (address router, uint16 feeBps, uint16 operatorShareBps);
}
