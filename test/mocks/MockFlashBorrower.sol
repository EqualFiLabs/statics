// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsFlashBorrower} from "../../src/interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";

contract MockFlashBorrower is IStaticsFlashBorrower {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");

    address public immutable PROTOCOL;
    bool public repay = true;
    bytes32 public callbackResult = CALLBACK_SUCCESS;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(address protocol) {
        PROTOCOL = protocol;
    }

    function setRepay(bool value) external {
        repay = value;
    }

    function setCallbackResult(bytes32 value) external {
        callbackResult = value;
    }

    function approveProtocol(address token, uint256 amount) external {
        IERC20(token).approve(PROTOCOL, amount);
    }

    function setReentryData(bytes calldata data) external {
        reentryData = data;
    }

    function execute(uint256 basketId, uint256 shares, bytes calldata data) external {
        IStaticsFlashLoan(PROTOCOL).flashLoan(basketId, shares, address(this), data);
    }

    function onStaticsFlashLoan(
        address,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == PROTOCOL, "only protocol");
        if (reentryData.length != 0) {
            (reentrySucceeded, reentryResult) = PROTOCOL.call(reentryData);
        }
        if (repay) {
            uint256 length = assets.length;
            for (uint256 i; i < length; ++i) {
                IERC20(assets[i]).approve(PROTOCOL, amounts[i] + fees[i]);
            }
        }
        return callbackResult;
    }
}
