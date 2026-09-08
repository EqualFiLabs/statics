// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @notice Prepares standard PositionManager calldata for an externally owned launch-liquidity NFT.
/// @dev This script never broadcasts and does not modify hook state.
contract PrepareStaticsPositionActions is Script {
    struct PositionActionConfig {
        uint256 chainId;
        address positionManager;
        Currency currency0;
        Currency currency1;
        uint256 tokenId;
        uint128 liquidityDelta;
        uint128 amount0Max;
        uint128 amount1Max;
        uint128 amount0Min;
        uint128 amount1Min;
        address recipient;
    }

    error EmptyArtifactPath();
    error InvalidChain(uint256 expected, uint256 actual);
    error ExpiredDeadline(uint256 deadline, uint256 currentTimestamp);
    error InvalidConfig();

    function run() external returns (PositionActionConfig memory config) {
        string memory poolArtifact =
            vm.envOr("STATICS_POOL_LAUNCH_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663-pool.json"));
        string memory preparedPath = vm.envOr(
            "STATICS_POSITION_ACTIONS_ARTIFACT",
            string("artifacts/launch-liquidity/robinhood-4663-position-actions.json")
        );
        uint256 deadline = vm.envUint("STATICS_POSITION_ACTION_DEADLINE");
        config = loadPoolAndEnvironment(poolArtifact);
        validate(config, deadline);
        vm.createDir("artifacts/launch-liquidity", true);
        writeArtifact(preparedPath, poolArtifact, config, deadline);
    }

    function loadPoolAndEnvironment(string memory path) public view returns (PositionActionConfig memory config) {
        if (bytes(path).length == 0) revert EmptyArtifactPath();
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.positionManager = vm.parseJsonAddress(json, ".positionManager");
        config.currency0 = Currency.wrap(vm.parseJsonAddress(json, ".currency0"));
        config.currency1 = Currency.wrap(vm.parseJsonAddress(json, ".currency1"));
        config.tokenId = vm.envUint("STATICS_POSITION_TOKEN_ID");
        config.liquidityDelta = _toUint128(vm.envUint("STATICS_POSITION_LIQUIDITY_DELTA"));
        config.amount0Max = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT0_MAX"));
        config.amount1Max = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT1_MAX"));
        config.amount0Min = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT0_MIN"));
        config.amount1Min = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT1_MIN"));
        config.recipient = vm.envAddress("STATICS_POSITION_RECIPIENT");
    }

    function validate(PositionActionConfig memory config, uint256 deadline) public view {
        if (config.chainId != block.chainid) revert InvalidChain(config.chainId, block.chainid);
        if (deadline < block.timestamp) revert ExpiredDeadline(deadline, block.timestamp);
        address currency0 = Currency.unwrap(config.currency0);
        address currency1 = Currency.unwrap(config.currency1);
        if (
            config.positionManager == address(0) || config.positionManager.code.length == 0 || currency0 == address(0)
                || currency1 == address(0) || currency0 >= currency1 || config.tokenId == 0
                || config.recipient == address(0) || config.recipient == config.positionManager
                || config.recipient == address(1) || config.recipient == address(2)
        ) revert InvalidConfig();
    }

    function increaseCalldata(PositionActionConfig memory config, uint256 deadline) public pure returns (bytes memory) {
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.INCREASE_LIQUIDITY)), bytes1(uint8(Actions.SETTLE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(config.tokenId, config.liquidityDelta, config.amount0Max, config.amount1Max, bytes(""));
        params[1] = abi.encode(config.currency0, config.currency1);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
    }

    function decreaseCalldata(PositionActionConfig memory config, uint256 deadline) public pure returns (bytes memory) {
        return _decreaseCalldata(config, config.liquidityDelta, config.amount0Min, config.amount1Min, deadline);
    }

    function collectCalldata(PositionActionConfig memory config, uint256 deadline) public pure returns (bytes memory) {
        return _decreaseCalldata(config, 0, 0, 0, deadline);
    }

    function exitAndBurnCalldata(PositionActionConfig memory config, uint256 deadline)
        public
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(config.tokenId, config.amount0Min, config.amount1Min, bytes(""));
        params[1] = abi.encode(config.currency0, config.currency1, config.recipient);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
    }

    function writeArtifact(
        string memory path,
        string memory poolArtifact,
        PositionActionConfig memory config,
        uint256 deadline
    ) public {
        if (bytes(path).length == 0 || bytes(poolArtifact).length == 0) {
            revert EmptyArtifactPath();
        }
        string memory objectKey = "preparedPositionActions";
        vm.serializeString(objectKey, "poolArtifact", poolArtifact);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "currency0", Currency.unwrap(config.currency0));
        vm.serializeAddress(objectKey, "currency1", Currency.unwrap(config.currency1));
        vm.serializeUint(objectKey, "tokenId", config.tokenId);
        vm.serializeUint(objectKey, "liquidityDelta", config.liquidityDelta);
        vm.serializeUint(objectKey, "amount0Max", config.amount0Max);
        vm.serializeUint(objectKey, "amount1Max", config.amount1Max);
        vm.serializeUint(objectKey, "amount0Min", config.amount0Min);
        vm.serializeUint(objectKey, "amount1Min", config.amount1Min);
        vm.serializeAddress(objectKey, "recipient", config.recipient);
        vm.serializeUint(objectKey, "deadline", deadline);
        vm.serializeBytes(objectKey, "increaseCalldata", increaseCalldata(config, deadline));
        vm.serializeBytes(objectKey, "decreaseCalldata", decreaseCalldata(config, deadline));
        vm.serializeBytes(objectKey, "collectCalldata", collectCalldata(config, deadline));
        string memory json = vm.serializeBytes(objectKey, "exitAndBurnCalldata", exitAndBurnCalldata(config, deadline));
        vm.writeJson(json, path);
    }

    function _decreaseCalldata(
        PositionActionConfig memory config,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) private pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.DECREASE_LIQUIDITY)), bytes1(uint8(Actions.TAKE_PAIR))
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(config.tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(config.currency0, config.currency1, config.recipient);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert InvalidConfig();
        return uint128(value);
    }
}
