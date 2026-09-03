// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Morpho} from "morpho-blue/Morpho.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {AdaptiveCurveIrm} from "morpho-blue-irm/AdaptiveCurveIrm.sol";
import {DeployMorphoTestnet, MorphoTestnetDeployment} from "../script/DeployMorphoTestnet.s.sol";

contract Create2FactoryHarness {
    fallback() external payable {
        assembly {
            calldatacopy(0, 32, sub(calldatasize(), 32))
            let deployed := create2(callvalue(), 0, sub(calldatasize(), 32), calldataload(0))
            if iszero(deployed) { revert(0, 0) }
            mstore(0, deployed)
            return(12, 20)
        }
    }
}

contract DeployMorphoTestnetTest is Test {
    DeployMorphoTestnet private deployer;
    Create2FactoryHarness private factory;

    function setUp() public {
        deployer = new DeployMorphoTestnet();
        factory = new Create2FactoryHarness();
    }

    function testDeploysAndConfiguresReusableInfrastructure() public {
        MorphoTestnetDeployment memory deployment = deployer.deployAndConfigure(address(deployer), address(factory));
        IMorpho morpho = IMorpho(deployment.morpho);

        assertTrue(deployment.deployedMorpho);
        assertTrue(deployment.deployedAdaptiveCurveIrm);
        assertEq(morpho.owner(), address(deployer));
        assertEq(morpho.feeRecipient(), address(0));
        assertEq(AdaptiveCurveIrm(deployment.adaptiveCurveIrm).MORPHO(), deployment.morpho);
        assertTrue(morpho.isIrmEnabled(deployment.adaptiveCurveIrm));
        assertTrue(morpho.isIrmEnabled(address(0)));

        uint256[9] memory lltvs = deployer.enabledLltvs();
        for (uint256 i; i < lltvs.length; ++i) {
            assertTrue(morpho.isLltvEnabled(lltvs[i]));
        }
    }

    function testReusesExistingDeploymentWithoutCreatingContracts() public {
        MorphoTestnetDeployment memory first = deployer.deployAndConfigure(address(deployer), address(factory));
        MorphoTestnetDeployment memory second = deployer.deployAndConfigure(address(deployer), address(factory));

        assertEq(second.morpho, first.morpho);
        assertEq(second.adaptiveCurveIrm, first.adaptiveCurveIrm);
        assertFalse(second.deployedMorpho);
        assertFalse(second.deployedAdaptiveCurveIrm);
    }

    function testResumesAfterOnlyMorphoWasDeployed() public {
        bytes memory morphoInitCode = abi.encodePacked(type(Morpho).creationCode, abi.encode(address(deployer)));
        (bool success,) = address(factory).call(abi.encodePacked(deployer.MORPHO_SALT(), morphoInitCode));
        assertTrue(success);

        MorphoTestnetDeployment memory deployment = deployer.deployAndConfigure(address(deployer), address(factory));

        assertFalse(deployment.deployedMorpho);
        assertTrue(deployment.deployedAdaptiveCurveIrm);
        assertEq(IMorpho(deployment.morpho).owner(), address(deployer));
        assertEq(AdaptiveCurveIrm(deployment.adaptiveCurveIrm).MORPHO(), deployment.morpho);
    }

    function testPredictionMatchesCreatedAddresses() public {
        MorphoTestnetDeployment memory deployment = deployer.deployAndConfigure(address(deployer), address(factory));

        bytes memory morphoInitCode = abi.encodePacked(type(Morpho).creationCode, abi.encode(address(deployer)));
        address predictedMorpho =
            deployer.computeCreate2Address(address(factory), deployer.MORPHO_SALT(), keccak256(morphoInitCode));
        bytes memory irmInitCode = abi.encodePacked(type(AdaptiveCurveIrm).creationCode, abi.encode(predictedMorpho));
        address predictedIrm = deployer.computeCreate2Address(
            address(factory), deployer.ADAPTIVE_CURVE_IRM_SALT(), keccak256(irmInitCode)
        );

        assertEq(deployment.morpho, predictedMorpho);
        assertEq(deployment.adaptiveCurveIrm, predictedIrm);
    }

    function testRejectsZeroOwner() public {
        vm.expectRevert(DeployMorphoTestnet.ZeroOwner.selector);
        deployer.deployAndConfigure(address(0), address(factory));
    }

    function testRejectsFactoryThatDoesNotDeploy() public {
        address emptyFactory = makeAddr("emptyFactory");
        bytes memory morphoInitCode = abi.encodePacked(type(Morpho).creationCode, abi.encode(address(deployer)));
        address expected =
            deployer.computeCreate2Address(emptyFactory, deployer.MORPHO_SALT(), keccak256(morphoInitCode));
        vm.expectRevert(abi.encodeWithSelector(DeployMorphoTestnet.MissingDeployment.selector, expected));
        deployer.deployAndConfigure(address(deployer), emptyFactory);
    }

    function testRunRejectsWrongChainBeforeReadingSecrets() public {
        vm.expectRevert(abi.encodeWithSelector(DeployMorphoTestnet.UnsupportedChain.selector, block.chainid));
        deployer.run();
    }
}
