// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {GenesisNFTFacet} from "../../../src/facets/GenesisNFTFacet.sol";
import {IStaticsGenesisProtocol} from "../../../src/interfaces/IStaticsGenesis.sol";
import {LibGenesisIntegration} from "../../../src/libraries/LibGenesisIntegration.sol";
import {LibGlobalRewards} from "../../../src/libraries/LibGlobalRewards.sol";
import {LibPosition} from "../../../src/position/LibPosition.sol";

contract FormalGenesisLinkCollection {
    mapping(uint256 genesisId => address owner) private _ownerOf;
    address public protocol;
    uint256 public refreshCount;

    function configure(address protocol_) external {
        protocol = protocol_;
    }

    function setOwner(uint256 genesisId, address owner) external {
        _ownerOf[genesisId] = owner;
    }

    function ownerOf(uint256 genesisId) external view returns (address) {
        return _ownerOf[genesisId];
    }

    function refreshLockStatus(uint256) external {
        ++refreshCount;
    }
}

contract FormalGenesisLinkRegistry {
    address public activeConsumer;
    uint16 public multiplier;

    function configure(address consumer, uint256 configuredMultiplierBps) external {
        if (configuredMultiplierBps > type(uint16).max) revert();
        activeConsumer = consumer;
        multiplier = uint16(configuredMultiplierBps);
    }

    function multiplierBps(uint256) external view returns (uint16) {
        return multiplier;
    }
}

contract FormalGenesisLinkFeeReceiver {
    address public activeDistributor;

    function configure(address distributor) external {
        activeDistributor = distributor;
    }

    function cumulativeDistributorAttributed(address, address) external pure returns (uint256) {
        return 0;
    }

    function distributorClaimable(address, address) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (uint256 staticsAmount, uint256 numeraireAmount) {
        return (0, 0);
    }
}

contract GenesisPositionHarness is GenesisNFTFacet {
    uint256 public constant POSITION_ID = 1;
    uint256 public constant GENESIS_ID = 1;
    bytes32 private constant OTHER_MODULE = keccak256("formal.other.position.module");

    mapping(uint256 positionId => address owner) private _positionOwner;

    function initializeHarness(
        address genesis,
        address registry,
        address feeReceiver,
        address owner,
        uint256 rawStake,
        uint256 initialGenesisWeight
    ) external {
        LibGenesisIntegration.GenesisStorage storage gs = LibGenesisIntegration.genesisStorage();
        gs.genesis = genesis;
        gs.vault = address(0xBEEF);
        gs.activationRegistry = registry;
        gs.feeReceiver = feeReceiver;
        gs.statics = address(0x1001);
        gs.numeraire = address(0x1002);
        gs.genesisRewardShareBps = 9_000;
        gs.initialized = true;
        gs.registered[GENESIS_ID] = true;
        gs.effectiveWeight[GENESIS_ID] = initialGenesisWeight;
        gs.totalWeight = initialGenesisWeight;

        _positionOwner[POSITION_ID] = owner;
        LibGlobalRewards.StakePosition storage position = LibGlobalRewards.rewardStorage().positions[POSITION_ID];
        position.balance = rawStake;
        position.rewardMultiplierBps = LibGlobalRewards.BASE_REWARD_MULTIPLIER_BPS;
        LibPosition.activateLeg(POSITION_ID, OTHER_MODULE, bytes32(uint256(77)));
    }

    function ownerOf(uint256 positionId) external view returns (address) {
        return _positionOwner[positionId];
    }

    function positionOwner(uint256 positionId) external view returns (address) {
        return _positionOwner[positionId];
    }

    function positionRawStake(uint256 positionId) external view returns (uint256) {
        return LibGlobalRewards.rewardStorage().positions[positionId].balance;
    }

    function positionMultiplier(uint256 positionId) external view returns (uint16) {
        return LibGlobalRewards.effectiveRewardMultiplier(LibGlobalRewards.rewardStorage().positions[positionId]);
    }

    function genesisWeight(uint256 genesisId) external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().effectiveWeight[genesisId];
    }

    function totalGenesisWeight() external view returns (uint256) {
        return LibGenesisIntegration.genesisStorage().totalWeight;
    }

    function genesisLegActive(uint256 positionId, uint256 genesisId) external view returns (bool) {
        return LibPosition.positionStorage().activeLeg[positionId][LibPosition.genesisLegKey(genesisId)];
    }

    function otherLegActive(uint256 positionId) external view returns (bool) {
        return
            LibPosition.positionStorage().activeLeg[positionId][LibPosition.legKey(OTHER_MODULE, bytes32(uint256(77)))];
    }

    function activeLegCount(uint256 positionId) external view returns (uint64) {
        return LibPosition.positionStorage().state[positionId].activeLegCount;
    }

    function recoveryAcknowledgement() external pure returns (bytes4) {
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }
}
