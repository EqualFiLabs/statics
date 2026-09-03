// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBasketCollateral {
    struct BasketCollateralPosition {
        uint256 depositedShares;
        uint256 lockedShares;
        uint256 rewardEligibleAt;
    }

    event BasketCollateralDeposited(
        uint256 indexed positionId, uint256 indexed basketId, address indexed payer, uint256 shares
    );
    event BasketCollateralWithdrawn(
        uint256 indexed positionId, uint256 indexed basketId, address indexed receiver, uint256 shares
    );
    event BasketCollateralRedeemed(
        uint256 indexed positionId, uint256 indexed basketId, address indexed receiver, uint256 shares
    );

    function createAndDepositBasketCollateral(uint256 basketId, uint256 shares, address receiver)
        external
        payable
        returns (uint256 positionId);

    function depositBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares) external;

    function withdrawBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares, address receiver) external;

    function createAndMintBasketCollateral(
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata maxAmountsIn
    ) external payable returns (uint256 positionId, uint256[] memory amountsIn);

    function mintBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares, uint256[] calldata maxAmountsIn)
        external
        returns (uint256[] memory amountsIn);

    function redeemBasketCollateral(
        uint256 positionId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amountsOut);

    function basketCollateralPosition(uint256 positionId, uint256 basketId)
        external
        view
        returns (BasketCollateralPosition memory position);
}
