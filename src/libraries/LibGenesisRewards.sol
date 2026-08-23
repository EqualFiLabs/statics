// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IGenesisRecoveryDistributor} from "../interfaces/IGenesisRecoveryDistributor.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGenesisIntegration} from "./LibGenesisIntegration.sol";

library LibGenesisRewards {
    uint256 internal constant RAY = 1e27;

    event GenesisRegistered(uint256 indexed genesisId, uint256 weight, uint256 totalWeight);
    event GenesisWeightChanged(
        uint256 indexed genesisId, uint256 previousWeight, uint256 newWeight, uint256 totalWeight
    );
    event GenesisRevenueAccrued(
        address indexed asset, uint256 amount, uint256 genesisAmount, uint256 treasuryAmount, uint256 indexRay
    );
    event GenesisRewardsClaimed(
        uint256 indexed genesisId, address indexed owner, address indexed asset, address receiver, uint256 amount
    );
    event GenesisOwnerRewardsClaimed(
        address indexed owner, address indexed asset, address indexed receiver, uint256 amount
    );
    event GenesisTreasuryRewardsClaimed(address indexed asset, address indexed receiver, uint256 amount);
    event GenesisRewardShareUpdated(uint16 previousShareBps, uint16 newShareBps);
    event GenesisRecoveryAccrued(uint256 amount, uint256 pendingAmount, uint256 indexRay);
    event PendingGenesisRecoveryIndexed(uint256 amount, uint256 indexRay);
    event PendingGenesisRecoveryMigrated(address indexed successor, uint256 amount);
    event PendingGenesisRecoveryReceived(address indexed predecessor, uint256 amount);

    error InvalidRewardAsset(address asset);
    error InvalidReceiver(address receiver);
    error GenesisAlreadyRegistered(uint256 genesisId);
    error GenesisHeldByVault(uint256 genesisId);
    error NotGenesisOwner(uint256 genesisId, address caller, address owner);
    error NoRewards();
    error InconsistentFeeTransfer(address asset, uint256 expected, uint256 received);
    error UnauthorizedRecoveryVault(address caller);
    error UnauthorizedRecoveryPredecessor(address caller);
    error InvalidRecoveryAmount();
    error UnexpectedRecoveryOwner(uint256 genesisId, address expectedOwner, address actualOwner);

    function register(uint256 genesisId) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (gs.registered[genesisId]) revert GenesisAlreadyRegistered(genesisId);
        address tokenOwner = IERC721(gs.genesis).ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        if (tokenOwner == gs.vault) revert GenesisHeldByVault(genesisId);

        accrue();
        gs.registered[genesisId] = true;
        uint256 weight = IGenesisActivationRegistry(gs.activationRegistry).multiplierBps(genesisId);
        gs.effectiveWeight[genesisId] = weight;
        gs.totalWeight += weight;
        gs.genesisAssetState[genesisId][gs.statics].checkpointRay = gs.rewardBooks[gs.statics].indexRay;
        gs.genesisAssetState[genesisId][gs.numeraire].checkpointRay = gs.rewardBooks[gs.numeraire].indexRay;
        emit GenesisRegistered(genesisId, weight, gs.totalWeight);
        flushPendingRecovery(gs);
    }

    function accrue() internal returns (uint256 staticsAmount, uint256 numeraireAmount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        IStaticsFeeReceiver receiver = IStaticsFeeReceiver(gs.feeReceiver);
        if (receiver.activeDistributor() == address(this)) receiver.harvest();
        staticsAmount = pullAttributed(gs, gs.statics);
        numeraireAmount = pullAttributed(gs, gs.numeraire);
    }

    function transition(uint256 genesisId, address previousOwner, address nextOwner, uint16 nextMultiplierBps)
        internal
    {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (!gs.registered[genesisId]) return;

        if (previousOwner == nextOwner) {
            accrue();
        } else {
            checkpointAttributed(gs, gs.statics);
            checkpointAttributed(gs, gs.numeraire);
        }
        settle(gs, genesisId, gs.statics);
        settle(gs, genesisId, gs.numeraire);
        if (previousOwner != nextOwner) {
            crystallizeToOwner(gs, genesisId, previousOwner, gs.statics);
            crystallizeToOwner(gs, genesisId, previousOwner, gs.numeraire);
        }

        uint256 previousWeight = gs.effectiveWeight[genesisId];
        uint256 nextWeight = nextOwner == gs.vault ? 0 : nextMultiplierBps;
        gs.totalWeight = gs.totalWeight - previousWeight + nextWeight;
        gs.effectiveWeight[genesisId] = nextWeight;
        clearRemaindersWhenEmpty(gs);
        emit GenesisWeightChanged(genesisId, previousWeight, nextWeight, gs.totalWeight);
        flushPendingRecovery(gs);
    }

    function settleRecoveryLink(uint256 genesisId, address previousOwner) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (!gs.registered[genesisId]) return;
        checkpointAttributed(gs, gs.statics);
        checkpointAttributed(gs, gs.numeraire);
        settle(gs, genesisId, gs.statics);
        settle(gs, genesisId, gs.numeraire);
        crystallizeToOwner(gs, genesisId, previousOwner, gs.statics);
        crystallizeToOwner(gs, genesisId, previousOwner, gs.numeraire);
        uint256 previousWeight = gs.effectiveWeight[genesisId];
        if (previousWeight != 0) {
            gs.totalWeight -= previousWeight;
            gs.effectiveWeight[genesisId] = 0;
            clearRemaindersWhenEmpty(gs);
            emit GenesisWeightChanged(genesisId, previousWeight, 0, gs.totalWeight);
        }
        flushPendingRecovery(gs);
    }

    function checkpointRecovery(uint256 genesisId, address expectedOwner) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (msg.sender != gs.vault) revert UnauthorizedRecoveryVault(msg.sender);
        address tokenOwner = IERC721(gs.genesis).ownerOf(genesisId);
        if (tokenOwner != expectedOwner) revert UnexpectedRecoveryOwner(genesisId, expectedOwner, tokenOwner);

        accrue();
        settle(gs, genesisId, gs.statics);
        settle(gs, genesisId, gs.numeraire);
        crystallizeToOwner(gs, genesisId, expectedOwner, gs.statics);
        crystallizeToOwner(gs, genesisId, expectedOwner, gs.numeraire);
    }

    function accrueRecovery(uint256 amount) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (msg.sender != gs.vault) revert UnauthorizedRecoveryVault(msg.sender);
        if (amount == 0) revert InvalidRecoveryAmount();
        reserveReceived(gs, gs.statics, amount);

        if (gs.totalWeight == 0) {
            gs.pendingGenesisRecovery += amount;
            emit GenesisRecoveryAccrued(amount, gs.pendingGenesisRecovery, gs.rewardBooks[gs.statics].indexRay);
            return;
        }
        increaseRecoveryIndex(gs, amount);
        emit GenesisRecoveryAccrued(amount, gs.pendingGenesisRecovery, gs.rewardBooks[gs.statics].indexRay);
    }

    function migratePendingRecovery(address successor) internal returns (uint256 amount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (msg.sender != gs.feeReceiver) revert UnauthorizedRecoveryPredecessor(msg.sender);
        amount = gs.pendingGenesisRecovery;
        if (amount == 0) return 0;
        gs.pendingGenesisRecovery = 0;
        gs.accountedCustody[gs.statics] -= amount;
        pushExact(gs.statics, successor, amount);
        IGenesisRecoveryDistributor(successor).acceptPendingGenesisRecovery(amount);
        emit PendingGenesisRecoveryMigrated(successor, amount);
    }

    function acceptPendingRecovery(uint256 amount) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        address predecessor = IStaticsFeeReceiver(gs.feeReceiver).activeDistributor();
        if (msg.sender != predecessor) revert UnauthorizedRecoveryPredecessor(msg.sender);
        if (amount == 0) revert InvalidRecoveryAmount();
        reserveReceived(gs, gs.statics, amount);
        gs.pendingGenesisRecovery += amount;
        emit PendingGenesisRecoveryReceived(msg.sender, amount);
    }

    function claimGenesis(uint256 genesisId, address asset, address receiver) internal returns (uint256 amount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        validateAsset(gs, asset);
        validateReceiver(receiver);
        address tokenOwner = IERC721(gs.genesis).ownerOf(genesisId);
        if (tokenOwner != msg.sender) revert NotGenesisOwner(genesisId, msg.sender, tokenOwner);
        accrue();
        settle(gs, genesisId, asset);
        LibGenesisIntegration.GenesisAssetState storage state = gs.genesisAssetState[genesisId][asset];
        amount = state.accrued;
        if (amount == 0) revert NoRewards();
        state.accrued = 0;
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        book.totalClaimable -= amount;
        book.totalClaimed += amount;
        gs.accountedCustody[asset] -= amount;
        pushExact(asset, receiver, amount);
        emit GenesisRewardsClaimed(genesisId, msg.sender, asset, receiver, amount);
    }

    function claimOwner(address asset, address receiver) internal returns (uint256 amount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        validateAsset(gs, asset);
        validateReceiver(receiver);
        pullAttributed(gs, asset);
        amount = gs.ownerClaimable[msg.sender][asset];
        if (amount == 0) revert NoRewards();
        delete gs.ownerClaimable[msg.sender][asset];
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        book.totalClaimable -= amount;
        book.totalClaimed += amount;
        gs.accountedCustody[asset] -= amount;
        pushExact(asset, receiver, amount);
        emit GenesisOwnerRewardsClaimed(msg.sender, asset, receiver, amount);
    }

    function claimTreasury(address asset, address receiver) internal returns (uint256 amount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        validateAsset(gs, asset);
        validateReceiver(receiver);
        accrue();
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        amount = book.treasuryClaimable;
        if (amount == 0) revert NoRewards();
        book.treasuryClaimable = 0;
        gs.accountedCustody[asset] -= amount;
        pushExact(asset, receiver, amount);
        emit GenesisTreasuryRewardsClaimed(asset, receiver, amount);
    }

    function setRewardShare(uint16 newShareBps) internal {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (newShareBps > LibGenesisIntegration.BPS) {
            revert LibGenesisIntegration.InvalidRewardShare(newShareBps);
        }
        accrue();
        uint16 previous = gs.genesisRewardShareBps;
        gs.genesisRewardShareBps = newShareBps;
        emit GenesisRewardShareUpdated(previous, newShareBps);
    }

    function pending(uint256 genesisId, address asset) internal view returns (uint256 amount) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        validateAsset(gs, asset);
        LibGenesisIntegration.GenesisAssetState storage state = gs.genesisAssetState[genesisId][asset];
        amount = state.accrued;
        uint256 weight = gs.effectiveWeight[genesisId];
        uint256 currentIndex = gs.rewardBooks[asset].indexRay;
        if (weight != 0 && currentIndex > state.checkpointRay) {
            amount += (weight * (currentIndex - state.checkpointRay) + state.settlementRemainderRay) / RAY;
        }
    }

    function pullAttributed(LibGenesisIntegration.GenesisStorage storage gs, address asset)
        internal
        returns (uint256 amount)
    {
        checkpointAttributed(gs, asset);
        IStaticsFeeReceiver receiver = IStaticsFeeReceiver(gs.feeReceiver);
        amount = receiver.distributorClaimable(address(this), asset);
        if (amount == 0) return 0;
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        uint256 reported = receiver.claimDistributorFees(asset, address(this));
        uint256 afterBalance = IERC20(asset).balanceOf(address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (reported != amount || received != amount) revert InconsistentFeeTransfer(asset, amount, received);
        LibCustody.reserve(LibCustody.genesisRewardAccount(), asset, amount);
        gs.accountedCustody[asset] += amount;
    }

    function checkpointAttributed(LibGenesisIntegration.GenesisStorage storage gs, address asset)
        internal
        returns (uint256 amount)
    {
        uint256 cumulative = IStaticsFeeReceiver(gs.feeReceiver).cumulativeDistributorAttributed(address(this), asset);
        uint256 checkpoint = gs.indexedReceiverAttribution[asset];
        amount = cumulative - checkpoint;
        if (amount == 0) return 0;
        gs.indexedReceiverAttribution[asset] = cumulative;
        allocate(gs, asset, amount);
    }

    function allocate(LibGenesisIntegration.GenesisStorage storage gs, address asset, uint256 amount) internal {
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        uint256 genesisAmount;
        if (gs.totalWeight != 0) {
            genesisAmount = Math.mulDiv(amount, gs.genesisRewardShareBps, LibGenesisIntegration.BPS);
        }
        uint256 treasuryAmount = amount - genesisAmount;
        book.treasuryClaimable += treasuryAmount;
        if (genesisAmount != 0) {
            uint256 scaled = genesisAmount * RAY + book.indexRemainder;
            book.indexRay += scaled / gs.totalWeight;
            book.indexRemainder = scaled % gs.totalWeight;
            book.indexedAmount += genesisAmount;
        }
        emit GenesisRevenueAccrued(asset, amount, genesisAmount, treasuryAmount, book.indexRay);
    }

    function flushPendingRecovery(LibGenesisIntegration.GenesisStorage storage gs) internal {
        uint256 amount = gs.pendingGenesisRecovery;
        if (amount == 0 || gs.totalWeight == 0) return;
        gs.pendingGenesisRecovery = 0;
        increaseRecoveryIndex(gs, amount);
        emit PendingGenesisRecoveryIndexed(amount, gs.rewardBooks[gs.statics].indexRay);
    }

    function increaseRecoveryIndex(LibGenesisIntegration.GenesisStorage storage gs, uint256 amount) internal {
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[gs.statics];
        uint256 scaled = amount * RAY + book.indexRemainder;
        book.indexRay += scaled / gs.totalWeight;
        book.indexRemainder = scaled % gs.totalWeight;
        book.indexedAmount += amount;
    }

    function settle(LibGenesisIntegration.GenesisStorage storage gs, uint256 genesisId, address asset) internal {
        LibGenesisIntegration.GenesisAssetState storage state = gs.genesisAssetState[genesisId][asset];
        LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
        uint256 currentIndex = book.indexRay;
        uint256 weight = gs.effectiveWeight[genesisId];
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

    function crystallizeToOwner(
        LibGenesisIntegration.GenesisStorage storage gs,
        uint256 genesisId,
        address rewardOwner,
        address asset
    ) internal {
        LibGenesisIntegration.GenesisAssetState storage state = gs.genesisAssetState[genesisId][asset];
        uint256 amount = state.accrued;
        if (amount != 0) {
            gs.ownerClaimable[rewardOwner][asset] += amount;
            state.accrued = 0;
        }
        uint256 combinedRemainder = gs.ownerClaimRemainderRay[rewardOwner][asset] + state.settlementRemainderRay;
        uint256 converted = combinedRemainder / RAY;
        gs.ownerClaimRemainderRay[rewardOwner][asset] = combinedRemainder % RAY;
        state.settlementRemainderRay = 0;
        if (converted != 0) {
            gs.ownerClaimable[rewardOwner][asset] += converted;
            LibGenesisIntegration.RewardBook storage book = gs.rewardBooks[asset];
            book.crystallizedAmount += converted;
            book.totalClaimable += converted;
        }
    }

    function reserveReceived(LibGenesisIntegration.GenesisStorage storage gs, address asset, uint256 amount) private {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 accounted = gs.accountedCustody[asset];
        uint256 available = balance > accounted ? balance - accounted : 0;
        if (available < amount) revert InconsistentFeeTransfer(asset, amount, available);
        LibCustody.reserve(LibCustody.genesisRewardAccount(), asset, amount);
        gs.accountedCustody[asset] = accounted + amount;
    }

    function pushExact(address asset, address receiver, uint256 amount) private {
        (uint256 spent, uint256 received) =
            LibCustody.pushReserved(LibCustody.genesisRewardAccount(), asset, receiver, amount, amount);
        if (spent != amount || received != amount) revert InconsistentFeeTransfer(asset, amount, received);
    }

    function clearRemaindersWhenEmpty(LibGenesisIntegration.GenesisStorage storage gs) private {
        if (gs.totalWeight != 0) return;
        gs.rewardBooks[gs.statics].indexRemainder = 0;
        gs.rewardBooks[gs.numeraire].indexRemainder = 0;
    }

    function validateAsset(LibGenesisIntegration.GenesisStorage storage gs, address asset) internal view {
        if (asset != gs.statics && asset != gs.numeraire) revert InvalidRewardAsset(asset);
    }

    function validateReceiver(address receiver) internal view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver(receiver);
    }
}
