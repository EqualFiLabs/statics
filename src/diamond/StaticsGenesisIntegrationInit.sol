// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC5192} from "../interfaces/IERC5192.sol";
import {IStaticsCustody} from "../interfaces/IStaticsCustody.sol";
import {IStaticsGenesisIntegration} from "../interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";

/// @notice One-time governed binding of separately deployed Genesis infrastructure to Statics.
contract StaticsGenesisIntegrationInit {
    function initialize(LibGenesisIntegration.InitArgs calldata args) external {
        LibDiamond.enforceIsContractOwner();
        LibGenesisIntegration.initialize(args);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        bytes4 priorCustodyInterface =
            type(IStaticsCustody).interfaceId ^ IStaticsCustody.genesisRewardCustodyAccount.selector;
        bytes4 priorGlobalRewardsInterface = type(IStaticsGlobalRewards).interfaceId
            ^ IStaticsGlobalRewards.checkpointRewardAssets.selector
            ^ IStaticsGlobalRewards.rewardBookNeedsCheckpoint.selector;
        ds.supportedInterfaces[priorCustodyInterface] = false;
        ds.supportedInterfaces[priorGlobalRewardsInterface] = false;
        ds.supportedInterfaces[type(IStaticsCustody).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGlobalRewards).interfaceId] = true;
        ds.supportedInterfaces[type(IERC5192).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGenesisIntegration).interfaceId] = true;
    }
}
