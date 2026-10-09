// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibRewardPayout} from "../libraries/LibRewardPayout.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "../libraries/LibPositionPortfolio.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPoolRewards} from "../libraries/LibPoolRewards.sol";
import {LibRewardPolicy} from "../libraries/LibRewardPolicy.sol";

contract GlobalRewardsFacet is ReentrancyGuard {
    error InvalidAmount();
    error InvalidReceiver();
    error InvalidAmountsLength();
    error InvalidRewardAssets();
    error InsufficientStake(uint256 requested, uint256 available);
    error IncompatibleStakingToken(uint256 requested, uint256 received);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error NoRewards(uint256 positionId);
    error ActionPaused(uint256 action);
    error LiquidityIntegrationNotInstalled();

    function createAndStake(uint256 amount, address receiver, address[] calldata rewardAssets)
        external
        payable
        nonReentrant
        returns (uint256 positionId)
    {
        _enforceStakeIngressAvailable();
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.STAKING_MODULE, bytes32(uint256(1))
        );
        _optIn(positionId, rewardAssets);
        _increaseStake(positionId, amount);
        emit IStaticsGlobalRewards.StakingPositionCreated(positionId, receiver, amount);
    }

    function stake(uint256 positionId, uint256 amount) external nonReentrant {
        _enforceStakeIngressAvailable();
        if (amount == 0) revert InvalidAmount();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        _increaseStake(positionId, amount);
    }

    function unstake(uint256 positionId, uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        uint256 balance = position.balance;
        uint256 collateral = LibMorpho.morphoStorage().staticsCollateral[positionId];
        uint256 gaugeLocked = LibGaugeRouting.lockedStake(positionId);
        uint256 locked = collateral > gaugeLocked ? collateral : gaugeLocked;
        uint256 available = balance > locked ? balance - locked : 0;
        if (amount > available) revert InsufficientStake(amount, available);
        LibGlobalRewards.decreaseStake(positionId, amount);
        position.balance = balance - amount;
        rs.totalStaked -= amount;
        IStaticsGaugeIncentives(address(this)).syncGaugeAllocationsAfterStakeLoss(positionId, position.balance);
        if (position.balance == 0) LibGlobalRewards.clearOptInsAfterFullUnstake(positionId);
        (uint256 spent, uint256 received) =
            LibCustody.pushReserved(LibCustody.stakingAccount(), rs.stakingToken, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
        emit IStaticsGlobalRewards.Unstaked(positionId, receiver, amount, position.balance);
    }

    function optInRewardAssets(uint256 positionId, address[] calldata assets) external nonReentrant {
        _enforceStakeIngressAvailable();
        if (assets.length == 0) revert InvalidRewardAssets();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        _optIn(positionId, assets);
        LibGlobalRewards.activateStakingLeg(positionId);
    }

    function optOutRewardAssets(uint256 positionId, address[] calldata assets) external nonReentrant {
        if (assets.length == 0) revert InvalidRewardAssets();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
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
        LibMorpho.syncIfInitialized(positionId, msg.sender);
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
                _fundRewardShortfall(asset, amount);
                hasRewards = true;
                position.claimable[asset] = 0;
                --position.claimAssetCount;
                rs.totalClaimable[asset] -= amount;
                if (position.optedInIndexPlusOne[asset] == 0) {
                    LibPositionPortfolio.removeGlobalRewardAsset(positionId, asset);
                }
            }
            amountsOut[i] = _payClaim(positionId, asset, receiver, amount);
            if (amountsOut[i] < minAmountsOut[i]) {
                revert MinimumOutputNotMet(asset, amountsOut[i], minAmountsOut[i]);
            }
        }
        if (!hasRewards) revert NoRewards(positionId);
        LibGlobalRewards.deactivateStakingLegIfEmpty(positionId);
    }

    function _payClaim(uint256 positionId, address asset, address receiver, uint256 amount)
        private
        returns (uint256 received)
    {
        uint256 debited;
        (debited, received) = LibRewardPayout.payMeasured(LibCustody.feeAccount(), asset, receiver, amount);
        if (amount != 0) emit IStaticsGlobalRewards.RewardClaimed(positionId, receiver, asset, debited, received);
    }

    function distributeTreasuryFees(address asset) external nonReentrant returns (uint256 amount) {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_TREASURY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_TREASURY);
        }
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        amount = rs.treasuryAccrued[asset];
        if (amount == 0) return 0;
        _fundRewardShortfall(asset, amount);
        rs.treasuryAccrued[asset] = 0;
        address treasury_ = LibBasket.basketStorage().treasury;
        LibCustody.pushReserved(LibCustody.feeAccount(), asset, treasury_, amount, amount);
        emit IStaticsGlobalRewards.TreasuryFeesDistributed(asset, treasury_, amount);
    }

    function rewardAsset(address asset) external view returns (IStaticsGlobalRewards.RewardAssetView memory state) {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.RewardBook storage stored = rs.books[asset];
        state = IStaticsGlobalRewards.RewardAssetView({
            eligibleStake: LibGlobalRewards.effectiveEligibleStake(stored),
            eligibleWeight: LibGlobalRewards.effectiveEligibleWeight(stored),
            pendingStake: LibGlobalRewards.effectivePendingStake(stored),
            pendingWeight: LibGlobalRewards.effectivePendingWeight(stored),
            indexRay: stored.indexRay,
            indexedReserve: stored.indexedAmount,
            totalClaimable: rs.totalClaimable[asset]
        });
    }

    function maxRewardAssetsPerPosition() external view returns (uint256) {
        return LibGlobalRewards.maxRewardAssetsPerPosition();
    }

    function hardMaxRewardAssetsPerPosition() external pure returns (uint256) {
        return LibGlobalRewards.HARD_MAX_REWARD_ASSETS_PER_POSITION;
    }

    function increaseMaxRewardAssetsPerPosition(uint8 newMax) external {
        LibDiamond.enforceIsContractOwner();
        LibGlobalRewards.increaseMaxRewardAssetsPerPosition(newMax);
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

    function unfundedSwapRewards(address asset) external view returns (uint256) {
        return LibGlobalRewards.unfundedSwapRewards(asset);
    }

    function fundedGlobalRewards(address asset) external view returns (uint256) {
        return LibGlobalRewards.fundedRewards(asset);
    }

    function outstandingGlobalRewardLiability(address asset) external view returns (uint256) {
        return LibGlobalRewards.outstandingLiability(asset);
    }

    function settlePublicSwapRewards(address asset, uint256 maximumAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        uint256 unfunded = LibGlobalRewards.unfundedSwapRewards(asset);
        amount = maximumAmount < unfunded ? maximumAmount : unfunded;
        if (amount != 0) _settlePublicSwapRewards(asset, amount);
    }

    function canAccrueStakerRewards(address asset) external view returns (bool) {
        return !LibRewardPolicy.isRestricted(asset)
            && LibGlobalRewards.effectiveEligibleWeight(LibGlobalRewards.rewardStorage().books[asset]) != 0;
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
            LibGlobalRewards.optIn(positionId, assets[i]);
        }
    }

    function _increaseStake(uint256 positionId, uint256 amount) private {
        LibGlobalRewards.RewardStorage storage rs = LibGlobalRewards.rewardStorage();
        LibGlobalRewards.increaseStake(positionId, amount);
        uint256 received = LibCustody.pullAndReserve(LibCustody.stakingAccount(), rs.stakingToken, msg.sender, amount);
        if (received != amount) revert IncompatibleStakingToken(amount, received);
        LibGlobalRewards.StakePosition storage position = rs.positions[positionId];
        position.balance += amount;
        rs.totalStaked += amount;
        LibGlobalRewards.activateStakingLeg(positionId);
        (uint40 nextAllocationAt, bool extended) =
            LibGaugeRouting.applyStakeIngressCooldown(positionId, uint40(block.timestamp));
        if (extended) {
            emit IStaticsGaugeIncentives.PositionGaugeAllocationCooldownExtended(positionId, nextAllocationAt);
        }
        emit IStaticsGlobalRewards.Staked(positionId, msg.sender, amount, position.balance);
    }

    function _enforceStakeIngressAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_STAKE != 0) {
            revert ActionPaused(LibGovernance.PAUSE_STAKE);
        }
    }

    function _fundRewardShortfall(address asset, uint256 requested) private {
        uint256 shortfall = LibGlobalRewards.fundingShortfall(asset, requested);
        if (shortfall != 0) _settlePublicSwapRewards(asset, shortfall);
        LibGlobalRewards.enforceFunded(asset, requested);
    }

    function _settlePublicSwapRewards(address asset, uint256 amount) private {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        LibPoolRewards.settleStaker(asset, amount);
        LibCustody.reserve(LibCustody.feeAccount(), asset, amount);
        LibGlobalRewards.fundCrystallizedSwapFee(asset, amount);
    }
}
