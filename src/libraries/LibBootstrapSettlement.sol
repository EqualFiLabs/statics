// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBootstrapCustodyFactory, IBootstrapCustodyCampaign} from "../interfaces/IStaticsBootstrapSettlement.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibDiamond} from "./LibDiamond.sol";
import {LibRestrictedBasket} from "./LibRestrictedBasket.sol";

/// @notice Exact Diamond-bridged movement for explicitly approved fixed-code campaigns.
/// No campaign can issue a token permission, select arbitrary assets or spend protocol inventory.
library LibBootstrapSettlement {
    bytes32 private constant POSITION = keccak256("statics.storage.bootstrap.settlement.v1");

    struct Factory {
        bytes32 runtimeHash;
        bytes32 creationCodeHash;
    }

    struct Storage {
        mapping(address factory => Factory pins) factories;
        mapping(address campaign => bytes32 runtimeHash) campaigns;
        mapping(address campaign => mapping(address token => bool allowed)) assets;
    }
    error InvalidBootstrapSettlement();
    event BootstrapFactoryInstalled(address indexed factory, bytes32 runtimeHash, bytes32 creationCodeHash);
    event BootstrapCampaignRegistered(address indexed factory, address indexed campaign);

    function state() internal pure returns (Storage storage s) {
        bytes32 slot = POSITION;
        assembly ("memory-safe") { s.slot := slot }
    }

    /// @dev Governance supplies audited deployment pins, never campaign-supplied contract markers.
    function install(address factory, bytes32 runtimeHash, bytes32 creationCodeHash) internal {
        LibDiamond.enforceIsContractOwner();
        if (
            runtimeHash == bytes32(0) || creationCodeHash == bytes32(0) || factory.code.length == 0
                || factory.codehash != runtimeHash || state().factories[factory].runtimeHash != bytes32(0)
                || IBootstrapCustodyFactory(factory).diamond() != address(this)
                || IBootstrapCustodyFactory(factory).creationCodeHash() != creationCodeHash
        ) revert InvalidBootstrapSettlement();
        state().factories[factory] = Factory(runtimeHash, creationCodeHash);
        emit BootstrapFactoryInstalled(factory, runtimeHash, creationCodeHash);
    }

    function approved(address factory) internal view returns (bool) {
        Factory storage pins = state().factories[factory];
        return pins.runtimeHash != bytes32(0) && factory.codehash == pins.runtimeHash;
    }

    function register(address campaign) internal {
        IBootstrapCustodyCampaign target = IBootstrapCustodyCampaign(campaign);
        if (
            !approved(msg.sender) || campaign.code.length == 0 || state().campaigns[campaign] != bytes32(0)
                || !IBootstrapCustodyFactory(msg.sender).isCampaign(campaign) || target.factory() != msg.sender
                || target.diamond() != address(this)
        ) revert InvalidBootstrapSettlement();
        uint256 length = target.assetCount();
        if (length == 0 || length > 16) revert InvalidBootstrapSettlement();
        state().campaigns[campaign] = campaign.codehash;
        state().assets[campaign][target.projectToken()] = true;
        for (uint256 i; i < length; ++i) {
            state().assets[campaign][target.custodyAsset(i)] = true;
        }
        emit BootstrapCampaignRegistered(msg.sender, campaign);
    }

    function settle(address token, address sender, address receiver, uint256 amount) internal {
        if (
            state().campaigns[msg.sender] == bytes32(0) || msg.sender.codehash != state().campaigns[msg.sender]
                || !state().assets[msg.sender][token] || !LibRestrictedBasket.isRestricted(token) || amount == 0
                || sender == receiver || sender == address(0) || receiver == address(0) || sender == address(this)
                || receiver == address(this) || (sender != msg.sender && receiver != msg.sender)
        ) revert InvalidBootstrapSettlement();
        // A fixed-code campaign derives inbound sender from its caller and outbound receiver from its terms/fill.
        uint256 floor = IERC20(token).balanceOf(address(this));
        uint256 senderBefore = IERC20(token).balanceOf(sender);
        uint256 received = LibCustody.pull(token, sender, amount);
        if (received != amount || IERC20(token).balanceOf(sender) + amount != senderBefore) {
            revert InvalidBootstrapSettlement();
        }
        (uint256 spent, uint256 delivered) = LibCustody.pushUnreserved(token, receiver, amount, amount);
        if (spent != amount || delivered != amount || IERC20(token).balanceOf(address(this)) != floor) {
            revert InvalidBootstrapSettlement();
        }
    }
}
