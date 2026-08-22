// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGenesisActivationConsumer, IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice Permanent activation source of truth shared by launch rewards and the later Statics protocol.
///         Activation payments are forwarded in full to the Statics treasury; STATICS is never burned.
contract GenesisActivationRegistry is IGenesisActivationRegistry, Ownable2Step, ReentrancyGuard {
    using LibExactAssetTransfer for IERC20;

    uint8 public constant MAX_TIER = 4;
    uint256 public constant MIN_TIER_COST = 1_000 ether;
    uint256 public constant MAX_TIER_COST = 100_000 ether;

    IERC20 public immutable statics;
    address public immutable override treasury;
    address public bootstrapper;
    address public override genesisCollection;
    address public override activeConsumer;
    address public override pendingConsumer;

    mapping(uint256 genesisId => uint8 tier) private _tierOf;
    mapping(uint8 tier => uint256 cost) private _tierCost;

    error InvalidStaticsToken();
    error InvalidTreasury();
    error InvalidBootstrapper();
    error UnauthorizedBootstrapper(address caller);
    error InvalidGenesisCollection();
    error GenesisCollectionAlreadyBound();
    error UnauthorizedGenesisCollection(address caller);
    error InvalidGenesisOwner(uint256 genesisId, address caller, address owner);
    error InvalidTargetTier(uint8 currentTier, uint8 targetTier);
    error InvalidTier(uint8 tier);
    error TierCostOutOfBounds(uint256 cost, uint256 minimum, uint256 maximum);
    error InvalidConsumer(address consumer);
    error UnauthorizedPendingConsumer(address caller);
    error OwnershipRenunciationDisabled();

    constructor(IERC20 statics_, address bootstrapper_, address governance, address treasury_) Ownable(governance) {
        if (address(statics_) == address(0) || address(statics_).code.length == 0) revert InvalidStaticsToken();
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        if (treasury_ == address(0)) revert InvalidTreasury();
        statics = statics_;
        bootstrapper = bootstrapper_;
        treasury = treasury_;
        _tierCost[1] = 10_000 ether;
        _tierCost[2] = 20_000 ether;
        _tierCost[3] = 30_000 ether;
        _tierCost[4] = 40_000 ether;
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function tierOf(uint256 genesisId) public view override returns (uint8) {
        return _tierOf[genesisId];
    }

    function multiplierBps(uint256 genesisId) public view override returns (uint16) {
        return multiplierForTier(_tierOf[genesisId]);
    }

    function multiplierForTier(uint8 tier) public pure returns (uint16) {
        if (tier == 0) return 10_000;
        if (tier == 1) return 11_000;
        if (tier == 2) return 11_500;
        if (tier == 3) return 12_000;
        if (tier == 4) return 12_500;
        revert InvalidTier(tier);
    }

    function tierCost(uint8 tier) external view override returns (uint256) {
        if (tier == 0 || tier > MAX_TIER) revert InvalidTier(tier);
        return _tierCost[tier];
    }

    function bindGenesisCollection(address collection) external override {
        if (msg.sender != bootstrapper) revert UnauthorizedBootstrapper(msg.sender);
        if (genesisCollection != address(0)) revert GenesisCollectionAlreadyBound();
        if (collection == address(0) || collection.code.length == 0) revert InvalidGenesisCollection();
        try IStaticsGenesis(collection).activationRegistry() returns (address registry) {
            if (registry != address(this)) revert InvalidGenesisCollection();
        } catch {
            revert InvalidGenesisCollection();
        }
        genesisCollection = collection;
        delete bootstrapper;
        emit GenesisCollectionBound(collection);
    }

    /// @notice Activate a Genesis to a higher tier. The exact cumulative STATICS cost is transferred to
    ///         the Statics treasury. STATICS totalSupply is never reduced and Genesis backing is untouched.
    function activate(uint256 genesisId, uint8 targetTier) external override nonReentrant returns (uint256 paid) {
        address collection = genesisCollection;
        if (collection == address(0)) revert InvalidGenesisCollection();
        address tokenOwner = IERC721(collection).ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert InvalidGenesisOwner(genesisId, msg.sender, tokenOwner);
        uint8 currentTier = _tierOf[genesisId];
        if (targetTier <= currentTier || targetTier > MAX_TIER) revert InvalidTargetTier(currentTier, targetTier);

        for (uint8 tier = currentTier + 1; tier <= targetTier; ++tier) {
            paid += _tierCost[tier];
        }

        _notifyConsumer(
            genesisId, tokenOwner, tokenOwner, multiplierForTier(currentTier), multiplierForTier(targetTier)
        );
        _tierOf[genesisId] = targetTier;
        statics.pullExact(msg.sender, paid);
        statics.pushExact(treasury, paid);
        emit GenesisActivated(genesisId, currentTier, targetTier, paid);
        IStaticsGenesis(collection).refreshMetadata(genesisId);
    }

    function onGenesisTransfer(uint256 genesisId, address previousOwner, address nextOwner)
        external
        override
        nonReentrant
    {
        if (msg.sender != genesisCollection) revert UnauthorizedGenesisCollection(msg.sender);
        uint8 previousTier = _tierOf[genesisId];
        _notifyConsumer(genesisId, previousOwner, nextOwner, multiplierForTier(previousTier), multiplierForTier(0));
        if (previousTier != 0) {
            delete _tierOf[genesisId];
            emit GenesisActivationReset(genesisId, previousOwner, nextOwner);
        }
    }

    function setTierCost(uint8 tier, uint256 newCost) external override onlyOwner {
        if (tier == 0 || tier > MAX_TIER) revert InvalidTier(tier);
        if (newCost < MIN_TIER_COST || newCost > MAX_TIER_COST) {
            revert TierCostOutOfBounds(newCost, MIN_TIER_COST, MAX_TIER_COST);
        }
        uint256 previousCost = _tierCost[tier];
        _tierCost[tier] = newCost;
        emit TierCostUpdated(tier, previousCost, newCost);
    }

    function proposeConsumer(address consumer) external override onlyOwner {
        if (consumer == address(0) || consumer.code.length == 0 || consumer == activeConsumer) {
            revert InvalidConsumer(consumer);
        }
        pendingConsumer = consumer;
        emit ConsumerProposed(activeConsumer, consumer);
    }

    function acceptConsumer() external override {
        address pending = pendingConsumer;
        if (msg.sender != pending) revert UnauthorizedPendingConsumer(msg.sender);
        address previous = activeConsumer;
        activeConsumer = pending;
        delete pendingConsumer;
        emit ConsumerAccepted(previous, pending);
    }

    function _notifyConsumer(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplier,
        uint16 nextMultiplier
    ) private {
        address consumer = activeConsumer;
        if (consumer == address(0)) return;
        IGenesisActivationConsumer(consumer)
            .onGenesisTransition(genesisId, previousOwner, nextOwner, previousMultiplier, nextMultiplier);
    }
}
