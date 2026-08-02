// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract GlobalRewardsFacet is IStaticsGlobalRewards, ReentrancyGuard {
    error InvalidAmount();
    error InvalidReceiver();
    error InvalidAmountsLength();
    error InsufficientStake(uint256 requested, uint256 available);
    error UnstakeCooldownActive(uint256 availableAt);
    error IncompatibleStakingToken(uint256 requested, uint256 received);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error NoRewards(uint256 positionId);
    error OnlySwapFeeHook(address caller, address expected);
    error IncompatibleRewardAsset(address asset, uint256 requested, uint256 received);

    function createAndStake(uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        positionId =
            IStaticsPositionModule(address(this)).createPositionForModule(receiver, LibPosition.stakingLegKey());
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
        uint256 availableAt = position.lastIncreaseTimestamp + LibGlobalRewards.UNSTAKE_COOLDOWN;
        if (block.timestamp < availableAt) revert UnstakeCooldownActive(availableAt);
        uint256 balance = position.balance;
        if (amount > balance) revert InsufficientStake(amount, balance);
        LibGlobalRewards.settleAll(positionId);
        LibGlobalRewards.resetIndexRemainders();
        position.balance = balance - amount;
        rs.totalStaked -= amount;
        (uint256 spent, uint256 received) = LibCustody.pushReserved(
            LibCustody.stakingAccount(), rs.stakingToken, receiver, amount, amount
        );
        if (spent != amount || received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
        emit Unstaked(positionId, receiver, amount, position.balance);
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

    function routeSwapFees(address asset, uint256 stakerAmount, uint256 treasuryAmount) external nonReentrant {
        address expected = LibBasketLiquidity.liquidityStorage().hook;
        if (msg.sender != expected) revert OnlySwapFeeHook(msg.sender, expected);
        uint256 total = stakerAmount + treasuryAmount;
        if (total == 0) return;
        uint256 received = LibCustody.pull(asset, msg.sender, total);
        if (received != total) revert IncompatibleRewardAsset(asset, total, received);
        LibCustody.reserve(LibCustody.feeAccount(), asset, total);
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, stakerAmount);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, treasuryAmount);
    }

    function beginRewardAssetRetirement(uint256 slot) external {
        LibDiamond.enforceIsContractOwner();
        if (slot >= LibGlobalRewards.MAX_REWARD_ASSETS) revert LibGlobalRewards.InvalidRewardSlot(slot);
        uint256 nextPositionId = LibPosition.positionStorage().nextPositionId;
        LibGlobalRewards.beginRetirement(uint8(slot), nextPositionId - 1);
    }

    function settleRetiringRewardAsset(uint256 slot, uint256 maxPositions)
        external
        returns (uint256 nextPositionId, bool complete)
    {
        if (slot >= LibGlobalRewards.MAX_REWARD_ASSETS) revert LibGlobalRewards.InvalidRewardSlot(slot);
        return LibGlobalRewards.settleRetirement(uint8(slot), maxPositions);
    }

    function finalizeRewardAssetRetirement(uint256 slot, address replacement) external {
        LibDiamond.enforceIsContractOwner();
        if (slot >= LibGlobalRewards.MAX_REWARD_ASSETS) revert LibGlobalRewards.InvalidRewardSlot(slot);
        LibGlobalRewards.finalizeRetirement(uint8(slot), replacement);
    }

    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) amounts[i] = LibGlobalRewards.pending(positionId, assets[i]);
    }

    function stakePosition(uint256 positionId) external view returns (StakePositionView memory position) {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGlobalRewards.StakePosition storage stored = LibGlobalRewards.rewardStorage().positions[positionId];
        position = StakePositionView({
            stakedBalance: stored.balance,
            unstakeAvailableAt: stored.lastIncreaseTimestamp + LibGlobalRewards.UNSTAKE_COOLDOWN,
            claimAssetCount: stored.claimAssetCount
        });
    }

    function rewardAsset(uint256 slot) external view returns (RewardAssetView memory state) {
        if (slot >= LibGlobalRewards.MAX_REWARD_ASSETS) revert LibGlobalRewards.InvalidRewardSlot(slot);
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.RewardSlot storage stored = rs.slots[slot];
        state = RewardAssetView({
            asset: stored.asset,
            status: stored.status,
            generation: stored.generation,
            indexRay: stored.indexRay,
            indexRemainder: stored.indexRemainder,
            indexedReserve: stored.indexedAmount,
            totalClaimable: rs.totalClaimable[stored.asset],
            retirementCursor: stored.retirementCursor,
            retirementHighWater: stored.retirementHighWater
        });
    }

    function rewardAssetSlot(address asset) external view returns (uint256 slot, bool activeOrRetiring) {
        uint256 plusOne = LibGlobalRewards.rewardStorage().slotPlusOne[asset];
        return plusOne == 0 ? (0, false) : (plusOne - 1, true);
    }

    function queuedRewardAsset(address asset) external view returns (bool queued) {
        return LibGlobalRewards.rewardStorage().queued[asset];
    }

    function rewardAssetQueue(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assets, bool[] memory queued, uint256 totalLength)
    {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        uint256 queueLength = rs.queue.length;
        if (offset >= queueLength || limit == 0) return (new address[](0), new bool[](0), queueLength);
        uint256 count = limit < queueLength - offset ? limit : queueLength - offset;
        assets = new address[](count);
        queued = new bool[](count);
        for (uint256 i; i < count; ++i) {
            address asset = rs.queue[offset + i];
            assets[i] = asset;
            queued[i] = rs.queued[asset];
        }
        return (assets, queued, queueLength);
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
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        uint256 plusOne = rs.slotPlusOne[asset];
        if (rs.totalStaked == 0 || rs.queued[asset]) return false;
        if (plusOne == 0) return rs.occupiedSlots < LibGlobalRewards.MAX_REWARD_ASSETS;
        return rs.slots[plusOne - 1].status == RewardAssetStatus.Active;
    }

    function _increaseStake(uint256 positionId, uint256 amount) private {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.settleAll(positionId);
        LibGlobalRewards.resetIndexRemainders();
        uint256 received = LibCustody.pullAndReserve(LibCustody.stakingAccount(), rs.stakingToken, msg.sender, amount);
        if (received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        position.balance += amount;
        position.lastIncreaseTimestamp = block.timestamp;
        rs.totalStaked += amount;
        LibGlobalRewards.activateStakingLeg(positionId);
        emit Staked(positionId, msg.sender, amount, position.balance);
    }
}
