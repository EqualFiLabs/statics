// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";

contract GovernanceFacet is IStaticsGovernance {
    error InvalidActions(uint256 actions);
    error NotGuardianOrOwner(address caller);
    error NotGuardian(address caller);
    error BasketNotFound(uint256 basketId);
    error InvalidBasketStatus(uint256 basketId, IStaticsBasket.BasketStatus status);

    function guardian() external view returns (address) {
        return LibGovernance.governanceStorage().guardian;
    }

    function pausedActions() external view returns (uint256) {
        return LibGovernance.governanceStorage().pausedActions;
    }

    function isPaused(uint256 actions) external view returns (bool) {
        return LibGovernance.governanceStorage().pausedActions & actions != 0;
    }

    function setGuardian(address newGuardian) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernance.GovernanceStorage storage gs = LibGovernance.governanceStorage();
        address previousGuardian = gs.guardian;
        gs.guardian = newGuardian;
        emit GuardianChanged(previousGuardian, newGuardian);
    }

    function pause(uint256 actions) external {
        if (actions == 0 || actions & ~LibGovernance.ALL_ACTIONS != 0) revert InvalidActions(actions);
        LibGovernance.GovernanceStorage storage gs = LibGovernance.governanceStorage();
        address owner_ = LibDiamond.diamondStorage().contractOwner;
        if (msg.sender != owner_) {
            if (msg.sender != gs.guardian) revert NotGuardianOrOwner(msg.sender);
            if (actions & ~LibGovernance.GUARDIAN_ACTIONS != 0) revert InvalidActions(actions);
        }
        gs.pausedActions |= actions;
        emit ActionsPaused(msg.sender, actions);
    }

    function unpause(uint256 actions) external {
        LibDiamond.enforceIsContractOwner();
        if (actions == 0 || actions & ~LibGovernance.ALL_ACTIONS != 0) revert InvalidActions(actions);
        LibGovernance.governanceStorage().pausedActions &= ~actions;
        emit ActionsUnpaused(msg.sender, actions);
    }

    function quarantineBasket(uint256 basketId) external {
        LibGovernance.GovernanceStorage storage gs = LibGovernance.governanceStorage();
        if (msg.sender != gs.guardian) revert NotGuardian(msg.sender);
        LibBasket.Basket storage configured = _getBasket(basketId);
        if (configured.status != IStaticsBasket.BasketStatus.Active) {
            revert InvalidBasketStatus(basketId, configured.status);
        }
        configured.status = IStaticsBasket.BasketStatus.Quarantined;
        emit BasketQuarantined(basketId, msg.sender);
    }

    function releaseBasketQuarantine(uint256 basketId) external {
        LibDiamond.enforceIsContractOwner();
        LibBasket.Basket storage configured = _getBasket(basketId);
        if (configured.status != IStaticsBasket.BasketStatus.Quarantined) {
            revert InvalidBasketStatus(basketId, configured.status);
        }
        configured.status = IStaticsBasket.BasketStatus.Active;
        emit BasketQuarantineReleased(basketId);
    }

    function decommissionBasket(uint256 basketId) external {
        LibDiamond.enforceIsContractOwner();
        LibBasket.Basket storage configured = _getBasket(basketId);
        if (configured.status == IStaticsBasket.BasketStatus.ExitOnly) {
            revert InvalidBasketStatus(basketId, configured.status);
        }
        configured.status = IStaticsBasket.BasketStatus.ExitOnly;
        emit BasketDecommissioned(basketId);
    }

    function _getBasket(uint256 basketId) private view returns (LibBasket.Basket storage configured) {
        configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }
}
