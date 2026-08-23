// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {IStaticsGenesis, IStaticsGenesisProtocol} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisIntegration} from "../interfaces/IStaticsGenesisIntegration.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibGenesisRewards} from "../libraries/LibGenesisRewards.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract GenesisNFTFacet is IStaticsGenesisIntegration, ReentrancyGuard {
    error GenesisIntegrationNotReady();
    error NotAssetOwner(uint256 tokenId, address caller, address owner);
    error GenesisAlreadyLinked(uint256 genesisId, uint256 positionId);
    error PositionAlreadyLinked(uint256 positionId, uint256 genesisId);
    error GenesisLinkMismatch(uint256 positionId, uint256 genesisId);
    error LinkedOwnerMismatch(uint256 genesisId, uint256 positionId, address genesisOwner, address positionOwner);
    error UnauthorizedGenesis(address caller);
    error UnauthorizedActivationRegistry(address caller);
    error UnauthorizedTreasury(address caller);

    function linkGenesis(uint256 positionId, uint256 genesisId) external nonReentrant {
        if (!LibGenesisIntegration.integrationReady()) revert GenesisIntegrationNotReady();
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        uint256 existingPosition = gs.linkedPosition[genesisId];
        if (existingPosition != 0) revert GenesisAlreadyLinked(genesisId, existingPosition);
        uint256 existingGenesis = gs.linkedGenesis[positionId];
        if (existingGenesis != 0) revert PositionAlreadyLinked(positionId, existingGenesis);

        address genesisOwner = IERC721(gs.genesis).ownerOf(genesisId);
        if (genesisOwner != msg.sender) revert NotAssetOwner(genesisId, msg.sender, genesisOwner);
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (positionOwner != msg.sender) revert NotAssetOwner(positionId, msg.sender, positionOwner);

        uint16 multiplierBps = IGenesisActivationRegistry(gs.activationRegistry).multiplierBps(genesisId);
        if (multiplierBps != LibGlobalRewards.BASE_REWARD_MULTIPLIER_BPS) {
            LibGlobalRewards.transitionPositionWeight(positionId, multiplierBps);
        }
        gs.linkedPosition[genesisId] = positionId;
        gs.linkedGenesis[positionId] = genesisId;
        LibPosition.activateLeg(positionId, LibPosition.GENESIS_MODULE, bytes32(genesisId));
        emit IERC5192.Locked(positionId);
        IStaticsGenesis(gs.genesis).refreshLockStatus(genesisId);
        emit GenesisLinked(positionId, genesisId, msg.sender, multiplierBps);
    }

    function unlinkGenesis(uint256 positionId, uint256 genesisId) external nonReentrant {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        _enforceLink(gs, positionId, genesisId);
        address genesisOwner = IERC721(gs.genesis).ownerOf(genesisId);
        if (genesisOwner != msg.sender) revert NotAssetOwner(genesisId, msg.sender, genesisOwner);
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (positionOwner != msg.sender) revert NotAssetOwner(positionId, msg.sender, positionOwner);
        uint16 previousMultiplierBps =
            LibGlobalRewards.effectiveRewardMultiplier(LibGlobalRewards.rewardStorage().positions[positionId]);
        _clearLink(gs, positionId, genesisId);
        emit GenesisUnlinked(positionId, genesisId, msg.sender, previousMultiplierBps);
    }

    function onGenesisRecovery(uint256 genesisId, address previousOwner)
        external
        nonReentrant
        returns (bytes4 acknowledgement)
    {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (msg.sender != gs.genesis) revert UnauthorizedGenesis(msg.sender);
        LibGenesisRewards.settleRecoveryLink(genesisId, previousOwner);
        uint256 positionId = gs.linkedPosition[genesisId];
        if (positionId == 0) return IStaticsGenesisProtocol.onGenesisRecovery.selector;
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (positionOwner != previousOwner) {
            revert LinkedOwnerMismatch(genesisId, positionId, previousOwner, positionOwner);
        }
        uint16 previousMultiplierBps =
            LibGlobalRewards.effectiveRewardMultiplier(LibGlobalRewards.rewardStorage().positions[positionId]);
        _clearLink(gs, positionId, genesisId);
        emit GenesisUnlinked(positionId, genesisId, previousOwner, previousMultiplierBps);
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }

    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16,
        uint16 nextMultiplierBps
    ) external nonReentrant {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        if (msg.sender != gs.activationRegistry) revert UnauthorizedActivationRegistry(msg.sender);
        LibGenesisRewards.transition(genesisId, previousOwner, nextOwner, nextMultiplierBps);
        uint256 positionId = gs.linkedPosition[genesisId];
        if (positionId == 0) return;
        address positionOwner = IERC721(address(this)).ownerOf(positionId);
        if (previousOwner != nextOwner || positionOwner != nextOwner) {
            revert LinkedOwnerMismatch(genesisId, positionId, nextOwner, positionOwner);
        }
        LibGlobalRewards.transitionPositionWeight(positionId, nextMultiplierBps);
    }

    function linkedGenesis(uint256 positionId) external view returns (uint256 genesisId) {
        return LibGenesisIntegration.genesisStorage().linkedGenesis[positionId];
    }

    function linkedPosition(uint256 genesisId) external view returns (uint256 positionId) {
        return LibGenesisIntegration.genesisStorage().linkedPosition[genesisId];
    }

    function genesisCollection() external view returns (address) {
        return LibGenesisIntegration.genesisStorage().genesis;
    }

    function genesisRecoveryVault() external view returns (address) {
        return LibGenesisIntegration.genesisStorage().vault;
    }

    function genesisRecoveryAsset() external view returns (address) {
        return LibGenesisIntegration.genesisStorage().statics;
    }

    function genesisRecoveryReady() public view returns (bool) {
        return LibGenesisIntegration.recoveryReady();
    }

    function genesisIntegrationReady() external view returns (bool) {
        return LibGenesisIntegration.integrationReady();
    }

    function genesisRecoveryCallback() external pure returns (bytes4 acknowledgement) {
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }

    /// @dev Deliberately not guarded by the Diamond-wide reentrancy slot. A predecessor
    /// distributor may synchronously migrate recovery value back into this Diamond during acceptance.
    function acceptGenesisDistributorRole() external {
        IStaticsFeeReceiver(LibGenesisIntegration.genesisStorage().feeReceiver).acceptDistributor();
    }

    function acceptGenesisConsumerRole() external {
        IGenesisActivationRegistry(LibGenesisIntegration.genesisStorage().activationRegistry).acceptConsumer();
    }

    function registerGenesis(uint256 genesisId) external nonReentrant {
        if (!LibGenesisIntegration.integrationReady()) revert GenesisIntegrationNotReady();
        LibGenesisRewards.register(genesisId);
    }

    function accrueGenesisRewards() external nonReentrant returns (uint256 staticsAmount, uint256 numeraireAmount) {
        if (!LibGenesisIntegration.recoveryReady()) revert GenesisIntegrationNotReady();
        return LibGenesisRewards.accrue();
    }

    function claimGenesisRewards(uint256 genesisId, address asset, address receiver)
        external
        nonReentrant
        returns (uint256 amount)
    {
        return LibGenesisRewards.claimGenesis(genesisId, asset, receiver);
    }

    function claimGenesisOwnerRewards(address asset, address receiver) external nonReentrant returns (uint256 amount) {
        return LibGenesisRewards.claimOwner(asset, receiver);
    }

    function claimGenesisTreasuryRewards(address asset, address receiver)
        external
        nonReentrant
        returns (uint256 amount)
    {
        address treasury = LibBasket.basketStorage().treasury;
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        return LibGenesisRewards.claimTreasury(asset, receiver);
    }

    function setGenesisRewardShareBps(uint16 newShareBps) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibGenesisRewards.setRewardShare(newShareBps);
    }

    function checkpointGenesisRecovery(uint256 genesisId, address expectedOwner) external nonReentrant {
        if (!LibGenesisIntegration.recoveryReady()) revert GenesisIntegrationNotReady();
        LibGenesisRewards.checkpointRecovery(genesisId, expectedOwner);
    }

    function accrueGenesisRecovery(uint256 amount) external nonReentrant {
        LibGenesisRewards.accrueRecovery(amount);
    }

    function migratePendingGenesisRecovery(address successor) external nonReentrant returns (uint256 amount) {
        return LibGenesisRewards.migratePendingRecovery(successor);
    }

    function acceptPendingGenesisRecovery(uint256 amount) external nonReentrant {
        LibGenesisRewards.acceptPendingRecovery(amount);
    }

    function pendingGenesisRewards(uint256 genesisId, address asset) external view returns (uint256 amount) {
        return LibGenesisRewards.pending(genesisId, asset);
    }

    function genesisRewardBook(address asset) external view returns (GenesisRewardBookView memory book) {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        LibGenesisRewards.validateAsset(gs, asset);
        LibGenesisIntegration.RewardBook storage stored = gs.rewardBooks[asset];
        book = GenesisRewardBookView({
            indexRay: stored.indexRay,
            indexRemainder: stored.indexRemainder,
            indexedAmount: stored.indexedAmount,
            crystallizedAmount: stored.crystallizedAmount,
            totalClaimable: stored.totalClaimable,
            totalClaimed: stored.totalClaimed,
            treasuryClaimable: stored.treasuryClaimable
        });
    }

    function genesisRegistered(uint256 genesisId) external view returns (bool) {
        return LibGenesisIntegration.genesisStorage().registered[genesisId];
    }

    function genesisEffectiveWeight(uint256 genesisId) external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().effectiveWeight[genesisId];
    }

    function genesisTotalWeight() external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().totalWeight;
    }

    function genesisRewardShareBps() external view returns (uint16) {
        return LibGenesisIntegration.genesisStorage().genesisRewardShareBps;
    }

    function genesisOwnerClaimable(address owner, address asset) external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().ownerClaimable[owner][asset];
    }

    function pendingGenesisRecovery() external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().pendingGenesisRecovery;
    }

    function _clearLink(LibGenesisIntegration.GenesisStorage storage gs, uint256 positionId, uint256 genesisId)
        private
    {
        _enforceLink(gs, positionId, genesisId);
        LibGlobalRewards.transitionPositionWeight(positionId, LibGlobalRewards.BASE_REWARD_MULTIPLIER_BPS);
        delete gs.linkedPosition[genesisId];
        delete gs.linkedGenesis[positionId];
        LibPosition.deactivateLeg(positionId, LibPosition.genesisLegKey(genesisId));
        emit IERC5192.Unlocked(positionId);
        IStaticsGenesis(gs.genesis).refreshLockStatus(genesisId);
    }

    function _enforceLink(LibGenesisIntegration.GenesisStorage storage gs, uint256 positionId, uint256 genesisId)
        private
        view
    {
        if (gs.linkedPosition[genesisId] != positionId || gs.linkedGenesis[positionId] != genesisId) {
            revert GenesisLinkMismatch(positionId, genesisId);
        }
    }
}
