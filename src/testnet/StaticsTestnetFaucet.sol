// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Public Robinhood testnet fixture faucet for the Statics beta.
/// @dev This contract deliberately has no owner or recovery path. It distributes
///      its fixed inventory bundle once per wallet per cooldown.
contract StaticsTestnetFaucet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ASSET_COUNT = 6;
    uint256 public constant COOLDOWN = 1 days;

    uint256 public constant USDG_AMOUNT = 5_000e6;
    uint256 public constant USDSTX_AMOUNT = 5_000e18;
    uint256 public constant STATICS_AMOUNT = 1_000e18;
    uint256 public constant STOCK_AMOUNT = 0.001e18;

    IERC20[ASSET_COUNT] private _assets;

    mapping(address account => uint64 timestamp) public lastClaimAt;

    event Claimed(address indexed account, uint64 claimedAt, address[ASSET_COUNT] assets, uint256[ASSET_COUNT] amounts);

    error ClaimNotReady(uint256 nextClaimAt);
    error FaucetUnderfunded(address asset, uint256 available, uint256 required);

    constructor(address[ASSET_COUNT] memory assets_) {
        for (uint256 i; i < ASSET_COUNT; ++i) {
            _assets[i] = IERC20(assets_[i]);
        }
    }

    function asset(uint256 index) external view returns (address token, uint256 amount) {
        token = address(_assets[index]);
        amount = _claimAmount(index);
    }

    function nextClaimAt(address account) external view returns (uint256) {
        uint256 claimedAt = lastClaimAt[account];
        return claimedAt == 0 ? 0 : claimedAt + COOLDOWN;
    }

    function claim() external nonReentrant {
        uint256 claimedAt = lastClaimAt[msg.sender];
        uint256 availableAt = claimedAt + COOLDOWN;
        if (claimedAt != 0 && block.timestamp < availableAt) revert ClaimNotReady(availableAt);

        address[ASSET_COUNT] memory assets;
        uint256[ASSET_COUNT] memory amounts;
        for (uint256 i; i < ASSET_COUNT; ++i) {
            IERC20 token = _assets[i];
            uint256 amount = _claimAmount(i);
            uint256 available = token.balanceOf(address(this));
            if (available < amount) revert FaucetUnderfunded(address(token), available, amount);
            assets[i] = address(token);
            amounts[i] = amount;
        }

        lastClaimAt[msg.sender] = uint64(block.timestamp);

        for (uint256 i; i < ASSET_COUNT; ++i) {
            _assets[i].safeTransfer(msg.sender, amounts[i]);
        }

        emit Claimed(msg.sender, uint64(block.timestamp), assets, amounts);
    }

    function _claimAmount(uint256 index) private pure returns (uint256) {
        if (index == 0) return USDG_AMOUNT;
        if (index == 1) return USDSTX_AMOUNT;
        if (index == 2) return STATICS_AMOUNT;
        return STOCK_AMOUNT;
    }
}
