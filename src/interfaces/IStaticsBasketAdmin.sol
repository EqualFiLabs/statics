// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsBasketAdmin {
    struct BasketFeeAllocation {
        uint16 holderShareBps;
        uint16 liquidityShareBps;
        uint16 protocolShareBps;
    }

    event CreationFeeChanged(uint256 amount);
    event CreationFeePaid(address indexed creator, address indexed treasury, uint256 amount);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);
    event BasketFeeAllocationChanged(
        uint16 previousHolderShareBps,
        uint16 previousLiquidityShareBps,
        uint16 previousProtocolShareBps,
        uint16 newHolderShareBps,
        uint16 newLiquidityShareBps,
        uint16 newProtocolShareBps
    );
    event ProtocolRevenueClaimed(
        uint256 indexed basketId, address indexed asset, address indexed receiver, uint256 amount
    );

    function setCreationFee(uint256 amount) external;
    function setTreasury(address newTreasury) external;
    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external;
    function claimProtocolRevenue(uint256 basketId, address asset, uint256 amount, address receiver) external;
    function creationFee() external view returns (uint256 amount);
    function treasury() external view returns (address);
    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation);
    function protocolRevenue(uint256 basketId, address asset) external view returns (uint256);
}
