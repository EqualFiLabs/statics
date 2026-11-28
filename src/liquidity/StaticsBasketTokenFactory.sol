// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";

interface PinnedCreateX {
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
}

/// @notice Diamond-controlled CREATE3 deployment for prepared basket tokens.
/// @dev Basket pools use the separately deployed Basket hook, so this factory deploys only basket tokens.
contract StaticsBasketTokenFactory {
    address public constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 public constant CREATE_X_CODE_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    bytes32 public constant CREATE3_PROXY_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    uint88 public constant PREPARED_SALT_BIT = uint88(1) << 87;

    address public immutable staticsDiamond;
    IPoolManager public immutable poolManager;
    bytes32 public immutable tokenCreationCodeHash;

    uint256 public nextAutomaticNonce;

    error OnlyDiamond();
    error InvalidDeploymentAuthority();
    error UnsupportedCreateX(bytes32 actualHash);
    error InvalidSalt(bytes32 salt);
    error SaltUnavailable(bytes32 salt);
    error UnexpectedDeploymentAddress(address expected, address actual);

    event BasketTokenDeployed(bytes32 indexed tokenSalt, uint256 indexed basketId, address token);

    constructor(address diamond, IPoolManager manager) {
        if (diamond.code.length == 0 || address(manager).code.length == 0) revert InvalidDeploymentAuthority();
        if (CREATE_X.codehash != CREATE_X_CODE_HASH) revert UnsupportedCreateX(CREATE_X.codehash);
        staticsDiamond = diamond;
        poolManager = manager;
        bytes memory tokenCode = type(StaticsBasketToken).creationCode;
        tokenCreationCodeHash = keccak256(tokenCode);
    }

    modifier onlyDiamond() {
        if (msg.sender != staticsDiamond) revert OnlyDiamond();
        _;
    }

    function saltFor(uint88 entropy) public view returns (bytes32) {
        return bytes32((uint256(uint160(address(this))) << 96) | (uint256(1) << 88) | uint256(entropy));
    }

    function preparedSaltFor(address creator, bytes32 configurationHash, uint256 nonce) public view returns (bytes32) {
        uint88 entropy = uint88(
            uint256(
                keccak256(abi.encode(block.chainid, address(this), staticsDiamond, creator, configurationHash, nonce))
            )
        );
        return saltFor(entropy | PREPARED_SALT_BIT);
    }

    function automaticSaltFor(uint256 nonce) public view returns (bytes32) {
        uint88 entropy =
            uint88(uint256(keccak256(abi.encode("STATICS_AUTOMATIC_BASKET", block.chainid, address(this), nonce))));
        return saltFor(entropy & (PREPARED_SALT_BIT - 1));
    }

    function effectiveSalt(bytes32 rawSalt) public view returns (bytes32) {
        _validateSalt(rawSalt);
        return keccak256(abi.encode(address(this), block.chainid, rawSalt));
    }

    function predict(bytes32 rawSalt) public view returns (address deployed, address proxy) {
        proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", CREATE_X, effectiveSalt(rawSalt), CREATE3_PROXY_HASH))))
        );
        deployed = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    function saltAvailable(bytes32 rawSalt) public view returns (bool) {
        (address deployed, address proxy) = predict(rawSalt);
        return deployed.code.length == 0 && proxy.code.length == 0;
    }

    /// @notice Deploy a prepared token immediately; its launch terms are retained by the Diamond.
    function deployBasketToken(bytes32 tokenSalt, string calldata name, string calldata symbol, uint256 basketId)
        external
        onlyDiamond
        returns (address token)
    {
        return _deployToken(tokenSalt, name, symbol, basketId);
    }

    function deployNextBasketToken(string calldata name, string calldata symbol, uint256 basketId)
        external
        onlyDiamond
        returns (address token)
    {
        return _deployToken(automaticSaltFor(nextAutomaticNonce++), name, symbol, basketId);
    }

    function _deployToken(bytes32 tokenSalt, string memory name, string memory symbol, uint256 basketId)
        private
        returns (address token)
    {
        token = _deploy(tokenSalt, abi.encode(name, symbol, staticsDiamond, basketId, poolManager));
        emit BasketTokenDeployed(tokenSalt, basketId, token);
    }

    function _validateSalt(bytes32 salt) private view {
        if (address(bytes20(salt)) != address(this) || uint8(salt[20]) != 1) revert InvalidSalt(salt);
    }

    function _deploy(bytes32 salt, bytes memory args) private returns (address deployed) {
        if (CREATE_X.codehash != CREATE_X_CODE_HASH) revert UnsupportedCreateX(CREATE_X.codehash);
        (address expected, address proxy) = predict(salt);
        if (expected.code.length != 0 || proxy.code.length != 0) revert SaltUnavailable(salt);
        bytes memory code = type(StaticsBasketToken).creationCode;
        deployed = PinnedCreateX(CREATE_X).deployCreate3(salt, bytes.concat(code, args));
        if (deployed != expected) revert UnexpectedDeploymentAddress(expected, deployed);
    }
}
