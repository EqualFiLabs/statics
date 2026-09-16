// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LibCustody} from "../../../src/libraries/LibCustody.sol";

contract FormalFlashCustodyToken is ERC20 {
    constructor() ERC20("Formal Flash Asset", "FFA") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/// @notice Thin production-library harness for flash reservation/backing properties.
contract FlashCustodyHarness {
    bytes32 private constant PRINCIPAL_ACCOUNT = keccak256("formal.flash.principal");
    bytes32 private constant CALLBACK_ACCOUNT = keccak256("formal.flash.callback");
    bytes32 private constant FEE_ACCOUNT = keccak256("formal.flash.fee");
    address private constant RECEIVER = address(0xBEEF);

    FormalFlashCustodyToken internal immutable flashToken;

    constructor() {
        flashToken = new FormalFlashCustodyToken();
    }

    function seedCustody(uint256 initialPhysicalBalance, uint256 reserved) public {
        flashToken.mint(address(this), initialPhysicalBalance);
        LibCustody.reserve(PRINCIPAL_ACCOUNT, address(flashToken), reserved);
    }

    function lendAndCheckpoint(uint256 amount) public returns (uint256 spent, uint256 received) {
        (spent, received) = LibCustody.pushFlash(address(flashToken), RECEIVER, amount);
        LibCustody.checkpointFlashReservationDeficit(address(flashToken));
    }

    function restorePhysicalBacking(uint256 amount) public {
        flashToken.mint(address(this), amount);
    }

    function reserveDuringCallback(uint256 amount) external {
        LibCustody.reserve(CALLBACK_ACCOUNT, address(flashToken), amount);
    }

    /// @dev Mirrors FlashLoanFacet's final solvency requirement before clearing the
    /// transient reservation deficit. Token-transfer exactness is tested separately.
    function finishFlash(uint256 startingUnreserved, uint256 fee) public {
        uint256 endingBalance = flashToken.balanceOf(address(this));
        uint256 requiredBalance = LibCustody.globalReserved(address(flashToken)) + startingUnreserved + fee;
        if (endingBalance < requiredBalance) revert();
        LibCustody.clearFlashReservationDeficit(address(flashToken));
    }

    function reserveFee(uint256 fee) public {
        LibCustody.reserve(FEE_ACCOUNT, address(flashToken), fee);
    }

    function physicalBalance() public view returns (uint256) {
        return flashToken.balanceOf(address(this));
    }

    function globalReserved() public view returns (uint256) {
        return LibCustody.globalReserved(address(flashToken));
    }

    function callbackReserved() public view returns (uint256) {
        return LibCustody.accountReserved(CALLBACK_ACCOUNT, address(flashToken));
    }

    function feeReserved() public view returns (uint256) {
        return LibCustody.accountReserved(FEE_ACCOUNT, address(flashToken));
    }

    function unreserved() public view returns (uint256) {
        return LibCustody.unreservedBalance(address(flashToken));
    }
}
