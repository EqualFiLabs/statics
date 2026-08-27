// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "./DeployStaticsGenesis.s.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";

/// @notice Development-only launcher for a persistent Anvil fork of Robinhood mainnet.
/// @dev The canonical production `run()` remains configuration-hash gated. This entrypoint
///      additionally requires Anvil's private RPC namespace before it will broadcast anything.
contract DeployStaticsGenesisLocalFork is DeployStaticsGenesis {
    error InvalidLocalForkChain(uint256 chainId);
    error InvalidLocalForkRpc();

    function runLocalFork() external returns (StaticsGenesisDeployment memory deployment) {
        if (block.chainid != ROBINHOOD_MAINNET_CHAIN_ID) revert InvalidLocalForkChain(block.chainid);

        // A public Robinhood RPC does not expose this method. Forge aborts on an RPC error, and
        // the explicit empty-result guard also rejects a malformed intermediary response.
        bytes memory nodeInfo = vm.rpc("anvil_nodeInfo", "[]");
        if (nodeInfo.length == 0) revert InvalidLocalForkRpc();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 fee = vm.envOr("STATICS_DOPPLER_FEE", uint256(30_000));
        uint256 rewardShare = vm.envOr("STATICS_GENESIS_REWARD_SHARE_BPS", uint256(5_000));
        uint256 reserveShare = vm.envOr("STATICS_GENESIS_RESERVE_SHARE_BPS", uint256(5_000));
        uint256 recoveryCallerShare = vm.envOr("STATICS_GENESIS_RECOVERY_CALLER_SHARE_BPS", uint256(2_000));
        uint256 genesisEpochEnd = vm.envOr("STATICS_GENESIS_EPOCH_END", block.timestamp + 7 days);
        if (fee > type(uint24).max) revert InvalidFee(fee);
        if (rewardShare > type(uint16).max) revert InvalidRewardShare(rewardShare);
        if (reserveShare > type(uint16).max) revert InvalidReserveShare(reserveShare);
        if (recoveryCallerShare > type(uint16).max) revert InvalidRecoveryCallerShare(recoveryCallerShare);
        if (genesisEpochEnd <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd);

        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: vm.envOr("STATICS_GENESIS_GOVERNANCE", deployer),
            treasury: vm.envOr("STATICS_GENESIS_TREASURY", deployer),
            numeraire: vm.envAddress("WETH_ADDRESS"),
            integrator: vm.envOr("STATICS_DOPPLER_INTEGRATOR", address(0)),
            modules: StaticsDopplerLaunchConfig.modules(block.chainid),
            salt: vm.envOr("STATICS_DOPPLER_SALT", keccak256(abi.encode("STATICS_LOCAL_FORK", deployer, block.number))),
            fee: uint24(fee),
            genesisRewardShareBps: uint16(rewardShare),
            reserveShareBps: uint16(reserveShare),
            creditOriginationFee: vm.envOr("STATICS_GENESIS_CREDIT_ORIGINATION_FEE", uint256(0.003 ether)),
            creditExtensionFee: vm.envOr("STATICS_GENESIS_CREDIT_EXTENSION_FEE", uint256(0.003 ether)),
            recoveryCallerShareBps: uint16(recoveryCallerShare),
            genesisEpochEnd: genesisEpochEnd,
            tokenURI: staticsTokenURI(),
            contractURI: vm.envOr("STATICS_GENESIS_CONTRACT_URI", staticsGenesisContractURI()),
            externalURLBase: vm.envOr("STATICS_GENESIS_EXTERNAL_URL_BASE", staticsGenesisExternalURLBase())
        });

        vm.startBroadcast(privateKey);
        deployment = deploy(config, deployer);
        vm.stopBroadcast();
        _log(deployment);
    }
}
