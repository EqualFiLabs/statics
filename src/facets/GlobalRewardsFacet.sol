// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGenesis} from "../libraries/LibGenesis.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "../libraries/LibPositionPortfolio.sol";

contract GlobalRewardsFacet is IStaticsGlobalRewards, ReentrancyGuard {
    error InvalidAmount();
    error InvalidReceiver();
    error InvalidAmountsLength();
    error InvalidRewardAssets();
    error InsufficientStake(uint256 requested, uint256 available);
    error IncompatibleStakingToken(uint256 requested, uint256 received);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error NoRewards(uint256 positionId);

    function createAndStake(uint256 amount, address receiver, address[] calldata rewardAssets)
        external
        payable
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.STAKING_MODULE, bytes32(uint256(1))
        );
        _optIn(positionId, rewardAssets);
        _increaseStake(positionId, amount);
        emit StakingPositionCreated(positionId, receiver, amount);
    }

    function stake(uint256 positionId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        _increaseStake(positionId, amount);
    }

    function unstake(uint256 positionId, uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        uint256 balance = position.balance;
        if (amount > balance) revert InsufficientStake(amount, balance);
        LibGlobalRewards.decreaseStake(positionId, amount, LibGenesis.positionMultiplier(positionId));
        position.balance = balance - amount;
        rs.totalStaked -= amount;
        if (position.balance == 0) LibGlobalRewards.clearOptInsAfterFullUnstake(positionId);
        (uint256 spent, uint256 received) =
            LibCustody.pushReserved(LibCustody.stakingAccount(), rs.stakingToken, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
        emit Unstaked(positionId, receiver, amount, position.balance);
    }

    function optInRewardAssets(uint256 positionId, address[] calldata assets) external nonReentrant {
        if (assets.length == 0) revert InvalidRewardAssets();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        _optIn(positionId, assets);
        LibGlobalRewards.activateStakingLeg(positionId);
    }

    function optOutRewardAssets(uint256 positionId, address[] calldata assets) external nonReentrant {
        if (assets.length == 0) revert InvalidRewardAssets();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            LibGlobalRewards.optOut(positionId, assets[i]);
        }
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
    }

    function claimRewards(
        uint256 positionId,
        address[] calldata assets,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external nonReentrant returns (uint256[] memory amountsOut) {
        if (receiver == address(0)) revert InvalidReceiver();
        if (assets.length != minAmountsOut.length) revert InvalidAmountsLength();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        uint256 length = assets.length;
        amountsOut = new uint256[](length);
        bool hasRewards;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            LibGlobalRewards.settleAsset(positionId, asset);
            uint256 amount = position.claimable[asset];
            if (amount != 0) {
                hasRewards = true;
                position.claimable[asset] = 0;
                --position.claimAssetCount;
                rs.totalClaimable[asset] -= amount;
                if (position.optedInIndexPlusOne[asset] == 0) {
                    LibPositionPortfolio.removeGlobalRewardAsset(positionId, asset);
                }
                (, amountsOut[i]) = LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
                emit RewardClaimed(positionId, receiver, asset, amount);
            }
            if (amountsOut[i] < minAmountsOut[i]) {
                revert MinimumOutputNotMet(asset, amountsOut[i], minAmountsOut[i]);
            }
        }
        if (!hasRewards) revert NoRewards(positionId);
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
    }

    function distributeTreasuryFees(address asset) external nonReentrant returns (uint256 amount) {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        amount = rs.treasuryAccrued[asset];
        if (amount == 0) return 0;
        rs.treasuryAccrued[asset] = 0;
        address treasury_ = LibBasket.basketStorage().treasury;
        LibCustody.pushReserved(LibCustody.feeAccount(), asset, treasury_, amount, amount);
        emit TreasuryFeesDistributed(asset, treasury_, amount);
    }

    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = LibGlobalRewards.pending(positionId, assets[i]);
        }
    }

    function stakePosition(uint256 positionId) external view returns (StakePositionView memory position) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGlobalRewards.StakePosition storage stored = LibGlobalRewards.rewardStorage().positions[positionId];
        position = StakePositionView({
            stakedBalance: stored.balance,
            claimAssetCount: stored.claimAssetCount,
            optedInAssetCount: stored.optedInAssets.length
        });
    }

    function rewardAsset(address asset) external view returns (RewardAssetView memory state) {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.RewardBook storage stored = rs.books[asset];
        state = RewardAssetView({
            actualEligibleStake: LibGlobalRewards.effectiveActualEligibleStake(stored),
            actualPendingStake: LibGlobalRewards.effectiveActualPendingStake(stored),
            effectiveEligibleWeight: LibGlobalRewards.effectiveEligibleWeight(stored),
            effectivePendingWeight: LibGlobalRewards.effectivePendingWeight(stored),
            indexRay: stored.indexRay,
            indexRemainder: stored.indexRemainder,
            indexedReserve: stored.indexedAmount,
            totalClaimable: rs.totalClaimable[asset]
        });
    }

    function positionRewardAssets(uint256 positionId) external view returns (address[] memory assets) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        return LibGlobalRewards.rewardStorage().positions[positionId].optedInAssets;
    }

    function isRewardAssetOptedIn(uint256 positionId, address asset) external view returns (bool) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        return LibGlobalRewards.isOptedIn(positionId, asset);
    }

    function rewardSelection(uint256 positionId, address asset)
        external
        view
        returns (RewardSelectionView memory selection)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        return LibGlobalRewards.selectionView(positionId, asset);
    }

    function maxRewardAssetsPerPosition() external pure returns (uint256) {
        return LibGlobalRewards.MAX_REWARD_ASSETS_PER_POSITION;
    }

    function rewardEligibilityDelay() external pure returns (uint256) {
        return LibGlobalRewards.REWARD_ELIGIBILITY_DELAY;
    }

    function rewardEligibilityBucketSize() external pure returns (uint256) {
        return LibGlobalRewards.REWARD_BUCKET_SIZE;
    }

    function stakingToken() external view returns (address) {
        return LibGlobalRewards.rewardStorage().stakingToken;
    }

    function totalStaked() external view returns (uint256) {
        return LibGlobalRewards.rewardStorage().totalStaked;
    }

    function treasuryAccrued(address asset) external view returns (uint256) {
        return LibGlobalRewards.rewardStorage().treasuryAccrued[asset];
    }

    function canAccrueStakerRewards(address asset) external view returns (bool) {
        return LibGlobalRewards.effectiveEligibleWeight(LibGlobalRewards.rewardStorage().books[asset]) != 0;
    }

    function checkpointRewardAssets(address[] calldata assets) external {
        LibGlobalRewards.checkpointRewardAssets(assets);
    }

    function rewardBookNeedsCheckpoint(address asset) external view returns (bool) {
        return LibGlobalRewards.rewardBookNeedsCheckpoint(asset);
    }

    function _optIn(uint256 positionId, address[] calldata assets) private {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            LibGlobalRewards.optIn(positionId, assets[i], LibGenesis.positionMultiplier(positionId));
        }
    }

    function _increaseStake(uint256 positionId, uint256 amount) private {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.increaseStake(positionId, amount, LibGenesis.positionMultiplier(positionId));
        uint256 received = LibCustody.pullAndReserve(LibCustody.stakingAccount(), rs.stakingToken, msg.sender, amount);
        if (received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        position.balance += amount;
        rs.totalStaked += amount;
        LibGlobalRewards.activateStakingLeg(positionId);
        emit Staked(positionId, msg.sender, amount, position.balance);
    }
}
