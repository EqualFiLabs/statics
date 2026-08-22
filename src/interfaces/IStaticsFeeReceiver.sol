// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

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

    function statics() external view returns (address);
    function numeraire() external view returns (address);
    function poolInitializer() external view returns (address);
    function poolId() external view returns (bytes32);
    function reserveVault() external view returns (address);
    function reserveShareBps() external view returns (uint16);
    function activeDistributor() external view returns (address);
    function pendingDistributor() external view returns (address);
    function cumulativeHarvested(address asset) external view returns (uint256);
    function cumulativeDistributorAttributed(address distributor, address asset) external view returns (uint256);
    function distributorClaimable(address distributor, address asset) external view returns (uint256);
    function totalDistributorLiability(address asset) external view returns (uint256);
    function cumulativeReserveWeth() external view returns (uint256);
    function cumulativeDistributorWeth() external view returns (uint256);
    function bindMarket(address statics_, bytes32 poolId_) external;
    function bindReserveVault(address reserveVault_) external;
    function setReserveShareBps(uint16 newShareBps) external;
    function harvest() external returns (uint256 staticsAmount, uint256 numeraireAmount);
    function proposeDistributor(address distributor) external;
    function acceptDistributor() external;
    function claimDistributorFees(address asset, address receiver) external returns (uint256 amount);
    function recoverSurplus(address asset, address receiver, uint256 amount) external;
}
