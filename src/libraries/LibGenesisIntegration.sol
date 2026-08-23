// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";

interface IGenesisVaultConfiguration {
    function statics() external view returns (address);
    function feeReceiver() external view returns (address);
    function treasury() external view returns (address);
}

library LibGenesisIntegration {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.genesis.integration.v1");

    struct InitArgs {
        address genesis;
        address vault;
        address activationRegistry;
        address feeReceiver;
        address statics;
        address numeraire;
    }

    struct GenesisStorage {
        address genesis;
        address vault;
        address activationRegistry;
        address feeReceiver;
        address statics;
        address numeraire;
        bool initialized;
        mapping(uint256 genesisId => uint256 positionId) linkedPosition;
        mapping(uint256 positionId => uint256 genesisId) linkedGenesis;
    }

    error AlreadyInitialized();
    error InvalidIntegrationContract(address target);
    error InvalidGenesisConfiguration();
    error InvalidVaultConfiguration();
    error InvalidActivationRegistryConfiguration();
    error InvalidFeeReceiverConfiguration();

    function genesisStorage() internal pure returns (GenesisStorage storage gs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            gs.slot := position
        }
    }

    function initialize(InitArgs memory args) internal {
        GenesisStorage storage gs = genesisStorage();
        if (gs.initialized) revert AlreadyInitialized();
        _enforceContract(args.genesis);
        _enforceContract(args.vault);
        _enforceContract(args.activationRegistry);
        _enforceContract(args.feeReceiver);
        _enforceContract(args.statics);
        _enforceContract(args.numeraire);

        IStaticsGenesis genesis = IStaticsGenesis(args.genesis);
        if (genesis.vault() != args.vault || genesis.activationRegistry() != args.activationRegistry) {
            revert InvalidGenesisConfiguration();
        }
        IGenesisVaultConfiguration vault = IGenesisVaultConfiguration(args.vault);
        address treasury = LibBasket.basketStorage().treasury;
        if (vault.statics() != args.statics || vault.feeReceiver() != args.feeReceiver || vault.treasury() != treasury) revert InvalidVaultConfiguration();
        IGenesisActivationRegistry registry = IGenesisActivationRegistry(args.activationRegistry);
        if (registry.genesisCollection() != args.genesis || registry.treasury() != treasury) {
            revert InvalidActivationRegistryConfiguration();
        }
        IStaticsFeeReceiver receiver = IStaticsFeeReceiver(args.feeReceiver);
        if (
            receiver.statics() != args.statics || receiver.numeraire() != args.numeraire
                || receiver.reserveVault() != args.vault
        ) revert InvalidFeeReceiverConfiguration();
        if (LibGlobalRewards.rewardStorage().stakingToken != args.statics) revert InvalidVaultConfiguration();

        gs.genesis = args.genesis;
        gs.vault = args.vault;
        gs.activationRegistry = args.activationRegistry;
        gs.feeReceiver = args.feeReceiver;
        gs.statics = args.statics;
        gs.numeraire = args.numeraire;
        gs.initialized = true;
    }

    function integrationReady() internal view returns (bool) {
        GenesisStorage storage gs = genesisStorage();
        if (!gs.initialized) return false;
        try IStaticsGenesis(gs.genesis).protocol() returns (address protocol) {
            if (protocol != address(this)) return false;
        } catch {
            return false;
        }
        return recoveryReady();
    }

    function recoveryReady() internal view returns (bool) {
        GenesisStorage storage gs = genesisStorage();
        if (!gs.initialized) return false;
        try IStaticsFeeReceiver(gs.feeReceiver).activeDistributor() returns (address distributor) {
            if (distributor != address(this)) return false;
        } catch {
            return false;
        }
        try IGenesisActivationRegistry(gs.activationRegistry).activeConsumer() returns (address consumer) {
            return consumer == address(this);
        } catch {
            return false;
        }
    }

    function _enforceContract(address target) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidIntegrationContract(target);
    }
}
