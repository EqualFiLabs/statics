// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CustodyFacet} from "../src/facets/CustodyFacet.sol";
import {GenesisNFTFacet} from "../src/facets/GenesisNFTFacet.sol";
import {GlobalRewardsFacet} from "../src/facets/GlobalRewardsFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {PositionNFTFacet} from "../src/position/PositionNFTFacet.sol";

struct StaticsGenesisUpgradeParts {
    address globalRewards;
    address positionNFT;
    address custody;
    address genesisNFT;
}

library StaticsGenesisUpgradeCut {
    function build(StaticsGenesisUpgradeParts memory parts) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        bytes4[] memory globalSelectors = StaticsSelectors.globalRewards();
        bytes4[] memory positionSelectors = StaticsSelectors.position();
        bytes4[] memory custodySelectors = StaticsSelectors.custody();
        cut = new IDiamondCut.FacetCut[](7);
        cut[0] = IDiamondCut.FacetCut(
            parts.globalRewards, IDiamondCut.FacetCutAction.Replace, _slice(globalSelectors, 0, 21)
        );
        cut[1] = IDiamondCut.FacetCut(
            parts.globalRewards, IDiamondCut.FacetCutAction.Add, _slice(globalSelectors, 21, globalSelectors.length)
        );
        cut[2] = IDiamondCut.FacetCut(
            parts.positionNFT, IDiamondCut.FacetCutAction.Replace, _slice(positionSelectors, 0, 26)
        );
        cut[3] = IDiamondCut.FacetCut(
            parts.positionNFT, IDiamondCut.FacetCutAction.Add, _slice(positionSelectors, 26, positionSelectors.length)
        );
        cut[4] = IDiamondCut.FacetCut(parts.custody, IDiamondCut.FacetCutAction.Replace, _slice(custodySelectors, 0, 7));
        cut[5] = IDiamondCut.FacetCut(
            parts.custody, IDiamondCut.FacetCutAction.Add, _slice(custodySelectors, 7, custodySelectors.length)
        );
        cut[6] = IDiamondCut.FacetCut(parts.genesisNFT, IDiamondCut.FacetCutAction.Add, StaticsSelectors.genesisNFT());
    }

    function _slice(bytes4[] memory source, uint256 start, uint256 end) private pure returns (bytes4[] memory result) {
        result = new bytes4[](end - start);
        for (uint256 i = start; i < end; ++i) {
            result[i - start] = source[i];
        }
    }
}

/// @notice Deploys implementation facets for an existing pre-Genesis Statics Diamond.
contract PrepareStaticsGenesisUpgrade is Script {
    function run() external returns (StaticsGenesisUpgradeParts memory parts) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        parts = deploy();
        vm.stopBroadcast();
        console2.log("STATICS_GLOBAL_REWARDS_FACET_ADDRESS", parts.globalRewards);
        console2.log("STATICS_POSITION_NFT_FACET_ADDRESS", parts.positionNFT);
        console2.log("STATICS_CUSTODY_FACET_ADDRESS", parts.custody);
        console2.log("STATICS_GENESIS_NFT_FACET_ADDRESS", parts.genesisNFT);
    }

    function deploy() public returns (StaticsGenesisUpgradeParts memory parts) {
        parts = StaticsGenesisUpgradeParts({
            globalRewards: address(new GlobalRewardsFacet()),
            positionNFT: address(new PositionNFTFacet()),
            custody: address(new CustodyFacet()),
            genesisNFT: address(new GenesisNFTFacet())
        });
    }

    function buildCut(StaticsGenesisUpgradeParts memory parts) public pure returns (IDiamondCut.FacetCut[] memory cut) {
        return StaticsGenesisUpgradeCut.build(parts);
    }
}
