// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

type MorphoMarketId is bytes32;

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoPosition {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorphoBlue {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function supplyCollateral(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;

    function withdrawCollateral(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    function borrow(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function liquidate(
        MorphoMarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256 assetsSeized, uint256 assetsRepaid);

    function position(MorphoMarketId id, address user) external view returns (MorphoPosition memory);
    function market(MorphoMarketId id) external view returns (MorphoMarket memory);
    function idToMarketParams(MorphoMarketId id) external view returns (MorphoMarketParams memory);
}
