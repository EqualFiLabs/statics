// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGenesisRecoveryDistributor} from "../../src/interfaces/IGenesisRecoveryDistributor.sol";

contract MockGenesisFeeReceiver {
    address public immutable statics;
    address public activeDistributor;

    constructor(address statics_) {
        statics = statics_;
    }

    function setActiveDistributor(address distributor) external {
        activeDistributor = distributor;
    }
}

contract MockGenesisRecoveryDistributor is IGenesisRecoveryDistributor {
    address public immutable override genesisRecoveryVault;
    address public immutable override genesisRecoveryAsset;
    uint256 public override pendingGenesisRecovery;
    uint256 public totalRecoveryAccrued;
    bool public shouldRevert;

    constructor(address vault_, address asset_) {
        genesisRecoveryVault = vault_;
        genesisRecoveryAsset = asset_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function accrueGenesisRecovery(uint256 amount) external override {
        require(msg.sender == genesisRecoveryVault, "ONLY_VAULT");
        require(!shouldRevert, "RECOVERY_REVERTED");
        require(IERC20(genesisRecoveryAsset).balanceOf(address(this)) >= totalRecoveryAccrued + amount, "MISSING_ASSET");
        totalRecoveryAccrued += amount;
        emit GenesisRecoveryAccrued(amount, 0, 0);
    }
}
