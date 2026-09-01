// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IModularPositionNFT} from "../interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../interfaces/IPositionOwnerIndex.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPositionSVG} from "../metadata/LibPositionSVG.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "./LibPosition.sol";

contract PositionNFTFacet is
    ERC721Upgradeable,
    IModularPositionNFT,
    IStaticsPosition,
    IStaticsPositionFees,
    IStaticsPositionModule,
    IERC5192
{
    using Strings for uint256;
    uint256 internal constant MAX_POSITION_PAGE_SIZE = 100;

    event PositionCreated(uint256 indexed positionId, address indexed owner);
    event PositionClosed(uint256 indexed positionId);
    event PositionCreationFeeSet(uint256 previousAmount, uint256 newAmount);
    event PositionCreationFeePaid(uint256 indexed positionId, address indexed treasury, uint256 amount);

    error OnlyDiamondSelf(address caller);
    error IncorrectPositionCreationFee(uint256 required, uint256 provided);
    error PositionCreationFeeTransferFailed(address treasury, uint256 amount);
    error PositionInitializing(uint256 positionId);
    error PositionHasActiveLegs(uint256 positionId, uint256 activeLegCount);
    error PositionHasUnresolvedObligations(uint256 positionId, uint256 unresolvedObligationCount);
    error InvalidPositionPageSize(uint256 requested, uint256 maximum);
    error PositionLocked(uint256 positionId);

    function createPosition(address receiver) external payable returns (uint256 positionId) {
        _enforcePositionCreationFee();
        positionId = _createPosition(receiver, bytes32(0), bytes32(0));
        _forwardPositionCreationFee(positionId);
    }

    function createPositionForModule(address receiver, bytes32 moduleType, bytes32 localPositionId)
        external
        payable
        returns (uint256 positionId)
    {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        if (moduleType == bytes32(0)) revert LibPosition.InvalidModuleType();
        _enforcePositionCreationFee();
        positionId = _createPosition(receiver, moduleType, localPositionId);
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

    function positionCount(address owner) external view returns (uint256) {
        return LibPosition.positionStorage().ownedPositions[owner].length;
    }

    function positionsOfOwner(address owner, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_POSITION_PAGE_SIZE) {
            revert InvalidPositionPageSize(limit, MAX_POSITION_PAGE_SIZE);
        }
        uint256[] storage ownedPositions = LibPosition.positionStorage().ownedPositions[owner];
        uint256 length = ownedPositions.length;
        if (cursor >= length) return (new uint256[](0), length);
        uint256 remaining = length - cursor;
        uint256 pageLength = remaining < limit ? remaining : limit;
        positionIds = new uint256[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            positionIds[i] = ownedPositions[cursor + i];
        }
        nextCursor = cursor + pageLength;
    }

    function syncPositionOwnerIndex(uint256 positionId) external {
        address owner = ownerOf(positionId);
        LibPosition.syncOwnerIndex(positionId, owner);
        emit IPositionOwnerIndex.PositionOwnerIndexSynced(positionId, owner);
    }

    function tokenURI(uint256 positionId) public view override returns (string memory) {
        _requireOwned(positionId);
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(LibPositionSVG.render(positionId))));
        bytes memory json = abi.encodePacked(
            '{"name":"Statics Position #',
            positionId.toString(),
            '","description":"A transferable financial account containing its Statics protocol assets and liabilities.","image":"',
            image,
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function closePosition(uint256 positionId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibPosition.PackedPositionState storage state = LibPosition.positionStorage().state[positionId];
        if (state.initializing) revert PositionInitializing(positionId);
        if (state.activeLegCount != 0) revert PositionHasActiveLegs(positionId, state.activeLegCount);
        if (state.unresolvedObligationCount != 0) {
            revert PositionHasUnresolvedObligations(positionId, state.unresolvedObligationCount);
        }
        LibPosition.incrementNonce(positionId);
        _burn(positionId);
        LibPosition.emitStateChanged(positionId);
        emit PositionClosed(positionId);
    }

    function nextPositionId() external view returns (uint256) {
        return LibPosition.positionStorage().nextPositionId;
    }

    function activeLegCount(uint256 positionId) external view returns (uint256) {
        return LibPosition.positionStorage().state[positionId].activeLegCount;
    }

    function positionInitializing(uint256 positionId) external view returns (bool) {
        return LibPosition.positionStorage().state[positionId].initializing;
    }

    function positionState(uint256 positionId) external view returns (PositionState memory state) {
        LibPosition.PackedPositionState storage stored = LibPosition.positionStorage().state[positionId];
        state = PositionState({
            exists: _ownerOf(positionId) != address(0),
            stateNonce: stored.stateNonce,
            activeLegCount: stored.activeLegCount,
            unresolvedObligationCount: stored.unresolvedObligationCount
        });
    }

    function isLegActive(uint256 positionId, bytes32 legKey_) external view returns (bool) {
        return LibPosition.positionStorage().activeLeg[positionId][legKey_];
    }

    function isPositionClosable(uint256 positionId) external view returns (bool) {
        LibPosition.PackedPositionState storage state = LibPosition.positionStorage().state[positionId];
        return _ownerOf(positionId) != address(0) && !state.initializing && state.activeLegCount == 0
            && state.unresolvedObligationCount == 0;
    }

    function locked(uint256 positionId) public view returns (bool) {
        _requireOwned(positionId);
        return LibGenesisIntegration.genesisStorage().linkedGenesis[positionId] != 0;
    }

    function _createPosition(address receiver, bytes32 moduleType, bytes32 localPositionId)
        private
        returns (uint256 positionId)
    {
        positionId = LibPosition.allocatePositionId();
        _safeMint(receiver, positionId);
        LibPosition.emitStateChanged(positionId);
        if (moduleType != bytes32(0)) LibPosition.activateLeg(positionId, moduleType, localPositionId);
        LibPosition.finishInitialization(positionId);
        emit PositionCreated(positionId, receiver);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address previousOwner) {
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0) && currentOwner != to && locked(tokenId)) {
            revert PositionLocked(tokenId);
        }
        previousOwner = super._update(to, tokenId, auth);
        LibPosition.syncOwnerIndex(tokenId, to);
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
