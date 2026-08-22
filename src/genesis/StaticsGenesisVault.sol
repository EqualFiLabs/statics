// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {
    GenesisPurchaseQuote,
    GenesisRedemptionQuote,
    GenesisVaultAccounting,
    IStaticsGenesisVault
} from "../interfaces/IStaticsGenesisVault.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice Fixed-supply, dual-backed Genesis vault. Each Genesis is redeemable for exactly
///         180,000 STATICS and, after the immutable Genesis Epoch, a 1/5,555 share of a
///         permanent native ETH reserve. The reserve is capitalized by protocol revenue and
///         explicit donations; it can never be withdrawn by governance.
contract StaticsGenesisVault is IStaticsGenesisVault, IERC721Receiver, Ownable2Step, ReentrancyGuard {
    using LibExactAssetTransfer for IERC20;

    /// @notice STATICS backing supplied for each acquired Genesis.
    uint256 public constant GENESIS_PRICE = 180_000 ether;
    /// @notice Fixed reserve denominator. Never depends on circulating or vault-held Genesis.
    uint256 public constant RESERVE_DENOMINATOR = 5_555;
    /// @notice Self-consistent post-epoch buy-in denominator (N - 1).
    uint256 public constant RESERVE_BUY_IN_DENOMINATOR = 5_554;
    uint256 public constant DEFAULT_NATIVE_ACQUISITION_FEE = 0.003 ether;
    uint256 public constant MAX_NATIVE_ACQUISITION_FEE = 0.01 ether;

    IERC20 public immutable statics;
    /// @notice Immutable Genesis Epoch end. Before this timestamp reserve pricing is dormant.
    uint256 public immutable override genesisEpochEnd;
    address public bootstrapper;
    IStaticsGenesis public genesis;
    uint256 public tokenBacking;
    /// @notice Sole source of truth for native ETH reserve NAV. Forced ETH never increments it.
    uint256 public override reserveETH;
    uint256 public override nativeAcquisitionFee;
    bool public purchasesPaused;
    bool public finalized;

    error InvalidStaticsToken();
    error InvalidBootstrapper();
    error InvalidEpochEnd(uint256 genesisEpochEnd);
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
    error ReserveCustodyInsolvent(uint256 available, uint256 required);
    error InsufficientNative(uint256 provided, uint256 required);
    error UnexpectedNative(uint256 provided);
    error ZeroDonation();
    error NativeFeeExceedsMaximum(uint256 fee, uint256 maximumFee);
    error RefundFailed(address receiver, uint256 amount);
    error ReservePayoutFailed(address receiver, uint256 amount);
    error UnsupportedNFT(address collection);
    error OwnershipRenunciationDisabled();

    constructor(IERC20 statics_, address bootstrapper_, address governance, uint256 genesisEpochEnd_)
        Ownable(governance)
    {
        if (address(statics_) == address(0)) revert InvalidStaticsToken();
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        if (genesisEpochEnd_ <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd_);
        statics = statics_;
        bootstrapper = bootstrapper_;
        genesisEpochEnd = genesisEpochEnd_;
        nativeAcquisitionFee = DEFAULT_NATIVE_ACQUISITION_FEE;
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
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
                || genesis_.balanceOf(address(this)) != genesis_.COLLECTION_SIZE()
                || genesis_.COLLECTION_SIZE() != RESERVE_DENOMINATOR
        ) revert InvalidGenesisCollection();

        genesis = genesis_;
        finalized = true;
        delete bootstrapper;
        genesis_.finalizeLaunch();
        _enforceSolvency();
        emit GenesisCollectionFinalized(collection);
    }

    /// @notice Permissionless reserve capitalization. Increases reserveETH by exactly msg.value.
    function donate() external payable override nonReentrant {
        if (msg.value == 0) revert ZeroDonation();
        reserveETH += msg.value;
        _enforceSolvency();
        emit ReserveFunded(msg.sender, msg.value, reserveETH);
    }

    function buyGenesis(uint256 tokenId, address receiver)
        external
        payable
        override
        nonReentrant
        whenFinalized
        whenPurchasesOpen
    {
        _validateReceiver(receiver);
        if (genesis.balanceOf(address(this)) == 0) revert VaultInventoryEmpty();
        if (!_isVaultInventory(tokenId)) revert GenesisNotInVault(tokenId);

        bool epochActive_ = _epochActive();
        uint256 buyIn;
        uint256 fee;
        if (!epochActive_) {
            buyIn = _reserveBuyIn(reserveETH);
            fee = nativeAcquisitionFee;
        }
        uint256 requiredNative = buyIn + fee;
        if (msg.value < requiredNative) revert InsufficientNative(msg.value, requiredNative);

        // Effects: buy-in and fee both permanently accrete to the reserve after the epoch.
        statics.pullExact(msg.sender, GENESIS_PRICE);
        tokenBacking += GENESIS_PRICE;
        if (buyIn + fee != 0) reserveETH += buyIn + fee;

        // Interactions.
        genesis.safeTransferFrom(address(this), receiver, tokenId);
        uint256 refund = msg.value - requiredNative;
        if (refund != 0) {
            (bool refunded,) = msg.sender.call{value: refund}("");
            if (!refunded) revert RefundFailed(msg.sender, refund);
            emit PurchaseRefunded(msg.sender, refund);
        }
        _enforceSolvency();
        emit GenesisPurchased(msg.sender, receiver, tokenId, GENESIS_PRICE, buyIn, fee);
    }

    function redeemGenesis(uint256 tokenId, address receiver) external override nonReentrant whenFinalized {
        _validateReceiver(receiver);
        address tokenOwner = genesis.ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(tokenId, msg.sender, tokenOwner);
        if (tokenBacking < GENESIS_PRICE) revert InsufficientBacking(tokenBacking, GENESIS_PRICE);

        uint256 reservePayout = _epochActive() ? 0 : _reserveRedemptionPayout(reserveETH);

        // Effects.
        tokenBacking -= GENESIS_PRICE;
        if (reservePayout != 0) reserveETH -= reservePayout;

        // Interactions.
        genesis.transferFrom(msg.sender, address(this), tokenId);
        statics.pushExact(receiver, GENESIS_PRICE);
        if (reservePayout != 0) {
            (bool paid,) = receiver.call{value: reservePayout}("");
            if (!paid) revert ReservePayoutFailed(receiver, reservePayout);
        }
        _enforceSolvency();
        emit GenesisRedeemed(msg.sender, receiver, tokenId, GENESIS_PRICE, reservePayout);
    }

    function setPurchasesPaused(bool paused) external override onlyOwner {
        purchasesPaused = paused;
        emit PurchasesPausedSet(paused);
    }

    function setNativeAcquisitionFee(uint256 newFee) external override onlyOwner {
        if (newFee > MAX_NATIVE_ACQUISITION_FEE) {
            revert NativeFeeExceedsMaximum(newFee, MAX_NATIVE_ACQUISITION_FEE);
        }
        uint256 previousFee = nativeAcquisitionFee;
        nativeAcquisitionFee = newFee;
        emit NativeAcquisitionFeeSet(previousFee, newFee);
    }

    function quoteGenesisPurchase() external view override returns (GenesisPurchaseQuote memory quote) {
        bool epochActive_ = _epochActive();
        uint256 buyIn = epochActive_ ? 0 : _reserveBuyIn(reserveETH);
        uint256 fee = epochActive_ ? 0 : nativeAcquisitionFee;
        quote = GenesisPurchaseQuote({
            staticsPrice: GENESIS_PRICE,
            reserveBuyIn: buyIn,
            nativeFee: fee,
            requiredNative: buyIn + fee,
            epochActive: epochActive_
        });
    }

    function quoteGenesisRedemption() external view override returns (GenesisRedemptionQuote memory quote) {
        bool epochActive_ = _epochActive();
        quote = GenesisRedemptionQuote({
            staticsPayout: GENESIS_PRICE,
            reservePayout: epochActive_ ? 0 : _reserveRedemptionPayout(reserveETH),
            epochActive: epochActive_
        });
    }

    function reserveBuyIn() external view override returns (uint256) {
        return _epochActive() ? 0 : _reserveBuyIn(reserveETH);
    }

    function reserveRedemptionPayout() external view override returns (uint256) {
        return _epochActive() ? 0 : _reserveRedemptionPayout(reserveETH);
    }

    function reserveBackingPerGenesis() public view override returns (uint256) {
        return reserveETH / RESERVE_DENOMINATOR;
    }

    function epochActive() external view override returns (bool) {
        return _epochActive();
    }

    function reserveDenominator() external pure override returns (uint256) {
        return RESERVE_DENOMINATOR;
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
        bool epochActive_ = _epochActive();
        accounting = GenesisVaultAccounting({
            vaultPrice: GENESIS_PRICE,
            maximumSupply: RESERVE_DENOMINATOR,
            mintedSupply: minted,
            vaultInventory: inventory,
            circulatingGenesis: circulating,
            tokenBacking: tokenBacking,
            requiredBacking: circulating * GENESIS_PRICE,
            tokenCustody: statics.balanceOf(address(this)),
            reserveETH: reserveETH,
            nativeCustody: address(this).balance,
            genesisEpochEnd: genesisEpochEnd,
            epochActive: epochActive_,
            reserveBackingPerGenesis: reserveETH / RESERVE_DENOMINATOR
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (!finalized || msg.sender != address(genesis)) revert UnsupportedNFT(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _epochActive() private view returns (bool) {
        return block.timestamp < genesisEpochEnd;
    }

    /// @dev Post-epoch single-NFT reserve buy-in. Rounds up so integer truncation cannot dilute
    ///      the reserve: x = ceil(R / (N - 1)).
    function _reserveBuyIn(uint256 reserve) private pure returns (uint256) {
        return Math.ceilDiv(reserve, RESERVE_BUY_IN_DENOMINATOR);
    }

    /// @dev Post-epoch redemption payout. Rounds down so rounding dust stays with the reserve:
    ///      floor(R / N).
    function _reserveRedemptionPayout(uint256 reserve) private pure returns (uint256) {
        return reserve / RESERVE_DENOMINATOR;
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
        uint256 nativeCustody = address(this).balance;
        if (nativeCustody < reserveETH) revert ReserveCustodyInsolvent(nativeCustody, reserveETH);
    }
}
