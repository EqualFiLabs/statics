// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract BasketAdminFacet is IStaticsBasketAdmin {
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

    function creationFee() external view returns (uint256 amount) {
        return LibBasket.basketStorage().creationFeeAmount;
    }

    function treasury() external view returns (address) {
        return LibBasket.basketStorage().treasury;
    }
}
