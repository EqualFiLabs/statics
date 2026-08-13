// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Consecutive} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Consecutive.sol";
import {IStaticsGenesis, IStaticsGenesisBinding, IStaticsGenesisProtocol} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisRenderer} from "../interfaces/IStaticsGenesisRenderer.sol";

/// @notice Immutable collection of the 5,555 scarce Statics Genesis NFTs.
contract StaticsGenesis is ERC721Consecutive, IERC4906, IStaticsGenesis {
    uint256 public constant COLLECTION_SIZE = 5_555;
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    address public bootstrapBinder;
    IStaticsGenesisRenderer public immutable renderer;
    address public protocol;

    error InvalidTreasury();
    error InvalidRenderer();
    error InvalidProtocol();
    error ProtocolAlreadyBound();
    error UnauthorizedBootstrapBinder(address caller);
    error UnauthorizedProtocol(address caller);
    error TransfersDisabled();

    constructor(address treasury, IStaticsGenesisRenderer renderer_) ERC721("Statics Genesis", "STATICS-GENESIS") {
        if (treasury == address(0)) revert InvalidTreasury();
        if (address(renderer_) == address(0)) revert InvalidRenderer();
        bootstrapBinder = msg.sender;
        renderer = renderer_;
        _mintConsecutive(treasury, 5_000);
        _mintConsecutive(treasury, 555);
    }

    function bindProtocol(address protocol_) external {
        if (protocol != address(0)) revert ProtocolAlreadyBound();
        if (msg.sender != bootstrapBinder) revert UnauthorizedBootstrapBinder(msg.sender);
        if (protocol_ == address(0) || protocol_.code.length == 0) revert InvalidProtocol();
        address collection;
        try IStaticsGenesisBinding(protocol_).genesisCollection() returns (address reportedCollection) {
            collection = reportedCollection;
        } catch {
            revert InvalidProtocol();
        }
        if (collection != address(this)) revert InvalidProtocol();
        protocol = protocol_;
        delete bootstrapBinder;
        emit BatchMetadataUpdate(1, COLLECTION_SIZE);
    }

    function refreshMetadata(uint256 genesisId) external {
        if (msg.sender != protocol) revert UnauthorizedProtocol(msg.sender);
        _requireOwned(genesisId);
        emit MetadataUpdate(genesisId);
    }

    function tokenURI(uint256 genesisId) public view override returns (string memory) {
        _requireOwned(genesisId);
        return renderer.renderTokenURI(address(this), genesisId, protocol);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || interfaceId == type(IStaticsGenesis).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _firstConsecutiveId() internal pure override returns (uint96) {
        return 1;
    }

    function _update(address to, uint256 genesisId, address auth)
        internal
        override(ERC721Consecutive)
        returns (address previousOwner)
    {
        previousOwner = _ownerOf(genesisId);
        bool ownerChangingTransfer = previousOwner != address(0) && to != address(0) && previousOwner != to;
        if (ownerChangingTransfer && protocol == address(0)) revert TransfersDisabled();
        previousOwner = super._update(to, genesisId, auth);
        if (ownerChangingTransfer) {
            IStaticsGenesisProtocol(protocol).onGenesisTransfer(genesisId, previousOwner, to);
            emit MetadataUpdate(genesisId);
        }
    }
}
