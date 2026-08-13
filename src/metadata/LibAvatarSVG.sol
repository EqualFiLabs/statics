// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibAvatarTraits} from "./LibAvatarTraits.sol";

library LibAvatarSVG {
    using Strings for uint256;

    string internal constant WHITE = "#F5F7F2";
    string internal constant BLACK = "#030504";
    string internal constant PLATE = "#080B09";
    string internal constant GRID = "#273028";

    function render(bytes32 seed, LibAvatarTraits.Traits memory traits_, uint8 tier) internal pure returns (string memory) {
        string memory accent = LibAvatarTraits.signalColor(traits_.signal);
        string memory foreground = string.concat(
            _field(traits_.field, accent, seed),
            _telemetry(traits_.telemetry, accent),
            _mantle(traits_.mantle, accent),
            _shell(traits_.shell, accent)
        );
        string memory overlay = string.concat(
            _interface(traits_.interfaceType, accent),
            _sigil(traits_.sigil, accent),
            _boundary(traits_.boundary, accent),
            _activationOverlay(tier, accent)
        );
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">',
            '<rect width="256" height="256" fill="#030504"/>',
            foreground,
            overlay,
            "</svg>"
        );
    }

    function _activationOverlay(uint8 tier, string memory accent) private pure returns (string memory) {
        if (tier == 0) return "";
        bytes memory marks;
        for (uint256 i; i < tier; ++i) {
            marks = abi.encodePacked(
                marks,
                '<rect x="',
                (104 + i * 14).toString(),
                '" y="232" width="8" height="8" fill="',
                accent,
                '"/>'
            );
        }
        return string.concat(
            '<g id="activation-tier"><rect x="96" y="226" width="64" height="20" rx="4" fill="#080B09" stroke="',
            accent,
            '"/>',
            string(marks),
            "</g>"
        );
    }

    function _field(uint8 value, string memory accent, bytes32 seed) private pure returns (string memory) {
        if (value == 0) return "";
        if (value == 1) {
            bytes memory output;
            for (uint256 n = 32; n <= 224; n += 24) {
                string memory coordinate = n.toString();
                output = abi.encodePacked(
                    output, _path(string.concat("M", coordinate, " 24V232M24 ", coordinate, "H232"), GRID, "none", "1")
                );
            }
            return string(output);
        }
        if (value == 2) {
            return string.concat(
                _circle("128", "126", "92", "none", GRID, "1"),
                _circle("128", "126", "70", "none", GRID, "1"),
                _path("M22 126H234M128 22V230", GRID, "none", "1")
            );
        }
        if (value == 3) {
            return string.concat(
                '<path d="M20 132H236V236H20Z" fill="#0E130F"/>',
                _path("M20 132H236", accent, "none", "2"),
                _path("M35 153H221M44 174H212M56 195H200", GRID, "none", "1")
            );
        }
        if (value == 4) return _staticField(accent, seed);
        if (value == 5) {
            return string.concat(
                _path("M28 38H91V78H28ZM165 38H228V78H165ZM28 180H76V220H28Z", GRID, "none", "1"),
                _path("M37 50h36M37 59h24M174 50h35M174 59h20M37 192h28M37 201h18", accent, "none", "2")
            );
        }
        if (value == 6) {
            return string.concat(
                _path("M30 48H226M30 58H198M58 68H226M30 188H201M55 198H226M30 208H183", GRID, "none", "4"),
                _path("M30 48H91M156 68H226M30 208H79", accent, "none", "4")
            );
        }
        return string.concat(
            _path("M38 34H218L232 58V205L210 228H46L24 205V58Z", GRID, "none", "2"),
            _path("M51 49H205M39 64V194M217 64V194M51 213H205", accent, "none", "2")
        );
    }

    function _staticField(string memory accent, bytes32 seed) private pure returns (string memory) {
        bytes memory output;
        for (uint256 n; n < 24; ++n) {
            uint256 x = 25 + uint8(seed[n]) % 204;
            uint256 y = 28 + uint8(seed[(n + 7) % 32]) % 190;
            uint256 width = 3 + uint8(seed[(n + 13) % 32]) % 13;
            output = abi.encodePacked(
                output,
                _path(
                    string.concat("M", x.toString(), " ", y.toString(), "h", width.toString()),
                    n % 5 == 0 ? accent : "#39413A",
                    "none",
                    n % 7 == 0 ? "2" : "1"
                )
            );
        }
        return string(output);
    }

    function _telemetry(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 0) return "";
        if (value == 1) {
            return _path(
                "M34 149v-18h7v18M45 149v-31h7v31M56 149v-23h7v23M193 149v-27h7v27M204 149v-16h7v16M215 149v-35h7v35",
                accent,
                "none",
                "3"
            );
        }
        if (value == 2) {
            return string.concat(
                _path("M28 145L39 132L50 138L61 113L72 124", accent, "none", "2"),
                _path("M184 130L195 119L206 136L217 109L228 118", accent, "none", "2")
            );
        }
        if (value == 3) {
            return _path("M29 102h39v12H29zM29 120h27v9H29zM188 96h39v12h-39zM199 114h28v9h-28z", accent, "none", "2");
        }
        if (value == 4) {
            return string.concat(
                _dot("38", "117", "4", accent),
                _dot("50", "117", "4", WHITE),
                _dot("62", "117", "4", accent),
                _dot("194", "117", "4", WHITE),
                _dot("206", "117", "4", accent),
                _dot("218", "117", "4", WHITE)
            );
        }
        if (value == 5) {
            return string.concat(
                _path(
                    "M30 103h38v44H30zM188 103h38v44h-38zM37 136v-16h6v16M47 136v-26h6v26M57 136v-10h5v10M195 135h24M195 126h17M195 117h9",
                    accent,
                    "none",
                    "2"
                )
            );
        }
        if (value == 6) {
            return string.concat(
                _path("M28 105h40v34H28zM188 105h40v34h-40z", WHITE, "none", "2"),
                _path("M35 129l8-12 7 7 11-13M195 128l9-18 7 13 10-9", accent, "none", "2")
            );
        }
        return string.concat(
            _path(
                "M28 105h40v34H28zM188 105h40v34h-40zM35 113h26M35 122h18M195 113h26M203 122h18", accent, "none", "2"
            ),
            _path("M35 132h8M53 132h8M195 132h8M213 132h8", WHITE, "none", "2")
        );
    }

    function _mantle(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 0) return _path("M78 169L62 219H194L178 169L157 184H99Z", WHITE, "#0A0D0B", "3");
        if (value == 1) {
            return string.concat(
                _path("M71 225L82 160L108 179H148L174 160L185 225Z", WHITE, "#0A0D0B", "4"),
                _path("M95 179v42M161 179v42", accent, "none", "2")
            );
        }
        if (value == 2) {
            return string.concat(
                _path("M52 226L67 164L91 146L105 178H151L165 146L189 164L204 226Z", WHITE, "#0A0D0B", "3"),
                _path("M67 164L98 194M189 164L158 194", accent, "none", "2")
            );
        }
        if (value == 3) {
            return string.concat(
                _path("M59 224L74 171L100 181H156L182 171L197 224Z", WHITE, "#0A0D0B", "4"),
                _path("M76 184h25v40M180 184h-25v40M104 197h48", accent, "none", "3")
            );
        }
        if (value == 4) {
            return string.concat(
                _path("M47 227L67 173L98 181H158L189 173L209 227Z", WHITE, "#0A0D0B", "3"),
                _path("M64 195h128M58 211h140M88 183l-11 44M168 183l11 44", "#555F56", "none", "2")
            );
        }
        return string.concat(
            _path("M51 226L74 169L111 185V226ZM205 226L182 169L145 185V226Z", WHITE, "#0A0D0B", "3"),
            _path("M128 180V228M79 177l29 29M177 177l-29 29", accent, "none", "3")
        );
    }

    function _shell(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 0) {
            return string.concat(
                _path(
                    "M70 111C70 66 92 43 128 43S186 66 186 111V154C186 181 165 195 128 195S70 181 70 154Z",
                    WHITE,
                    PLATE,
                    "4"
                ),
                _path("M79 82C98 59 158 59 177 82", accent, "none", "2")
            );
        }
        if (value == 1) {
            return string.concat(
                _path("M66 102L85 55L128 38L171 55L190 102L180 169L153 194H103L76 169Z", WHITE, PLATE, "4"),
                _path("M85 55l19 29h48l19-29M76 169l32-17h40l32 17", accent, "none", "2")
            );
        }
        if (value == 2) {
            return string.concat(
                _path("M54 116L72 66L101 40H155L184 66L202 116L186 188L158 205H98L70 188Z", WHITE, PLATE, "4"),
                _path("M72 66l28 26-13 91M184 66l-28 26 13 91", accent, "none", "2")
            );
        }
        if (value == 3) {
            return string.concat(
                _path("M64 89L97 45H159L192 89V158L159 197H97L64 158Z", WHITE, PLATE, "4"),
                _path("M97 45l15 30h32l15-30M64 158l37-20h54l37 20", accent, "none", "2")
            );
        }
        if (value == 4) {
            return string.concat(
                _path("M64 58H192V181L166 199H90L64 181Z", WHITE, PLATE, "4"),
                _path("M75 73h106v73H75zM90 181h76", accent, "none", "2")
            );
        }
        if (value == 5) {
            return string.concat(
                _path("M55 79L84 44H172L201 79L190 181L162 205H94L66 181Z", WHITE, PLATE, "6"),
                _path("M84 44l18 35h52l18-35M66 181l35-32h54l35 32", accent, "none", "3")
            );
        }
        if (value == 6) {
            return string.concat(
                _path("M82 54L109 40H147L174 54L185 101L174 177L151 194H105L82 177L71 101Z", WHITE, PLATE, "3"),
                _path("M90 60l20 19h36l20-19M83 168l31-17h28l31 17", accent, "none", "2")
            );
        }
        return string.concat(
            _path(
                "M65 92L86 51L123 39V197L91 188L70 163ZM191 92L170 51L133 39V197L165 188L186 163Z", WHITE, PLATE, "4"
            ),
            _path("M128 39V198M86 51l27 32M170 51l-27 32", accent, "none", "2")
        );
    }

    function _interface(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 0) {
            return _path("M96 101h64v9H96zM96 126h64v9H96z", "none", accent, "0");
        }
        if (value == 1) {
            return string.concat(
                '<path d="M91 110H165L156 125H100Z" fill="', accent, '"/>', _path("M104 116h48", BLACK, "none", "3")
            );
        }
        if (value == 2) {
            return string.concat(
                _path("M92 104h29v26H92zM135 104h29v26h-29z", "none", accent, "0"),
                _path("M121 117h14", WHITE, "none", "2")
            );
        }
        if (value == 3) {
            return string.concat(
                _dot("108", "133", "7", accent),
                _dot("128", "133", "7", accent),
                _dot("148", "133", "7", accent),
                _dot("148", "114", "7", accent),
                _dot("128", "95", "7", accent)
            );
        }
        if (value == 4) return _path("M108 99V138M148 99V138", accent, "none", "8");
        if (value == 5) {
            return string.concat(
                _path("M89 117H167", accent, "none", "8"),
                _path("M128 98V136", WHITE, "none", "2"),
                _circle("128", "117", "5", BLACK, WHITE, "2")
            );
        }
        if (value == 6) {
            return _path(
                "M145 99C134 92 111 96 108 108C105 122 149 113 146 130C144 141 121 144 108 135M128 90V149",
                accent,
                "none",
                "6"
            );
        }
        return string.concat(
            _path(
                "M102 96h13v13h-13zM140 96h13v13h-13zM121 115h13v13h-13zM102 134h13v13h-13zM140 134h13v13h-13z",
                "none",
                accent,
                "0"
            ),
            _path("M121 96h13v13h-13zM102 115h13v13h-13zM140 115h13v13h-13zM121 134h13v13h-13z", "none", WHITE, "0")
        );
    }

    function _sigil(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 7) return "";
        if (value == 0) {
            return string.concat(
                _circle("128", "207", "14", "#050705", accent, "2"),
                _path("M119 202h18M119 211h18", accent, "none", "3")
            );
        }
        if (value == 1) {
            return string.concat(
                _circle("128", "207", "14", "#050705", accent, "2"),
                _path("M133 196c-12-5-17 5-5 10s7 15-5 11M128 191v31", accent, "none", "2")
            );
        }
        if (value == 2) {
            return string.concat(
                _path("M114 193h28v28h-28z", accent, "#050705", "2"),
                '<path d="M119 198h7v7h-7zM130 198h7v7h-7zM119 209h7v7h-7zM130 209h7v7h-7z" fill="',
                accent,
                '"/>'
            );
        }
        if (value == 3) {
            return string.concat(
                _path("M128 191L143 200L138 218H118L113 200Z", accent, "#050705", "2"),
                _path("M128 196v17", accent, "none", "3")
            );
        }
        if (value == 4) return _path("M128 190l5 11 12 1-9 8 3 12-11-6-11 6 3-12-9-8 12-1Z", accent, "#050705", "2");
        if (value == 5) {
            return string.concat(
                _circle("128", "207", "14", "#050705", accent, "2"),
                _path("M116 212c5-16 19-16 24 0M119 202h18", accent, "none", "2")
            );
        }
        return
            string.concat(
                _path("M114 201l14-10 14 10-5 17h-18Z", accent, "#050705", "2"), _dot("128", "205", "4", accent)
            );
    }

    function _boundary(uint8 value, string memory accent) private pure returns (string memory) {
        if (value == 0) return _circle("128", "128", "113", "none", WHITE, "4");
        if (value == 1) {
            return string.concat(
                _circle("128", "128", "114", "none", WHITE, "3"), _circle("128", "128", "105", "none", accent, "2")
            );
        }
        if (value == 2) {
            return string.concat(
                '<circle cx="128" cy="128" r="112" stroke="#F5F7F2" fill="none" stroke-width="5" stroke-linecap="square" stroke-linejoin="miter" stroke-dasharray="38 13"/>',
                '<circle cx="128" cy="128" r="103" stroke="',
                accent,
                '" fill="none" stroke-width="1" stroke-linecap="square" stroke-linejoin="miter" stroke-dasharray="7 18"/>'
            );
        }
        if (value == 3) {
            return string.concat(
                _circle("128", "128", "109", "none", WHITE, "3"),
                _path(
                    "M128 7v25M128 224v25M7 128h25M224 128h25M43 43l17 17M196 196l17 17M43 213l17-17M196 60l17-17",
                    accent,
                    "none",
                    "4"
                )
            );
        }
        if (value == 4) {
            return string.concat(
                _path("M46 17H210L239 46V210L210 239H46L17 210V46Z", WHITE, "none", "4"),
                _path("M75 25h106M75 231h106M25 75v106M231 75v106", accent, "none", "2")
            );
        }
        return string.concat(
            _path("M128 10L224 40V124C224 184 184 226 128 245C72 226 32 184 32 124V40Z", WHITE, "none", "4"),
            _path("M128 21L213 48", accent, "none", "2")
        );
    }

    function _path(string memory d, string memory stroke, string memory fill, string memory width)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '<path d="',
            d,
            '" stroke="',
            stroke,
            '" fill="',
            fill,
            '" stroke-width="',
            width,
            '" stroke-linecap="square" stroke-linejoin="miter"/>'
        );
    }

    function _circle(
        string memory cx,
        string memory cy,
        string memory radius,
        string memory fill,
        string memory stroke,
        string memory width
    ) private pure returns (string memory) {
        return string.concat(
            '<circle cx="',
            cx,
            '" cy="',
            cy,
            '" r="',
            radius,
            '" fill="',
            fill,
            '" stroke="',
            stroke,
            '" stroke-width="',
            width,
            '"/>'
        );
    }

    function _dot(string memory cx, string memory cy, string memory radius, string memory fill)
        private
        pure
        returns (string memory)
    {
        return string.concat('<circle cx="', cx, '" cy="', cy, '" r="', radius, '" fill="', fill, '"/>');
    }
}
