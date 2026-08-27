// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct GenesisCreditConfig {
    /// @dev Fee receiver used for recovery-distributor validation.
    address feeReceiver;
    /// @dev Treasury receiving the treasury share of native credit fees.
    address treasury;
    /// @dev Native origination fee in wei.
    uint256 originationFee;
    /// @dev Native extension fee in wei.
    uint256 extensionFee;
    /// @dev Recovery caller incentive in basis points.
    uint16 recoveryCallerShareBps;
}

struct GenesisCredit {
    /// @dev Current Genesis owner responsible for repayment.
    address owner;
    /// @dev Outstanding principal in STATICS wei.
    uint256 principal;
    /// @dev Unix timestamp at which recovery becomes eligible after grace.
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

/// @notice Fixed-price Genesis custody, reserve, and secured-credit interface.
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
    event GenesisCreditDrawn(
        uint256 indexed genesisId, address indexed owner, uint256 amount, uint256 newPrincipal, uint256 nativeFee
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
    event CreditIncreasesPausedSet(bool paused);

    /// @notice Purchases a vault-held Genesis for the fixed STATICS price.
    /// @dev Excess native value is refunded; the acquisition fee always increases the reserve.
    /// @param tokenId Vault-held Genesis token ID.
    /// @param receiver Recipient of the purchased Genesis.
    function buyGenesis(uint256 tokenId, address receiver) external payable;
    /// @notice Redeems a caller-owned Genesis for STATICS and, after the epoch, its reserve share.
    /// @param tokenId Genesis token ID.
    /// @param receiver Recipient of the redemption assets.
    function redeemGenesis(uint256 tokenId, address receiver) external;
    /// @notice Finalizes the collection binding and opens the launch lifecycle.
    /// @param collection Genesis ERC-721 collection address.
    function finalizeGenesisCollection(address collection) external;
    /// @notice Pauses or resumes Genesis purchases.
    /// @param paused Whether purchases should be paused.
    function setPurchasesPaused(bool paused) external;
    /// @notice Sets the native acquisition fee, subject to its configured maximum.
    /// @param newFee New fee in wei.
    function setNativeAcquisitionFee(uint256 newFee) external;
    /// @notice Permissionless reserve capitalization by native ETH.
    function donate() external payable;
    /// @notice Opens secured credit against a caller-owned Genesis.
    /// @dev `msg.value` must equal the configured origination fee.
    /// @param genesisId Genesis token ID.
    /// @param principal Principal advanced in STATICS wei.
    function openGenesisCredit(uint256 genesisId, uint256 principal) external payable;
    /// @notice Increases utilization for an active Genesis credit.
    /// @dev `msg.value` must equal the configured origination fee.
    /// @param genesisId Genesis token ID.
    /// @param amount Additional principal in STATICS wei.
    function drawGenesisCredit(uint256 genesisId, uint256 amount) external payable;
    /// @notice Extends the maturity of an active Genesis credit.
    /// @dev `msg.value` must equal the configured extension fee.
    /// @param genesisId Genesis token ID.
    function extendGenesisCredit(uint256 genesisId) external payable;
    /// @notice Repays part or all of an active credit; permissionless for the payer.
    /// @param genesisId Genesis token ID.
    /// @param amount Repayment amount in STATICS wei.
    function repayGenesisCredit(uint256 genesisId, uint256 amount) external;
    /// @notice Recovers an expired credit after its maturity grace period.
    /// @param genesisId Genesis token ID.
    function recoverGenesisCredit(uint256 genesisId) external;
    function setCreditOriginationFee(uint256 newFee) external;
    function setCreditExtensionFee(uint256 newFee) external;
    function setRecoveryCallerShareBps(uint16 newShareBps) external;
    function setCreditServiceFeeSplit(uint16 reserveShareBps, uint16 treasuryShareBps) external;
    function setCreditIncreasesPaused(bool paused) external;

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
    /// @notice Returns the native fee split for a prospective credit origination.
    /// @param principal Prospective principal in STATICS wei.
    /// @return quote Fee and reserve/treasury split snapshot; not an execution guarantee.
    function quoteGenesisCredit(uint256 principal) external view returns (GenesisCreditServiceQuote memory quote);
    function quoteGenesisCreditExtension(uint256 genesisId)
        external
        view
        returns (GenesisCreditServiceQuote memory quote);
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
    function creditIncreasesPaused() external view returns (bool);
}
