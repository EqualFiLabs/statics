// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsGovernance {
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event ActionsPaused(address indexed caller, uint256 actions);
    event ActionsUnpaused(address indexed caller, uint256 actions);
    event BasketQuarantined(uint256 indexed basketId, address indexed guardian);
    event BasketQuarantineReleased(uint256 indexed basketId);
    event BasketDecommissioned(uint256 indexed basketId);
    event ProtocolSwapsPauseSet(address indexed caller, bool paused);
    event ProtocolPoolQuarantineSet(PoolId indexed poolId, address indexed caller, bool quarantined);

    function guardian() external view returns (address);
    function pausedActions() external view returns (uint256);
    function isPaused(uint256 actions) external view returns (bool);
    function setGuardian(address newGuardian) external;
    function pause(uint256 actions) external;
    function unpause(uint256 actions) external;
    function quarantineBasket(uint256 basketId) external;
    function releaseBasketQuarantine(uint256 basketId) external;
    function decommissionBasket(uint256 basketId) external;
    function pauseProtocolSwaps() external;
    function unpauseProtocolSwaps() external;
    function quarantineProtocolPool(PoolId poolId) external;
    function releaseProtocolPoolQuarantine(PoolId poolId) external;
    function protocolSwapsPaused() external view returns (bool paused);
    function isProtocolPoolQuarantined(PoolId poolId) external view returns (bool quarantined);
    function protocolPoolSwapsBlocked(PoolId poolId) external view returns (bool blocked);
}
