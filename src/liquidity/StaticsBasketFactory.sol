// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketHook} from "./StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../tokens/StaticsRestrictedBasketToken.sol";

interface PinnedCreateX {
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
}

/// @dev STOP-prefixed, immutable data. Only the factory's compiled creation code is installed here.
contract StaticsCreationCodeStore {
    error CreationCodeTooLarge();

    constructor(bytes memory creationCode) {
        if (creationCode.length + 1 > 24_576) revert CreationCodeTooLarge();
        bytes memory data = bytes.concat(hex"00", creationCode);
        assembly ("memory-safe") { return(add(data, 32), mload(data)) }
    }
}

/// @notice Diamond-controlled, typed CREATE3 deployment with reserved identities and a premined queue.
/// @dev CreateX v1.0.0, upstream cbac803268835138f86a69bfe01fcf05a50e0447.
contract StaticsBasketFactory {
    address public constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    bytes32 public constant CREATE_X_CODE_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    bytes32 public constant CREATE3_PROXY_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;
    uint160 public constant HOOK_PERMISSION_MASK = 0x1fec;
    uint160 private constant ALL_HOOK_BITS = (1 << 14) - 1;
    uint256 public constant VERSION = 1;
    uint256 public constant MAX_HOOKS = 16;

    enum SaltState {
        Unused,
        QueuedToken,
        QueuedHook,
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
        bytes32[] hookSalts;
        bool tokenDeployed;
        uint256 hookCursor;
    }

    // forge-lint: disable-start(screaming-snake-case-immutable)
    address public immutable staticsDiamond;
    IPoolManager public immutable poolManager;
    IStaticsSwapFeeHook public immutable feePolicy;
    address public immutable tokenCodeStore;
    address public immutable hookCodeStore;
    bytes32 public immutable tokenCreationCodeHash;
    bytes32 public immutable hookCreationCodeHash;
    // forge-lint: disable-end(screaming-snake-case-immutable)

    mapping(bytes32 salt => SaltState state) public saltState;
    mapping(bytes32 id => Preparation prepared) private preparations;
    bytes32[] private tokenQueue;
    bytes32[] private hookQueue;
    uint256 private tokenHead;
    uint256 private hookHead;

    error OnlyDiamond();
    error InvalidDeploymentAuthority();
    error UnsupportedCreateX(bytes32 actualHash);
    error InvalidSalt(bytes32 salt);
    error SaltUnavailable(bytes32 salt);
    error InvalidHookAddress(address predicted);
    error InvalidPreparation();
    error PreparationExpired();
    error SaltQueueDepleted(bool hook);
    error InvalidDeploymentOrder();
    error UnexpectedDeploymentAddress(address expected, address actual);

    event SaltQueued(bytes32 indexed salt, bool indexed hook, address predicted);
    event CreationPrepared(bytes32 indexed id, address indexed payer, address indexed creator, address token);
    event BasketTokenDeployed(bytes32 indexed id, uint256 indexed basketId, address token);
    event BasketHookDeployed(bytes32 indexed id, uint256 indexed index, address hook);

    constructor(address diamond, IPoolManager manager, IStaticsSwapFeeHook policy) {
        if (diamond == address(0) || address(manager).code.length == 0 || policy.staticsDiamond() != diamond) {
            revert InvalidDeploymentAuthority();
        }
        if (CREATE_X.codehash != CREATE_X_CODE_HASH) revert UnsupportedCreateX(CREATE_X.codehash);
        staticsDiamond = diamond;
        poolManager = manager;
        feePolicy = policy;
        bytes memory tokenCode = type(StaticsRestrictedBasketToken).creationCode;
        bytes memory hookCode = type(StaticsBasketHook).creationCode;
        tokenCreationCodeHash = keccak256(tokenCode);
        hookCreationCodeHash = keccak256(hookCode);
        tokenCodeStore = address(new StaticsCreationCodeStore(tokenCode));
        hookCodeStore = address(new StaticsCreationCodeStore(hookCode));
    }

    modifier onlyDiamond() {
        if (msg.sender != staticsDiamond) revert OnlyDiamond();
        _;
    }

    /// @notice Caller-bound, cross-chain-protected salt accepted by pinned CreateX.
    function saltFor(uint88 entropy) public view returns (bytes32) {
        return bytes32((uint256(uint160(address(this))) << 96) | (uint256(1) << 88) | uint256(entropy));
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

    function queueAvailability() external view returns (uint256 tokens, uint256 hooks) {
        return (tokenQueue.length - tokenHead, hookQueue.length - hookHead);
    }

    /// @notice Anyone can replenish; validation never searches or mines onchain.
    function enqueueSalts(bytes32[] calldata salts, bool hook) external {
        if (salts.length == 0 || salts.length > 128) revert InvalidPreparation();
        for (uint256 i; i < salts.length; ++i) {
            bytes32 salt = salts[i];
            _requireAvailable(salt, hook);
            saltState[salt] = hook ? SaltState.QueuedHook : SaltState.QueuedToken;
            if (hook) hookQueue.push(salt);
            else tokenQueue.push(salt);
            (address predicted,) = predict(salt);
            emit SaltQueued(salt, hook, predicted);
        }
    }

    function preparationId(Intent memory intent, bytes32 tokenSalt, bytes32[] memory hookSalts)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), staticsDiamond, intent, tokenSalt, hookSalts));
    }

    function preparation(bytes32 id) external view returns (Preparation memory) {
        return preparations[id];
    }

    function reserve(Intent calldata intent, bytes32 tokenSalt, bytes32[] calldata hookSalts)
        external
        onlyDiamond
        returns (bytes32 id)
    {
        _validateIntent(intent, hookSalts.length);
        _requireAvailable(tokenSalt, false);
        saltState[tokenSalt] = SaltState.Reserved;
        for (uint256 i; i < hookSalts.length; ++i) {
            _requireAvailable(hookSalts[i], true);
            saltState[hookSalts[i]] = SaltState.Reserved;
        }
        return _record(intent, tokenSalt, hookSalts);
    }

    function reserveQueued(Intent calldata intent, uint256 hookCount) external onlyDiamond returns (bytes32 id) {
        _validateIntent(intent, hookCount);
        bytes32 tokenSalt = _takeQueue(false);
        bytes32[] memory hookSalts = new bytes32[](hookCount);
        for (uint256 i; i < hookCount; ++i) {
            hookSalts[i] = _takeQueue(true);
        }
        return _record(intent, tokenSalt, hookSalts);
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

    function deployBasketHook(bytes32 id, StaticsBasketHook.Binding calldata binding)
        external
        onlyDiamond
        returns (address hook)
    {
        Preparation storage prepared = _livePreparation(id);
        uint256 index = prepared.hookCursor;
        if (!prepared.tokenDeployed || index == prepared.hookSalts.length) revert InvalidDeploymentOrder();
        if (binding.creator != prepared.intent.creator || binding.version != VERSION) revert InvalidPreparation();
        prepared.hookCursor = index + 1;
        bytes memory args = abi.encode(poolManager, staticsDiamond, feePolicy, binding);
        hook = _deploy(prepared.hookSalts[index], hookCodeStore, args);
        emit BasketHookDeployed(id, index, hook);
    }

    function _record(Intent memory intent, bytes32 tokenSalt, bytes32[] memory hookSalts) private returns (bytes32 id) {
        id = preparationId(intent, tokenSalt, hookSalts);
        Preparation storage prepared = preparations[id];
        prepared.intent = intent;
        prepared.tokenSalt = tokenSalt;
        prepared.hookSalts = hookSalts;
        (address token,) = predict(tokenSalt);
        emit CreationPrepared(id, intent.payer, intent.creator, token);
    }

    function _validateIntent(Intent memory intent, uint256 hooks) private view {
        if (
            intent.payer == address(0) || intent.creator == address(0) || intent.configurationHash == bytes32(0)
                || intent.version != VERSION || hooks == 0 || hooks > MAX_HOOKS
        ) revert InvalidPreparation();
        if (block.timestamp > intent.deadline) revert PreparationExpired();
    }

    function _livePreparation(bytes32 id) private view returns (Preparation storage prepared) {
        prepared = preparations[id];
        if (
            prepared.intent.payer == address(0)
                || id != preparationId(prepared.intent, prepared.tokenSalt, prepared.hookSalts)
        ) revert InvalidPreparation();
        if (block.timestamp > prepared.intent.deadline) revert PreparationExpired();
    }

    function _takeQueue(bool hook) private returns (bytes32 salt) {
        if (hook) {
            if (hookHead == hookQueue.length) revert SaltQueueDepleted(true);
            salt = hookQueue[hookHead++];
        } else {
            if (tokenHead == tokenQueue.length) revert SaltQueueDepleted(false);
            salt = tokenQueue[tokenHead++];
        }
        saltState[salt] = SaltState.Reserved;
    }

    function _validateSalt(bytes32 salt) private view {
        if (address(bytes20(salt)) != address(this) || uint8(salt[20]) != 1) revert InvalidSalt(salt);
    }

    function _requireAvailable(bytes32 salt, bool hook) private view {
        if (!saltAvailable(salt)) revert SaltUnavailable(salt);
        (address predicted,) = predict(salt);
        if (hook && uint160(predicted) & ALL_HOOK_BITS != HOOK_PERMISSION_MASK) revert InvalidHookAddress(predicted);
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
