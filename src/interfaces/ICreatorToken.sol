// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Current creator-token transfer-validator discovery interface.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function setTransferValidator(address validator) external;
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
}

/// @notice Legacy creator-token discovery interface retained by marketplace integrations.
interface ICreatorTokenLegacy {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function setTransferValidator(address validator) external;
}

interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}
