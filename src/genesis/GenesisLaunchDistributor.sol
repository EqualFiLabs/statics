// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGenesisActivationConsumer, IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IGenesisLaunchDistributor} from "../interfaces/IGenesisLaunchDistributor.sol";
import {IGenesisRecoveryDistributor} from "../interfaces/IGenesisRecoveryDistributor.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice Temporary two-asset launch reward index for registered Genesis NFTs.
/// @dev Finalization stops launch accrual and parameter changes; outstanding claims remain payable.
contract GenesisLaunchDistributor is
    IGenesisLaunchDistributor,
    IGenesisRecoveryDistributor,
    IGenesisActivationConsumer,
    Ownable2Step,
    ReentrancyGuard
{
    using LibExactAssetTransfer for IERC20;

    uint256 public constant RAY = 1e27;
    uint256 public constant BPS = 10_000;

    struct RewardBook {
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint256 totalClaimable;
        uint256 totalClaimed;
        uint256 treasuryClaimable;
    }

    struct GenesisAssetState {
        uint256 checkpointRay;
        uint256 settlementRemainderRay;
        uint256 accrued;
    }

    IStaticsFeeReceiver public immutable feeReceiver;
    IStaticsGenesis public immutable genesis;
    IGenesisActivationRegistry public immutable activationRegistry;
    address public immutable statics;
    address public immutable numeraire;
    address public immutable vault;
    address public immutable treasury;

    uint16 public genesisRewardShareBps;
    uint256 public totalWeight;
    bool public finalized;
    uint256 public override pendingGenesisRecovery;

    mapping(uint256 genesisId => bool registered) public registered;
    mapping(uint256 genesisId => uint256 weight) public effectiveWeight;
    mapping(address asset => RewardBook book) private _rewardBooks;
    mapping(uint256 genesisId => mapping(address asset => GenesisAssetState state)) private _genesisAssetState;
    mapping(address owner => mapping(address asset => uint256 amount)) public ownerClaimable;
    mapping(address owner => mapping(address asset => uint256 remainderRay)) public ownerClaimRemainderRay;
    mapping(address asset => uint256 amount) public accountedCustody;
    mapping(address asset => uint256 amount) public indexedReceiverAttribution;

    error InvalidContract(address target);
    error InvalidTreasury();
    error InvalidRewardPair(address statics, address numeraire);
    error InvalidRewardShare(uint256 shareBps);
    error InvalidRewardAsset(address asset);
    error InvalidReceiver(address receiver);
    error GenesisAlreadyRegistered(uint256 genesisId);
    error GenesisHeldByVault(uint256 genesisId);
    error NotGenesisOwner(uint256 genesisId, address caller, address owner);
    error UnauthorizedActivationRegistry(address caller);
    error UnauthorizedTreasury(address caller);
    error LaunchRewardsAlreadyFinalized();
    error FeeReceiverStillActive();
    error NoRewards();
    error InconsistentFeeTransfer(address asset, uint256 expected, uint256 received);
    error InsufficientSurplus(address asset, uint256 available, uint256 requested);
    error OwnershipRenunciationDisabled();
    error UnauthorizedRecoveryVault(address caller);
    error UnauthorizedRecoveryPredecessor(address caller);
    error InvalidRecoveryAmount();
    error RecoveryRolesNotActive();
    error UnexpectedRecoveryOwner(uint256 genesisId, address expectedOwner, address actualOwner);

    constructor(
        IStaticsFeeReceiver feeReceiver_,
        IStaticsGenesis genesis_,
        IGenesisActivationRegistry activationRegistry_,
        address treasury_,
        address governance,
        uint16 genesisRewardShareBps_
    ) Ownable(governance) {
        if (address(feeReceiver_) == address(0) || address(feeReceiver_).code.length == 0) {
            revert InvalidContract(address(feeReceiver_));
        }
        if (address(genesis_) == address(0) || address(genesis_).code.length == 0) {
            revert InvalidContract(address(genesis_));
        }
        if (address(activationRegistry_) == address(0) || address(activationRegistry_).code.length == 0) {
            revert InvalidContract(address(activationRegistry_));
        }
        if (treasury_ == address(0)) revert InvalidTreasury();
        if (genesisRewardShareBps_ > BPS) revert InvalidRewardShare(genesisRewardShareBps_);
        feeReceiver = feeReceiver_;
        genesis = genesis_;
        activationRegistry = activationRegistry_;
        address statics_ = feeReceiver_.statics();
        address numeraire_ = feeReceiver_.numeraire();
        if (
            statics_ == address(0) || numeraire_ == address(0) || statics_ == numeraire_ || statics_.code.length == 0
                || numeraire_.code.length == 0
        ) {
            revert InvalidRewardPair(statics_, numeraire_);
        }
        statics = statics_;
        numeraire = numeraire_;
        vault = genesis_.vault();
        treasury = treasury_;
        genesisRewardShareBps = genesisRewardShareBps_;
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function acceptFeeReceiverRole() external override onlyOwner {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        feeReceiver.acceptDistributor();
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function acceptActivationConsumer() external override onlyOwner {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        if (feeReceiver.activeDistributor() != address(this)) revert RecoveryRolesNotActive();
        activationRegistry.acceptConsumer();
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function registerGenesis(uint256 genesisId) external override nonReentrant {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        if (!genesisRecoveryReady()) revert RecoveryRolesNotActive();
        if (registered[genesisId]) revert GenesisAlreadyRegistered(genesisId);
        address tokenOwner = genesis.ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        if (tokenOwner == vault) revert GenesisHeldByVault(genesisId);

        _accrue();
        registered[genesisId] = true;
        uint256 weight = activationRegistry.multiplierBps(genesisId);
        effectiveWeight[genesisId] = weight;
        totalWeight += weight;
        _genesisAssetState[genesisId][statics].checkpointRay = _rewardBooks[statics].indexRay;
        _genesisAssetState[genesisId][numeraire].checkpointRay = _rewardBooks[numeraire].indexRay;
        emit GenesisRegistered(genesisId, weight, totalWeight);
        _flushPendingGenesisRecovery();
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function accrue() external override nonReentrant returns (uint256 staticsAmount, uint256 numeraireAmount) {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        return _accrue();
    }

    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16,
        uint16 nextMultiplierBps
    ) external override nonReentrant {
        if (msg.sender != address(activationRegistry)) revert UnauthorizedActivationRegistry(msg.sender);
        if (!registered[genesisId]) return;

        // Activation changes weight and checkpoints newly harvestable fees first. Owner-changing
        // transfers deliberately perform storage-only settlement so a reward-token failure cannot brick ERC-721 transfers.
        if (!finalized) {
            if (previousOwner == nextOwner) {
                _accrue();
            } else {
                _checkpointAttributed(statics);
                _checkpointAttributed(numeraire);
            }
        }
        _settle(genesisId, statics);
        _settle(genesisId, numeraire);
        if (previousOwner != nextOwner) {
            _crystallizeToOwner(genesisId, previousOwner, statics);
            _crystallizeToOwner(genesisId, previousOwner, numeraire);
        }

        uint256 previousWeight = effectiveWeight[genesisId];
        uint256 nextWeight = nextOwner == vault ? 0 : nextMultiplierBps;
        totalWeight = totalWeight - previousWeight + nextWeight;
        effectiveWeight[genesisId] = nextWeight;
        if (totalWeight == 0) {
            _rewardBooks[statics].indexRemainder = 0;
            _rewardBooks[numeraire].indexRemainder = 0;
        }
        emit GenesisWeightChanged(genesisId, previousWeight, nextWeight, totalWeight);
        _flushPendingGenesisRecovery();
    }

    function accrueGenesisRecovery(uint256 amount) external override nonReentrant {
        if (msg.sender != vault) revert UnauthorizedRecoveryVault(msg.sender);
        if (amount == 0) revert InvalidRecoveryAmount();
        IERC20 token = IERC20(statics);
        uint256 balance = token.balanceOf(address(this));
        uint256 accounted = accountedCustody[statics];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (available < amount) revert InconsistentFeeTransfer(statics, amount, available);
        accountedCustody[statics] = accounted + amount;

        if (totalWeight == 0) {
            pendingGenesisRecovery += amount;
            emit GenesisRecoveryAccrued(amount, pendingGenesisRecovery, _rewardBooks[statics].indexRay);
            return;
        }
        _increaseRecoveryIndex(amount);
        emit GenesisRecoveryAccrued(amount, pendingGenesisRecovery, _rewardBooks[statics].indexRay);
    }

    function checkpointGenesisRecovery(uint256 genesisId, address expectedOwner) external override nonReentrant {
        if (msg.sender != vault) revert UnauthorizedRecoveryVault(msg.sender);
        if (!genesisRecoveryReady()) revert RecoveryRolesNotActive();
        address tokenOwner = genesis.ownerOf(genesisId);
        if (tokenOwner != expectedOwner) revert UnexpectedRecoveryOwner(genesisId, expectedOwner, tokenOwner);

        _accrue();
        _settle(genesisId, statics);
        _settle(genesisId, numeraire);
        _crystallizeToOwner(genesisId, expectedOwner, statics);
        _crystallizeToOwner(genesisId, expectedOwner, numeraire);
    }

    function migratePendingGenesisRecovery(address successor) external override nonReentrant returns (uint256 amount) {
        if (msg.sender != address(feeReceiver)) revert UnauthorizedRecoveryPredecessor(msg.sender);
        amount = pendingGenesisRecovery;
        if (amount == 0) return 0;
        pendingGenesisRecovery = 0;
        accountedCustody[statics] -= amount;
        IERC20(statics).pushExact(successor, amount);
        IGenesisRecoveryDistributor(successor).acceptPendingGenesisRecovery(amount);
        emit PendingGenesisRecoveryMigrated(successor, amount);
    }

    function acceptPendingGenesisRecovery(uint256 amount) external override nonReentrant {
        if (msg.sender != feeReceiver.activeDistributor()) revert UnauthorizedRecoveryPredecessor(msg.sender);
        if (amount == 0) revert InvalidRecoveryAmount();
        IERC20 token = IERC20(statics);
        uint256 balance = token.balanceOf(address(this));
        uint256 accounted = accountedCustody[statics];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (available < amount) revert InconsistentFeeTransfer(statics, amount, available);
        accountedCustody[statics] = accounted + amount;
        pendingGenesisRecovery += amount;
        emit PendingGenesisRecoveryReceived(msg.sender, amount);
    }

    function genesisRecoveryVault() external view override returns (address) {
        return vault;
    }

    function genesisRecoveryAsset() external view override returns (address) {
        return statics;
    }

    function genesisRecoveryReady() public view override returns (bool) {
        return feeReceiver.activeDistributor() == address(this) && activationRegistry.activeConsumer() == address(this);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function claimGenesis(uint256 genesisId, address asset, address receiver)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        _validateAsset(asset);
        _validateReceiver(receiver);
        address tokenOwner = genesis.ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        if (!finalized) _accrue();
        amount = _consumeGenesisRewards(genesisId, asset, msg.sender, receiver);
        if (amount == 0) revert NoRewards();
        _releaseGenesisRewards(asset, receiver, amount);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function claimOwnerRewards(address asset, address receiver)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        _validateAsset(asset);
        _validateReceiver(receiver);
        if (!finalized) _accrue();
        amount = _consumeOwnerRewards(msg.sender, asset, receiver);
        if (amount == 0) revert NoRewards();
        _releaseGenesisRewards(asset, receiver, amount);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function claimTreasuryRewards(address asset, address receiver)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _validateAsset(asset);
        _validateReceiver(receiver);
        if (!finalized) _accrue();
        RewardBook storage book = _rewardBooks[asset];
        amount = book.treasuryClaimable;
        if (amount == 0) revert NoRewards();
        book.treasuryClaimable = 0;
        accountedCustody[asset] -= amount;
        IERC20(asset).pushExact(receiver, amount);
        emit TreasuryRewardsClaimed(asset, receiver, amount);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function claimAllGenesisRewards(uint256[] calldata genesisIds, address receiver)
        external
        override
        nonReentrant
        returns (uint256 staticsAmount, uint256 numeraireAmount)
    {
        _validateReceiver(receiver);
        uint256 count = genesisIds.length;
        for (uint256 i; i < count; ++i) {
            uint256 genesisId = genesisIds[i];
            address tokenOwner = genesis.ownerOf(genesisId);
            if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        }
        if (!finalized) _accrue();
        for (uint256 i; i < count; ++i) {
            uint256 genesisId = genesisIds[i];
            staticsAmount += _consumeGenesisRewards(genesisId, statics, msg.sender, receiver);
            numeraireAmount += _consumeGenesisRewards(genesisId, numeraire, msg.sender, receiver);
        }
        staticsAmount += _consumeOwnerRewards(msg.sender, statics, receiver);
        numeraireAmount += _consumeOwnerRewards(msg.sender, numeraire, receiver);
        if (staticsAmount == 0 && numeraireAmount == 0) revert NoRewards();
        _releaseGenesisRewards(statics, receiver, staticsAmount);
        _releaseGenesisRewards(numeraire, receiver, numeraireAmount);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function claimAllGenesisTreasuryRewards(address receiver)
        external
        override
        nonReentrant
        returns (uint256 staticsAmount, uint256 numeraireAmount)
    {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _validateReceiver(receiver);
        if (!finalized) _accrue();
        RewardBook storage staticsBook = _rewardBooks[statics];
        RewardBook storage numeraireBook = _rewardBooks[numeraire];
        staticsAmount = staticsBook.treasuryClaimable;
        numeraireAmount = numeraireBook.treasuryClaimable;
        if (staticsAmount == 0 && numeraireAmount == 0) revert NoRewards();
        staticsBook.treasuryClaimable = 0;
        numeraireBook.treasuryClaimable = 0;
        _releaseTreasuryRewards(statics, receiver, staticsAmount);
        _releaseTreasuryRewards(numeraire, receiver, numeraireAmount);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function setGenesisRewardShareBps(uint16 newShareBps) external override onlyOwner nonReentrant {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        if (newShareBps > BPS) revert InvalidRewardShare(newShareBps);
        _accrue();
        uint16 previous = genesisRewardShareBps;
        genesisRewardShareBps = newShareBps;
        emit GenesisRewardShareUpdated(previous, newShareBps);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function finalizeLaunchRewards() external override onlyOwner nonReentrant {
        if (finalized) revert LaunchRewardsAlreadyFinalized();
        if (feeReceiver.activeDistributor() == address(this)) revert FeeReceiverStillActive();
        _pullAttributed(statics);
        _pullAttributed(numeraire);
        finalized = true;
        emit LaunchRewardsFinalized(_rewardBooks[statics].indexRay, _rewardBooks[numeraire].indexRay);
    }

    /// @inheritdoc IGenesisLaunchDistributor
    function recoverSurplus(address asset, address receiver, uint256 amount) external override onlyOwner nonReentrant {
        _validateAsset(asset);
        _validateReceiver(receiver);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 accounted = accountedCustody[asset];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (amount > available) revert InsufficientSurplus(asset, available, amount);
        IERC20(asset).pushExact(receiver, amount);
        emit SurplusRecovered(asset, receiver, amount);
    }

    function pendingGenesis(uint256 genesisId, address asset) external view override returns (uint256 amount) {
        _validateAsset(asset);
        GenesisAssetState storage state = _genesisAssetState[genesisId][asset];
        amount = state.accrued;
        uint256 weight = effectiveWeight[genesisId];
        uint256 currentIndex = _rewardBooks[asset].indexRay;
        if (weight != 0 && currentIndex > state.checkpointRay) {
            amount += (weight * (currentIndex - state.checkpointRay) + state.settlementRemainderRay) / RAY;
        }
    }

    function rewardBook(address asset) external view override returns (RewardBookView memory book) {
        _validateAsset(asset);
        RewardBook storage stored = _rewardBooks[asset];
        book = RewardBookView({
            indexRay: stored.indexRay,
            indexRemainder: stored.indexRemainder,
            indexedAmount: stored.indexedAmount,
            crystallizedAmount: stored.crystallizedAmount,
            totalClaimable: stored.totalClaimable,
            totalClaimed: stored.totalClaimed,
            treasuryClaimable: stored.treasuryClaimable
        });
    }

    function _accrue() private returns (uint256 staticsAmount, uint256 numeraireAmount) {
        if (feeReceiver.activeDistributor() == address(this)) feeReceiver.harvest();
        staticsAmount = _pullAttributed(statics);
        numeraireAmount = _pullAttributed(numeraire);
    }

    function _pullAttributed(address asset) private returns (uint256 amount) {
        _checkpointAttributed(asset);
        amount = feeReceiver.distributorClaimable(address(this), asset);
        if (amount == 0) return 0;
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 reported = feeReceiver.claimDistributorFees(asset, address(this));
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (reported != amount || received != amount) revert InconsistentFeeTransfer(asset, amount, received);
        accountedCustody[asset] += amount;
    }

    /// @dev Indexes receiver-attributed revenue without moving reward tokens. Genesis transfers
    ///      use this storage-only path so a reward token cannot brick ERC-721 transfers while
    ///      already-attributed fees still settle to the previous owner.
    function _checkpointAttributed(address asset) private returns (uint256 amount) {
        uint256 cumulative = feeReceiver.cumulativeDistributorAttributed(address(this), asset);
        uint256 checkpoint = indexedReceiverAttribution[asset];
        amount = cumulative - checkpoint;
        if (amount == 0) return 0;
        indexedReceiverAttribution[asset] = cumulative;
        _allocate(asset, amount);
    }

    function _allocate(address asset, uint256 amount) private {
        RewardBook storage book = _rewardBooks[asset];
        uint256 genesisAmount;
        if (totalWeight != 0) genesisAmount = Math.mulDiv(amount, genesisRewardShareBps, BPS);
        uint256 treasuryAmount = amount - genesisAmount;
        book.treasuryClaimable += treasuryAmount;
        if (genesisAmount != 0) {
            uint256 scaled = genesisAmount * RAY + book.indexRemainder;
            book.indexRay += scaled / totalWeight;
            book.indexRemainder = scaled % totalWeight;
            book.indexedAmount += genesisAmount;
        }
        emit RevenueAccrued(asset, amount, genesisAmount, treasuryAmount, book.indexRay);
    }

    function _flushPendingGenesisRecovery() private {
        uint256 amount = pendingGenesisRecovery;
        if (amount == 0 || totalWeight == 0) return;
        pendingGenesisRecovery = 0;
        _increaseRecoveryIndex(amount);
        emit PendingGenesisRecoveryIndexed(amount, _rewardBooks[statics].indexRay);
    }

    function _increaseRecoveryIndex(uint256 amount) private {
        RewardBook storage book = _rewardBooks[statics];
        uint256 scaled = amount * RAY + book.indexRemainder;
        book.indexRay += scaled / totalWeight;
        book.indexRemainder = scaled % totalWeight;
        book.indexedAmount += amount;
    }

    function _consumeGenesisRewards(uint256 genesisId, address asset, address rewardOwner, address receiver)
        private
        returns (uint256 amount)
    {
        _settle(genesisId, asset);
        GenesisAssetState storage state = _genesisAssetState[genesisId][asset];
        amount = state.accrued;
        if (amount == 0) return 0;
        state.accrued = 0;
        emit GenesisRewardsClaimed(genesisId, rewardOwner, asset, receiver, amount);
    }

    function _consumeOwnerRewards(address rewardOwner, address asset, address receiver)
        private
        returns (uint256 amount)
    {
        amount = ownerClaimable[rewardOwner][asset];
        if (amount == 0) return 0;
        delete ownerClaimable[rewardOwner][asset];
        emit OwnerRewardsClaimed(rewardOwner, asset, receiver, amount);
    }

    function _releaseGenesisRewards(address asset, address receiver, uint256 amount) private {
        if (amount == 0) return;
        RewardBook storage book = _rewardBooks[asset];
        book.totalClaimable -= amount;
        book.totalClaimed += amount;
        accountedCustody[asset] -= amount;
        IERC20(asset).pushExact(receiver, amount);
    }

    function _releaseTreasuryRewards(address asset, address receiver, uint256 amount) private {
        if (amount == 0) return;
        accountedCustody[asset] -= amount;
        IERC20(asset).pushExact(receiver, amount);
        emit TreasuryRewardsClaimed(asset, receiver, amount);
    }

    function _settle(uint256 genesisId, address asset) private {
        GenesisAssetState storage state = _genesisAssetState[genesisId][asset];
        RewardBook storage book = _rewardBooks[asset];
        uint256 currentIndex = book.indexRay;
        uint256 weight = effectiveWeight[genesisId];
        if (weight != 0 && currentIndex > state.checkpointRay) {
            uint256 scaled = weight * (currentIndex - state.checkpointRay) + state.settlementRemainderRay;
            uint256 added = scaled / RAY;
            state.settlementRemainderRay = scaled % RAY;
            if (added != 0) {
                state.accrued += added;
                book.crystallizedAmount += added;
                book.totalClaimable += added;
            }
        }
        state.checkpointRay = currentIndex;
    }

    function _crystallizeToOwner(uint256 genesisId, address rewardOwner, address asset) private {
        GenesisAssetState storage state = _genesisAssetState[genesisId][asset];
        uint256 amount = state.accrued;
        if (amount != 0) {
            ownerClaimable[rewardOwner][asset] += amount;
            state.accrued = 0;
        }
        uint256 combinedRemainder = ownerClaimRemainderRay[rewardOwner][asset] + state.settlementRemainderRay;
        uint256 converted = combinedRemainder / RAY;
        ownerClaimRemainderRay[rewardOwner][asset] = combinedRemainder % RAY;
        state.settlementRemainderRay = 0;
        if (converted != 0) {
            ownerClaimable[rewardOwner][asset] += converted;
            RewardBook storage book = _rewardBooks[asset];
            book.crystallizedAmount += converted;
            book.totalClaimable += converted;
        }
    }

    function _validateAsset(address asset) private view {
        if (asset != statics && asset != numeraire) revert InvalidRewardAsset(asset);
    }

    function _validateReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver(receiver);
    }
}
