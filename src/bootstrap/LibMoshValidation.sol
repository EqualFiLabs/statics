// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMoshSwarm, IMoshFactory, IMoshRegistry, IMoshClaimMarket} from "../interfaces/IMoshSwarm.sol";

/// @notice Provenance checks for the runtime-pinned native-counter Mosh generation.
/// @dev Pins are approved deployment configuration, not values supplied by individual deposit callers.
/// This library grants no transfer authority and does not collect fees or touch principal.
library LibMoshValidation {
    struct SourcePins {
        uint256 chainId;
        address factory;
        bytes32 factoryRuntimeHash;
        address registry;
        bytes32 registryRuntimeHash;
        address implementation;
        bytes32 implementationRuntimeHash;
    }

    struct MarketPins {
        address market;
        bytes32 runtimeHash;
        uint256 feeBps;
    }

    struct Offer {
        address swarm;
        address seller;
        address buyer;
        uint256 amount;
        uint256 price;
        uint64 deadline;
        uint16 feeBps;
    }

    error InvalidMoshSource();
    error InvalidMoshMarket();
    error InvalidMoshOffer();

    /// @dev Entry policy checks current factory configuration. Do not use changing factory policy to lock exits.
    /// Native-only support is deliberate; unsupported payout generations must not be approximated.
    function validateNativeSource(IMoshSwarm source, address projectToken, SourcePins memory pins) internal view {
        if (
            pins.chainId != block.chainid || projectToken.code.length == 0
                || !_matches(pins.factory, pins.factoryRuntimeHash)
                || !_matches(pins.registry, pins.registryRuntimeHash)
                || !_matches(pins.implementation, pins.implementationRuntimeHash)
        ) revert InvalidMoshSource();
        // A proxy runtime pin by itself is insufficient. Require this exact immutable EIP-1167 target.
        bytes32 expectedClone = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", pins.implementation, hex"5af43d82803e903d91602b57fd5bf3")
        );
        if (address(source).codehash != expectedClone) revert InvalidMoshSource();
        IMoshFactory factory = IMoshFactory(pins.factory);
        if (
            source.factory() != pins.factory || source.registry() != pins.registry || source.memecoin() != projectToken
                || !source.counterIsNative() || source.counterAsset() != address(0) || !factory.isSwarm(address(source))
                || factory.registry() != pins.registry || factory.swarmImplementation() != pins.implementation
                || factory.pairToken() != address(0)
        ) revert InvalidMoshSource();
    }

    function validateMarket(address registry, MarketPins memory pins) internal view {
        if (
            !_matches(pins.market, pins.runtimeHash) || pins.feeBps > 10_000
                || !IMoshRegistry(registry).isClaimMarket(pins.market)
                || IMoshClaimMarket(pins.market).feeBps() != pins.feeBps
        ) revert InvalidMoshMarket();
    }

    function readOffer(IMoshClaimMarket market, uint256 id) internal view returns (Offer memory offer) {
        (offer.swarm, offer.seller, offer.buyer, offer.amount, offer.price, offer.deadline, offer.feeBps) =
            market.offers(id);
    }

    /// @dev Supported custody movements use a one-wei price with a zero rounded fee.
    /// Callers must additionally measure both claim balances and automatic fee callbacks.
    function validateCustodyOffer(
        IMoshClaimMarket market,
        uint256 id,
        address source,
        address seller,
        address buyer,
        uint256 amount,
        uint256 feeBps
    ) internal view returns (Offer memory offer) {
        offer = readOffer(market, id);
        if (
            source == address(0) || seller == address(0) || buyer == address(0) || seller == buyer || amount == 0
                || feeBps >= 10_000 || offer.swarm != source || offer.seller != seller || offer.buyer != buyer
                || offer.amount != amount || offer.price != 1 || offer.deadline <= block.timestamp
                || offer.feeBps != feeBps
        ) revert InvalidMoshOffer();
    }

    function _matches(address target, bytes32 runtimeHash) private view returns (bool) {
        return runtimeHash != bytes32(0) && target.code.length != 0 && target.codehash == runtimeHash;
    }
}
