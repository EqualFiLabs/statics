// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StaticsRestrictedBasketToken} from "../tokens/StaticsRestrictedBasketToken.sol";

interface PinnedCreateX {
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
}

/// @dev STOP-prefixed, immutable data containing only the restricted-token creation code.
contract StaticsCreationCodeStore {
    error CreationCodeTooLarge();

    constructor(bytes memory creationCode) {
        if (creationCode.length + 1 > 24_576) revert CreationCodeTooLarge();
        bytes memory data = bytes.concat(hex"00", creationCode);
        assembly ("memory-safe") { return(add(data, 32), mload(data)) }
    }
}

/// @notice Diamond-controlled CREATE3 deployment for prepared restricted basket tokens.
/// @dev Public pools share one separately deployed and verified hook, so this factory never deploys hooks.
contract StaticsBasketTokenFactory {
    address public constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 public constant CREATE_X_CODE_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    bytes32 public constant CREATE3_PROXY_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    uint256 public constant VERSION = 1;
    uint88 public constant PREPARED_SALT_BIT = uint88(1) << 87;

    enum SaltState {
        Unused,
        QueuedToken,
        Reserved,
        Consumed
    }

    struct Intent {
        address payer;
        address creator;
        bytes32 configurationHash;
        uint256 deadline;
        uint256 version;
    }

    struct Preparation {
        Intent intent;
        bytes32 tokenSalt;
        bool tokenDeployed;
    }

    address public immutable staticsDiamond;
    IPoolManager public immutable poolManager;
    address public immutable tokenCodeStore;
    bytes32 public immutable tokenCreationCodeHash;

    mapping(bytes32 salt => SaltState state) public saltState;
    mapping(bytes32 id => Preparation prepared) private preparations;
    bytes32[] private tokenQueue;
    uint256 private tokenHead;

    error OnlyDiamond();
    error InvalidDeploymentAuthority();
    error UnsupportedCreateX(bytes32 actualHash);
    error InvalidSalt(bytes32 salt);
    error SaltUnavailable(bytes32 salt);
    error InvalidPreparation();
    error PreparationExpired();
    error SaltQueueDepleted();
    error InvalidDeploymentOrder();
    error UnexpectedDeploymentAddress(address expected, address actual);

    event SaltQueued(bytes32 indexed salt, address predicted);
    event CreationPrepared(bytes32 indexed id, address indexed payer, address indexed creator, address token);
    event BasketTokenDeployed(bytes32 indexed id, uint256 indexed basketId, address token);

    constructor(address diamond, IPoolManager manager) {
        if (diamond.code.length == 0 || address(manager).code.length == 0) revert InvalidDeploymentAuthority();
        if (CREATE_X.codehash != CREATE_X_CODE_HASH) revert UnsupportedCreateX(CREATE_X.codehash);
        staticsDiamond = diamond;
        poolManager = manager;
        bytes memory tokenCode = type(StaticsRestrictedBasketToken).creationCode;
        tokenCreationCodeHash = keccak256(tokenCode);
        tokenCodeStore = address(new StaticsCreationCodeStore(tokenCode));
    }

    modifier onlyDiamond() {
        if (msg.sender != staticsDiamond) revert OnlyDiamond();
        _;
    }

    function saltFor(uint88 entropy) public view returns (bytes32) {
        return bytes32((uint256(uint160(address(this))) << 96) | (uint256(1) << 88) | uint256(entropy));
    }

    function preparedSaltFor(Intent memory intent, uint256 nonce) public view returns (bytes32) {
        uint88 entropy =
            uint88(uint256(keccak256(abi.encode(block.chainid, address(this), staticsDiamond, intent, nonce))));
        return saltFor(entropy | PREPARED_SALT_BIT);
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
        return saltState[rawSalt] == SaltState.Unused && deployed.code.length == 0 && proxy.code.length == 0;
    }

    function queueAvailability() external view returns (uint256 tokens) {
        return tokenQueue.length - tokenHead;
    }

    function queuedSalt(uint256 offset) external view returns (bytes32) {
        if (offset >= tokenQueue.length - tokenHead) revert SaltQueueDepleted();
        return tokenQueue[tokenHead + offset];
    }

    function enqueueSalts(bytes32[] calldata salts) external {
        if (salts.length == 0 || salts.length > 128) revert InvalidPreparation();
        for (uint256 i; i < salts.length; ++i) {
            bytes32 salt = salts[i];
            if (uint88(uint256(salt)) & PREPARED_SALT_BIT != 0) revert InvalidSalt(salt);
            _requireAvailable(salt);
            saltState[salt] = SaltState.QueuedToken;
            tokenQueue.push(salt);
            (address predicted,) = predict(salt);
            emit SaltQueued(salt, predicted);
        }
    }

    function preparationId(Intent memory intent, bytes32 tokenSalt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), staticsDiamond, intent, tokenSalt));
    }

    function preparation(bytes32 id) external view returns (Preparation memory) {
        return preparations[id];
    }

    function reserve(Intent calldata intent, uint256 tokenNonce) external onlyDiamond returns (bytes32 id) {
        _validateIntent(intent);
        bytes32 tokenSalt = preparedSaltFor(intent, tokenNonce);
        _requireAvailable(tokenSalt);
        saltState[tokenSalt] = SaltState.Reserved;
        return _record(intent, tokenSalt);
    }

    function reserveQueued(Intent calldata intent) external onlyDiamond returns (bytes32 id) {
        _validateIntent(intent);
        return _record(intent, _takeQueue());
    }

    function deployBasketToken(bytes32 id, string calldata name, string calldata symbol, uint256 basketId)
        external
        onlyDiamond
        returns (address token)
    {
        Preparation storage prepared = _livePreparation(id);
        if (prepared.tokenDeployed) revert InvalidDeploymentOrder();
        prepared.tokenDeployed = true;
        bytes memory args = abi.encode(name, symbol, staticsDiamond, basketId, poolManager);
        token = _deploy(prepared.tokenSalt, tokenCodeStore, args);
        emit BasketTokenDeployed(id, basketId, token);
    }

    function _record(Intent memory intent, bytes32 tokenSalt) private returns (bytes32 id) {
        id = preparationId(intent, tokenSalt);
        Preparation storage prepared = preparations[id];
        prepared.intent = intent;
        prepared.tokenSalt = tokenSalt;
        (address token,) = predict(tokenSalt);
        emit CreationPrepared(id, intent.payer, intent.creator, token);
    }

    function _validateIntent(Intent memory intent) private view {
        if (
            intent.payer == address(0) || intent.creator == address(0) || intent.configurationHash == bytes32(0)
                || intent.version != VERSION
        ) revert InvalidPreparation();
        if (block.timestamp > intent.deadline) revert PreparationExpired();
    }

    function _livePreparation(bytes32 id) private view returns (Preparation storage prepared) {
        prepared = preparations[id];
        if (prepared.intent.payer == address(0) || id != preparationId(prepared.intent, prepared.tokenSalt)) {
            revert InvalidPreparation();
        }
        if (block.timestamp > prepared.intent.deadline) revert PreparationExpired();
    }

    function _takeQueue() private returns (bytes32 salt) {
        if (tokenHead == tokenQueue.length) revert SaltQueueDepleted();
        salt = tokenQueue[tokenHead++];
        saltState[salt] = SaltState.Reserved;
    }

    function _validateSalt(bytes32 salt) private view {
        if (address(bytes20(salt)) != address(this) || uint8(salt[20]) != 1) revert InvalidSalt(salt);
    }

    function _requireAvailable(bytes32 salt) private view {
        if (!saltAvailable(salt)) revert SaltUnavailable(salt);
    }

    function _deploy(bytes32 salt, address store, bytes memory args) private returns (address deployed) {
        if (CREATE_X.codehash != CREATE_X_CODE_HASH) revert UnsupportedCreateX(CREATE_X.codehash);
        if (saltState[salt] != SaltState.Reserved) revert SaltUnavailable(salt);
        (address expected, address proxy) = predict(salt);
        if (expected.code.length != 0 || proxy.code.length != 0) revert SaltUnavailable(salt);
        saltState[salt] = SaltState.Consumed;
        bytes memory code = new bytes(store.code.length - 1);
        assembly ("memory-safe") { extcodecopy(store, add(code, 32), 1, mload(code)) }
        deployed = PinnedCreateX(CREATE_X).deployCreate3(salt, bytes.concat(code, args));
        if (deployed != expected) revert UnexpectedDeploymentAddress(expected, deployed);
    }
}
