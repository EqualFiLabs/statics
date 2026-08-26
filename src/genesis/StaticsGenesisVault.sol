// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IGenesisRecoveryDistributor} from "../interfaces/IGenesisRecoveryDistributor.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {
    GenesisCredit,
    GenesisCreditConfig,
    GenesisCreditRecoveryQuote,
    GenesisCreditServiceQuote,
    GenesisCreditView,
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
    using SafeCast for uint256;

    /// @notice STATICS backing supplied for each acquired Genesis.
    uint256 public constant GENESIS_PRICE = 180_000 ether;
    /// @notice Fixed reserve denominator. Never depends on circulating or vault-held Genesis.
    uint256 public constant RESERVE_DENOMINATOR = 5_555;
    /// @notice Self-consistent post-epoch buy-in denominator (N - 1).
    uint256 public constant RESERVE_BUY_IN_DENOMINATOR = 5_554;
    uint256 public constant DEFAULT_NATIVE_ACQUISITION_FEE = 0.003 ether;
    uint256 public constant MAX_NATIVE_ACQUISITION_FEE = 0.01 ether;
    uint256 public constant MAX_CREDIT_PRINCIPAL = 171_000 ether;
    uint256 public constant RECOVERY_RESIDUAL = 9_000 ether;
    uint256 public constant CREDIT_TERM = 30 days;
    uint256 public constant RECOVERY_GRACE = 1 hours;
    uint16 public constant BPS = 10_000;
    uint16 public constant INITIAL_CREDIT_SERVICE_RESERVE_SHARE_BPS = 1_000;
    uint16 public constant INITIAL_CREDIT_SERVICE_TREASURY_SHARE_BPS = 9_000;
    uint256 public constant INITIAL_TREASURY_GENESIS = 555;
    uint256 public constant INITIAL_VAULT_INVENTORY = RESERVE_DENOMINATOR - INITIAL_TREASURY_GENESIS;
    uint256 public constant INITIAL_TOKEN_BACKING = INITIAL_TREASURY_GENESIS * GENESIS_PRICE;

    IERC20 public immutable override statics;
    IStaticsFeeReceiver public immutable feeReceiver;
    address public immutable treasury;
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
    uint256 public override totalOutstandingGenesisCredit;
    uint256 public override creditOriginationFee;
    uint256 public override creditExtensionFee;
    uint16 public override recoveryCallerShareBps;
    uint16 public override creditServiceReserveShareBps;
    uint16 public override creditServiceTreasuryShareBps;
    bool public override creditOriginationsPaused;

    mapping(uint256 genesisId => GenesisCredit state) private _credit;

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
    error InvalidFeeReceiver();
    error InvalidTreasury();
    error InvalidRecoveryCallerShare(uint256 shareBps);
    error InvalidCreditServiceFeeSplit(uint256 reserveShareBps, uint256 treasuryShareBps);
    error CreditOriginationsPaused();
    error CreditUnavailableDuringEpoch();
    error InvalidCreditPrincipal(uint256 principal);
    error CreditAlreadyActive(uint256 genesisId);
    error CreditNotActive(uint256 genesisId);
    error CreditExpired(uint256 genesisId, uint40 maturity);
    error CreditNotRecoverable(uint256 genesisId, uint40 recoverableAt);
    error IncorrectNativeFee(uint256 provided, uint256 required);
    error NativeTreasuryTransferFailed(address treasury, uint256 amount);
    error InvalidRecoveryDistributor(address distributor);

    constructor(
        IERC20 statics_,
        address bootstrapper_,
        address governance,
        uint256 genesisEpochEnd_,
        GenesisCreditConfig memory creditConfig
    ) Ownable(governance) {
        if (address(statics_) == address(0)) revert InvalidStaticsToken();
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        if (genesisEpochEnd_ <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd_);
        if (creditConfig.feeReceiver == address(0) || creditConfig.feeReceiver.code.length == 0) {
            revert InvalidFeeReceiver();
        }
        if (IStaticsFeeReceiver(creditConfig.feeReceiver).statics() != address(statics_)) revert InvalidFeeReceiver();
        if (creditConfig.treasury == address(0) || creditConfig.treasury == address(this)) revert InvalidTreasury();
        _validateRecoveryCallerShare(creditConfig.recoveryCallerShareBps);
        statics = statics_;
        feeReceiver = IStaticsFeeReceiver(creditConfig.feeReceiver);
        treasury = creditConfig.treasury;
        bootstrapper = bootstrapper_;
        genesisEpochEnd = genesisEpochEnd_;
        nativeAcquisitionFee = DEFAULT_NATIVE_ACQUISITION_FEE;
        creditOriginationFee = creditConfig.originationFee;
        creditExtensionFee = creditConfig.extensionFee;
        recoveryCallerShareBps = creditConfig.recoveryCallerShareBps;
        creditServiceReserveShareBps = INITIAL_CREDIT_SERVICE_RESERVE_SHARE_BPS;
        creditServiceTreasuryShareBps = INITIAL_CREDIT_SERVICE_TREASURY_SHARE_BPS;
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
            genesis_.vault() != address(this) || genesis_.treasuryVesting() != msg.sender
                || genesis_.mintedSupply() != genesis_.COLLECTION_SIZE()
                || genesis_.balanceOf(address(this)) != INITIAL_VAULT_INVENTORY
                || genesis_.balanceOf(msg.sender) != INITIAL_TREASURY_GENESIS
                || genesis_.COLLECTION_SIZE() != RESERVE_DENOMINATOR
        ) revert InvalidGenesisCollection();

        genesis = genesis_;
        finalized = true;
        tokenBacking = INITIAL_TOKEN_BACKING;
        delete bootstrapper;
        genesis_.finalizeLaunch();
        _enforceSolvency();
        emit GenesisCollectionFinalized(collection);
    }

    /// @notice Permissionless reserve capitalization. Increases reserveETH by exactly msg.value.
    function donate() external payable override {
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
        uint256 buyIn = epochActive_ ? 0 : _reserveBuyIn(reserveETH);
        uint256 fee = nativeAcquisitionFee;
        uint256 requiredNative = buyIn + fee;
        if (msg.value < requiredNative) revert InsufficientNative(msg.value, requiredNative);

        // Effects: the fee always accretes to the reserve; the buy-in joins it after the epoch.
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
        if (_credit[tokenId].principal != 0) revert CreditAlreadyActive(tokenId);
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

    function openGenesisCredit(uint256 genesisId, uint256 principal)
        external
        payable
        override
        nonReentrant
        whenFinalized
    {
        if (creditOriginationsPaused) revert CreditOriginationsPaused();
        if (_epochActive()) revert CreditUnavailableDuringEpoch();
        if (principal == 0 || principal > MAX_CREDIT_PRINCIPAL) revert InvalidCreditPrincipal(principal);
        if (_credit[genesisId].principal != 0) revert CreditAlreadyActive(genesisId);
        address tokenOwner = genesis.ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        _activeRecoveryDistributor();

        uint40 maturity = (block.timestamp + CREDIT_TERM).toUint40();
        _credit[genesisId] = GenesisCredit({owner: msg.sender, principal: principal, maturity: maturity});
        totalOutstandingGenesisCredit += principal;
        tokenBacking -= principal;

        _collectCreditServiceFee(creditOriginationFee);
        statics.pushExact(msg.sender, principal);
        genesis.refreshLockStatus(genesisId);
        _enforceSolvency();
        emit GenesisCreditOpened(genesisId, msg.sender, principal, maturity, creditOriginationFee);
    }

    function extendGenesisCredit(uint256 genesisId) external payable override nonReentrant whenFinalized {
        GenesisCredit storage state = _credit[genesisId];
        uint256 principal = state.principal;
        if (principal == 0) revert CreditNotActive(genesisId);
        address tokenOwner = genesis.ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        uint40 previousMaturity = state.maturity;
        if (block.timestamp > previousMaturity) revert CreditExpired(genesisId, previousMaturity);

        uint40 newMaturity = (uint256(previousMaturity) + CREDIT_TERM).toUint40();
        state.maturity = newMaturity;
        _collectCreditServiceFee(creditExtensionFee);
        _enforceSolvency();
        emit GenesisCreditExtended(genesisId, msg.sender, previousMaturity, newMaturity, creditExtensionFee);
    }

    function repayGenesisCredit(uint256 genesisId) external override nonReentrant whenFinalized {
        GenesisCredit memory state = _credit[genesisId];
        uint256 principal = state.principal;
        if (principal == 0) revert CreditNotActive(genesisId);

        delete _credit[genesisId];
        totalOutstandingGenesisCredit -= principal;
        tokenBacking += principal;

        statics.pullExact(msg.sender, principal);
        genesis.refreshLockStatus(genesisId);
        _enforceSolvency();
        emit GenesisCreditRepaid(genesisId, msg.sender, state.owner, principal);
    }

    function recoverGenesisCredit(uint256 genesisId) external override nonReentrant whenFinalized {
        GenesisCredit memory state = _credit[genesisId];
        uint256 principal = state.principal;
        if (principal == 0) revert CreditNotActive(genesisId);
        uint40 recoverableAt = _recoverableAt(state.maturity);
        if (block.timestamp <= recoverableAt) revert CreditNotRecoverable(genesisId, recoverableAt);
        IGenesisRecoveryDistributor distributor = _activeRecoveryDistributor();

        uint256 unusedCredit = MAX_CREDIT_PRINCIPAL - principal;
        uint256 callerIncentive = Math.mulDiv(RECOVERY_RESIDUAL, recoveryCallerShareBps, BPS);
        uint256 genesisDistribution = RECOVERY_RESIDUAL - callerIncentive;

        distributor.checkpointGenesisRecovery(genesisId, state.owner);
        genesis.recoverToVault(genesisId, state.owner);

        delete _credit[genesisId];
        totalOutstandingGenesisCredit -= principal;
        tokenBacking -= GENESIS_PRICE - principal;
        if (unusedCredit != 0) statics.pushExact(state.owner, unusedCredit);
        statics.pushExact(msg.sender, callerIncentive);
        statics.pushExact(address(distributor), genesisDistribution);
        distributor.accrueGenesisRecovery(genesisDistribution);
        genesis.refreshLockStatus(genesisId);
        _enforceSolvency();
        emit GenesisCreditRecovered(
            genesisId, state.owner, msg.sender, principal, unusedCredit, callerIncentive, genesisDistribution
        );
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

    function setCreditOriginationFee(uint256 newFee) external override onlyOwner {
        uint256 previousFee = creditOriginationFee;
        creditOriginationFee = newFee;
        emit CreditOriginationFeeSet(previousFee, newFee);
    }

    function setCreditExtensionFee(uint256 newFee) external override onlyOwner {
        uint256 previousFee = creditExtensionFee;
        creditExtensionFee = newFee;
        emit CreditExtensionFeeSet(previousFee, newFee);
    }

    function setRecoveryCallerShareBps(uint16 newShareBps) external override onlyOwner {
        _validateRecoveryCallerShare(newShareBps);
        uint16 previousShareBps = recoveryCallerShareBps;
        recoveryCallerShareBps = newShareBps;
        emit RecoveryCallerShareSet(previousShareBps, newShareBps);
    }

    function setCreditServiceFeeSplit(uint16 reserveShareBps, uint16 treasuryShareBps) external override onlyOwner {
        if (uint256(reserveShareBps) + treasuryShareBps != BPS) {
            revert InvalidCreditServiceFeeSplit(reserveShareBps, treasuryShareBps);
        }
        uint16 previousReserveShareBps = creditServiceReserveShareBps;
        uint16 previousTreasuryShareBps = creditServiceTreasuryShareBps;
        creditServiceReserveShareBps = reserveShareBps;
        creditServiceTreasuryShareBps = treasuryShareBps;
        emit CreditServiceFeeSplitSet(
            previousReserveShareBps, previousTreasuryShareBps, reserveShareBps, treasuryShareBps
        );
    }

    function setCreditOriginationsPaused(bool paused) external override onlyOwner {
        creditOriginationsPaused = paused;
        emit CreditOriginationsPausedSet(paused);
    }

    function quoteGenesisPurchase() external view override returns (GenesisPurchaseQuote memory quote) {
        bool epochActive_ = _epochActive();
        uint256 buyIn = epochActive_ ? 0 : _reserveBuyIn(reserveETH);
        uint256 fee = nativeAcquisitionFee;
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

    function creditLimit(uint256 genesisId) external view override returns (uint256) {
        if (!finalized) return 0;
        try genesis.ownerOf(genesisId) returns (address tokenOwner) {
            return tokenOwner == address(this) ? 0 : MAX_CREDIT_PRINCIPAL;
        } catch {
            return 0;
        }
    }

    function credit(uint256 genesisId) external view override returns (GenesisCreditView memory state) {
        GenesisCredit storage stored = _credit[genesisId];
        uint256 principal = stored.principal;
        state = GenesisCreditView({
            owner: stored.owner,
            principal: principal,
            maturity: stored.maturity,
            recoverableAt: principal == 0 ? 0 : _recoverableAt(stored.maturity),
            active: principal != 0
        });
    }

    function creditActive(uint256 genesisId) external view override returns (bool) {
        return _credit[genesisId].principal != 0;
    }

    function creditRecoverableAt(uint256 genesisId) external view override returns (uint40) {
        GenesisCredit storage state = _credit[genesisId];
        return state.principal == 0 ? 0 : _recoverableAt(state.maturity);
    }

    function quoteGenesisCredit(uint256 principal)
        external
        view
        override
        returns (GenesisCreditServiceQuote memory quote)
    {
        if (principal == 0 || principal > MAX_CREDIT_PRINCIPAL) revert InvalidCreditPrincipal(principal);
        return _quoteCreditService(creditOriginationFee);
    }

    function quoteGenesisCreditExtension(uint256 genesisId)
        external
        view
        override
        returns (GenesisCreditServiceQuote memory quote)
    {
        if (_credit[genesisId].principal == 0) revert CreditNotActive(genesisId);
        return _quoteCreditService(creditExtensionFee);
    }

    function quoteGenesisCreditRecovery(uint256 genesisId)
        external
        view
        override
        returns (GenesisCreditRecoveryQuote memory quote)
    {
        GenesisCredit storage state = _credit[genesisId];
        uint256 principal = state.principal;
        if (principal == 0) revert CreditNotActive(genesisId);
        uint256 callerIncentive = Math.mulDiv(RECOVERY_RESIDUAL, recoveryCallerShareBps, BPS);
        quote = GenesisCreditRecoveryQuote({
            unusedCredit: MAX_CREDIT_PRINCIPAL - principal,
            recoveryResidual: RECOVERY_RESIDUAL,
            callerIncentive: callerIncentive,
            genesisDistribution: RECOVERY_RESIDUAL - callerIncentive,
            recoverableAt: _recoverableAt(state.maturity)
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
        return grossBacking() - totalOutstandingGenesisCredit;
    }

    function grossBacking() public view override returns (uint256) {
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
            grossBacking: circulating * GENESIS_PRICE,
            outstandingGenesisCredit: totalOutstandingGenesisCredit,
            requiredBacking: circulating * GENESIS_PRICE - totalOutstandingGenesisCredit,
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

    function _quoteCreditService(uint256 fee) private view returns (GenesisCreditServiceQuote memory quote) {
        uint16 reserveShareBps = creditServiceReserveShareBps;
        uint256 reservePortion = Math.mulDiv(fee, reserveShareBps, BPS);
        quote = GenesisCreditServiceQuote({
            totalNativeFee: fee,
            reserveShareBps: reserveShareBps,
            treasuryShareBps: creditServiceTreasuryShareBps,
            reservePortion: reservePortion,
            treasuryPortion: fee - reservePortion
        });
    }

    function _collectCreditServiceFee(uint256 fee) private {
        if (msg.value != fee) revert IncorrectNativeFee(msg.value, fee);
        uint256 reservePortion = Math.mulDiv(fee, creditServiceReserveShareBps, BPS);
        uint256 treasuryPortion = fee - reservePortion;
        if (reservePortion != 0) reserveETH += reservePortion;
        if (treasuryPortion != 0) {
            (bool paid,) = treasury.call{value: treasuryPortion}("");
            if (!paid) revert NativeTreasuryTransferFailed(treasury, treasuryPortion);
        }
    }

    function _activeRecoveryDistributor() private view returns (IGenesisRecoveryDistributor distributor) {
        address active = feeReceiver.activeDistributor();
        if (active == address(0) || active.code.length == 0) revert InvalidRecoveryDistributor(active);
        distributor = IGenesisRecoveryDistributor(active);
        try distributor.genesisRecoveryVault() returns (address recoveryVault) {
            if (recoveryVault != address(this)) revert InvalidRecoveryDistributor(active);
        } catch {
            revert InvalidRecoveryDistributor(active);
        }
        try distributor.genesisRecoveryAsset() returns (address recoveryAsset) {
            if (recoveryAsset != address(statics)) revert InvalidRecoveryDistributor(active);
        } catch {
            revert InvalidRecoveryDistributor(active);
        }
        try distributor.genesisRecoveryReady() returns (bool ready) {
            if (!ready) revert InvalidRecoveryDistributor(active);
        } catch {
            revert InvalidRecoveryDistributor(active);
        }
    }

    function _recoverableAt(uint40 maturity) private pure returns (uint40) {
        return (uint256(maturity) + RECOVERY_GRACE).toUint40();
    }

    function _validateRecoveryCallerShare(uint256 shareBps) private pure {
        if (shareBps == 0 || shareBps >= BPS) revert InvalidRecoveryCallerShare(shareBps);
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
