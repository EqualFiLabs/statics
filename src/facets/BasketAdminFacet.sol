// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract BasketAdminFacet is IStaticsBasketAdmin, ReentrancyGuard {
    error InvalidFeeAllocation(uint256 totalBps);
    error OnlyTreasury(address caller);
    error InsufficientRevenue(uint256 basketId, address asset, uint256 requested, uint256 available);

    function setCreationFee(uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        LibBasket.basketStorage().creationFeeAmount = amount;
        emit CreationFeeChanged(amount);
    }

    function setTreasury(address newTreasury) external {
        LibDiamond.enforceIsContractOwner();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        address previousTreasury = bs.treasury;
        bs.treasury = newTreasury;
        emit TreasuryChanged(previousTreasury, newTreasury);
    }

    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external {
        LibDiamond.enforceIsContractOwner();
        uint256 totalBps =
            uint256(allocation.holderShareBps) + allocation.liquidityShareBps + allocation.protocolShareBps;
        if (totalBps != LibBasket.BPS) revert InvalidFeeAllocation(totalBps);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        BasketFeeAllocation memory previous = bs.feeAllocation;
        bs.feeAllocation = allocation;
        emit BasketFeeAllocationChanged(
            previous.holderShareBps,
            previous.liquidityShareBps,
            previous.protocolShareBps,
            allocation.holderShareBps,
            allocation.liquidityShareBps,
            allocation.protocolShareBps
        );
    }

    function claimProtocolRevenue(uint256 basketId, address asset, uint256 amount, address receiver)
        external
        nonReentrant
    {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        if (msg.sender != bs.treasury) revert OnlyTreasury(msg.sender);
        uint256 available = bs.protocolRevenue[basketId][asset];
        if (amount > available) revert InsufficientRevenue(basketId, asset, amount, available);
        bs.protocolRevenue[basketId][asset] = available - amount;
        if (amount != 0) {
            LibCustody.pushReserved(LibCustody.basketAccount(basketId), asset, receiver, amount, amount);
        }
        emit ProtocolRevenueClaimed(basketId, asset, receiver, amount);
    }

    function creationFee() external view returns (uint256 amount) {
        return LibBasket.basketStorage().creationFeeAmount;
    }

    function treasury() external view returns (address) {
        return LibBasket.basketStorage().treasury;
    }

    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation) {
        return LibBasket.basketStorage().feeAllocation;
    }

    function protocolRevenue(uint256 basketId, address asset) external view returns (uint256) {
        return LibBasket.basketStorage().protocolRevenue[basketId][asset];
    }
}
