// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Permanent fee-ingress and reserve-accounting interface for the Genesis launch.
interface IStaticsFeeReceiver {
    event MarketBound(address indexed statics, address indexed numeraire, bytes32 indexed poolId);
    event ReserveVaultBound(address indexed reserveVault);
    event ReserveShareUpdated(uint16 previousShareBps, uint16 newShareBps);
    event ReserveFunded(uint256 grossWeth, uint256 reserveWeth, uint256 distributorWeth);
    event FeesHarvested(address indexed distributor, address indexed asset, uint256 amount, uint256 cumulativeAmount);
    event DistributorProposed(address indexed currentDistributor, address indexed pendingDistributor);
    event DistributorAccepted(address indexed previousDistributor, address indexed newDistributor);
    event DistributorFeesClaimed(
        address indexed distributor, address indexed asset, address indexed receiver, uint256 amount
    );
    event SurplusRecovered(address indexed asset, address indexed receiver, uint256 amount);

    /// @notice STATICS token address for the bound market.
    function statics() external view returns (address);
    /// @notice WETH (or configured wrapped-native numeraire) address.
    function numeraire() external view returns (address);
    /// @notice Canonical Doppler pool initializer used by the bound market.
    function poolInitializer() external view returns (address);
    /// @notice Uniswap V4 PoolId used for fee collection.
    function poolId() external view returns (bytes32);
    /// @notice Permanent Genesis vault receiving the reserve share.
    function reserveVault() external view returns (address);
    /// @notice WETH reserve share in basis points.
    function reserveShareBps() external view returns (uint16);
    /// @notice Active distributor receiving non-reserve fees.
    function activeDistributor() external view returns (address);
    /// @notice Distributor awaiting two-step acceptance.
    function pendingDistributor() external view returns (address);
    function cumulativeHarvested(address asset) external view returns (uint256);
    function cumulativeDistributorAttributed(address distributor, address asset) external view returns (uint256);
    function distributorClaimable(address distributor, address asset) external view returns (uint256);
    function totalDistributorLiability(address asset) external view returns (uint256);
    function cumulativeReserveWeth() external view returns (uint256);
    function cumulativeDistributorWeth() external view returns (uint256);
    /// @notice Permanently binds the STATICS market and validates its pair, hook, and fee share.
    /// @param statics_ STATICS token address.
    /// @param poolId_ Canonical Uniswap V4 PoolId.
    function bindMarket(address statics_, bytes32 poolId_) external;
    /// @notice Permanently binds the reserve vault.
    /// @param reserveVault_ Genesis vault that receives unwrapped native ETH.
    function bindReserveVault(address reserveVault_) external;
    /// @notice Harvests under the current reserve split, then updates the split.
    /// @param newShareBps New reserve share in basis points.
    function setReserveShareBps(uint16 newShareBps) external;
    /// @notice Collects fee-source revenue and attributes it to the active distributor.
    /// @return staticsAmount STATICS collected.
    /// @return numeraireAmount Wrapped-native numeraire collected.
    function harvest() external returns (uint256 staticsAmount, uint256 numeraireAmount);
    /// @notice Proposes a new distributor for two-step acceptance.
    /// @param distributor Proposed distributor contract.
    function proposeDistributor(address distributor) external;
    /// @notice Accepts the caller's pending distributor appointment.
    function acceptDistributor() external;
    /// @notice Claims the caller's attributed fee balance.
    /// @param asset Asset to claim.
    /// @param receiver Recipient of the claimed asset.
    /// @return amount Amount transferred.
    function claimDistributorFees(address asset, address receiver) external returns (uint256 amount);
    /// @notice Recovers only fee tokens exceeding all distributor liabilities.
    /// @param asset Asset to recover.
    /// @param receiver Recipient of the surplus.
    /// @param amount Amount to recover.
    function recoverSurplus(address asset, address receiver, uint256 amount) external;
}
