// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {StaticsDiamond} from "src/diamond/StaticsDiamond.sol";
import {StaticsProtocolInit} from "src/diamond/StaticsProtocolInit.sol";
import {DiamondCutFacet} from "src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {BasketAdminFacet} from "src/facets/BasketAdminFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IStaticsPosition, IStaticsPositionFees, IStaticsPositionModule} from "src/interfaces/IStaticsPosition.sol";
import {LibPosition} from "src/position/LibPosition.sol";
import {PositionNFTFacet} from "src/position/PositionNFTFacet.sol";
import {StaticsSelectors} from "src/libraries/StaticsSelectors.sol";

contract PositionModuleHarnessFacet {
    function createWithLeg(address receiver, bytes32 moduleId, bytes32 localId)
        external
        payable
        returns (uint256 positionId)
    {
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.legKey(moduleId, localId)
        );
    }

    function activate(uint256 positionId, bytes32 moduleId, bytes32 localId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.activateLeg(positionId, LibPosition.legKey(moduleId, localId));
    }

    function deactivate(uint256 positionId, bytes32 moduleId, bytes32 localId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.deactivateLeg(positionId, LibPosition.legKey(moduleId, localId));
    }
}

contract PositionReceiver is IERC721Receiver {
    IStaticsPosition internal immutable positions;
    bytes4 public callbackRevert;

    constructor(address diamond) {
        positions = IStaticsPosition(diamond);
    }

    function onERC721Received(address, address, uint256 positionId, bytes calldata) external returns (bytes4) {
        try positions.closePosition(positionId) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) callbackRevert = bytes4(reason);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function close(uint256 positionId) external {
        positions.closePosition(positionId);
    }
}

contract PositionHolder is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RejectNativeValue {
    receive() external payable {
        revert();
    }
}

contract PositionNFTTest is Test {
    bytes32 internal constant DOLLAR = keccak256("dollar");
    bytes32 internal constant BASKET = keccak256("basket");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    StaticsDiamond internal diamond;
    IERC721 internal nft;
    IERC721Metadata internal metadata;
    IStaticsPosition internal positions;
    IStaticsPositionFees internal positionFees;
    PositionModuleHarnessFacet internal moduleHarness;
    BasketAdminFacet internal basketAdmin;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        PositionNFTFacet positionFacet = new PositionNFTFacet();
        PositionModuleHarnessFacet harnessFacet = new PositionModuleHarnessFacet();
        BasketAdminFacet basketAdminFacet = new BasketAdminFacet();

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](6);
        cut[0] = _cut(address(cutFacet), StaticsSelectors.diamondCut());
        cut[1] = _cut(address(loupeFacet), StaticsSelectors.diamondLoupe());
        cut[2] = _cut(address(ownershipFacet), StaticsSelectors.ownership());
        cut[3] = _cut(address(positionFacet), StaticsSelectors.position());
        bytes4[] memory harnessSelectors = new bytes4[](3);
        harnessSelectors[0] = PositionModuleHarnessFacet.createWithLeg.selector;
        harnessSelectors[1] = PositionModuleHarnessFacet.activate.selector;
        harnessSelectors[2] = PositionModuleHarnessFacet.deactivate.selector;
        cut[4] = _cut(address(harnessFacet), harnessSelectors);
        cut[5] = _cut(address(basketAdminFacet), StaticsSelectors.basketAdmin());

        StaticsProtocolInit init = new StaticsProtocolInit();
        PositionReceiver stakingToken = new PositionReceiver(address(0));
        diamond = new StaticsDiamond(
            address(this),
            cut,
            address(init),
            abi.encodeCall(StaticsProtocolInit.initialize, (makeAddr("guardian"), treasury, address(stakingToken), 0, 0)),
            address(0)
        );
        nft = IERC721(address(diamond));
        metadata = IERC721Metadata(address(diamond));
        positions = IStaticsPosition(address(diamond));
        positionFees = IStaticsPositionFees(address(diamond));
        moduleHarness = PositionModuleHarnessFacet(address(diamond));
        basketAdmin = BasketAdminFacet(address(diamond));
    }

    function test_ChargesExactCreationFeeAndPaysCanonicalTreasury() public {
        uint256 fee = 0.001 ether;
        positionFees.setPositionCreationFee(fee);
        vm.deal(alice, fee);

        vm.expectEmit(true, true, false, true, address(diamond));
        emit PositionNFTFacet.PositionCreationFeePaid(1, treasury, fee);
        vm.prank(alice);
        uint256 positionId = positions.createPosition{value: fee}(bob);

        assertEq(positionId, 1);
        assertEq(nft.ownerOf(positionId), bob);
        assertEq(treasury.balance, fee);
        assertEq(address(diamond).balance, 0);
    }

    function test_ModuleCreationForwardsExactFee() public {
        uint256 fee = 0.001 ether;
        positionFees.setPositionCreationFee(fee);
        vm.deal(alice, fee);

        vm.prank(alice);
        uint256 positionId = moduleHarness.createWithLeg{value: fee}(alice, DOLLAR, bytes32(uint256(1)));

        assertEq(nft.ownerOf(positionId), alice);
        assertEq(positions.activeLegCount(positionId), 1);
        assertEq(treasury.balance, fee);
        assertEq(address(diamond).balance, 0);
    }

    function test_RevertsOnIncorrectCreationFee() public {
        uint256 fee = 0.001 ether;
        positionFees.setPositionCreationFee(fee);
        vm.deal(alice, fee * 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.IncorrectPositionCreationFee.selector, fee, 0));
        positions.createPosition(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.IncorrectPositionCreationFee.selector, fee, fee + 1));
        positions.createPosition{value: fee + 1}(alice);

        assertEq(positions.nextPositionId(), 1);
    }

    function test_FailedTreasuryPaymentRollsBackCreation() public {
        uint256 fee = 0.001 ether;
        RejectNativeValue rejector = new RejectNativeValue();
        basketAdmin.setTreasury(address(rejector));
        positionFees.setPositionCreationFee(fee);
        vm.deal(alice, fee);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PositionNFTFacet.PositionCreationFeeTransferFailed.selector, address(rejector), fee)
        );
        positions.createPosition{value: fee}(alice);

        assertEq(positions.nextPositionId(), 1);
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_OwnerCanSetAnyCreationFeeAndZeroMakesCreationFree() public {
        vm.expectEmit(false, false, false, true, address(diamond));
        emit PositionNFTFacet.PositionCreationFeeSet(0, type(uint256).max);
        positionFees.setPositionCreationFee(type(uint256).max);
        assertEq(positionFees.positionCreationFee(), type(uint256).max);

        positionFees.setPositionCreationFee(0);
        vm.prank(alice);
        uint256 positionId = positions.createPosition(alice);
        assertEq(nft.ownerOf(positionId), alice);
    }

    function test_NonOwnerCannotSetCreationFee() public {
        vm.prank(alice);
        vm.expectRevert();
        positionFees.setPositionCreationFee(1);
    }

    function test_ExposesOpenZeppelinErc721AtTheDiamondAddress() public {
        vm.prank(alice);
        uint256 positionId = positions.createPosition(alice);

        assertEq(positionId, 1);
        assertEq(positions.nextPositionId(), 2);
        assertEq(nft.ownerOf(positionId), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(metadata.name(), "Statics Position");
        assertEq(metadata.symbol(), "etPOS");
        assertEq(metadata.tokenURI(positionId), "");
        assertEq(positions.positionKey(positionId), keccak256(abi.encode(address(diamond), positionId)));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC721).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsPosition).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsPositionFees).interfaceId));
    }

    function test_ApprovalTransferAndSafeTransferUseStandardSemantics() public {
        vm.prank(alice);
        uint256 positionId = positions.createPosition(alice);

        vm.prank(alice);
        nft.approve(bob, positionId);
        assertEq(nft.getApproved(positionId), bob);
        vm.prank(bob);
        nft.transferFrom(alice, carol, positionId);
        assertEq(nft.ownerOf(positionId), carol);
        assertEq(nft.getApproved(positionId), address(0));

        PositionHolder receiver = new PositionHolder();
        vm.prank(carol);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.safeTransferFrom(carol, address(receiver), positionId);
        assertEq(nft.ownerOf(positionId), address(receiver));
    }

    function test_SafeMintCallbackCannotCloseBeforeInitialLegAttaches() public {
        PositionReceiver receiver = new PositionReceiver(address(diamond));
        uint256 positionId = moduleHarness.createWithLeg(address(receiver), DOLLAR, bytes32(uint256(42)));
        bytes32 key = LibPosition.legKey(DOLLAR, bytes32(uint256(42)));

        assertEq(receiver.callbackRevert(), PositionNFTFacet.PositionInitializing.selector);
        assertEq(nft.ownerOf(positionId), address(receiver));
        assertFalse(positions.positionInitializing(positionId));
        assertEq(positions.activeLegCount(positionId), 1);
        assertTrue(positions.isPositionLegActive(positionId, key));

        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 1));
        receiver.close(positionId);
        vm.prank(address(receiver));
        moduleHarness.deactivate(positionId, DOLLAR, bytes32(uint256(42)));
        receiver.close(positionId);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, positionId));
        nft.ownerOf(positionId);
    }

    function test_MultipleModuleLegsRemainIndependentlyKeyed() public {
        vm.prank(alice);
        uint256 positionId = positions.createPosition(alice);
        bytes32 dollarKey = LibPosition.legKey(DOLLAR, bytes32(uint256(1)));
        bytes32 firstBasketKey = LibPosition.legKey(BASKET, bytes32(uint256(1)));
        bytes32 secondBasketKey = LibPosition.legKey(BASKET, bytes32(uint256(2)));

        vm.startPrank(alice);
        moduleHarness.activate(positionId, DOLLAR, bytes32(uint256(1)));
        moduleHarness.activate(positionId, BASKET, bytes32(uint256(1)));
        moduleHarness.activate(positionId, BASKET, bytes32(uint256(2)));
        vm.stopPrank();

        assertEq(positions.activeLegCount(positionId), 3);
        assertTrue(positions.isPositionLegActive(positionId, dollarKey));
        assertTrue(positions.isPositionLegActive(positionId, firstBasketKey));
        assertTrue(positions.isPositionLegActive(positionId, secondBasketKey));

        vm.prank(alice);
        moduleHarness.deactivate(positionId, BASKET, bytes32(uint256(1)));
        assertEq(positions.activeLegCount(positionId), 2);
        assertTrue(positions.isPositionLegActive(positionId, dollarKey));
        assertTrue(positions.isPositionLegActive(positionId, secondBasketKey));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 2));
        positions.closePosition(positionId);

        vm.startPrank(alice);
        moduleHarness.deactivate(positionId, DOLLAR, bytes32(uint256(1)));
        moduleHarness.deactivate(positionId, BASKET, bytes32(uint256(2)));
        positions.closePosition(positionId);
        vm.stopPrank();
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_ModuleCreationEntryPointRejectsDirectCaller() public {
        bytes32 key = LibPosition.legKey(DOLLAR, bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.OnlyDiamondSelf.selector, alice));
        IStaticsPositionModule(address(diamond)).createPositionForModule(alice, key);
    }

    function _cut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }
}
