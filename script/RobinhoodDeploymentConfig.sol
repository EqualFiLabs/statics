// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

abstract contract RobinhoodDeploymentConfig {
    uint256 internal constant ROBINHOOD_MAINNET_CHAIN_ID = 4663;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    error UnsupportedRobinhoodChain(uint256 chainId);

    function _robinhoodManifestPath(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ROBINHOOD_MAINNET_CHAIN_ID) {
            return "deployments/robinhood-chain-4663.json";
        }
        if (chainId == ROBINHOOD_TESTNET_CHAIN_ID) {
            return "deployments/robinhood-chain-testnet-46630.json";
        }
        revert UnsupportedRobinhoodChain(chainId);
    }
}
