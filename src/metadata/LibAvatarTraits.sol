// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibAvatarTraits {
    bytes32 internal constant DOMAIN = bytes32("STATICS_GENESIS_AVATAR_V1");

    uint8 internal constant FIELD_COUNT = 8;
    uint8 internal constant BOUNDARY_COUNT = 6;
    uint8 internal constant SHELL_COUNT = 8;
    uint8 internal constant INTERFACE_COUNT = 8;
    uint8 internal constant MANTLE_COUNT = 6;
    uint8 internal constant TELEMETRY_COUNT = 8;
    uint8 internal constant SIGIL_COUNT = 8;
    uint8 internal constant SIGNAL_COUNT = 6;

    struct Traits {
        uint8 field;
        uint8 boundary;
        uint8 shell;
        uint8 interfaceType;
        uint8 mantle;
        uint8 telemetry;
        uint8 sigil;
        uint8 signal;
    }

    function seed(uint256 chainId, address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(DOMAIN, chainId, collection, tokenId));
    }

    function derive(bytes32 value) internal pure returns (Traits memory traits_) {
        traits_.field = _select(value, 0, FIELD_COUNT);
        traits_.boundary = _select(value, 3, BOUNDARY_COUNT);
        traits_.shell = _select(value, 6, SHELL_COUNT);
        traits_.interfaceType = _select(value, 9, INTERFACE_COUNT);
        traits_.mantle = _select(value, 12, MANTLE_COUNT);
        traits_.telemetry = _select(value, 15, TELEMETRY_COUNT);
        traits_.sigil = _select(value, 18, SIGIL_COUNT);
        traits_.signal = _select(value, 21, SIGNAL_COUNT);
    }

    function fieldName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Void";
        if (value == 1) return "Grid";
        if (value == 2) return "Target";
        if (value == 3) return "Split Horizon";
        if (value == 4) return "Static Field";
        if (value == 5) return "Data Panel";
        if (value == 6) return "Signal Bands";
        return "Vault";
    }

    function boundaryName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Single Ring";
        if (value == 1) return "Double Ring";
        if (value == 2) return "Broken Ring";
        if (value == 3) return "Reticle Ring";
        if (value == 4) return "Peg Frame";
        return "Shield Ring";
    }

    function shellName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Round Shell";
        if (value == 1) return "Angular Helm";
        if (value == 2) return "Operator Hood";
        if (value == 3) return "Hex Mask";
        if (value == 4) return "Box Visor";
        if (value == 5) return "Heavy Plate";
        if (value == 6) return "Slim Mask";
        return "Split Head";
    }

    function interfaceName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Equal Sign";
        if (value == 1) return "Narrow Visor";
        if (value == 2) return "Dual Blocks";
        if (value == 3) return "Glider";
        if (value == 4) return "Double Pipe";
        if (value == 5) return "Peg Bar";
        if (value == 6) return "Dollar Glyph";
        return "Basket Grid";
    }

    function mantleName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Minimal Collar";
        if (value == 1) return "High Collar";
        if (value == 2) return "Hood Wrap";
        if (value == 3) return "Armor Neck";
        if (value == 4) return "Tactical Coat";
        return "Split Mantle";
    }

    function telemetryName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "None";
        if (value == 1) return "Bar Chart";
        if (value == 2) return "Line Graph";
        if (value == 3) return "Metric Blocks";
        if (value == 4) return "Basket Indicators";
        if (value == 5) return "Liquidity Panel";
        if (value == 6) return "Yield Readout";
        return "Risk Readout";
    }

    function sigilName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Equal Seal";
        if (value == 1) return "Dollar Core";
        if (value == 2) return "Basket Core";
        if (value == 3) return "Risk Share";
        if (value == 4) return "Staking Sigil";
        if (value == 5) return "Liquidity Mark";
        if (value == 6) return "Position Key";
        return "Empty";
    }

    function signalName(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "Neon Green";
        if (value == 1) return "Cyan";
        if (value == 2) return "Amber";
        if (value == 3) return "Red";
        if (value == 4) return "Purple";
        return "White Only";
    }

    function signalColor(uint8 value) internal pure returns (string memory) {
        if (value == 0) return "#8CFF00";
        if (value == 1) return "#00E5FF";
        if (value == 2) return "#FFB000";
        if (value == 3) return "#FF3344";
        if (value == 4) return "#B55CFF";
        return "#FFFFFF";
    }

    function _select(bytes32 value, uint256 offset, uint8 count) private pure returns (uint8) {
        uint16 sample = (uint16(uint8(value[offset])) << 8) | uint16(uint8(value[offset + 1]));
        return uint8(sample % count);
    }
}
