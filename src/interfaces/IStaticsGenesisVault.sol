// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct GenesisCreditConfig {
    address feeReceiver;
    address treasury;
    uint256 originationFee;
    uint256 extensionFee;
    uint16 recoveryCallerShareBps;
}

struct GenesisCredit {
    address owner;
    uint256 principal;
    uint40 maturity;
}

struct GenesisCreditServiceQuote {
    uint256 totalNativeFee;
    uint16 reserveShareBps;
    uint16 treasuryShareBps;
    uint256 reservePortion;
    uint256 treasuryPortion;
}

struct GenesisCreditView {
    address owner;
    uint256 principal;
    uint40 maturity;
    uint40 recoverableAt;
    bool active;
}

struct GenesisCreditRecoveryQuote {
    uint256 unusedCredit;
    uint256 recoveryResidual;
    uint256 callerIncentive;
    uint256 genesisDistribution;
    uint40 recoverableAt;
}

struct GenesisCreditAdjustmentQuote {
    uint256 currentPrincipal;
    uint256 newPrincipal;
    uint256 amountToOwner;
    uint256 amountFromOwner;
    uint256 totalNativeFee;
    uint16 reserveShareBps;
    uint16 treasuryShareBps;
    uint256 reservePortion;
    uint256 treasuryPortion;
}

/// @notice Full snapshot of Genesis Vault STATICS and native ETH reserve accounting.
struct GenesisVaultAccounting {
    uint256 vaultPrice;
    uint256 maximumSupply;
    uint256 mintedSupply;
    uint256 vaultInventory;
    uint256 circulatingGenesis;
    uint256 tokenBacking;
    uint256 grossBacking;
    uint256 outstandingGenesisCredit;
    uint256 requiredBacking;
    uint256 tokenCustody;
    uint256 reserveETH;
    uint256 nativeCustody;
    uint256 genesisEpochEnd;
    bool epochActive;
    uint256 reserveBackingPerGenesis;
}

/// @notice Deterministic pricing snapshot for a single Genesis acquisition.
struct GenesisPurchaseQuote {
    uint256 staticsPrice;
    uint256 reserveBuyIn;
    uint256 nativeFee;
    uint256 requiredNative;
    bool epochActive;
}

/// @notice Deterministic pricing snapshot for a single Genesis redemption.
struct GenesisRedemptionQuote {
    uint256 staticsPayout;
    uint256 reservePayout;
    bool epochActive;
}

interface IStaticsGenesisVault {
    event GenesisPurchased(
        address indexed payer,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 staticsPrice,
        uint256 reserveBuyIn,
        uint256 nativeFee
    );
    event GenesisRedeemed(
        address indexed owner,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 staticsPayout,
        uint256 reservePayout
    );
    event GenesisCollectionFinalized(address indexed collection);
    event PurchasesPausedSet(bool paused);
    event NativeAcquisitionFeeSet(uint256 previousFee, uint256 newFee);
    event ReserveFunded(address indexed contributor, uint256 amount, uint256 reserveETH);
    event PurchaseRefunded(address indexed payer, uint256 amount);
    event GenesisCreditOpened(
        uint256 indexed genesisId, address indexed owner, uint256 principal, uint40 maturity, uint256 nativeFee
    );
    event GenesisCreditExtended(
        uint256 indexed genesisId, address indexed owner, uint40 previousMaturity, uint40 newMaturity, uint256 nativeFee
    );
    event GenesisCreditPrincipalAdjusted(
        uint256 indexed genesisId,
        address indexed owner,
        uint256 previousPrincipal,
        uint256 newPrincipal,
        uint256 amountToOwner,
        uint256 amountFromOwner
    );
    event GenesisCreditRepaid(
        uint256 indexed genesisId,
        address indexed payer,
        address indexed owner,
        uint256 amount,
        uint256 remainingPrincipal
    );
    event GenesisCreditRecovered(
        uint256 indexed genesisId,
        address indexed formerOwner,
        address indexed caller,
        uint256 principal,
        uint256 unusedCredit,
        uint256 callerIncentive,
        uint256 genesisDistribution
    );
    event CreditOriginationFeeSet(uint256 previousFee, uint256 newFee);
    event CreditExtensionFeeSet(uint256 previousFee, uint256 newFee);
    event RecoveryCallerShareSet(uint16 previousShareBps, uint16 newShareBps);
    event CreditServiceFeeSplitSet(
        uint16 previousReserveShareBps,
        uint16 previousTreasuryShareBps,
        uint16 newReserveShareBps,
        uint16 newTreasuryShareBps
    );
    event CreditOriginationsPausedSet(bool paused);

    function buyGenesis(uint256 tokenId, address receiver) external payable;
    function redeemGenesis(uint256 tokenId, address receiver) external;
    function finalizeGenesisCollection(address collection) external;
    function setPurchasesPaused(bool paused) external;
    function setNativeAcquisitionFee(uint256 newFee) external;
    function donate() external payable;
    function openGenesisCredit(uint256 genesisId, uint256 principal) external payable;
    function extendGenesisCredit(uint256 genesisId, uint256 newPrincipal) external payable;
    function repayGenesisCredit(uint256 genesisId, uint256 amount) external;
    function recoverGenesisCredit(uint256 genesisId) external;
    function setCreditOriginationFee(uint256 newFee) external;
    function setCreditExtensionFee(uint256 newFee) external;
    function setRecoveryCallerShareBps(uint16 newShareBps) external;
    function setCreditServiceFeeSplit(uint16 reserveShareBps, uint16 treasuryShareBps) external;
    function setCreditOriginationsPaused(bool paused) external;

    function quoteGenesisPurchase() external view returns (GenesisPurchaseQuote memory quote);
    function quoteGenesisRedemption() external view returns (GenesisRedemptionQuote memory quote);
    function reserveBuyIn() external view returns (uint256);
    function reserveRedemptionPayout() external view returns (uint256);
    function reserveBackingPerGenesis() external view returns (uint256);
    function epochActive() external view returns (bool);
    function genesisEpochEnd() external view returns (uint256);
    function reserveETH() external view returns (uint256);
    function statics() external view returns (IERC20);
    function tokenBacking() external view returns (uint256);
    function reserveDenominator() external view returns (uint256);
    function vaultPrice() external view returns (uint256);
    function nativeAcquisitionFee() external view returns (uint256);
    function circulatingGenesis() external view returns (uint256);
    function vaultInventory() external view returns (uint256);
    function requiredBacking() external view returns (uint256);
    function isVaultInventory(uint256 tokenId) external view returns (bool);
    function vaultAccounting() external view returns (GenesisVaultAccounting memory accounting);
    function creditLimit(uint256 genesisId) external view returns (uint256);
    function creditAvailable(uint256 genesisId) external view returns (uint256);
    function credit(uint256 genesisId) external view returns (GenesisCreditView memory state);
    function creditActive(uint256 genesisId) external view returns (bool);
    function creditRecoverableAt(uint256 genesisId) external view returns (uint40);
    function quoteGenesisCredit(uint256 principal) external view returns (GenesisCreditServiceQuote memory quote);
    function quoteGenesisCreditExtension(uint256 genesisId)
        external
        view
        returns (GenesisCreditServiceQuote memory quote);
    function quoteGenesisCreditAdjustment(uint256 genesisId, uint256 newPrincipal)
        external
        view
        returns (GenesisCreditAdjustmentQuote memory quote);
    function quoteGenesisCreditRecovery(uint256 genesisId)
        external
        view
        returns (GenesisCreditRecoveryQuote memory quote);
    function grossBacking() external view returns (uint256);
    function totalOutstandingGenesisCredit() external view returns (uint256);
    function creditOriginationFee() external view returns (uint256);
    function creditExtensionFee() external view returns (uint256);
    function recoveryCallerShareBps() external view returns (uint16);
    function creditServiceReserveShareBps() external view returns (uint16);
    function creditServiceTreasuryShareBps() external view returns (uint16);
    function creditOriginationsPaused() external view returns (bool);
}
