// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Test} from "forge-std/Test.sol";
import {IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";

contract GenesisProtocolMock is IStaticsGenesisProtocol {
    uint256 public lastGenesisId;
    address public lastPreviousOwner;
    address public lastNewOwner;
    mapping(uint256 genesisId => uint8 tier) public tiers;

    error LinkedGenesis(uint256 genesisId);

    function onGenesisTransfer(uint256 genesisId, address previousOwner, address newOwner) external {
        if (tiers[genesisId] == type(uint8).max) revert LinkedGenesis(genesisId);
        lastGenesisId = genesisId;
        lastPreviousOwner = previousOwner;
        lastNewOwner = newOwner;
        delete tiers[genesisId];
    }

    function genesisTier(uint256 genesisId) external view returns (uint8) {
        return tiers[genesisId];
    }

    function setTier(uint256 genesisId, uint8 tier) external {
        tiers[genesisId] = tier;
    }

    function refresh(StaticsGenesis genesis, uint256 genesisId) external {
        genesis.refreshMetadata(genesisId);
    }
}

contract StaticsGenesisTest is Test {
    address internal treasury = makeAddr("treasury");
    address internal receiver = makeAddr("receiver");
    StaticsGenesis internal genesis;
    GenesisProtocolMock internal protocol;

    function setUp() public {
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(treasury, address(this), renderer);
        protocol = new GenesisProtocolMock();
    }

    function test_ConstructorMintsFixedCollectionAcrossOneBasedIds() public view {
        assertEq(genesis.COLLECTION_SIZE(), 5_555);
        assertEq(genesis.ownerOf(1), treasury);
        assertEq(genesis.ownerOf(5_555), treasury);
        assertEq(genesis.balanceOf(treasury), 5_555);
    }

    function test_TransfersStayDisabledUntilOneTimeProtocolBinding() public {
        vm.prank(treasury);
        vm.expectRevert(StaticsGenesis.TransfersDisabled.selector);
        genesis.transferFrom(treasury, receiver, 1);

        genesis.bindProtocol(address(protocol));
        vm.expectRevert(StaticsGenesis.ProtocolAlreadyBound.selector);
        genesis.bindProtocol(address(protocol));

        vm.prank(treasury);
        genesis.transferFrom(treasury, receiver, 1);
        assertEq(genesis.ownerOf(1), receiver);
        assertEq(protocol.lastGenesisId(), 1);
        assertEq(protocol.lastPreviousOwner(), treasury);
        assertEq(protocol.lastNewOwner(), receiver);
    }

    function test_ProtocolCanBlockLinkedTransferAndResetTierOnAllowedTransfer() public {
        genesis.bindProtocol(address(protocol));
        protocol.setTier(2, type(uint8).max);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(GenesisProtocolMock.LinkedGenesis.selector, 2));
        genesis.transferFrom(treasury, receiver, 2);

        protocol.setTier(2, 3);
        vm.prank(treasury);
        genesis.transferFrom(treasury, receiver, 2);
        assertEq(protocol.tiers(2), 0);
    }

    function test_SelfTransferDoesNotInvokeResetHook() public {
        genesis.bindProtocol(address(protocol));
        protocol.setTier(3, 4);
        vm.prank(treasury);
        genesis.transferFrom(treasury, treasury, 3);
        assertEq(protocol.tiers(3), 4);
    }

    function test_OnlyBoundProtocolRefreshesMetadata() public {
        genesis.bindProtocol(address(protocol));
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.UnauthorizedProtocol.selector, address(this)));
        genesis.refreshMetadata(1);

        vm.expectEmit(false, false, false, true, address(genesis));
        emit IERC4906.MetadataUpdate(1);
        protocol.refresh(genesis, 1);
    }
}
