// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {GenesisVaultAccounting, IStaticsGenesisVault} from "../interfaces/IStaticsGenesisVault.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice Fixed-price conversion between STATICS and circulating Genesis NFTs.
contract StaticsGenesisVault is IStaticsGenesisVault, IERC721Receiver, Ownable2Step, ReentrancyGuard {
    using LibExactAssetTransfer for IERC20;

    uint256 public constant GENESIS_PRICE = 180_010 ether;
    uint256 public constant FOUNDER_BACKING = 99_905_550 ether;

    IERC20 public immutable statics;
    address public immutable founderTreasury;
    address public bootstrapper;
    IStaticsGenesis public genesis;
    uint256 public tokenBacking;
    bool public purchasesPaused;
    bool public finalized;

    error InvalidStaticsToken();
    error InvalidBootstrapper();
    error InvalidReceiver(address receiver);
    error UnauthorizedBootstrapper(address caller);
    error AlreadyFinalized();
    error NotFinalized();
    error InvalidGenesisCollection();
    error PurchasesPaused();
    error VaultInventoryEmpty();
    error GenesisNotInVault(uint256 tokenId);
    error NotGenesisOwner(uint256 tokenId, address caller, address owner);
    error InsufficientBacking(uint256 available, uint256 required);
    error BackingInvariant(uint256 available, uint256 required);
    error CustodyInsolvent(uint256 available, uint256 required);
    error UnsupportedNFT(address collection);

    constructor(IERC20 statics_, address bootstrapper_, address governance, address founderTreasury_)
        Ownable(governance)
    {
        if (address(statics_) == address(0)) revert InvalidStaticsToken();
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        if (founderTreasury_ == address(0)) revert InvalidReceiver(founderTreasury_);
        statics = statics_;
        bootstrapper = bootstrapper_;
        founderTreasury = founderTreasury_;
    }

    modifier whenFinalized() {
        if (!finalized) revert NotFinalized();
        _;
    }

    modifier whenPurchasesOpen() {
        if (purchasesPaused) revert PurchasesPaused();
        _;
    }

    function finalizeGenesisCollection(address collection) external override nonReentrant {
        if (msg.sender != bootstrapper) revert UnauthorizedBootstrapper(msg.sender);
        if (finalized) revert AlreadyFinalized();
        if (collection == address(0) || collection.code.length == 0) revert InvalidGenesisCollection();
        IStaticsGenesis genesis_ = IStaticsGenesis(collection);
        if (
            genesis_.vault() != address(this) || genesis_.mintedSupply() != genesis_.COLLECTION_SIZE()
                || genesis_.balanceOf(address(this)) != genesis_.VAULT_GENESIS_COUNT()
                || genesis_.balanceOf(founderTreasury) != genesis_.TREASURY_GENESIS_COUNT()
        ) revert InvalidGenesisCollection();
        uint256 custody = statics.balanceOf(address(this));
        if (custody < FOUNDER_BACKING) revert CustodyInsolvent(custody, FOUNDER_BACKING);

        genesis = genesis_;
        tokenBacking = FOUNDER_BACKING;
        finalized = true;
        delete bootstrapper;
        genesis_.finalizeLaunch();
        _enforceSolvency();
        emit GenesisCollectionFinalized(collection, FOUNDER_BACKING);
    }

    function buyGenesis(uint256 tokenId, address receiver)
        external
        override
        nonReentrant
        whenFinalized
        whenPurchasesOpen
    {
        _validateReceiver(receiver);
        if (genesis.balanceOf(address(this)) == 0) revert VaultInventoryEmpty();
        if (!_isVaultInventory(tokenId)) revert GenesisNotInVault(tokenId);

        statics.pullExact(msg.sender, GENESIS_PRICE);
        tokenBacking += GENESIS_PRICE;
        genesis.safeTransferFrom(address(this), receiver, tokenId);
        _enforceSolvency();
        emit GenesisPurchased(msg.sender, receiver, tokenId, GENESIS_PRICE);
    }

    function redeemGenesis(uint256 tokenId, address receiver) external override nonReentrant whenFinalized {
        _validateReceiver(receiver);
        address tokenOwner = genesis.ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(tokenId, msg.sender, tokenOwner);
        if (tokenBacking < GENESIS_PRICE) revert InsufficientBacking(tokenBacking, GENESIS_PRICE);

        genesis.transferFrom(msg.sender, address(this), tokenId);
        tokenBacking -= GENESIS_PRICE;
        statics.pushExact(receiver, GENESIS_PRICE);
        _enforceSolvency();
        emit GenesisRedeemed(msg.sender, receiver, tokenId, GENESIS_PRICE);
    }

    function setPurchasesPaused(bool paused) external override onlyOwner {
        purchasesPaused = paused;
        emit PurchasesPausedSet(paused);
    }

    function vaultPrice() external pure override returns (uint256) {
        return GENESIS_PRICE;
    }

    function circulatingGenesis() public view override returns (uint256) {
        if (!finalized) return 0;
        return genesis.mintedSupply() - genesis.balanceOf(address(this));
    }

    function vaultInventory() public view override returns (uint256) {
        return finalized ? genesis.balanceOf(address(this)) : 0;
    }

    function requiredBacking() public view override returns (uint256) {
        return circulatingGenesis() * GENESIS_PRICE;
    }

    function isVaultInventory(uint256 tokenId) external view override returns (bool) {
        return finalized && _isVaultInventory(tokenId);
    }

    function vaultAccounting() external view override returns (GenesisVaultAccounting memory accounting) {
        uint256 minted = finalized ? genesis.mintedSupply() : 0;
        uint256 inventory = finalized ? genesis.balanceOf(address(this)) : 0;
        uint256 circulating = minted - inventory;
        accounting = GenesisVaultAccounting({
            vaultPrice: GENESIS_PRICE,
            maximumSupply: 5_555,
            mintedSupply: minted,
            vaultInventory: inventory,
            circulatingGenesis: circulating,
            tokenBacking: tokenBacking,
            requiredBacking: circulating * GENESIS_PRICE,
            tokenCustody: statics.balanceOf(address(this))
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (!finalized || msg.sender != address(genesis)) revert UnsupportedNFT(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _validateReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == address(genesis)) {
            revert InvalidReceiver(receiver);
        }
    }

    function _isVaultInventory(uint256 tokenId) private view returns (bool) {
        try genesis.ownerOf(tokenId) returns (address tokenOwner) {
            return tokenOwner == address(this);
        } catch {
            return false;
        }
    }

    function _enforceSolvency() private view {
        uint256 required = requiredBacking();
        uint256 backing = tokenBacking;
        if (backing < required) revert BackingInvariant(backing, required);
        uint256 custody = statics.balanceOf(address(this));
        if (custody < backing) revert CustodyInsolvent(custody, backing);
    }
}
