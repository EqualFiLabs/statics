// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {Test} from "forge-std/Test.sol";
import {ExternalModulesTest} from "./ExternalModules.t.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ExternalModuleHandler is Test {
    IStaticsExternalModules public core;
    bytes32 public constant TYPE = keccak256("invariant.external");
    address public admin;
    address public other = address(0xA11CE);
    uint256[3] public positions;
    bool[8][3][2] public active;
    bool[2] public enabled;
    uint256[3] public transferNonces;
    uint256 public transferCount;
    uint256 public attachments;
    uint256 public detachments;

    constructor(address core_, address admin_, uint256[3] memory ids) {
        core = IStaticsExternalModules(core_);
        admin = admin_;
        positions = ids;
    }

    function admission(uint256 who, bool enable) public {
        who %= 2;
        vm.prank(admin);
        core.setExternalModule(who == 0 ? address(this) : other, TYPE, enable);
        enabled[who] = enable;
    }

    function attach(uint256 who, uint256 position, uint256 key) external {
        who %= 2;
        position %= 3;
        key %= 8;
        if (!enabled[who] || active[who][position][key]) return;
        vm.prank(who == 0 ? address(this) : other);
        core.attachExternalAccountLeg(positions[position], TYPE, bytes32(key));
        active[who][position][key] = true;
        ++attachments;
    }

    function detach(uint256 who, uint256 position, uint256 key) external {
        who %= 2;
        position %= 3;
        key %= 8;
        if (!active[who][position][key]) return;
        vm.prank(who == 0 ? address(this) : other);
        core.detachExternalAccountLeg(positions[position], TYPE, bytes32(key));
        active[who][position][key] = false;
        ++detachments;
    }

    function transfer(uint256 position, bool back) external {
        position %= 3;
        IERC721 nft = IERC721(address(core));
        address from = nft.ownerOf(positions[position]);
        address to = back ? address(0xB0B) : address(0xCA401);
        vm.prank(from);
        nft.transferFrom(from, to, positions[position]);
        if (from != to) {
            ++transferCount;
            ++transferNonces[position];
        }
    }
}

contract ExternalModulesInvariantTest is ExternalModulesTest {
    ExternalModuleHandler internal handler;

    function setUp() public override {
        super.setUp();
        uint256[3] memory ids = [_createPosition(alice), _createPosition(bob), _createPosition(alice)];
        handler = new ExternalModuleHandler(address(diamond), address(this), ids);
        handler.admission(0, true);
        handler.admission(1, true);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.admission.selector;
        selectors[1] = handler.attach.selector;
        selectors[2] = handler.detach.selector;
        selectors[3] = handler.transfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantExternalLegsMatchModelAndStructuralCount() public view {
        uint256 total;
        for (uint256 p; p < 3; ++p) {
            uint256 count;
            for (uint256 who; who < 2; ++who) {
                for (uint256 key; key < 8; ++key) {
                    if (handler.active(who, p, key)) ++count;
                }
            }
            uint256 id = handler.positions(p);
            assertEq(externalCore.externalLegCount(id), count);
            assertEq(IModularPositionNFT(address(diamond)).positionState(id).activeLegCount, count);
            (IStaticsExternalModules.ExternalLeg[] memory legs,) = externalCore.externalLegs(id, 0, 100);
            assertEq(legs.length, count);
            for (uint256 i; i < legs.length; ++i) {
                uint256 who = legs[i].authority == address(handler) ? 0 : 1;
                assertTrue(handler.active(who, p, uint256(legs[i].localId)));
                assertTrue(IModularPositionNFT(address(diamond)).isLegActive(id, legs[i].legKey));
                for (uint256 j; j < i; ++j) {
                    assertTrue(legs[i].legKey != legs[j].legKey);
                }
            }
            total += count;
        }
        assertEq(total, handler.attachments() - handler.detachments());
    }

    function invariantTransferHeadAndPerNFTNoncesMatchOwnerChanges() public view {
        assertEq(externalCore.transferHead(), handler.transferCount());
        for (uint256 p; p < 3; ++p) {
            assertEq(
                externalCore.transferState(address(diamond), handler.positions(p)).nonce, handler.transferNonces(p)
            );
        }
    }
}
