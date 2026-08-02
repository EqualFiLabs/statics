// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";

import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {PositionCreationFeeUpgrade, UpgradePositionCreationFee} from "../../script/UpgradePositionCreationFee.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";

contract PositionCreationFeeUpgradeTest is Test {
    uint256 internal constant POSITION_FEE = 0.001 ether;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    StaticsDollarStackDeployment internal deployment;
    StaticsTimelock internal timelock;
    UpgradePositionCreationFee internal ceremony;

    function setUp() public {
        ceremony = new UpgradePositionCreationFee();
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: address(ceremony),
            guardian: makeAddr("guardian"),
            treasury: treasury,
            stakingToken: address(deployer),
            creationFeeAmount: 0,
            positionCreationFeeAmount: 0
        });
        (deployment, timelock) = deployer.deploy(config);
        _removeFeeSurface();
    }

    function testTimelockBatchInstallsAndConfiguresPositionCreationFee() public {
        PositionCreationFeeUpgrade memory upgrade = ceremony.deployFacets(POSITION_FEE);
        bytes32 salt = keccak256("install position creation fee");

        bytes32 operationId = ceremony.schedule(deployment.diamond, upgrade, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(deployment.diamond, upgrade, salt);

        assertEq(IStaticsPositionFees(deployment.diamond).positionCreationFee(), POSITION_FEE);
        assertTrue(IERC165(deployment.diamond).supportsInterface(type(IStaticsPositionFees).interfaceId));
        assertEq(
            IDiamondLoupe(deployment.diamond).facetAddress(IStaticsPositionFees.positionCreationFee.selector),
            upgrade.positionFacet
        );

        uint256 treasuryBefore = treasury.balance;
        vm.deal(alice, POSITION_FEE);
        vm.prank(alice);
        uint256 positionId = IStaticsPosition(deployment.diamond).createPosition{value: POSITION_FEE}(alice);
        assertEq(IERC721(deployment.diamond).ownerOf(positionId), alice);
        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
    }

    function _removeFeeSurface() private {
        bytes4[] memory feeSelectors = new bytes4[](2);
        feeSelectors[0] = IStaticsPositionFees.setPositionCreationFee.selector;
        feeSelectors[1] = IStaticsPositionFees.positionCreationFee.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: feeSelectors
        });
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = type(IStaticsPositionFees).interfaceId;
        bool[] memory supported = new bool[](1);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), bytes("")));
        payloads[1] = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported));
        address[] memory targets = new address[](2);
        targets[0] = deployment.diamond;
        targets[1] = deployment.diamond;
        uint256[] memory values = new uint256[](2);
        bytes32 salt = keccak256("remove current position fee surface");
        uint256 delay = timelock.getMinDelay();
        vm.prank(address(ceremony));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertEq(IDiamondLoupe(deployment.diamond).facetAddress(feeSelectors[0]), address(0));
        assertFalse(IERC165(deployment.diamond).supportsInterface(type(IStaticsPositionFees).interfaceId));
    }
}
