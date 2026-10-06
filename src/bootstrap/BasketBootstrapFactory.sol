// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BasketBootstrapCampaign} from "./BasketBootstrapCampaign.sol";

contract CampaignCreationCodeStore {
    constructor(bytes memory approvedCode) {
        bytes memory runtime = bytes.concat(hex"00", approvedCode);
        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
    }
}

/// @notice Isolated, fixed-code campaigns. Predicted payer identity binds complete campaign terms.
contract BasketBootstrapFactory {
    address public immutable diamond;
    address public immutable codeStore0;
    address public immutable codeStore1;
    bytes32 public immutable creationCodeHash;
    mapping(address campaign => bool deployed) public isCampaign;
    error CampaignDeploymentFailed();
    event CampaignCreated(address indexed campaign, address indexed creator, bytes32 indexed termsHash);

    constructor(address protocol) {
        if (protocol.code.length == 0) revert CampaignDeploymentFailed();
        diamond = protocol;
        bytes memory code = type(BasketBootstrapCampaign).creationCode;
        creationCodeHash = keccak256(code);
        uint256 first = code.length > 24575 ? 24575 : code.length;
        codeStore0 = address(new CampaignCreationCodeStore(_slice(code, 0, first)));
        codeStore1 = address(new CampaignCreationCodeStore(_slice(code, first, code.length - first)));
    }

    function predict(BasketBootstrapCampaign.Terms calldata terms, bytes32 salt) external view returns (address) {
        bytes32 initHash = keccak256(bytes.concat(_code(), abi.encode(diamond, terms)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function create(BasketBootstrapCampaign.Terms calldata terms, bytes32 salt) external returns (address campaign) {
        bytes memory initCode = bytes.concat(_code(), abi.encode(diamond, terms));
        assembly ("memory-safe") { campaign := create2(0, add(initCode, 32), mload(initCode), salt) }
        if (campaign == address(0)) revert CampaignDeploymentFailed();
        isCampaign[campaign] = true;
        emit CampaignCreated(campaign, terms.creator, BasketBootstrapCampaign(campaign).termsHash());
    }

    function _code() private view returns (bytes memory code) {
        address first = codeStore0;
        address second = codeStore1;
        uint256 length = first.code.length - 1;
        code = new bytes(length + second.code.length - 1);
        assembly ("memory-safe") {
            extcodecopy(first, add(code, 32), 1, length)
            extcodecopy(second, add(add(code, 32), length), 1, sub(extcodesize(second), 1))
        }
    }

    function _slice(bytes memory code, uint256 offset, uint256 length) private pure returns (bytes memory result) {
        result = new bytes(length);
        assembly ("memory-safe") { mcopy(add(result, 32), add(add(code, 32), offset), length) }
    }
}
