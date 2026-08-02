// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Owner-published L2 sequencer status for public testnet deployments.
/// @dev Matches Chainlink uptime semantics: zero is up and one is down.
contract TestnetSequencerUptimeAggregator is Ownable {
    error InvalidInitialStartedAt(uint256 startedAt, uint256 currentTimestamp);

    event SequencerStatusPublished(uint80 indexed roundId, bool down, uint256 startedAt, uint256 updatedAt);

    uint8 public constant decimals = 0;
    string public constant description = "Testnet Sequencer Uptime";
    uint256 public constant version = 1;

    uint80 private _roundId = 1;
    bool public down;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(address owner_, uint256 initialStartedAt) Ownable(owner_) {
        if (initialStartedAt == 0 || initialStartedAt > block.timestamp) {
            revert InvalidInitialStartedAt(initialStartedAt, block.timestamp);
        }
        _startedAt = initialStartedAt;
        _updatedAt = block.timestamp;
        emit SequencerStatusPublished(1, false, initialStartedAt, block.timestamp);
    }

    function publishStatus(bool down_) external onlyOwner {
        if (down_ != down) {
            down = down_;
            _startedAt = block.timestamp;
        }

        uint80 roundId = _roundId + 1;
        _roundId = roundId;
        _updatedAt = block.timestamp;
        emit SequencerStatusPublished(roundId, down_, _startedAt, block.timestamp);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = _roundId;
        answer = down ? int256(1) : int256(0);
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = roundId;
    }
}
