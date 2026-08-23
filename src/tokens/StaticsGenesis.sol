// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Consecutive} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Consecutive.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {ICreatorToken, ICreatorTokenLegacy, ITransferValidator} from "../interfaces/ICreatorToken.sol";
import {IGenesisActivationRegistry} from "../interfaces/IGenesisActivationRegistry.sol";
import {IERC5192} from "../interfaces/IERC5192.sol";
import {IERC7572} from "../interfaces/IERC7572.sol";
import {IStaticsGenesis, IStaticsGenesisProtocol} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisVault} from "../interfaces/IStaticsGenesisVault.sol";
import {IStaticsGenesisRenderer} from "../interfaces/IStaticsGenesisRenderer.sol";

/// @notice Fixed 5,555-token collection paired one-for-one with 180,000 STATICS claims plus a
///         1/5,555 permanent native ETH reserve share.
contract StaticsGenesis is
    ERC721Consecutive,
    ERC2981,
    IERC4906,
    IERC5192,
    IERC7572,
    ICreatorToken,
    IStaticsGenesis,
    Ownable2Step
{
    uint256 public constant override COLLECTION_SIZE = 5_555;
    uint256 public constant override mintedSupply = COLLECTION_SIZE;
    uint96 public constant DEFAULT_ROYALTY_BPS = 500;
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    address public immutable override vault;
    address public immutable override activationRegistry;
    IStaticsGenesisRenderer public immutable renderer;
    address public override protocol;
    bool public override launchFinalized;
    string public override contractURI;
    string public externalURLBase;
    address private transferValidator;
    mapping(uint256 genesisId => bool reportedLocked) private reportedLockStatus;

    error InvalidVault();
    error InvalidActivationRegistry();
    error InvalidRenderer();
    error InvalidProtocol();
    error ProtocolAlreadyBound();
    error UnauthorizedVault(address caller);
    error UnauthorizedProtocol(address caller);
    error LaunchNotFinalized();
    error LaunchAlreadyFinalized();
    error TransfersDisabled();
    error InvalidMetadataURI();
    error RoyaltyExceedsMaximum(uint96 royaltyBps, uint96 maximumRoyaltyBps);
    error OwnershipRenunciationDisabled();
    error InvalidTransferValidator(address validator);
    error GenesisLocked(uint256 genesisId);
    error UnexpectedGenesisOwner(uint256 genesisId, address expected, address actual);
    error InvalidRecoveryAcknowledgement(address protocol, bytes4 acknowledgement);

    event DefaultRoyaltyUpdated(address indexed receiver, uint96 royaltyBps);
    event ExternalURLBaseUpdated(string externalURLBase);

    constructor(
        address vault_,
        address activationRegistry_,
        IStaticsGenesisRenderer renderer_,
        address protocolBinder,
        address royaltyReceiver,
        string memory contractURI_,
        string memory externalURLBase_
    ) ERC721("Statics Genesis", "STATICS-GENESIS") Ownable(protocolBinder) {
        if (vault_ == address(0)) revert InvalidVault();
        if (activationRegistry_ == address(0) || activationRegistry_.code.length == 0) {
            revert InvalidActivationRegistry();
        }
        if (address(renderer_) == address(0)) revert InvalidRenderer();
        if (protocolBinder == address(0)) revert InvalidProtocol();
        if (royaltyReceiver == address(0)) revert InvalidProtocol();
        if (bytes(contractURI_).length == 0 || bytes(externalURLBase_).length == 0) revert InvalidMetadataURI();
        vault = vault_;
        activationRegistry = activationRegistry_;
        renderer = renderer_;
        contractURI = contractURI_;
        externalURLBase = externalURLBase_;
        _setDefaultRoyalty(royaltyReceiver, DEFAULT_ROYALTY_BPS);
        // Keep each ERC-2309 batch within OpenZeppelin's marketplace-friendly 5,000-token cap.
        _mintConsecutive(vault_, 5_000);
        _mintConsecutive(vault_, uint96(COLLECTION_SIZE - 5_000));
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
        try IStaticsGenesisProtocol(protocol_).linkedPosition(1) returns (uint256) {}
        catch {
            revert InvalidProtocol();
        }
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

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        uint256 denominator = _feeDenominator();
        uint256 royaltyBps;
        (receiver, royaltyBps) = super.royaltyInfo(tokenId, denominator);
        royaltyAmount = Math.mulDiv(salePrice, royaltyBps, denominator);
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

    function setTransferValidator(address validator) external override onlyOwner {
        if (validator != address(0) && validator.code.length == 0) revert InvalidTransferValidator(validator);
        address previousValidator = transferValidator;
        transferValidator = validator;
        emit TransferValidatorUpdated(previousValidator, validator);
    }

    function getTransferValidator() public view override returns (address validator) {
        return transferValidator;
    }

    function getTransferValidationFunction()
        external
        pure
        override
        returns (bytes4 functionSignature, bool isViewFunction)
    {
        functionSignature = ITransferValidator.validateTransfer.selector;
        isViewFunction = true;
    }

    function locked(uint256 genesisId) public view override returns (bool) {
        _requireOwned(genesisId);
        try IStaticsGenesisVault(vault).creditActive(genesisId) returns (bool active) {
            if (active) return true;
        } catch {
            return true;
        }
        address protocol_ = protocol;
        if (protocol_ == address(0)) return false;
        try IStaticsGenesisProtocol(protocol_).linkedPosition(genesisId) returns (uint256 positionId) {
            return positionId != 0;
        } catch {
            return true;
        }
    }

    function refreshLockStatus(uint256 genesisId) external override {
        if (msg.sender != protocol && msg.sender != vault) revert UnauthorizedProtocol(msg.sender);
        bool currentStatus = locked(genesisId);
        if (reportedLockStatus[genesisId] == currentStatus) return;
        reportedLockStatus[genesisId] = currentStatus;
        if (currentStatus) emit Locked(genesisId);
        else emit Unlocked(genesisId);
    }

    function refreshMetadata(uint256 genesisId) external override {
        if (msg.sender != protocol && msg.sender != activationRegistry) revert UnauthorizedProtocol(msg.sender);
        _requireOwned(genesisId);
        emit MetadataUpdate(genesisId);
    }

    function recoverToVault(uint256 genesisId, address expectedOwner) external override {
        if (msg.sender != vault) revert UnauthorizedVault(msg.sender);
        address previousOwner = _ownerOf(genesisId);
        if (previousOwner != expectedOwner) revert UnexpectedGenesisOwner(genesisId, expectedOwner, previousOwner);

        address protocol_ = protocol;
        if (protocol_ != address(0)) {
            bytes4 acknowledgement = IStaticsGenesisProtocol(protocol_).onGenesisRecovery(genesisId, previousOwner);
            if (acknowledgement != IStaticsGenesisProtocol.onGenesisRecovery.selector) {
                revert InvalidRecoveryAcknowledgement(protocol_, acknowledgement);
            }
        }

        IGenesisActivationRegistry(activationRegistry).onGenesisTransfer(genesisId, previousOwner, vault);
        super._update(vault, genesisId, address(0));
        emit MetadataUpdate(genesisId);
    }

    function tokenURI(uint256 genesisId) public view override returns (string memory) {
        _requireOwned(genesisId);
        return renderer.renderTokenURI(address(this), genesisId, activationRegistry, externalURLBase);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || interfaceId == type(IStaticsGenesis).interfaceId
            || interfaceId == type(IERC5192).interfaceId || interfaceId == type(IERC7572).interfaceId
            || interfaceId == type(ICreatorToken).interfaceId || interfaceId == type(ICreatorTokenLegacy).interfaceId
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
        if (ownerChangingTransfer) {
            if (!launchFinalized) revert TransfersDisabled();
            if (locked(genesisId)) revert GenesisLocked(genesisId);
            if (auth != address(0)) _checkAuthorized(previousOwner, auth, genesisId);
            address validator = transferValidator;
            if (validator != address(0) && msg.sender != validator) {
                ITransferValidator(validator).validateTransfer(_msgSender(), previousOwner, to, genesisId);
            }
            IGenesisActivationRegistry(activationRegistry).onGenesisTransfer(genesisId, previousOwner, to);
            previousOwner = super._update(to, genesisId, address(0));
            emit MetadataUpdate(genesisId);
            return previousOwner;
        }
        return super._update(to, genesisId, auth);
    }
}
