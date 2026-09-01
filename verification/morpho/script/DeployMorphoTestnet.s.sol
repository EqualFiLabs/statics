// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {Morpho} from "morpho-blue/Morpho.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {AdaptiveCurveIrm} from "morpho-blue-irm/AdaptiveCurveIrm.sol";

struct MorphoTestnetDeployment {
    address morpho;
    address adaptiveCurveIrm;
    bool deployedMorpho;
    bool deployedAdaptiveCurveIrm;
}

/// @notice Deploys or resumes the shared Robinhood testnet Morpho Blue infrastructure.
/// @dev Uses fixed CREATE2 salts so an interrupted initial run cannot create a second singleton.
contract DeployMorphoTestnet is Script {
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant CREATE2_DEPLOYER_RUNTIME_CODE_HASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    bytes32 public constant MORPHO_SALT = keccak256("STATICS_ROBINHOOD_TESTNET_MORPHO_BLUE_V1");
    bytes32 public constant ADAPTIVE_CURVE_IRM_SALT = keccak256("STATICS_ROBINHOOD_TESTNET_ADAPTIVE_CURVE_IRM_V1");

    uint256 public constant LLTV_ZERO = 0;
    uint256 public constant LLTV_38_5 = 0.385e18;
    uint256 public constant LLTV_62_5 = 0.625e18;
    uint256 public constant LLTV_77 = 0.77e18;
    uint256 public constant LLTV_86 = 0.86e18;
    uint256 public constant LLTV_91_5 = 0.915e18;
    uint256 public constant LLTV_94_5 = 0.945e18;
    uint256 public constant LLTV_96_5 = 0.965e18;
    uint256 public constant LLTV_98 = 0.98e18;

    error UnsupportedChain(uint256 chainId);
    error InvalidCreate2Deployer(bytes32 expected, bytes32 actual);
    error ZeroOwner();
    error Create2DeploymentFailed(bytes32 salt);
    error MissingDeployment(address expected);
    error UnexpectedOwner(address expected, address actual);
    error UnexpectedFeeRecipient(address expected, address actual);
    error UnexpectedMorphoBinding(address expected, address actual);
    error ConfigurationFailed();

    function run() external returns (MorphoTestnetDeployment memory deployment) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
        bytes32 factoryCodeHash = CREATE2_DEPLOYER.codehash;
        if (factoryCodeHash != CREATE2_DEPLOYER_RUNTIME_CODE_HASH) {
            revert InvalidCreate2Deployer(CREATE2_DEPLOYER_RUNTIME_CODE_HASH, factoryCodeHash);
        }

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        if (owner == address(0)) revert ZeroOwner();

        vm.startBroadcast(privateKey);
        deployment = deployAndConfigure(owner, CREATE2_DEPLOYER);
        vm.stopBroadcast();

        writeDeploymentArtifact(vm.envString("MORPHO_TESTNET_ARTIFACT"), owner, deployment);
        console2.log("Morpho", deployment.morpho);
        console2.log("AdaptiveCurveIrm", deployment.adaptiveCurveIrm);
    }

    function deployAndConfigure(address owner, address create2Deployer)
        public
        returns (MorphoTestnetDeployment memory deployment)
    {
        if (owner == address(0)) revert ZeroOwner();

        bytes memory morphoInitCode = abi.encodePacked(type(Morpho).creationCode, abi.encode(owner));
        deployment.morpho = computeCreate2Address(create2Deployer, MORPHO_SALT, keccak256(morphoInitCode));
        if (deployment.morpho.code.length == 0) {
            _deployCreate2(create2Deployer, MORPHO_SALT, morphoInitCode);
            deployment.deployedMorpho = true;
        }
        if (deployment.morpho.code.length == 0) revert MissingDeployment(deployment.morpho);

        address actualOwner = IMorpho(deployment.morpho).owner();
        if (actualOwner != owner) revert UnexpectedOwner(owner, actualOwner);

        bytes memory irmInitCode = abi.encodePacked(type(AdaptiveCurveIrm).creationCode, abi.encode(deployment.morpho));
        deployment.adaptiveCurveIrm =
            computeCreate2Address(create2Deployer, ADAPTIVE_CURVE_IRM_SALT, keccak256(irmInitCode));
        if (deployment.adaptiveCurveIrm.code.length == 0) {
            _deployCreate2(create2Deployer, ADAPTIVE_CURVE_IRM_SALT, irmInitCode);
            deployment.deployedAdaptiveCurveIrm = true;
        }
        if (deployment.adaptiveCurveIrm.code.length == 0) {
            revert MissingDeployment(deployment.adaptiveCurveIrm);
        }

        address boundMorpho = AdaptiveCurveIrm(deployment.adaptiveCurveIrm).MORPHO();
        if (boundMorpho != deployment.morpho) {
            revert UnexpectedMorphoBinding(deployment.morpho, boundMorpho);
        }

        IMorpho morpho = IMorpho(deployment.morpho);
        if (!morpho.isIrmEnabled(deployment.adaptiveCurveIrm)) morpho.enableIrm(deployment.adaptiveCurveIrm);
        if (!morpho.isIrmEnabled(address(0))) morpho.enableIrm(address(0));

        uint256[9] memory lltvs = enabledLltvs();
        for (uint256 i; i < lltvs.length; ++i) {
            if (!morpho.isLltvEnabled(lltvs[i])) morpho.enableLltv(lltvs[i]);
        }

        _validateConfiguration(owner, deployment);
    }

    function computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        public
        pure
        returns (address predicted)
    {
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function enabledLltvs() public pure returns (uint256[9] memory lltvs) {
        lltvs = [LLTV_ZERO, LLTV_38_5, LLTV_62_5, LLTV_77, LLTV_86, LLTV_91_5, LLTV_94_5, LLTV_96_5, LLTV_98];
    }

    function writeDeploymentArtifact(string memory path, address owner, MorphoTestnetDeployment memory deployment)
        public
    {
        string memory objectKey = "morpho-testnet";
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "deployer", owner);
        vm.serializeAddress(objectKey, "owner", owner);
        vm.serializeAddress(objectKey, "create2Deployer", CREATE2_DEPLOYER);
        vm.serializeBytes32(objectKey, "create2DeployerRuntimeCodeHash", CREATE2_DEPLOYER_RUNTIME_CODE_HASH);
        vm.serializeBytes32(objectKey, "morphoSalt", MORPHO_SALT);
        vm.serializeBytes32(objectKey, "adaptiveCurveIrmSalt", ADAPTIVE_CURVE_IRM_SALT);
        vm.serializeAddress(objectKey, "morpho", deployment.morpho);
        vm.serializeBytes32(objectKey, "morphoRuntimeCodeHash", deployment.morpho.codehash);
        vm.serializeAddress(objectKey, "adaptiveCurveIrm", deployment.adaptiveCurveIrm);
        vm.serializeBytes32(objectKey, "adaptiveCurveIrmRuntimeCodeHash", deployment.adaptiveCurveIrm.codehash);
        vm.serializeAddress(objectKey, "feeRecipient", IMorpho(deployment.morpho).feeRecipient());
        vm.serializeBool(objectKey, "adaptiveCurveIrmEnabled", true);
        vm.serializeBool(objectKey, "zeroIrmEnabled", true);
        uint256[9] memory lltvs = enabledLltvs();
        uint256[] memory serializedLltvs = new uint256[](lltvs.length);
        for (uint256 i; i < lltvs.length; ++i) {
            serializedLltvs[i] = lltvs[i];
        }
        string memory json = vm.serializeUint(objectKey, "enabledLltvs", serializedLltvs);
        vm.writeJson(json, path);
    }

    function _deployCreate2(address create2Deployer, bytes32 salt, bytes memory initCode) private {
        (bool success,) = create2Deployer.call(abi.encodePacked(salt, initCode));
        if (!success) revert Create2DeploymentFailed(salt);
    }

    function _validateConfiguration(address owner, MorphoTestnetDeployment memory deployment) private view {
        IMorpho morpho = IMorpho(deployment.morpho);
        address actualOwner = morpho.owner();
        if (actualOwner != owner) revert UnexpectedOwner(owner, actualOwner);
        address feeRecipient = morpho.feeRecipient();
        if (feeRecipient != address(0)) revert UnexpectedFeeRecipient(address(0), feeRecipient);
        if (!morpho.isIrmEnabled(deployment.adaptiveCurveIrm) || !morpho.isIrmEnabled(address(0))) {
            revert ConfigurationFailed();
        }
        uint256[9] memory lltvs = enabledLltvs();
        for (uint256 i; i < lltvs.length; ++i) {
            if (!morpho.isLltvEnabled(lltvs[i])) revert ConfigurationFailed();
        }
    }
}
