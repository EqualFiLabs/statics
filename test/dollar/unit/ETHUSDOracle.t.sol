// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {IUsdOracle} from "src/dollar/interfaces/IUsdOracle.sol";

contract ChainlinkUsdOracleTest is Test {
    MockChainlinkFeed internal feed;
    MockChainlinkFeed internal sequencer;

    uint256 internal constant NOW = 1_700_000_000;
    uint256 internal constant MAX_STALENESS = 1 hours;
    uint256 internal constant MIN_PRICE_WAD = 100e18;
    uint256 internal constant MAX_PRICE_WAD = 10_000e18;
    uint256 internal constant GRACE_PERIOD = 1 hours;

    function setUp() public {
        vm.warp(NOW);
        feed = new MockChainlinkFeed(8);
        feed.setRoundData(1, 2_500e8, NOW - 10 minutes, NOW - 10 minutes, 1);
        sequencer = new MockChainlinkFeed(0);
        sequencer.setRoundData(1, 0, NOW - GRACE_PERIOD - 1, NOW - 1, 1);
    }

    function test_NormalizesCollateralPriceAndAcceptsHealthySequencer() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        assertEq(oracle.priceWad(), 2_500e18);
        assertEq(oracle.feedDecimals(), 8);
        assertEq(oracle.sequencerUptimeFeed(), address(sequencer));
    }

    function test_WithoutSequencerProtectionSupportsNonL2Deployment() public {
        ChainlinkUsdOracle oracle = _newOracle(address(0), 0);
        assertEq(oracle.priceWad(), 2_500e18);
    }

    function test_RevertWhen_SequencerConfigurationIsHalfSet() public {
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerConfiguration.selector);
        _newOracle(address(sequencer), 0);

        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerConfiguration.selector);
        _newOracle(address(0), GRACE_PERIOD);
    }

    function test_RevertWhen_SequencerIsDownOrStatusIsUnsupported() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        sequencer.setRoundData(2, 1, NOW - 2 hours, NOW - 1, 2);
        vm.expectRevert(ChainlinkUsdOracle.SequencerDown.selector);
        oracle.priceWad();

        sequencer.setRoundData(3, 2, NOW - 2 hours, NOW - 1, 3);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkUsdOracle.InvalidSequencerStatus.selector, int256(2)));
        oracle.priceWad();
    }

    function test_RevertThroughoutGraceAndAllowImmediatelyAfterBoundary() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        sequencer.setRoundData(2, 0, NOW - GRACE_PERIOD, NOW - 1, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkUsdOracle.SequencerGracePeriodActive.selector, NOW - GRACE_PERIOD, GRACE_PERIOD
            )
        );
        oracle.priceWad();

        sequencer.setRoundData(3, 0, NOW - GRACE_PERIOD - 1, NOW - 1, 3);
        assertEq(oracle.priceWad(), 2_500e18);
    }

    function test_RevertWhen_SequencerRoundIsMalformed() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        sequencer.setRoundData(0, 0, NOW - 2 hours, NOW - 1, 0);
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerRound.selector);
        oracle.priceWad();

        sequencer.setRoundData(2, 0, 0, NOW - 1, 2);
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerRound.selector);
        oracle.priceWad();

        sequencer.setRoundData(3, 0, NOW - 1, NOW - 2, 3);
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerRound.selector);
        oracle.priceWad();

        sequencer.setRoundData(4, 0, NOW - 2 hours, NOW + 1, 4);
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerRound.selector);
        oracle.priceWad();

        sequencer.setRoundData(5, 0, NOW - 2 hours, NOW - 1, 4);
        vm.expectRevert(ChainlinkUsdOracle.InvalidSequencerRound.selector);
        oracle.priceWad();
    }

    function test_RevertWhen_PriceRoundTimestampsAreMalformed() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        feed.setRoundData(2, 2_500e8, 0, NOW - 1, 2);
        vm.expectRevert(IUsdOracle.InvalidPrice.selector);
        oracle.priceWad();

        feed.setRoundData(3, 2_500e8, NOW - 1, NOW - 2, 3);
        vm.expectRevert(IUsdOracle.InvalidPrice.selector);
        oracle.priceWad();

        feed.setRoundData(4, 2_500e8, NOW, NOW + 1, 4);
        vm.expectRevert(IUsdOracle.InvalidPrice.selector);
        oracle.priceWad();
    }

    function test_RevertWhen_PriceIsStaleIncompleteOrOutOfBounds() public {
        ChainlinkUsdOracle oracle = _newOracle(address(sequencer), GRACE_PERIOD);
        feed.setRoundData(2, 2_500e8, NOW - MAX_STALENESS - 1, NOW - MAX_STALENESS - 1, 2);
        vm.expectRevert(abi.encodeWithSelector(IUsdOracle.StalePrice.selector, NOW - MAX_STALENESS - 1, MAX_STALENESS));
        oracle.priceWad();

        feed.setRoundData(3, 2_500e8, NOW - 1, NOW - 1, 2);
        vm.expectRevert(IUsdOracle.InvalidPrice.selector);
        oracle.priceWad();

        feed.setRoundData(4, 100e8, NOW - 1, NOW - 1, 4);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkUsdOracle.PriceOutOfBounds.selector, 100e18, MIN_PRICE_WAD, MAX_PRICE_WAD)
        );
        oracle.priceWad();
    }

    function test_RevertWhen_FeedConfigurationIsInvalid() public {
        vm.expectRevert(ChainlinkUsdOracle.ZeroAddress.selector);
        new ChainlinkUsdOracle(address(0), MAX_STALENESS, MIN_PRICE_WAD, MAX_PRICE_WAD, address(0), 0);

        vm.expectRevert(ChainlinkUsdOracle.InvalidMaxStaleness.selector);
        new ChainlinkUsdOracle(address(feed), 0, MIN_PRICE_WAD, MAX_PRICE_WAD, address(0), 0);

        MockChainlinkFeed unsupported = new MockChainlinkFeed(19);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkUsdOracle.UnsupportedFeedDecimals.selector, uint8(19)));
        new ChainlinkUsdOracle(address(unsupported), MAX_STALENESS, MIN_PRICE_WAD, MAX_PRICE_WAD, address(0), 0);
    }

    function _newOracle(address sequencerFeed, uint256 gracePeriod) internal returns (ChainlinkUsdOracle) {
        return
            new ChainlinkUsdOracle(
                address(feed), MAX_STALENESS, MIN_PRICE_WAD, MAX_PRICE_WAD, sequencerFeed, gracePeriod
            );
    }
}

contract MockChainlinkFeed {
    uint8 public immutable decimals;
    uint80 internal roundId;
    int256 internal answer;
    uint256 internal startedAt;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
