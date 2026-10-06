// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMoshSwarm, IMoshClaimMarket} from "../interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "./LibMoshValidation.sol";
import {MeasuredCampaignRevenue} from "./MeasuredCampaignRevenue.sol";
import {IRevenueWeth} from "./NativeCampaignRevenue.sol";
import {BasketBootstrapCampaign} from "./BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "./BasketBootstrapFactory.sol";

/// @notice Permanently routes explicitly authorized Mosh team fee rights, never Swarm principal.
/// @dev Predeploy as a new launch's teamRecipient, or have an existing team recipient hand off selected
/// claims through its approved market. The historical teamRecipient is not changed by that handoff.
contract MoshTeamRevenueAdapter is MeasuredCampaignRevenue {
    IMoshSwarm public swarm;
    address public sourceToken;
    address public sourceTeamRecipient;
    bytes32 public swarmRuntimeHash;
    bytes32 public immutable wethRuntimeHash;
    uint256 public immutable expectedTeamShareBps;
    IMoshClaimMarket public immutable market;
    LibMoshValidation.SourcePins private sourcePins;
    LibMoshValidation.MarketPins private marketPins;
    uint256 public teamClaims;
    uint256 public nativeReserved;
    uint256 public totalMeasured;
    bool public rightsBound;
    bool private collecting;

    error InvalidMoshTeamIntegration();
    event TeamSourceBound(address indexed swarm, address indexed originalRecipient, uint256 teamShareBps);
    event TeamRightsBound(address indexed seller, uint256 indexed offerId, uint256 claims);
    event TeamRevenueMeasured(uint256 amount);

    constructor(
        address owner,
        address wrappedNative,
        bytes32 wrappedRuntimeHash,
        BasketBootstrapFactory campaigns,
        LibMoshValidation.SourcePins memory approvedSource,
        LibMoshValidation.MarketPins memory approvedMarket,
        uint256 teamShareBps
    ) MeasuredCampaignRevenue(owner, wrappedNative, campaigns) {
        if (
            wrappedRuntimeHash == bytes32(0) || wrappedNative.codehash != wrappedRuntimeHash
                || approvedSource.chainId != block.chainid || teamShareBps < 500 || teamShareBps > 2500
                || approvedMarket.feeBps >= 10_000
        ) revert InvalidMoshTeamIntegration();
        wethRuntimeHash = wrappedRuntimeHash;
        expectedTeamShareBps = teamShareBps;
        sourcePins = approvedSource;
        marketPins = approvedMarket;
        market = IMoshClaimMarket(approvedMarket.market);
    }

    /// @notice Bind only after the real launch establishes its token and provenance.
    /// Campaign creator authority does not substitute for an existing team's right-transfer authority.
    function bindSource(IMoshSwarm source) external nonReentrant {
        if (msg.sender != creator || address(swarm) != address(0) || address(campaign) == address(0)) {
            revert InvalidMoshTeamIntegration();
        }
        address token = source.memecoin();
        LibMoshValidation.validateNativeSource(source, token, sourcePins);
        if (token != campaign.projectToken() || source.teamShareBps() != expectedTeamShareBps) {
            revert InvalidMoshTeamIntegration();
        }
        address team = source.teamRecipient();
        if (team == address(0)) revert InvalidMoshTeamIntegration();
        swarm = source;
        sourceToken = token;
        sourceTeamRecipient = team;
        swarmRuntimeHash = address(source).codehash;
        if (team == address(this)) {
            uint256 amount = source.claim(address(this));
            if (amount == 0) revert InvalidMoshTeamIntegration();
            rightsBound = true;
            teamClaims = amount;
            emit TeamRightsBound(team, 0, amount);
        } else if (source.claim(address(this)) != 0) {
            // An unsolicited claim transfer cannot masquerade as the authorized one-time handoff.
            revert InvalidMoshTeamIntegration();
        }
        emit TeamSourceBound(address(source), team, expectedTeamShareBps);
    }

    /// @notice The existing historical team explicitly sells selected fee claims for one wei.
    /// Pre-transfer fees remain with the seller; these fee rights never provide principal redemption.
    function acceptTeamHandoff(uint256 offerId, uint256 amount) external payable nonReentrant {
        _runtime();
        if (
            rightsBound || msg.sender != sourceTeamRecipient || amount == 0 || msg.value != 1
                || swarm.claim(address(this)) != 0 || address(campaign) == address(0) || !campaign.prepared()
        ) revert InvalidMoshTeamIntegration();
        LibMoshValidation.validateNativeSource(swarm, sourceToken, sourcePins);
        LibMoshValidation.validateMarket(sourcePins.registry, marketPins);
        LibMoshValidation.validateCustodyOffer(
            market, offerId, address(swarm), msg.sender, address(this), amount, marketPins.feeBps
        );
        // Realize currently distributable fees before the market's automatic old-owner checkpoint.
        swarm.syncFees();
        uint256 sellerBefore = swarm.claim(msg.sender);
        market.fill{value: 1}(offerId);
        if (swarm.claim(msg.sender) + amount != sellerBefore || swarm.claim(address(this)) != amount) {
            revert InvalidMoshTeamIntegration();
        }
        rightsBound = true;
        teamClaims = amount;
        emit TeamRightsBound(msg.sender, offerId, amount);
    }

    /// @dev Accept only this adapter's authenticated collection, not another holder's redirected payout.
    receive() external payable {
        if (!collecting || msg.sender != address(swarm) || msg.value == 0) revert InvalidMoshTeamIntegration();
        _runtime();
        if (!rightsBound || swarm.claim(address(this)) != teamClaims) revert InvalidMoshTeamIntegration();
        nativeReserved += msg.value;
        totalMeasured += msg.value;
        emit TeamRevenueMeasured(msg.value);
    }

    function sync() external nonReentrant returns (uint256 amount) {
        _runtime();
        if (
            !rightsBound || swarm.claim(address(this)) != teamClaims || address(campaign) == address(0)
                || !campaign.prepared()
        ) revert InvalidMoshTeamIntegration();
        swarm.syncFees();
        if (swarm.claimable(address(this)) == 0) return 0;
        uint256 beforeBalance = address(this).balance;
        uint256 beforeMeasured = totalMeasured;
        collecting = true;
        amount = swarm.collectFees();
        collecting = false;
        if (totalMeasured - beforeMeasured != amount || address(this).balance != beforeBalance + amount) {
            revert InexactRevenue();
        }
    }

    /// @notice Deliver only measured receipts; wrapping/delivery failure leaves collection independently retryable.
    function flushTeamRevenue() external nonReentrant returns (uint256 amount) {
        amount = nativeReserved;
        if (amount == 0) return 0;
        _runtime();
        address destination = recipient();
        uint256 nativeFloor = address(this).balance - amount;
        uint256 tokenFloor = payoutAsset.balanceOf(address(this));
        nativeReserved = 0;
        IRevenueWeth(address(payoutAsset)).deposit{value: amount}();
        if (address(this).balance != nativeFloor) revert InexactRevenue();
        _deliverReceived(address(swarm), destination, amount, tokenFloor);
        if (address(this).balance != nativeFloor) revert InexactRevenue();
    }

    function _validateCampaignBinding(BasketBootstrapCampaign destination) internal view override {
        if (address(swarm) != address(0) && destination.projectToken() != sourceToken) {
            revert InvalidMoshTeamIntegration();
        }
    }

    function _runtime() private view {
        if (
            address(swarm) == address(0) || address(swarm).codehash != swarmRuntimeHash
                || sourcePins.implementation.codehash != sourcePins.implementationRuntimeHash
                || address(payoutAsset).codehash != wethRuntimeHash || swarm.teamRecipient() != sourceTeamRecipient
                || swarm.teamShareBps() != expectedTeamShareBps
        ) revert InvalidMoshTeamIntegration();
    }
}
