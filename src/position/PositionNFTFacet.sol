// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPosition} from "./LibPosition.sol";

contract PositionNFTFacet is ERC721Upgradeable, IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule {
    event PositionCreated(uint256 indexed positionId, address indexed owner);
    event PositionClosed(uint256 indexed positionId);
    event PositionCreationFeeSet(uint256 previousAmount, uint256 newAmount);
    event PositionCreationFeePaid(uint256 indexed positionId, address indexed treasury, uint256 amount);

    error OnlyDiamondSelf(address caller);
    error IncorrectPositionCreationFee(uint256 required, uint256 provided);
    error PositionCreationFeeTransferFailed(address treasury, uint256 amount);
    error PositionInitializing(uint256 positionId);
    error PositionHasActiveLegs(uint256 positionId, uint256 activeLegCount);

    function createPosition(address receiver) external payable returns (uint256 positionId) {
        _enforcePositionCreationFee();
        positionId = _createPosition(receiver, bytes32(0));
        _forwardPositionCreationFee(positionId);
    }

    function createPositionForModule(address receiver, bytes32 initialLegKey)
        external
        payable
        returns (uint256 positionId)
    {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        if (initialLegKey == bytes32(0)) revert LibPosition.ZeroLegKey();
        _enforcePositionCreationFee();
        positionId = _createPosition(receiver, initialLegKey);
        _forwardPositionCreationFee(positionId);
    }

    function setPositionCreationFee(uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        uint256 previousAmount = ps.creationFeeAmount;
        ps.creationFeeAmount = amount;
        emit PositionCreationFeeSet(previousAmount, amount);
    }

    function positionCreationFee() external view returns (uint256) {
        return LibPosition.positionStorage().creationFeeAmount;
    }

    function closePosition(uint256 positionId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.positionInitializing[positionId]) revert PositionInitializing(positionId);
        uint256 count = ps.activeLegCount[positionId];
        if (count != 0) revert PositionHasActiveLegs(positionId, count);
        _burn(positionId);
        emit PositionClosed(positionId);
    }

    function nextPositionId() external view returns (uint256) {
        return LibPosition.positionStorage().nextPositionId;
    }

    function activeLegCount(uint256 positionId) external view returns (uint256) {
        return LibPosition.positionStorage().activeLegCount[positionId];
    }

    function positionInitializing(uint256 positionId) external view returns (bool) {
        return LibPosition.positionStorage().positionInitializing[positionId];
    }

    function isPositionLegActive(uint256 positionId, bytes32 legKey_) external view returns (bool) {
        return LibPosition.positionStorage().activeLeg[positionId][legKey_];
    }

    function positionKey(uint256 positionId) external view returns (bytes32) {
        ownerOf(positionId);
        return keccak256(abi.encode(address(this), positionId));
    }

    function _createPosition(address receiver, bytes32 initialLegKey) private returns (uint256 positionId) {
        positionId = LibPosition.allocatePositionId();
        _safeMint(receiver, positionId);
        if (initialLegKey != bytes32(0)) LibPosition.activateLeg(positionId, initialLegKey);
        LibPosition.finishInitialization(positionId);
        emit PositionCreated(positionId, receiver);
    }

    function _enforcePositionCreationFee() private view {
        uint256 required = LibPosition.positionStorage().creationFeeAmount;
        if (msg.value != required) revert IncorrectPositionCreationFee(required, msg.value);
    }

    function _forwardPositionCreationFee(uint256 positionId) private {
        uint256 amount = msg.value;
        if (amount == 0) return;
        address treasury = LibBasket.basketStorage().treasury;
        (bool sent,) = payable(treasury).call{value: amount}("");
        if (!sent) revert PositionCreationFeeTransferFailed(treasury, amount);
        emit PositionCreationFeePaid(positionId, treasury, amount);
    }
}
