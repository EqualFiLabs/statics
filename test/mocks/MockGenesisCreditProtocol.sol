// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsGenesis, IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";

contract MockGenesisCreditProtocol is IStaticsGenesisProtocol {
    address public immutable override genesisCollection;
    mapping(uint256 genesisId => uint256 positionId) public override linkedPosition;
    uint256 public unrelatedLedgerValue = 77;
    bool public recoveryCalled;
    bool public rejectRecovery;

    constructor(address collection) {
        genesisCollection = collection;
    }

    function link(uint256 genesisId, uint256 positionId) external {
        linkedPosition[genesisId] = positionId;
        IStaticsGenesis(genesisCollection).refreshLockStatus(genesisId);
    }

    function setRejectRecovery(bool value) external {
        rejectRecovery = value;
    }

    function onGenesisRecovery(uint256 genesisId, address previousOwner)
        external
        override
        returns (bytes4 acknowledgement)
    {
        previousOwner;
        require(msg.sender == genesisCollection, "ONLY_GENESIS");
        require(!rejectRecovery, "RECOVERY_REJECTED");
        recoveryCalled = true;
        delete linkedPosition[genesisId];
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }
}
