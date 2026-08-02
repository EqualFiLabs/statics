// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBasketRewards {
    struct BasketRewardState {
        uint256 totalEligibleShares;
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 feeYieldReserve;
        uint256 totalClaimable;
    }

    struct BasketPositionView {
        uint256 eligibleShares;
        uint256 lockedShares;
        uint256 withdrawableAfterBlock;
        address[] assets;
        uint256[] checkpointsRay;
        uint256[] claimable;
    }

    event BasketPositionDeposited(
        uint256 indexed positionId, uint256 indexed basketId, address indexed payer, uint256 shares
    );
    event BasketPositionWithdrawn(
        uint256 indexed positionId, uint256 indexed basketId, address indexed receiver, uint256 shares
    );
    event BasketPositionRedeemed(
        uint256 indexed positionId, uint256 indexed basketId, address indexed receiver, uint256 shares
    );
    event BasketFeesAccrued(
        uint256 indexed basketId,
        address indexed asset,
        uint256 grossFee,
        uint256 holderAmount,
        uint256 liquidityAmount,
        uint256 protocolAmount,
        uint256 indexRay
    );
    event BasketPositionRewardsSettled(
        uint256 indexed positionId, uint256 indexed basketId, address indexed asset, uint256 amount
    );
    event BasketRewardsClaimed(
        uint256 indexed positionId, uint256 indexed basketId, address indexed receiver, address asset, uint256 amount
    );

    function createAndDepositBasket(uint256 basketId, uint256 shares, address receiver)
        external
        returns (uint256 positionId);

    function depositBasket(uint256 positionId, uint256 basketId, uint256 shares) external;

    function withdrawBasket(uint256 positionId, uint256 basketId, uint256 shares, address receiver) external;

    function createAndMintBasket(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        external
        returns (uint256 positionId, uint256[] memory amountsIn);

    function mintBasketToPosition(uint256 positionId, uint256 basketId, uint256 shares, uint256[] calldata maxAmountsIn)
        external
        returns (uint256[] memory amountsIn);

    function redeemBasketFromPosition(
        uint256 positionId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amountsOut);

    function claimBasketRewards(
        uint256 positionId,
        uint256 basketId,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amountsOut);

    function pendingBasketRewards(uint256 positionId, uint256 basketId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    function basketRewardState(uint256 basketId, address asset) external view returns (BasketRewardState memory state);

    function basketPosition(uint256 positionId, uint256 basketId)
        external
        view
        returns (BasketPositionView memory position);
}
