// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IPositionOwnerIndex} from "../src/interfaces/IPositionOwnerIndex.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {PositionNFTFacet} from "../src/position/PositionNFTFacet.sol";

/// @notice Governed Robinhood testnet ceremony for installing the Position owner index.
contract UpgradePositionOwnerIndex is Script {
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint256 internal constant LEGACY_POSITION_SELECTOR_COUNT = 25;
    bytes4 internal constant ERC4906_INTERFACE_ID = 0x49064906;

    error UnsupportedChain(uint256 chainId);
    error InvalidDiamond(address diamond);
    error InvalidFacet(address facet);
    error InvalidTimelock(address timelock);
    error InvalidProposer(address proposer);
    error UnexpectedSelectorRoute(bytes4 selector, address expected, address actual);
    error UpgradeAlreadyInstalled();
    error UpgradeOperationExists(bytes32 operationId);
    error UpgradeOperationNotReady(bytes32 operationId);
    error UpgradeValidationFailed();
    error PositionSyncValidationFailed(uint256 positionId, address owner);

    event PositionOwnerIndexFacetDeployed(address indexed facet, bytes32 runtimeCodeHash);
    event PositionOwnerIndexUpgradePrepared(
        bytes32 indexed operationId, address indexed diamond, address indexed timelock, address facet, uint256 delay
    );
    event PositionOwnerIndexUpgradeExecuted(
        bytes32 indexed operationId, address indexed diamond, address indexed facet
    );
    event HistoricalPositionIndexed(uint256 indexed positionId, address indexed owner);

    function runDeploy() external returns (address facet) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        facet = address(new PositionNFTFacet());
        vm.stopBroadcast();

        _validateFacet(facet);
        emit PositionOwnerIndexFacetDeployed(facet, facet.codehash);
    }

    function runSchedule() external returns (bytes32 operationId) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address facet = vm.envAddress("POSITION_OWNER_INDEX_FACET");
        bytes32 salt = vm.envBytes32("POSITION_OWNER_INDEX_TIMELOCK_SALT");
        address proposer = vm.addr(privateKey);

        TimelockController timelock = _validateBeforeUpgrade(diamond, facet);
        _validateProposer(timelock, proposer);
        bytes memory payload = buildPayload(diamond, facet);
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (timelock.isOperation(operationId)) revert UpgradeOperationExists(operationId);
        uint256 delay = timelock.getMinDelay();

        vm.startBroadcast(privateKey);
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, delay);
        vm.stopBroadcast();

        if (!timelock.isOperationPending(operationId)) revert UpgradeValidationFailed();
        emit PositionOwnerIndexUpgradePrepared(operationId, diamond, address(timelock), facet, delay);
    }

    function runExecute() external returns (bytes32 operationId) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address facet = vm.envAddress("POSITION_OWNER_INDEX_FACET");
        bytes32 salt = vm.envBytes32("POSITION_OWNER_INDEX_TIMELOCK_SALT");
        TimelockController timelock = _timelock(diamond);
        bytes memory payload = buildPayload(diamond, facet);
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (!timelock.isOperationReady(operationId)) revert UpgradeOperationNotReady(operationId);

        vm.startBroadcast(privateKey);
        timelock.execute(diamond, 0, payload, bytes32(0), salt);
        vm.stopBroadcast();

        validateUpgraded(diamond, facet);
        emit PositionOwnerIndexUpgradeExecuted(operationId, diamond, facet);
    }

    function runSync() external {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address facet = vm.envAddress("POSITION_OWNER_INDEX_FACET");
        uint256[] memory positionIds = vm.envUint("POSITION_OWNER_INDEX_IDS", ",");
        validateUpgraded(diamond, facet);

        vm.startBroadcast(privateKey);
        for (uint256 i; i < positionIds.length; ++i) {
            IPositionOwnerIndex(diamond).syncPositionOwnerIndex(positionIds[i]);
        }
        vm.stopBroadcast();

        for (uint256 i; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            address owner = IERC721(diamond).ownerOf(positionId);
            if (!_ownerIndexContains(IPositionOwnerIndex(diamond), owner, positionId)) {
                revert PositionSyncValidationFailed(positionId, owner);
            }
            emit HistoricalPositionIndexed(positionId, owner);
        }
    }

    function schedule(address diamond, address facet, bytes32 salt) public returns (bytes32 operationId) {
        TimelockController timelock = _validateBeforeUpgrade(diamond, facet);
        bytes memory payload = buildPayload(diamond, facet);
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (timelock.isOperation(operationId)) revert UpgradeOperationExists(operationId);
        uint256 delay = timelock.getMinDelay();
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, delay);
        if (!timelock.isOperationPending(operationId)) revert UpgradeValidationFailed();
        emit PositionOwnerIndexUpgradePrepared(operationId, diamond, address(timelock), facet, delay);
    }

    function execute(address diamond, address facet, bytes32 salt) public returns (bytes32 operationId) {
        TimelockController timelock = _timelock(diamond);
        bytes memory payload = buildPayload(diamond, facet);
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (!timelock.isOperationReady(operationId)) revert UpgradeOperationNotReady(operationId);
        timelock.execute(diamond, 0, payload, bytes32(0), salt);
        validateUpgraded(diamond, facet);
        emit PositionOwnerIndexUpgradeExecuted(operationId, diamond, facet);
    }

    function buildPayload(address diamond, address facet) public pure returns (bytes memory payload) {
        IDiamondCut.FacetCut[] memory cut = buildCut(facet);
        (address init, bytes memory initData) = interfaceInitialization(diamond);
        payload = abi.encodeCall(IDiamondCut.diamondCut, (cut, init, initData));
    }

    function buildCut(address facet) public pure returns (IDiamondCut.FacetCut[] memory cut) {
        bytes4[] memory positionSelectors = StaticsSelectors.position();
        bytes4[] memory replacements = new bytes4[](LEGACY_POSITION_SELECTOR_COUNT);
        for (uint256 i; i < LEGACY_POSITION_SELECTOR_COUNT; ++i) {
            replacements[i] = positionSelectors[i];
        }
        uint256 additionCount = positionSelectors.length - LEGACY_POSITION_SELECTOR_COUNT;
        bytes4[] memory additions = new bytes4[](additionCount);
        for (uint256 i; i < additionCount; ++i) {
            additions[i] = positionSelectors[LEGACY_POSITION_SELECTOR_COUNT + i];
        }

        cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: replacements
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: additions
        });
    }

    function interfaceInitialization(address diamond) public pure returns (address init, bytes memory initData) {
        bytes4[] memory interfaceIds = new bytes4[](2);
        interfaceIds[0] = type(IPositionOwnerIndex).interfaceId;
        interfaceIds[1] = ERC4906_INTERFACE_ID;
        bool[] memory supported = new bool[](2);
        supported[0] = true;
        supported[1] = true;
        init = diamond;
        initData = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported));
    }

    function validateBeforeUpgrade(address diamond, address facet)
        external
        view
        returns (address timelock, address legacyFacet)
    {
        TimelockController owner = _validateBeforeUpgrade(diamond, facet);
        timelock = address(owner);
        legacyFacet = IDiamondLoupe(diamond).facetAddress(StaticsSelectors.position()[0]);
    }

    function validateUpgraded(address diamond, address facet) public view {
        _validateFacet(facet);
        bytes4[] memory selectors = StaticsSelectors.position();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        for (uint256 i; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != facet) revert UnexpectedSelectorRoute(selectors[i], facet, actual);
        }
        if (
            !IERC165(diamond).supportsInterface(type(IPositionOwnerIndex).interfaceId)
                || !IERC165(diamond).supportsInterface(ERC4906_INTERFACE_ID)
        ) revert UpgradeValidationFailed();
    }

    function _validateBeforeUpgrade(address diamond, address facet) private view returns (TimelockController timelock) {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        _validateFacet(facet);
        timelock = _timelock(diamond);

        bytes4[] memory selectors = StaticsSelectors.position();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address legacyFacet = loupe.facetAddress(selectors[0]);
        if (legacyFacet == address(0)) revert UnexpectedSelectorRoute(selectors[0], address(1), address(0));
        if (legacyFacet == facet) revert UpgradeAlreadyInstalled();
        for (uint256 i; i < LEGACY_POSITION_SELECTOR_COUNT; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != legacyFacet) revert UnexpectedSelectorRoute(selectors[i], legacyFacet, actual);
        }
        for (uint256 i = LEGACY_POSITION_SELECTOR_COUNT; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != address(0)) revert UnexpectedSelectorRoute(selectors[i], address(0), actual);
        }
        bytes4 interfaceInitSelector = StaticsInterfaceInit.setInterfaces.selector;
        if (loupe.facetAddress(interfaceInitSelector) == address(0)) {
            revert UnexpectedSelectorRoute(interfaceInitSelector, address(1), address(0));
        }
    }

    function _validateFacet(address facet) private view {
        if (facet.code.length == 0 || facet.codehash != keccak256(type(PositionNFTFacet).runtimeCode)) {
            revert InvalidFacet(facet);
        }
    }

    function _timelock(address diamond) private view returns (TimelockController timelock) {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));
    }

    function _validateProposer(TimelockController timelock, address proposer) private view {
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), proposer)) revert InvalidProposer(proposer);
    }

    function _ownerIndexContains(IPositionOwnerIndex ownerIndex, address owner, uint256 positionId)
        private
        view
        returns (bool)
    {
        uint256 count = ownerIndex.positionCount(owner);
        uint256 cursor;
        while (cursor < count) {
            uint256 limit = count - cursor;
            if (limit > 100) limit = 100;
            (uint256[] memory positionIds, uint256 nextCursor) = ownerIndex.positionsOfOwner(owner, cursor, limit);
            for (uint256 i; i < positionIds.length; ++i) {
                if (positionIds[i] == positionId) return true;
            }
            if (nextCursor <= cursor) return false;
            cursor = nextCursor;
        }
        return false;
    }

    function _enforceRobinhoodTestnet() private view {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
    }
}
