// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {AdaptiveCurveIrm} from "morpho-blue-irm/AdaptiveCurveIrm.sol";

contract RobinhoodTestnetMorphoForkTest is Test {
    string private constant MANIFEST = "../../deployments/robinhood-testnet-46630-morpho.json";

    function testLiveDeploymentMatchesTrackedManifest() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_MORPHO_TESTNET_FORK_PROOF", false)) {
                fail("Robinhood testnet Morpho fork required");
            }
            return;
        }

        string memory manifest = vm.readFile(MANIFEST);
        uint256 deploymentEndBlock = vm.parseJsonUint(manifest, ".network.deploymentEndBlock");
        vm.createSelectFork(rpcUrl, deploymentEndBlock);

        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));

        address morphoAddress = vm.parseJsonAddress(manifest, ".morpho");
        address irmAddress = vm.parseJsonAddress(manifest, ".adaptiveCurveIrm");
        IMorpho morpho = IMorpho(morphoAddress);

        assertEq(morphoAddress.codehash, vm.parseJsonBytes32(manifest, ".morphoRuntimeCodeHash"));
        assertEq(irmAddress.codehash, vm.parseJsonBytes32(manifest, ".adaptiveCurveIrmRuntimeCodeHash"));
        assertEq(morpho.owner(), vm.parseJsonAddress(manifest, ".owner"));
        assertEq(morpho.feeRecipient(), vm.parseJsonAddress(manifest, ".feeRecipient"));
        assertEq(AdaptiveCurveIrm(irmAddress).MORPHO(), morphoAddress);
        assertTrue(morpho.isIrmEnabled(irmAddress));
        assertTrue(morpho.isIrmEnabled(address(0)));

        uint256[] memory enabledLltvs = vm.parseJsonUintArray(manifest, ".enabledLltvs");
        assertEq(enabledLltvs.length, 9);
        for (uint256 i; i < enabledLltvs.length; ++i) {
            assertTrue(morpho.isLltvEnabled(enabledLltvs[i]));
        }
    }
}
