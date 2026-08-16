// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Consecutive} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Consecutive.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC7572} from "../interfaces/IERC7572.sol";
import {IStaticsGenesis, IStaticsGenesisProtocol} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisRenderer} from "../interfaces/IStaticsGenesisRenderer.sol";

/// @notice Fixed 5,555-token collection paired one-for-one with 180,010 STATICS claims.
contract StaticsGenesis is ERC721Consecutive, ERC2981, IERC4906, IERC7572, IStaticsGenesis, Ownable2Step {
    uint256 public constant override COLLECTION_SIZE = 5_555;
    uint256 public constant override TREASURY_GENESIS_COUNT = 555;
    uint256 public constant override VAULT_GENESIS_COUNT = 5_000;
    uint256 public constant override mintedSupply = COLLECTION_SIZE;
    uint96 public constant DEFAULT_ROYALTY_BPS = 500;
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    address public immutable override vault;
    IStaticsGenesisRenderer public immutable renderer;
    address public override protocol;
    bool public override launchFinalized;
    string public override contractURI;
    string public externalURLBase;
    bool private callbackEntered;

    error InvalidTreasury();
    error InvalidVault();
    error InvalidRenderer();
    error InvalidProtocol();
    error ProtocolAlreadyBound();
    error UnauthorizedVault(address caller);
    error UnauthorizedProtocol(address caller);
    error LaunchNotFinalized();
    error LaunchAlreadyFinalized();
    error TransfersDisabled();
    error ReentrantTransferCallback();
    error InvalidMetadataURI();
    error RoyaltyExceedsMaximum(uint96 royaltyBps, uint96 maximumRoyaltyBps);
    error OwnershipRenunciationDisabled();

    event DefaultRoyaltyUpdated(address indexed receiver, uint96 royaltyBps);
    event ExternalURLBaseUpdated(string externalURLBase);

    constructor(
        address treasury,
        address vault_,
        IStaticsGenesisRenderer renderer_,
        address protocolBinder,
        string memory contractURI_,
        string memory externalURLBase_
    ) ERC721("Statics Genesis", "STATICS-GENESIS") Ownable(protocolBinder) {
        if (treasury == address(0)) revert InvalidTreasury();
        if (vault_ == address(0)) revert InvalidVault();
        if (address(renderer_) == address(0)) revert InvalidRenderer();
        if (protocolBinder == address(0)) revert InvalidProtocol();
        if (bytes(contractURI_).length == 0 || bytes(externalURLBase_).length == 0) revert InvalidMetadataURI();
        vault = vault_;
        renderer = renderer_;
        contractURI = contractURI_;
        externalURLBase = externalURLBase_;
        _setDefaultRoyalty(treasury, DEFAULT_ROYALTY_BPS);
        _mintConsecutive(treasury, uint96(TREASURY_GENESIS_COUNT));
        _mintConsecutive(vault_, uint96(VAULT_GENESIS_COUNT));
    }

    function finalizeLaunch() external override {
        if (msg.sender != vault) revert UnauthorizedVault(msg.sender);
        if (launchFinalized) revert LaunchAlreadyFinalized();
        launchFinalized = true;
    }

    function bindProtocol(address protocol_) external override onlyOwner {
        if (!launchFinalized) revert LaunchNotFinalized();
        if (protocol != address(0)) revert ProtocolAlreadyBound();
        if (protocol_ == address(0) || protocol_.code.length == 0) revert InvalidProtocol();
        address collection;
        try IStaticsGenesisProtocol(protocol_).genesisCollection() returns (address reportedCollection) {
            collection = reportedCollection;
        } catch {
            revert InvalidProtocol();
        }
        if (collection != address(this)) revert InvalidProtocol();
        protocol = protocol_;
        emit ProtocolBound(protocol_);
        emit BatchMetadataUpdate(1, COLLECTION_SIZE);
    }

    function setDefaultRoyalty(address receiver, uint96 royaltyBps) external onlyOwner {
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyExceedsMaximum(royaltyBps, MAX_ROYALTY_BPS);
        if (royaltyBps == 0) {
            _deleteDefaultRoyalty();
            emit DefaultRoyaltyUpdated(address(0), 0);
            return;
        }
        _setDefaultRoyalty(receiver, royaltyBps);
        emit DefaultRoyaltyUpdated(receiver, royaltyBps);
    }

    function setContractURI(string calldata contractURI_) external onlyOwner {
        if (bytes(contractURI_).length == 0) revert InvalidMetadataURI();
        contractURI = contractURI_;
        emit ContractURIUpdated();
    }

    function setExternalURLBase(string calldata externalURLBase_) external onlyOwner {
        if (bytes(externalURLBase_).length == 0) revert InvalidMetadataURI();
        externalURLBase = externalURLBase_;
        emit ExternalURLBaseUpdated(externalURLBase_);
        emit BatchMetadataUpdate(1, COLLECTION_SIZE);
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function refreshMetadata(uint256 genesisId) external override {
        if (msg.sender != protocol) revert UnauthorizedProtocol(msg.sender);
        _requireOwned(genesisId);
        emit MetadataUpdate(genesisId);
    }

    function tokenURI(uint256 genesisId) public view override returns (string memory) {
        _requireOwned(genesisId);
        return renderer.renderTokenURI(address(this), genesisId, protocol, externalURLBase);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || interfaceId == type(IStaticsGenesis).interfaceId
            || interfaceId == type(IERC7572).interfaceId || super.supportsInterface(interfaceId);
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
        if (ownerChangingTransfer) {
            if (!launchFinalized) revert TransfersDisabled();
            if (auth != address(0)) _checkAuthorized(previousOwner, auth, genesisId);
            address protocol_ = protocol;
            if (protocol_ != address(0)) {
                if (callbackEntered) revert ReentrantTransferCallback();
                callbackEntered = true;
                IStaticsGenesisProtocol(protocol_).onGenesisTransfer(genesisId, previousOwner, to);
                callbackEntered = false;
                previousOwner = super._update(to, genesisId, address(0));
                emit MetadataUpdate(genesisId);
                return previousOwner;
            }
        }
        return super._update(to, genesisId, auth);
    }
}
