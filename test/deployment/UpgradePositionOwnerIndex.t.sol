// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";

import {UpgradePositionOwnerIndex} from "../../script/UpgradePositionOwnerIndex.s.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsProtocolInit} from "../../src/diamond/StaticsProtocolInit.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../../src/interfaces/IPositionOwnerIndex.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";

contract LegacyPositionIndexHarnessFacet {
    function clearOwnerIndex(uint256 positionId) external {
        LibPosition.syncOwnerIndex(positionId, address(0));
    }
}

contract UpgradePositionOwnerIndexTest is Test {
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;
    uint256 private constant LEGACY_POSITION_SELECTOR_COUNT = 25;

    UpgradePositionOwnerIndex private ceremony;
    StaticsTimelock private timelock;
    StaticsDiamond private diamond;
    LegacyPositionIndexHarnessFacet private migrationHarness;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        ceremony = new UpgradePositionOwnerIndex();
        address[] memory proposers = new address[](1);
        proposers[0] = address(ceremony);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new StaticsTimelock(proposers, executors, address(0));

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        PositionNFTFacet legacyPositionFacet = new PositionNFTFacet();
        StaticsInterfaceInit interfaceInit = new StaticsInterfaceInit();
        migrationHarness = new LegacyPositionIndexHarnessFacet();

        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](6);
        initialCut[0] = _cut(address(cutFacet), IDiamondCut.FacetCutAction.Add, StaticsSelectors.diamondCut());
        initialCut[1] = _cut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, StaticsSelectors.diamondLoupe());
        initialCut[2] = _cut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, StaticsSelectors.ownership());
        initialCut[3] = _cut(address(legacyPositionFacet), IDiamondCut.FacetCutAction.Add, _legacySelectors());
        initialCut[4] = _cut(address(interfaceInit), IDiamondCut.FacetCutAction.Add, StaticsSelectors.interfaceInit());
        bytes4[] memory harnessSelectors = new bytes4[](1);
        harnessSelectors[0] = LegacyPositionIndexHarnessFacet.clearOwnerIndex.selector;
        initialCut[5] = _cut(address(migrationHarness), IDiamondCut.FacetCutAction.Add, harnessSelectors);

        StaticsProtocolInit protocolInit = new StaticsProtocolInit();
        diamond = new StaticsDiamond(
            address(timelock),
            address(0),
            address(protocolInit),
            abi.encodeCall(
                StaticsProtocolInit.genesisInitialize,
                (initialCut, makeAddr("guardian"), makeAddr("treasury"), address(this), 0, 0, address(0))
            )
        );

        bytes4[] memory interfaceIds = new bytes4[](2);
        interfaceIds[0] = type(IPositionOwnerIndex).interfaceId;
        interfaceIds[1] = ERC4906_INTERFACE_ID;
        bool[] memory supported = new bool[](2);
        vm.prank(address(timelock));
        StaticsInterfaceInit(address(diamond)).setInterfaces(interfaceIds, supported);

        vm.prank(alice);
        uint256 positionId = IStaticsPosition(address(diamond)).createPosition(alice);
        assertEq(positionId, 1);
        LegacyPositionIndexHarnessFacet(address(diamond)).clearOwnerIndex(positionId);
    }

    function testGovernedUpgradePreservesPositionAndSeedsIndexPermissionlessly() public {
        PositionNFTFacet replacement = new PositionNFTFacet();
        address legacyFacet = IDiamondLoupe(address(diamond)).facetAddress(IERC721.ownerOf.selector);
        IModularPositionNFT.PositionState memory stateBefore = IModularPositionNFT(address(diamond)).positionState(1);

        assertFalse(IERC165(address(diamond)).supportsInterface(type(IPositionOwnerIndex).interfaceId));
        assertFalse(IERC165(address(diamond)).supportsInterface(ERC4906_INTERFACE_ID));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IPositionOwnerIndex.positionCount.selector), address(0));

        IDiamondCut.FacetCut[] memory directCut = ceremony.buildCut(address(replacement));
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, address(this), address(timelock)));
        IDiamondCut(address(diamond)).diamondCut(directCut, address(0), "");

        bytes32 salt = keccak256("Robinhood Position owner index");
        bytes32 operationId = ceremony.schedule(address(diamond), address(replacement), salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.expectRevert(
            abi.encodeWithSelector(UpgradePositionOwnerIndex.UpgradeOperationNotReady.selector, operationId)
        );
        ceremony.execute(address(diamond), address(replacement), salt);

        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(address(diamond), address(replacement), salt);

        assertTrue(IERC165(address(diamond)).supportsInterface(type(IPositionOwnerIndex).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(ERC4906_INTERFACE_ID));
        assertEq(IERC721(address(diamond)).ownerOf(1), alice);
        assertEq(IStaticsPosition(address(diamond)).nextPositionId(), 2);
        assertEq(IModularPositionNFT(address(diamond)).positionState(1).stateNonce, stateBefore.stateNonce);
        assertEq(IPositionOwnerIndex(address(diamond)).positionCount(alice), 0);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IERC721.ownerOf.selector), address(replacement));
        assertNotEq(legacyFacet, address(replacement));

        vm.prank(bob);
        IPositionOwnerIndex(address(diamond)).syncPositionOwnerIndex(1);
        assertEq(IPositionOwnerIndex(address(diamond)).positionCount(alice), 1);
        (uint256[] memory alicePositions, uint256 nextCursor) =
            IPositionOwnerIndex(address(diamond)).positionsOfOwner(alice, 0, 100);
        assertEq(alicePositions.length, 1);
        assertEq(alicePositions[0], 1);
        assertEq(nextCursor, 1);

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, 1);
        assertEq(IPositionOwnerIndex(address(diamond)).positionCount(alice), 0);
        assertEq(IPositionOwnerIndex(address(diamond)).positionCount(bob), 1);
        assertEq(IERC721(address(diamond)).ownerOf(1), bob);
    }

    function testScheduleRejectsFacetWithUnexpectedRuntime() public {
        DiamondCutFacet wrongFacet = new DiamondCutFacet();
        vm.expectRevert(abi.encodeWithSelector(UpgradePositionOwnerIndex.InvalidFacet.selector, address(wrongFacet)));
        ceremony.schedule(address(diamond), address(wrongFacet), keccak256("wrong facet"));
    }

    function _legacySelectors() private pure returns (bytes4[] memory legacySelectors) {
        bytes4[] memory selectors = StaticsSelectors.position();
        legacySelectors = new bytes4[](LEGACY_POSITION_SELECTOR_COUNT);
        for (uint256 i; i < LEGACY_POSITION_SELECTOR_COUNT; ++i) {
            legacySelectors[i] = selectors[i];
        }
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        private
        pure
        returns (IDiamondCut.FacetCut memory entry)
    {
        entry = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }
}

contract RobinhoodPositionOwnerIndexUpgradeForkTest is Test {
    uint256 private constant PRE_UPGRADE_FORK_BLOCK = 96_877_243;

    struct OwnerIndexRehearsal {
        address diamond;
        address proposer;
        uint256[] positionIds;
        UpgradePositionOwnerIndex ceremony;
        PositionNFTFacet replacement;
        StaticsTimelock timelock;
        address[] ownersBefore;
        bytes32[] statesBefore;
    }

    function testRehearsesUpgradeAgainstLiveRobinhoodState() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            return;
        }
        vm.createSelectFork(rpcUrl, PRE_UPGRADE_FORK_BLOCK);

        OwnerIndexRehearsal memory rehearsal = _snapshotOwnerIndex();
        _executeOwnerIndexUpgrade(rehearsal);
        _assertOwnerIndexPreserved(rehearsal);
    }

    function _snapshotOwnerIndex() private returns (OwnerIndexRehearsal memory rehearsal) {
        rehearsal.diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        rehearsal.proposer = vm.envAddress("STATICS_TIMELOCK_PROPOSER");
        rehearsal.positionIds = vm.envUint("POSITION_OWNER_INDEX_IDS", ",");
        assertGt(rehearsal.positionIds.length, 0, "position IDs required");
        assertLe(rehearsal.positionIds.length, 100, "position ID page exceeds limit");
        rehearsal.ceremony = new UpgradePositionOwnerIndex();
        rehearsal.replacement = new PositionNFTFacet();
        rehearsal.timelock = StaticsTimelock(payable(IERC173(rehearsal.diamond).owner()));

        uint256 count = rehearsal.positionIds.length;
        rehearsal.ownersBefore = new address[](count);
        rehearsal.statesBefore = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            rehearsal.ownersBefore[i] = IERC721(rehearsal.diamond).ownerOf(rehearsal.positionIds[i]);
            assertEq(rehearsal.ownersBefore[i], rehearsal.ownersBefore[0], "positions must share an owner");
            rehearsal.statesBefore[i] =
                keccak256(abi.encode(IModularPositionNFT(rehearsal.diamond).positionState(rehearsal.positionIds[i])));
        }
    }

    function _executeOwnerIndexUpgrade(OwnerIndexRehearsal memory rehearsal) private {
        (address validatedTimelock,) = rehearsal.ceremony.validateBeforeUpgrade(rehearsal.diamond, address(rehearsal.replacement));
        assertEq(validatedTimelock, address(rehearsal.timelock));
        bytes32 salt = keccak256("Robinhood Position owner index fork rehearsal");
        bytes memory payload = rehearsal.ceremony.buildPayload(rehearsal.diamond, address(rehearsal.replacement));
        uint256 delay = rehearsal.timelock.getMinDelay();

        vm.prank(rehearsal.proposer);
        rehearsal.timelock.schedule(rehearsal.diamond, 0, payload, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        rehearsal.timelock.execute(rehearsal.diamond, 0, payload, bytes32(0), salt);
        rehearsal.ceremony.validateUpgraded(rehearsal.diamond, address(rehearsal.replacement));
    }

    function _assertOwnerIndexPreserved(OwnerIndexRehearsal memory rehearsal) private {
        for (uint256 i; i < rehearsal.positionIds.length; ++i) {
            IPositionOwnerIndex(rehearsal.diamond).syncPositionOwnerIndex(rehearsal.positionIds[i]);
            assertEq(IERC721(rehearsal.diamond).ownerOf(rehearsal.positionIds[i]), rehearsal.ownersBefore[i]);
            assertEq(
                keccak256(abi.encode(IModularPositionNFT(rehearsal.diamond).positionState(rehearsal.positionIds[i]))),
                rehearsal.statesBefore[i]
            );
        }

        address owner = rehearsal.ownersBefore[0];
        assertEq(IPositionOwnerIndex(rehearsal.diamond).positionCount(owner), rehearsal.positionIds.length);
        (uint256[] memory indexedPositions, uint256 nextCursor) =
            IPositionOwnerIndex(rehearsal.diamond).positionsOfOwner(owner, 0, rehearsal.positionIds.length);
        assertEq(indexedPositions, rehearsal.positionIds);
        assertEq(nextCursor, rehearsal.positionIds.length);
    }
}
