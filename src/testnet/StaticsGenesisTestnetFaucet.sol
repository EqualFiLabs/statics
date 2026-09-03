// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Refillable single-asset faucet for a standalone Statics Genesis testnet launch.
/// @dev This contract deliberately has no owner or recovery path. Each wallet may
///      claim the fixed 200,000 STATICS bundle once per cooldown while funded.
contract StaticsGenesisTestnetFaucet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CLAIM_AMOUNT = 200_000e18;
    uint256 public constant COOLDOWN = 1 days;

    IERC20 public immutable STATICS;

    mapping(address account => uint64 timestamp) public lastClaimAt;

    event Claimed(address indexed account, uint64 claimedAt, uint256 amount);

    error ClaimNotReady(uint256 nextClaimAt);
    error FaucetUnderfunded(uint256 available, uint256 required);

    constructor(address statics) {
        STATICS = IERC20(statics);
    }

    function nextClaimAt(address account) external view returns (uint256) {
        uint256 claimedAt = lastClaimAt[account];
        return claimedAt == 0 ? 0 : claimedAt + COOLDOWN;
    }

    function claim() external nonReentrant {
        uint256 claimedAt = lastClaimAt[msg.sender];
        uint256 availableAt = claimedAt + COOLDOWN;
        if (claimedAt != 0 && block.timestamp < availableAt) revert ClaimNotReady(availableAt);

        uint256 available = STATICS.balanceOf(address(this));
        if (available < CLAIM_AMOUNT) revert FaucetUnderfunded(available, CLAIM_AMOUNT);

        lastClaimAt[msg.sender] = uint64(block.timestamp);
        STATICS.safeTransfer(msg.sender, CLAIM_AMOUNT);

        emit Claimed(msg.sender, uint64(block.timestamp), CLAIM_AMOUNT);
    }
}
