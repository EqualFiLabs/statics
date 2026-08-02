// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBasketRewards {
    struct BasketRewardState {
        uint256 totalEligibleShares;
        uint256 indexRay;
        uint256 indexedReserve;
        uint256 crystallizedReserve;
        uint256 totalClaimable;
    }

    event BasketRewardAccrued(
        uint256 indexed basketId, address indexed asset, uint256 amount, uint256 indexRay
    );
    event BasketRewardSettled(
        uint256 indexed positionId, uint256 indexed basketId, address indexed asset, uint256 amount
    );
    event BasketRewardClaimed(
        uint256 indexed positionId,
        uint256 indexed basketId,
        address indexed asset,
        address receiver,
        uint256 amount
    );
    event BasketRewardDustRouted(uint256 indexed basketId, address indexed asset, uint256 amount);

    function getBasketRewardAssets(uint256 basketId) external view returns (address[] memory assets);

    function getBasketRewards(uint256 positionId, uint256 basketId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    function claimBasketRewards(uint256 positionId, uint256 basketId, address receiver)
        external
        returns (address[] memory assets, uint256[] memory amounts);

    function basketRewardState(uint256 basketId, address asset)
        external
        view
        returns (BasketRewardState memory state);
}
