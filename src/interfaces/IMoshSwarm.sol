// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Integration subset of the current-generation ABI published at mosh.trade/docs/addresses.
/// @dev ABI declarations are not source verification. Supported deployments need runtime pins and fork evidence.
interface IMoshSwarm {
    function factory() external view returns (address);
    function registry() external view returns (address);
    function memecoin() external view returns (address);
    function counterAsset() external view returns (address);
    function counterIsNative() external view returns (bool);
    function teamRecipient() external view returns (address);
    function teamShareBps() external view returns (uint256);
    function claim(address owner) external view returns (uint256);
    function claimable(address owner) external view returns (uint256);
    function collectFees() external returns (uint256);
    function syncFees() external returns (uint256);
    function transferClaim(address from, address to, uint256 amount) external;
}

interface IMoshFactory {
    function registry() external view returns (address);
    function pairToken() external view returns (address);
    function swarmImplementation() external view returns (address);
    function isSwarm(address swarm) external view returns (bool);
}

interface IMoshRegistry {
    function isClaimMarket(address market) external view returns (bool);
}

/// @dev Market signatures are established by deployed-contract fork execution, not a published Solidity source.
interface IMoshClaimMarket {
    function offers(uint256 offerId)
        external
        view
        returns (
            address swarm,
            address seller,
            address buyer,
            uint256 amount,
            uint256 price,
            uint64 deadline,
            uint16 feeBps
        );
    function list(address swarm, uint256 amount, uint256 price, address buyer, uint64 deadline)
        external
        returns (uint256 offerId);
    function fill(uint256 offerId) external payable;
    function cancel(uint256 offerId) external;
    function feeBps() external view returns (uint256);
}
