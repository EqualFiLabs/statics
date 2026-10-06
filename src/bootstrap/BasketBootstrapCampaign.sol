// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketDelegation} from "../interfaces/IStaticsBasketDelegation.sol";
import {IStaticsBasketLaunchPreview} from "../interfaces/IStaticsBasketLaunchPreview.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {LibBasketLaunchMath} from "../libraries/LibBasketLaunchMath.sol";

/// @notice Firm procurement: suppliers sell assets for project tokens, never LP or refund rights.
contract BasketBootstrapCampaign is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 private constant RATE_SCALE = 1e18;
    enum State {
        Unprepared,
        Funding,
        Launched,
        Expired
    }

    struct Terms {
        address creator;
        address beneficiary;
        address projectToken;
        uint256 deadline;
        IStaticsBasket.CreateBasketParams basket;
        IStaticsBasket.PoolLaunchParams[] pools;
        uint256[] maximums;
        AuctionTerms[] auctions;
        address[] adapters;
    }

    struct AuctionTerms {
        uint256 targetCap;
        uint256 startRate;
        uint256 capRate;
        uint256 startsAt;
        uint256 endsAt;
        uint256 minimumFill;
    }

    struct Auction {
        bool activated;
        uint256 remaining;
        uint256 reservedPayment;
        uint256 acquired;
        uint256 paid;
    }
    address public immutable diamond;
    address public immutable creator;
    address public immutable beneficiary;
    address public immutable projectToken;
    uint256 public immutable deadline;
    bytes32 public immutable termsHash;
    bool public prepared;
    bool private launched;
    address public preparedToken;
    uint256 public basketId;
    bytes32 public requirementHash;
    uint256 public nativeRequired;
    uint256 public nativeInventory;
    uint256 public freePayment;
    uint256 public reservedPayment;
    IStaticsBasket.CreateBasketParams private definition;
    IStaticsBasket.PoolLaunchParams[] private pools;
    uint256[] private maximums;
    uint256[] private required;
    uint256[] private launchInventory;
    AuctionTerms[] private auctionTerms;
    Auction[] private auctions;
    mapping(address adapter => bool allowed) public revenueAdapters;
    IStaticsBasketDelegation.Authorization private authorization;
    bytes private creatorSignature;

    error InvalidCampaign();
    error CampaignNotFunding();
    error InvalidAuction();
    error InsufficientPaymentInventory();
    error InvalidFill();
    error InexactTransfer(address token);
    error InvalidRevenueAdapter();
    error CampaignNotReady();
    error LaunchCommitmentChanged();
    error InvalidPolCustody();
    error CampaignNotTerminal();
    error NativeTransferFailed();
    event CampaignPrepared(bytes32 indexed preparationId, address indexed token, bytes32 requirements);
    event Funded(address indexed sender, uint256 indexed assetIndex, uint256 amount, bool revenue);
    event PaymentFunded(address indexed sender, uint256 amount);
    event AuctionActivated(uint256 indexed assetIndex, uint256 target, uint256 paymentReserved);
    event AuctionFilled(
        uint256 indexed assetIndex,
        address indexed supplier,
        address indexed recipient,
        uint256 delivered,
        uint256 payment
    );
    event Bootstrapped(uint256 indexed basketId, address indexed token);
    event TerminalInventoryClaimed(address indexed beneficiary);

    constructor(address protocol, Terms memory terms) {
        uint256 length = terms.basket.assets.length;
        if (
            protocol.code.length == 0 || terms.creator == address(0) || terms.beneficiary == address(0)
                || terms.projectToken.code.length == 0 || terms.deadline <= block.timestamp || length == 0
                || length > 16 || terms.pools.length != length || terms.maximums.length != length
                || terms.auctions.length != length || terms.adapters.length > 16
        ) revert InvalidCampaign();
        diamond = protocol;
        creator = terms.creator;
        beneficiary = terms.beneficiary;
        projectToken = terms.projectToken;
        deadline = terms.deadline;
        termsHash = keccak256(abi.encode(protocol, terms));
        _storeDefinition(terms.basket);
        maximums = terms.maximums;
        // V1 procurement receives ordinary constituents, not arbitrary restricted-token exemptions.
        if (IStaticsBasketSettlement(protocol).isRestrictedBasketToken(terms.projectToken)) revert InvalidCampaign();
        for (uint256 i; i < length; ++i) {
            address asset = terms.basket.assets[i];
            if (asset.code.length == 0 || IStaticsBasketSettlement(protocol).isRestrictedBasketToken(asset)) {
                revert InvalidCampaign();
            }
            for (uint256 j; j < i; ++j) {
                if (terms.basket.assets[j] == asset) revert InvalidCampaign();
            }
            AuctionTerms memory procurement = terms.auctions[i];
            if (
                procurement.targetCap == 0 || procurement.minimumFill == 0
                    || procurement.minimumFill > procurement.targetCap || procurement.startRate == 0
                    || procurement.capRate < procurement.startRate || procurement.startsAt >= procurement.endsAt
                    || procurement.endsAt > terms.deadline
            ) revert InvalidCampaign();
            pools.push(terms.pools[i]);
            auctionTerms.push(procurement);
            auctions.push();
            launchInventory.push();
        }
        for (uint256 i; i < terms.adapters.length; ++i) {
            address adapter = terms.adapters[i];
            if (adapter.code.length == 0 || revenueAdapters[adapter]) revert InvalidCampaign();
            revenueAdapters[adapter] = true;
        }
    }

    function _storeDefinition(IStaticsBasket.CreateBasketParams memory params) private {
        definition.name = params.name;
        definition.symbol = params.symbol;
        definition.assets = params.assets;
        definition.bundleAmounts = params.bundleAmounts;
        definition.flashFeeBps = params.flashFeeBps;
        definition.originationFeeBps = params.originationFeeBps;
        definition.extensionFeeBps = params.extensionFeeBps;
        definition.ltvBps = params.ltvBps;
        definition.recoveryPenaltyBps = params.recoveryPenaltyBps;
        definition.loanDuration = params.loanDuration;
        for (uint256 i; i < params.mintFeeTiers.length; ++i) {
            definition.mintFeeTiers.push(params.mintFeeTiers[i]);
        }
        for (uint256 i; i < params.redemptionFeeTiers.length; ++i) {
            definition.redemptionFeeTiers.push(params.redemptionFeeTiers[i]);
        }
    }

    function state() public view returns (State) {
        if (launched) return State.Launched;
        if (block.timestamp >= deadline) return State.Expired;
        return prepared ? State.Funding : State.Unprepared;
    }

    function configuration()
        external
        view
        returns (IStaticsBasket.CreateBasketParams memory, IStaticsBasket.PoolLaunchParams[] memory, uint256[] memory)
    {
        return (definition, pools, maximums);
    }

    function launchAuthorization() external view returns (IStaticsBasketDelegation.Authorization memory) {
        return authorization;
    }

    function inventory(uint256 index)
        external
        view
        returns (address asset, uint256 target, uint256 held, uint256 missing)
    {
        return (definition.assets[index], required[index], launchInventory[index], deficit(index));
    }

    function assetCount() external view returns (uint256) {
        return definition.assets.length;
    }

    function auction(uint256 index) external view returns (AuctionTerms memory, Auction memory) {
        return (auctionTerms[index], auctions[index]);
    }

    function deficit(uint256 index) public view returns (uint256) {
        return required[index] > launchInventory[index] ? required[index] - launchInventory[index] : 0;
    }

    function revenueRecipient() external view returns (address) {
        State current = state();
        return current == State.Funding ? address(this) : beneficiary;
    }

    /// @dev No funds are accepted until deployment identities and exact requirements are reserved.
    function prepare(
        uint256 tokenNonce,
        uint256[] calldata hookNonces,
        IStaticsBasketDelegation.Authorization calldata intent,
        bytes calldata signature
    ) external nonReentrant {
        if (
            prepared || block.timestamp >= deadline || intent.creator != creator || intent.payer != address(this)
                || intent.deadline != deadline
        ) revert InvalidCampaign();
        (bytes32 id, address token) = IStaticsBasketDelegation(diamond)
            .prepareBasketCreationFor(definition, pools, maximums, tokenNonce, hookNonces, intent, signature);
        (address previewToken, LibBasketLaunchMath.Requirements memory requirements) =
            IStaticsBasketLaunchPreview(diamond).previewBasketLaunch(id, definition, pools, maximums, deadline);
        if (token != previewToken) revert InvalidCampaign();
        authorization = intent;
        creatorSignature = signature;
        preparedToken = token;
        required = requirements.totalAmounts;
        nativeRequired = requirements.nativeCreationFee;
        requirementHash = keccak256(abi.encode(requirements));
        prepared = true;
        emit CampaignPrepared(id, token, requirementHash);
    }

    function fund(uint256 index, uint256 amount) external nonReentrant {
        _fund(index, amount, false);
    }

    function deliverRevenue(uint256 index, uint256 amount) external nonReentrant {
        if (!revenueAdapters[msg.sender]) revert InvalidRevenueAdapter();
        _fund(index, amount, true);
    }

    function _fund(uint256 index, uint256 amount, bool revenue) private {
        _funding();
        if (amount == 0) revert InvalidFill();
        _receiveExact(definition.assets[index], msg.sender, amount);
        launchInventory[index] += amount;
        _resizeAuction(index);
        emit Funded(msg.sender, index, amount, revenue);
    }

    function fundPayment(uint256 amount) external nonReentrant {
        _funding();
        if (amount == 0) revert InvalidFill();
        _receiveExact(projectToken, msg.sender, amount);
        freePayment += amount;
        emit PaymentFunded(msg.sender, amount);
    }

    function fundNative() external payable nonReentrant {
        _funding();
        nativeInventory += msg.value;
    }

    /// @dev Rate is raw project-token units per raw underlying unit, scaled by 1e18.
    function rate(uint256 index) public view returns (uint256) {
        AuctionTerms storage terms = auctionTerms[index];
        if (block.timestamp <= terms.startsAt) return terms.startRate;
        if (block.timestamp >= terms.endsAt) return terms.capRate;
        return terms.startRate
            + Math.mulDiv(
            terms.capRate - terms.startRate, block.timestamp - terms.startsAt, terms.endsAt - terms.startsAt
        );
    }

    function capLiability(uint256 index, uint256 quantity) public view returns (uint256) {
        if (quantity == 0) return 0;
        AuctionTerms storage terms = auctionTerms[index];
        // At most ceil(quantity/minimumFill) fills, including one terminal-dust fill.
        // A ceil per fill adds strictly less than one raw payment unit to exact cap liability.
        return Math.mulDiv(quantity, terms.capRate, RATE_SCALE, Math.Rounding.Ceil)
            + Math.ceilDiv(quantity, terms.minimumFill);
    }

    function activateAuction(uint256 index) external nonReentrant {
        _funding();
        Auction storage book = auctions[index];
        AuctionTerms storage terms = auctionTerms[index];
        if (book.activated || block.timestamp >= terms.endsAt) revert InvalidAuction();
        uint256 target = Math.min(deficit(index), terms.targetCap);
        if (target == 0) revert InvalidAuction();
        uint256 liability = capLiability(index, target);
        if (freePayment < liability) revert InsufficientPaymentInventory();
        freePayment -= liability;
        reservedPayment += liability;
        book.activated = true;
        book.remaining = target;
        book.reservedPayment = liability;
        emit AuctionActivated(index, target, liability);
    }

    function quoteFill(uint256 index, uint256 amount) public view returns (uint256 payment) {
        Auction storage book = auctions[index];
        AuctionTerms storage terms = auctionTerms[index];
        if (
            state() != State.Funding || !book.activated || amount == 0 || amount > book.remaining
                || amount > deficit(index) || block.timestamp < terms.startsAt || block.timestamp >= terms.endsAt
                || (amount < terms.minimumFill && amount != book.remaining)
        ) revert InvalidFill();
        payment = Math.mulDiv(amount, rate(index), RATE_SCALE, Math.Rounding.Ceil);
    }

    function fill(uint256 index, uint256 amount, uint256 minimumPayment, address recipient, uint256 fillDeadline)
        external
        nonReentrant
        returns (uint256 payment)
    {
        if (recipient == address(0) || recipient == address(this) || block.timestamp > fillDeadline) {
            revert InvalidFill();
        }
        payment = quoteFill(index, amount);
        if (payment < minimumPayment) revert InvalidFill();
        Auction storage book = auctions[index];
        if (payment > book.reservedPayment) revert InsufficientPaymentInventory();
        _receiveExact(definition.assets[index], msg.sender, amount);
        launchInventory[index] += amount;
        book.remaining -= amount;
        book.acquired += amount;
        book.paid += payment;
        book.reservedPayment -= payment;
        reservedPayment -= payment;
        _resizeAuction(index);
        _sendExact(projectToken, recipient, payment);
        emit AuctionFilled(index, msg.sender, recipient, amount, payment);
    }

    function _resizeAuction(uint256 index) private {
        Auction storage book = auctions[index];
        if (!book.activated) return;
        book.remaining = Math.min(book.remaining, deficit(index));
        uint256 next = capLiability(index, book.remaining);
        if (next > book.reservedPayment) revert InsufficientPaymentInventory();
        uint256 released = book.reservedPayment - next;
        book.reservedPayment = next;
        reservedPayment -= released;
        freePayment += released;
    }

    function ready() public view returns (bool) {
        if (state() != State.Funding || nativeInventory < nativeRequired) return false;
        for (uint256 i; i < required.length; ++i) {
            if (deficit(i) != 0) return false;
        }
        return true;
    }

    function finalize() external nonReentrant returns (uint256 createdId, address token) {
        if (!ready()) revert CampaignNotReady();
        (address predicted, LibBasketLaunchMath.Requirements memory requirements) = IStaticsBasketLaunchPreview(diamond)
            .previewBasketLaunch(authorization.preparationId, definition, pools, maximums, deadline);
        if (predicted != preparedToken || keccak256(abi.encode(requirements)) != requirementHash) {
            revert LaunchCommitmentChanged();
        }
        uint256 length = required.length;
        uint256[] memory balances = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            IERC20 asset = IERC20(definition.assets[i]);
            balances[i] = asset.balanceOf(address(this));
            asset.forceApprove(diamond, required[i]);
        }
        (createdId, token) = IStaticsBasketDelegation(diamond).createBasketFor{value: nativeRequired}(
            definition, pools, maximums, authorization, creatorSignature
        );
        if (token != preparedToken || IStaticsBasket(diamond).basket(createdId).creator != creator) {
            revert LaunchCommitmentChanged();
        }
        for (uint256 i; i < length; ++i) {
            IERC20 asset = IERC20(definition.assets[i]);
            if (balances[i] - asset.balanceOf(address(this)) != required[i]) revert InexactTransfer(address(asset));
            asset.forceApprove(diamond, 0);
            launchInventory[i] -= required[i];
            _verifyPol(createdId, definition.assets[i]);
        }
        nativeInventory -= nativeRequired;
        launched = true;
        basketId = createdId;
        _releaseReserves();
        emit Bootstrapped(createdId, token);
    }

    function _verifyPol(uint256 createdId, address asset) private view {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool =
            IStaticsBasketLiquidity(diamond).canonicalPool(createdId, asset);
        IStaticsProtocolPools protocol = IStaticsProtocolPools(diamond);
        uint256[] memory ids = protocol.protocolPolPositionIds(pool.poolId);
        if (ids.length != 1 || protocol.protocolPool(pool.poolId).activePolPositions != 1) revert InvalidPolCustody();
        IStaticsProtocolPools.ProtocolPolPositionView memory position = protocol.protocolPolPosition(ids[0]);
        (address manager, bool installed) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (
            !installed || !position.active || position.manager != manager || position.liquidity == 0
                || IERC721(IStaticsLiquidityManager(manager).positionManager()).ownerOf(position.posmTokenId) != manager
        ) {
            revert InvalidPolCustody();
        }
    }

    function _releaseReserves() private {
        freePayment += reservedPayment;
        reservedPayment = 0;
        for (uint256 i; i < auctions.length; ++i) {
            auctions[i].remaining = 0;
            auctions[i].reservedPayment = 0;
        }
    }

    /// @notice Anyone may trigger closeout; only the immutable beneficiary can receive inventory.
    function claimTerminalInventory() external nonReentrant {
        State current = state();
        if (current != State.Launched && current != State.Expired) revert CampaignNotTerminal();
        _releaseReserves();
        freePayment = 0;
        nativeInventory = 0;
        bool projectIncluded;
        for (uint256 i; i < definition.assets.length; ++i) {
            address asset = definition.assets[i];
            launchInventory[i] = 0;
            if (asset == projectToken) projectIncluded = true;
            _sendExact(asset, beneficiary, IERC20(asset).balanceOf(address(this)));
        }
        if (!projectIncluded) _sendExact(projectToken, beneficiary, IERC20(projectToken).balanceOf(address(this)));
        uint256 nativeAmount = address(this).balance;
        if (nativeAmount != 0) {
            (bool ok,) = payable(beneficiary).call{value: nativeAmount}("");
            if (!ok) revert NativeTransferFailed();
        }
        emit TerminalInventoryClaimed(beneficiary);
    }

    function _funding() private view {
        if (state() != State.Funding) revert CampaignNotFunding();
    }

    function _receiveExact(address token, address sender, uint256 amount) private {
        IERC20 asset = IERC20(token);
        uint256 held = asset.balanceOf(address(this));
        uint256 balance = asset.balanceOf(sender);
        asset.safeTransferFrom(sender, address(this), amount);
        if (asset.balanceOf(address(this)) != held + amount || asset.balanceOf(sender) + amount != balance) {
            revert InexactTransfer(token);
        }
    }

    function _sendExact(address token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        IERC20 asset = IERC20(token);
        uint256 held = asset.balanceOf(address(this));
        uint256 balance = asset.balanceOf(recipient);
        asset.safeTransfer(recipient, amount);
        if (asset.balanceOf(address(this)) + amount != held || asset.balanceOf(recipient) != balance + amount) {
            revert InexactTransfer(token);
        }
    }
}
