// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMoshSwarm, IMoshClaimMarket} from "../interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "./LibMoshValidation.sol";
import {MeasuredCampaignRevenue} from "./MeasuredCampaignRevenue.sol";
import {IRevenueWeth} from "./NativeCampaignRevenue.sol";
import {BasketBootstrapCampaign} from "./BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "./BasketBootstrapFactory.sol";

/// @notice Temporary native-counter Mosh claim custody with measured, realization-based rewards.
/// @dev Market returns are asynchronous. Anyone can reconcile the filled owner's offer before the next movement.
/// No Swarm principal, fee-conversion operator privilege, arbitrary calls, or direct transferClaim authority.
contract MoshShareRevenueAdapter is MeasuredCampaignRevenue {
    using SafeERC20 for IERC20;
    uint256 private constant SCALE = 1 << 160;
    uint256 private constant REWARD_CAPACITY = type(uint96).max;

    IMoshSwarm public immutable swarm;
    IMoshClaimMarket public immutable market;
    address public immutable sourceToken;
    bytes32 public immutable swarmRuntimeHash;
    bytes32 public immutable wethRuntimeHash;
    LibMoshValidation.SourcePins private sourcePins;
    LibMoshValidation.MarketPins private marketPins;

    struct ReturnOffer {
        uint256 id;
        uint256 amount;
        bool active;
    }

    mapping(address owner => uint256 amount) public shares;
    mapping(address owner => ReturnOffer offer) public pendingReturns;
    mapping(address owner => uint256 index) private rewardDebt;
    mapping(address owner => uint256 fraction) private rewardFraction;
    mapping(address owner => uint256 amount) public unpaid;
    uint256 public totalShares;
    uint256 public totalMeasured;
    uint256 public campaignNativeReserved;
    uint256 public userNativeReserved;
    uint256 public rewardIndex;
    uint256 public rewardCarry;
    uint256 public rewardCapacityUsed;
    uint256 public unreconciledShares;
    uint256 public returnProceeds;

    error InvalidMoshCustody();
    error UnreconciledReturn();
    event ClaimsDeposited(address indexed owner, uint256 indexed offerId, uint256 amount);
    event ReturnListed(address indexed owner, uint256 indexed offerId, uint256 amount);
    event ReturnReconciled(address indexed owner, uint256 indexed offerId, uint256 amount);
    event ReturnCancelled(address indexed owner, uint256 indexed offerId);
    event NativeRewardMeasured(uint256 amount, bool campaignOwned);
    event RewardsClaimed(address indexed owner, uint256 amount);

    constructor(
        address owner,
        address wrappedNative,
        bytes32 wrappedRuntimeHash,
        BasketBootstrapFactory campaigns,
        IMoshSwarm source,
        LibMoshValidation.SourcePins memory approvedSource,
        LibMoshValidation.MarketPins memory approvedMarket
    ) MeasuredCampaignRevenue(owner, wrappedNative, campaigns) {
        if (wrappedRuntimeHash == bytes32(0) || wrappedNative.codehash != wrappedRuntimeHash) {
            revert InvalidMoshCustody();
        }
        address token = source.memecoin();
        LibMoshValidation.validateNativeSource(source, token, approvedSource);
        LibMoshValidation.validateMarket(approvedSource.registry, approvedMarket);
        if (approvedMarket.feeBps >= 10_000) revert InvalidMoshCustody();
        swarm = source;
        sourceToken = token;
        market = IMoshClaimMarket(approvedMarket.market);
        sourcePins = approvedSource;
        marketPins = approvedMarket;
        swarmRuntimeHash = address(source).codehash;
        wethRuntimeHash = wrappedRuntimeHash;
    }

    function _validateCampaignBinding(BasketBootstrapCampaign destination) internal view override {
        if (destination.projectToken() != sourceToken) revert InvalidMoshCustody();
    }

    receive() external payable {
        _runtime();
        if (msg.sender == address(swarm)) {
            if (unreconciledShares != 0 || swarm.claim(address(this)) != totalShares || totalShares == 0) {
                revert InvalidMoshCustody();
            }
            _account(msg.value);
        } else if (msg.sender == address(market)) {
            uint256 actual = swarm.claim(address(this));
            if (msg.value != 1 || unreconciledShares != 0 || totalShares <= actual) revert InvalidMoshCustody();
            unreconciledShares = totalShares - actual;
            returnProceeds = 1;
        } else {
            revert InvalidMoshCustody();
        }
    }

    function sync() external nonReentrant returns (uint256 received) {
        uint256 beforeMeasured = totalMeasured;
        _sync();
        return totalMeasured - beforeMeasured;
    }

    function _sync() private {
        _runtime();
        if (unreconciledShares != 0) revert UnreconciledReturn();
        if (swarm.claim(address(this)) != totalShares) revert InvalidMoshCustody();
        if (address(campaign) == address(0) || !campaign.prepared()) revert InvalidMoshCustody();
        swarm.syncFees();
        if (swarm.claimable(address(this)) != 0) swarm.collectFees();
    }

    function deposit(uint256 offerId, uint256 amount) external payable nonReentrant {
        if (msg.value != 1 || amount == 0 || amount > type(uint128).max - totalShares) revert InvalidMoshCustody();
        LibMoshValidation.validateNativeSource(swarm, sourceToken, sourcePins);
        LibMoshValidation.validateMarket(sourcePins.registry, marketPins);
        LibMoshValidation.validateCustodyOffer(
            market, offerId, address(swarm), msg.sender, address(this), amount, marketPins.feeBps
        );
        _sync();
        _settle(msg.sender);
        uint256 senderBefore = swarm.claim(msg.sender);
        market.fill{value: 1}(offerId);
        if (swarm.claim(msg.sender) + amount != senderBefore || swarm.claim(address(this)) != totalShares + amount) {
            revert InvalidMoshCustody();
        }
        // Automatic payout during transfer belongs to the OLD distribution, not the entering claims.
        _settle(msg.sender);
        shares[msg.sender] += amount;
        totalShares += amount;
        rewardCarry = 0;
        emit ClaimsDeposited(msg.sender, offerId, amount);
    }

    /// @notice Prepares a buyer-bound return. Claims remain earning in custody until the owner fills the market offer.
    function withdraw(uint256 amount, uint256 deadline) external nonReentrant returns (uint256 offerId) {
        if (
            amount == 0 || amount > shares[msg.sender] || pendingReturns[msg.sender].active
                || deadline <= block.timestamp || deadline > type(uint64).max
        ) revert InvalidMoshCustody();
        _sync();
        _settle(msg.sender);
        LibMoshValidation.MarketPins memory exitPins = marketPins;
        exitPins.feeBps = market.feeBps();
        if (exitPins.feeBps >= 10_000) revert InvalidMoshCustody();
        LibMoshValidation.validateMarket(sourcePins.registry, exitPins);
        offerId = market.list(address(swarm), amount, 1, msg.sender, uint64(deadline));
        LibMoshValidation.validateCustodyOffer(
            market, offerId, address(swarm), address(this), msg.sender, amount, exitPins.feeBps
        );
        pendingReturns[msg.sender] = ReturnOffer(offerId, amount, true);
        emit ReturnListed(msg.sender, offerId, amount);
    }

    /// @notice Anyone can reconcile the actual filled owner's record; no recipient or amount can be substituted.
    function checkpointWithdrawal(address owner) external nonReentrant {
        _runtime();
        ReturnOffer memory offer = pendingReturns[owner];
        if (
            !offer.active || unreconciledShares != offer.amount || returnProceeds != 1
                || swarm.claim(address(this)) + offer.amount != totalShares
        ) revert InvalidMoshCustody();
        LibMoshValidation.Offer memory externalOffer = LibMoshValidation.readOffer(market, offer.id);
        if (externalOffer.swarm != address(0) || externalOffer.amount != 0) revert InvalidMoshCustody();
        _settle(owner);
        shares[owner] -= offer.amount;
        totalShares -= offer.amount;
        rewardCarry = 0;
        delete pendingReturns[owner];
        unreconciledShares = 0;
        returnProceeds = 0;
        // Never push native proceeds to a potentially rejecting wallet inside principal reconciliation.
        unpaid[owner] += 1;
        userNativeReserved += 1;
        emit ReturnReconciled(owner, offer.id, offer.amount);
    }

    function cancelWithdrawal() external nonReentrant {
        _runtime();
        ReturnOffer memory offer = pendingReturns[msg.sender];
        if (!offer.active || unreconciledShares != 0) revert InvalidMoshCustody();
        market.cancel(offer.id);
        delete pendingReturns[msg.sender];
        emit ReturnCancelled(msg.sender, offer.id);
    }

    /// @notice Forward only already-reserved campaign receipts. Failure rolls back and cannot lock claim principal.
    function flushCampaignRevenue() external nonReentrant returns (uint256 amount) {
        amount = campaignNativeReserved;
        if (amount == 0) return 0;
        address destination = recipient();
        campaignNativeReserved = 0;
        uint256 floor = payoutAsset.balanceOf(address(this));
        _wrap(amount);
        _deliverReceived(address(swarm), destination, amount, floor);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        _sync();
        _settle(msg.sender);
        amount = unpaid[msg.sender];
        if (amount == 0) return 0;
        unpaid[msg.sender] = 0;
        userNativeReserved -= amount;
        uint256 floor = payoutAsset.balanceOf(address(this));
        uint256 beforeUser = payoutAsset.balanceOf(msg.sender);
        _wrap(amount);
        payoutAsset.safeTransfer(msg.sender, amount);
        if (payoutAsset.balanceOf(address(this)) != floor || payoutAsset.balanceOf(msg.sender) != beforeUser + amount) {
            revert InexactRevenue();
        }
        emit RewardsClaimed(msg.sender, amount);
    }

    function rewards(address owner) external view returns (uint256) {
        uint256 delta = rewardIndex - rewardDebt[owner];
        uint256 fractional = mulmod(shares[owner], delta, SCALE) + rewardFraction[owner];
        return unpaid[owner] + Math.mulDiv(shares[owner], delta, SCALE) + fractional / SCALE;
    }

    function _account(uint256 amount) private {
        if (amount == 0 || address(campaign) == address(0) || !campaign.prepared()) revert InvalidMoshCustody();
        totalMeasured += amount;
        bool funding = campaign.state() == BasketBootstrapCampaign.State.Funding;
        if (funding) {
            campaignNativeReserved += amount;
        } else {
            if (amount > REWARD_CAPACITY - rewardCapacityUsed) revert InvalidMoshCustody();
            rewardCapacityUsed += amount;
            userNativeReserved += amount;
            uint256 numeratorCarry = mulmod(amount, SCALE, totalShares) + rewardCarry;
            rewardIndex += Math.mulDiv(amount, SCALE, totalShares) + numeratorCarry / totalShares;
            rewardCarry = numeratorCarry % totalShares;
        }
        emit NativeRewardMeasured(amount, funding);
    }

    function _settle(address owner) private {
        uint256 delta = rewardIndex - rewardDebt[owner];
        uint256 fractional = mulmod(shares[owner], delta, SCALE) + rewardFraction[owner];
        unpaid[owner] += Math.mulDiv(shares[owner], delta, SCALE) + fractional / SCALE;
        rewardFraction[owner] = fractional % SCALE;
        rewardDebt[owner] = rewardIndex;
    }

    function _wrap(uint256 amount) private {
        if (address(payoutAsset).codehash != wethRuntimeHash) revert InvalidMoshCustody();
        uint256 beforeNative = address(this).balance;
        IRevenueWeth(address(payoutAsset)).deposit{value: amount}();
        if (address(this).balance + amount != beforeNative) revert InexactRevenue();
    }

    function _runtime() private view {
        if (
            address(swarm).codehash != swarmRuntimeHash
                || sourcePins.implementation.codehash != sourcePins.implementationRuntimeHash
                || address(market).codehash != marketPins.runtimeHash
        ) revert InvalidMoshCustody();
    }
}
