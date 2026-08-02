// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBorrowLiquidity {
    struct LiquidityParams {
        address asset;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        uint256 deadline;
    }

    event BorrowedLiquidityPositionMinted(
        uint256 indexed loanId,
        uint256 indexed basketId,
        address indexed asset,
        uint256 v4TokenId,
        address recipient,
        uint256 liquidity,
        uint256 spent0,
        uint256 spent1,
        uint256 refund0,
        uint256 refund1
    );
    event BorrowedLiquidityProvided(
        uint256 indexed loanId,
        uint256 indexed positionId,
        uint256 indexed basketId,
        address operator,
        address lpRecipient,
        uint256 sharesIn,
        uint256 basketSharesMinted,
        uint256[] v4TokenIds
    );
    event BorrowedLiquidityStaked(
        uint256 indexed loanId,
        uint256 indexed positionId,
        uint256 indexed basketId,
        address operator,
        address beneficiary,
        uint256 sharesIn,
        uint256 basketSharesMinted,
        uint256[] v4TokenIds
    );

    function borrowAndProvideLiquidity(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools,
        address lpRecipient
    ) external returns (uint256 loanId, uint256[] memory v4TokenIds);

    function borrowAndStakeLiquidity(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        LiquidityParams[] calldata pools
    ) external returns (uint256 loanId, uint256[] memory v4TokenIds);
}
