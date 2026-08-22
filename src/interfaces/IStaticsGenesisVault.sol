// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Full snapshot of Genesis Vault STATICS and native ETH reserve accounting.
struct GenesisVaultAccounting {
    uint256 vaultPrice;
    uint256 maximumSupply;
    uint256 mintedSupply;
    uint256 vaultInventory;
    uint256 circulatingGenesis;
    uint256 tokenBacking;
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

    function buyGenesis(uint256 tokenId, address receiver) external payable;
    function redeemGenesis(uint256 tokenId, address receiver) external;
    function finalizeGenesisCollection(address collection) external;
    function setPurchasesPaused(bool paused) external;
    function setNativeAcquisitionFee(uint256 newFee) external;
    function donate() external payable;

    function quoteGenesisPurchase() external view returns (GenesisPurchaseQuote memory quote);
    function quoteGenesisRedemption() external view returns (GenesisRedemptionQuote memory quote);
    function reserveBuyIn() external view returns (uint256);
    function reserveRedemptionPayout() external view returns (uint256);
    function reserveBackingPerGenesis() external view returns (uint256);
    function epochActive() external view returns (bool);
    function genesisEpochEnd() external view returns (uint256);
    function reserveETH() external view returns (uint256);
    function reserveDenominator() external view returns (uint256);
    function vaultPrice() external view returns (uint256);
    function nativeAcquisitionFee() external view returns (uint256);
    function circulatingGenesis() external view returns (uint256);
    function vaultInventory() external view returns (uint256);
    function requiredBacking() external view returns (uint256);
    function isVaultInventory(uint256 tokenId) external view returns (bool);
    function vaultAccounting() external view returns (GenesisVaultAccounting memory accounting);
}
