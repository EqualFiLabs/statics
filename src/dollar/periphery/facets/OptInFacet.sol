// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";
import {LibPosition} from "../../../position/LibPosition.sol";

contract OptInFacet is ReentrancyGuard {
    event OptedIn(uint256 indexed positionId, uint256 indexed seriesId, uint256 principal, uint256 storedUnits);
    event OptedOut(uint256 indexed positionId, uint256 indexed seriesId, address indexed receiver, uint256 principal);
    error ZeroAmount();
    error ZeroAddress();
    error NotAuthorized(uint256 positionId, address caller);
    error UnknownLeg(uint256 positionId, uint256 seriesId);
    error NoOptInPosition(uint256 positionId, uint256 seriesId);
    error NoZeroEffectiveDust(uint256 positionId, uint256 seriesId);
    error SeriesNotActive(uint256 seriesId);
    error InsufficientBasePrincipal(uint256 requested, uint256 available);
    error OptInAmountTooSmall(uint256 requested);

    function optIn(uint256 positionId, uint256 seriesId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(ps, positionId);
        LibPeriphery.PositionLeg storage leg = _leg(ps, positionId, seriesId);
        if (IStaticsDollarCore(ps.pool).riskSeries(seriesId).status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
            revert SeriesNotActive(seriesId);
        }
        uint256 available = leg.pendingPrincipal + leg.eligiblePrincipal;
        if (amount > available) revert InsufficientBasePrincipal(amount, available);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (leg.optInEpoch != book.optInEpoch) {
            leg.optInStored = 0;
            leg.optInEpoch = book.optInEpoch;
            leg.collateralOptInCheckpointRay = book.collateralOptIn[book.optInEpoch].accPerStoredRay;
            leg.staticsDollarOptInCheckpointRay = book.staticsDollarOptIn[book.optInEpoch].accPerStoredRay;
        }
        LibPeriphery.ensureLiveOptInScale(book);
        (uint256 stored, uint256 principal) = LibPeriphery.storedAdditionForEffectiveDown(book, leg.optInStored, amount);
        if (principal == 0) revert OptInAmountTooSmall(amount);
        uint256 pending = principal < leg.pendingPrincipal ? principal : leg.pendingPrincipal;
        leg.pendingPrincipal -= pending;
        if (leg.pendingPrincipal == 0) leg.pendingSince = 0;
        uint256 eligible = principal - pending;
        if (eligible != 0) {
            leg.eligiblePrincipal -= eligible;
            book.eligiblePrincipal -= eligible;
        }
        leg.optInStored += stored;
        book.optInTotalStored += stored;
        book.optInPrincipal += principal;
        emit OptedIn(positionId, seriesId, principal, stored);
    }

    function optOut(uint256 positionId, uint256 seriesId, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 principalOut)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(ps, positionId);
        LibPeriphery.PositionLeg storage leg = _leg(ps, positionId, seriesId);
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (leg.optInEpoch != book.optInEpoch || leg.optInStored == 0) revert NoOptInPosition(positionId, seriesId);
        uint256 available = LibPeriphery.optInPositionEffective(book, leg.optInStored);
        if (amount > available) revert InsufficientBasePrincipal(amount, available);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        uint256 effectiveBefore = LibPeriphery.optInEffective(book, leg.optInStored);
        uint256 storedToRemove = LibPeriphery.storedForEffective(book, amount);
        if (storedToRemove > leg.optInStored) storedToRemove = leg.optInStored;
        leg.optInStored -= storedToRemove;
        principalOut = storedToRemove == book.optInTotalStored
            ? book.optInPrincipal
            : effectiveBefore - LibPeriphery.optInEffective(book, leg.optInStored);
        book.optInTotalStored -= storedToRemove;
        book.optInPrincipal -= principalOut;
        if (book.optInTotalStored == 0) {
            book.optInScaleRay = LibPeriphery.RAY;
            book.optInEpoch += 1;
            leg.optInEpoch = book.optInEpoch;
            leg.collateralOptInCheckpointRay = book.collateralOptIn[book.optInEpoch].accPerStoredRay;
            leg.staticsDollarOptInCheckpointRay = book.staticsDollarOptIn[book.optInEpoch].accPerStoredRay;
        }
        IERC1155(ps.staticsDollarRisk).safeTransferFrom(address(this), receiver, seriesId, principalOut, "");
        emit OptedOut(positionId, seriesId, receiver, principalOut);
    }

    function optInBalanceOf(uint256 positionId, uint256 seriesId) external view returns (uint256) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.PositionLeg storage leg = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (leg.optInEpoch != book.optInEpoch) return 0;
        return LibPeriphery.optInPositionEffective(book, leg.optInStored);
    }

    function cleanupOptInDust(uint256 positionId, uint256 seriesId) external nonReentrant {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(ps, positionId);
        _leg(ps, positionId, seriesId);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        if (LibPeriphery.clearZeroEffectiveOptInDust(ps, positionId, seriesId) == 0) {
            revert NoZeroEffectiveDust(positionId, seriesId);
        }
    }

    function optInTotal(uint256 seriesId) external view returns (uint256) {
        LibPeriphery.SeriesBook storage book = LibPeriphery.s().series[seriesId];
        return book.optInPrincipal;
    }

    function optInScaleRay(uint256 seriesId) external view returns (uint256) {
        return LibPeriphery.s().series[seriesId].optInScaleRay;
    }

    function _leg(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        view
        returns (LibPeriphery.PositionLeg storage positionLeg)
    {
        positionLeg = ps.leg[positionId][seriesId];
        if (!positionLeg.exists) revert UnknownLeg(positionId, seriesId);
    }

    function _enforceAuthorized(LibPeriphery.PS storage, uint256 positionId) internal view {
        if (!LibPosition.isAuthorized(positionId, msg.sender)) revert NotAuthorized(positionId, msg.sender);
    }
}
