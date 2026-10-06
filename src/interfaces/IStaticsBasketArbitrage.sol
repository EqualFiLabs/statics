// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IStaticsBasketArbitrage {
    function deployBasketArbitrageReceiver() external returns (address receiver);
    function beginBasketArbitrage(uint256 basketId, uint256 shares, address executor) external;
    function settleBasketArbitrageInput(address token, address executor, uint256 amount) external;
    function settleBasketArbitrageOutput(address token, address executor, uint256 amount) external;
    function endBasketArbitrage() external;
}
