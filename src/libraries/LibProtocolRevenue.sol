// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Namespaced pull-based creator revenue accounting. Records point credits per creator and
/// aggregate liabilities per asset for custody and invariant reconciliation.
library LibProtocolRevenue {
    bytes32 internal constant PROTOCOL_REVENUE_STORAGE_POSITION = keccak256("statics.storage.protocol.revenue.v1");

    struct ProtocolRevenueStorage {
        mapping(address creator => mapping(address asset => uint256 amount)) creatorCredit;
        mapping(address asset => uint256 amount) totalCreatorCredit;
    }

    function protocolRevenueStorage() internal pure returns (ProtocolRevenueStorage storage rs) {
        bytes32 position = PROTOCOL_REVENUE_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function credit(address creator, address asset, uint256 amount) internal {
        if (amount == 0) return;
        ProtocolRevenueStorage storage rs = protocolRevenueStorage();
        rs.creatorCredit[creator][asset] += amount;
        rs.totalCreatorCredit[asset] += amount;
    }

    function clear(address creator, address asset) internal returns (uint256 amount) {
        ProtocolRevenueStorage storage rs = protocolRevenueStorage();
        amount = rs.creatorCredit[creator][asset];
        if (amount == 0) return 0;
        rs.creatorCredit[creator][asset] = 0;
        rs.totalCreatorCredit[asset] -= amount;
    }

    function creditOf(address creator, address asset) internal view returns (uint256 amount) {
        return protocolRevenueStorage().creatorCredit[creator][asset];
    }

    function totalOf(address asset) internal view returns (uint256 amount) {
        return protocolRevenueStorage().totalCreatorCredit[asset];
    }
}
