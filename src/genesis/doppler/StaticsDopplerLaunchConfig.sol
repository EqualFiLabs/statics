// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Official Doppler module addresses used by the standalone Genesis launcher.
/// @dev Source: whetstoneresearch/doppler Deployments.json at commit
///      86a5200456b148c156d2eb81a893747dd601c3ca.
library StaticsDopplerLaunchConfig {
    uint256 internal constant ROBINHOOD_MAINNET = 4_663;
    uint256 internal constant BASE_SEPOLIA = 84_532;

    struct Modules {
        address airlock;
        address tokenFactory;
        address governanceFactory;
        address poolInitializer;
        address noOpMigrator;
    }

    error UnsupportedDopplerChain(uint256 chainId);

    function modules(uint256 chainId) internal pure returns (Modules memory config) {
        if (chainId == ROBINHOOD_MAINNET) {
            return Modules({
                airlock: 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862,
                tokenFactory: 0x1B37D3a72082029c44B35B604Ea473617580b69a,
                governanceFactory: 0xdb036746D65DD52126b1915f1AdF555e6C5237Cf,
                poolInitializer: 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
                noOpMigrator: 0xba2F330EDb16cD8056f5988d8CE19BbC63475A0e
            });
        }
        if (chainId == BASE_SEPOLIA) {
            return Modules({
                airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
                tokenFactory: 0x89C261C05B5F9b6BcBA07C199b8DeE7cFaD45292,
                governanceFactory: 0x0902e7C7207df8ed6303Aef4382bcab181b5fBFA,
                poolInitializer: 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544,
                noOpMigrator: 0xF11066abbd329ac4bBA39455340539322C222eb0
            });
        }
        revert UnsupportedDopplerChain(chainId);
    }
}
