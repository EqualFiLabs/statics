// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

struct GenesisVaultAccounting {
    uint256 vaultPrice;
    uint256 maximumSupply;
    uint256 mintedSupply;
    uint256 vaultInventory;
    uint256 circulatingGenesis;
    uint256 tokenBacking;
    uint256 requiredBacking;
    uint256 tokenCustody;
}

interface IStaticsGenesisVault {
    event GenesisPurchased(
        address indexed payer,
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 staticsPrice,
        uint256 nativeFee
    );
    event GenesisRedeemed(address indexed owner, address indexed receiver, uint256 indexed tokenId, uint256 price);
    event GenesisCollectionFinalized(address indexed collection, uint256 founderBacking);
    event PurchasesPausedSet(bool paused);
    event NativeAcquisitionFeeSet(uint256 previousFee, uint256 newFee);
    event NativeFeeRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event NativeAcquisitionFeesClaimed(address indexed recipient, address indexed receiver, uint256 amount);

    function buyGenesis(uint256 tokenId, address receiver) external payable;
    function redeemGenesis(uint256 tokenId, address receiver) external;
    function finalizeGenesisCollection(address collection) external;
    function setPurchasesPaused(bool paused) external;
    function setNativeAcquisitionFee(uint256 newFee) external;
    function setNativeFeeRecipient(address newRecipient) external;
    function claimNativeAcquisitionFees(address payable receiver) external returns (uint256 amount);
    function quoteGenesisPurchase() external view returns (uint256 staticsPrice, uint256 nativeFee);
    function vaultPrice() external view returns (uint256);
    function nativeAcquisitionFee() external view returns (uint256);
    function nativeFeeRecipient() external view returns (address);
    function claimableNativeFees(address recipient) external view returns (uint256);
    function totalNativeFeeLiability() external view returns (uint256);
    function circulatingGenesis() external view returns (uint256);
    function vaultInventory() external view returns (uint256);
    function requiredBacking() external view returns (uint256);
    function isVaultInventory(uint256 tokenId) external view returns (bool);
    function vaultAccounting() external view returns (GenesisVaultAccounting memory accounting);
}
