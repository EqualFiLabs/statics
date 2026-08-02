// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "./IStaticsDollarCoreTypes.sol";

interface IStaticsDollarGateway {
    struct PermitSignature {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error ZeroAddress();
    error ZeroAmount();
    error UnexpectedCollateralProfile(uint256 expectedProfileId, uint256 actualProfileId);
    error OutputBelowMinimum(uint256 actual, uint256 minimum);
    error SharesAboveMaximum(uint256 required, uint256 maximum);
    error CollateralAboveMaximum(uint256 required, uint256 maximum);
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);
    error ResidualGatewayBalance(address token, uint256 expectedBalance, uint256 actualBalance);
    error ResidualGatewayERC1155Balance(address token, uint256 id, uint256 expectedBalance, uint256 actualBalance);
    error ResidualGatewayNativeBalance(uint256 expectedBalance, uint256 actualBalance);
    error ResidualGatewayApproval(address token, address spender, uint256 allowance);
    error NativeTransferFailed(address receiver, uint256 amount);
    error UnexpectedExitStatus(IStaticsDollarCoreTypes.ExitStatus status);
    error UnexpectedRiskIngressState();

    event ETHDeposited(
        address indexed caller,
        address indexed staticsDollarReceiver,
        address indexed shareReceiver,
        uint256 profileId,
        uint256 seriesId,
        uint256 ethAmount,
        uint256 staticsDollarMinted,
        uint256 sharesMinted
    );
    event WETHDeposited(
        address indexed caller,
        address indexed staticsDollarReceiver,
        address indexed shareReceiver,
        uint256 profileId,
        uint256 seriesId,
        uint256 wethAmount,
        uint256 staticsDollarMinted,
        uint256 sharesMinted
    );
    event RecombinedToWETH(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        uint256 staticsDollarBurned,
        uint256 sharesBurned,
        uint256 wethOut
    );
    event RecombinedToETH(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        uint256 staticsDollarBurned,
        uint256 sharesBurned,
        uint256 ethOut
    );
    event RecombinationDeferred(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );
    event PeggedMintedThroughGateway(
        address indexed caller,
        address indexed staticsDollarReceiver,
        uint256 indexed profileId,
        address collateralToken,
        uint256 staticsDollarMinted,
        uint256 collateralIn
    );
    event PeggedRedeemedThroughGateway(
        address indexed caller,
        address indexed receiver,
        uint256 indexed profileId,
        address collateralToken,
        uint256 staticsDollarBurned,
        uint256 collateralOut
    );
    event PeggedRedemptionDeferred(
        address indexed caller,
        address indexed receiver,
        uint256 indexed profileId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );

    function depositETH(
        address staticsDollarReceiver,
        address shareReceiver,
        uint256 minStaticsDollar,
        uint256 minShares
    ) external payable returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted);

    function depositWETH(
        uint256 wethAmount,
        address staticsDollarReceiver,
        address shareReceiver,
        uint256 minStaticsDollar,
        uint256 minShares
    ) external returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted);

    function recombineToWETH(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minWETHOut
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut);

    function recombineToWETHWithPermit(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minWETHOut,
        PermitSignature calldata permitSignature
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut);

    function recombineToETH(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minETHOut
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut);

    function recombineToETHWithPermit(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 maxSharesIn,
        address receiver,
        uint256 minETHOut,
        PermitSignature calldata permitSignature
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut);

    function previewPeggedMint(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview);

    function mintPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver
    ) external returns (uint256 collateralIn);

    function mintPeggedWithPermit(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver,
        PermitSignature calldata permitSignature
    ) external returns (uint256 collateralIn);

    function previewPeggedRedemption(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview);

    function redeemPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut);

    function redeemPeggedWithPermit(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver,
        PermitSignature calldata permitSignature
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut);

    function peggedRedemptionStatus()
        external
        view
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        );

    function pool() external view returns (address);
    function weth() external view returns (address);
    function staticsDollar() external view returns (address);
    function staticsDollarRisk() external view returns (address);
    function wethProfileId() external pure returns (uint256);
}
