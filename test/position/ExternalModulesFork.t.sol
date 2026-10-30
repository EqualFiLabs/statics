// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsExternalModules} from "../../src/interfaces/IStaticsExternalModules.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGenesis} from "../../src/interfaces/IStaticsGenesis.sol";
import {IStaticsFeeReceiver} from "../../src/interfaces/IStaticsFeeReceiver.sol";
import {IGenesisLaunchDistributor} from "../../src/interfaces/IGenesisLaunchDistributor.sol";
import {IGenesisActivationRegistry} from "../../src/interfaces/IGenesisActivationRegistry.sol";
import {GenesisNFTFacet} from "../../src/facets/GenesisNFTFacet.sol";
import {ExternalModuleFacet} from "../../src/facets/ExternalModuleFacet.sol";
import {StaticsGenesisIntegrationInit} from "../../src/diamond/StaticsGenesisIntegrationInit.sol";
import {LibGenesisIntegration} from "../../src/libraries/LibGenesisIntegration.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsTestDeployer} from "../helpers/StaticsTestBase.sol";

/// @notice Local fork only: governance impersonation never submits a network transaction.
contract ExternalModulesForkTest is Test {
    uint256 internal constant FORK_BLOCK = 101439372;

    function testForkRegistryHandoffRecordsActualOperatorTransfers() public {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 4663);
        string memory manifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        address nft = _binding(manifest, "operatorsNft");
        address registry = _binding(manifest, "activationRegistry");
        address receiver = _binding(manifest, "feeReceiver");
        address vault = _binding(manifest, "genesisVault");
        address token = _binding(manifest, "staticsToken");
        address predecessor = _binding(manifest, "launchDistributor");
        address candidate = address(
            new StaticsTestDeployer()
                .deploy(address(this), address(0x1234), vm.parseJsonAddress(manifest, ".roles.treasury"), token)
        );
        _install(candidate, nft, registry, receiver, vault, token);
        assertEq(IStaticsGenesis(nft).protocol(), address(0));
        vm.prank(IERC173(nft).owner());
        IStaticsGenesis(nft).bindProtocol(candidate);
        IStaticsExternalModules core = IStaticsExternalModules(candidate);
        assertFalse(core.historyCoverage(nft).ready);
        IStaticsGenesisIntegration integration = IStaticsGenesisIntegration(candidate);
        vm.prank(IERC173(receiver).owner());
        IStaticsFeeReceiver(receiver).proposeDistributor(candidate);
        integration.acceptGenesisDistributorRole();
        if (!IGenesisLaunchDistributor(predecessor).finalized()) {
            vm.prank(IERC173(predecessor).owner());
            IGenesisLaunchDistributor(predecessor).finalizeLaunchRewards();
        }
        vm.prank(IERC173(registry).owner());
        IGenesisActivationRegistry(registry).proposeConsumer(candidate);
        integration.acceptGenesisConsumerRole();
        assertTrue(core.historyCoverage(nft).ready);
        assertTrue(integration.genesisIntegrationReady());
        assertEq(core.historyCoverage(nft).startBlock, block.number);
        assertEq(IGenesisActivationRegistry(registry).activeConsumer(), candidate);
        uint256 id = 3;
        address seller = IERC721(nft).ownerOf(id);
        address buyer = makeAddr("fork buyer");
        vm.prank(seller);
        IERC721(nft).transferFrom(seller, buyer, id);
        assertEq(core.transferHead(), 1);
        assertEq(core.transferState(nft, id).nonce, 1);
        assertEq(IGenesisActivationRegistry(registry).multiplierBps(id), 10_000);
        vm.prank(buyer);
        IERC721(nft).transferFrom(buyer, seller, id);
        assertEq(core.transferHead(), 2);
        assertEq(core.transferState(nft, id).nonce, 2);
        assertEq(core.transferState(nft, id).transferredAt, block.timestamp);
        assertEq(integration.linkedPosition(id), 0);
    }

    function _binding(string memory manifest, string memory key) private view returns (address target) {
        string memory base = string.concat(".contracts.", key);
        target = vm.parseJsonAddress(manifest, string.concat(base, ".address"));
        assertEq(target.codehash, vm.parseJsonBytes32(manifest, string.concat(base, ".runtimeCodeHash")));
    }

    function _install(address candidate, address nft, address registry, address receiver, address vault, address token)
        private
    {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut(
            address(new GenesisNFTFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.genesisNFT()
        );
        cut[1] = IDiamondCut.FacetCut(
            address(new ExternalModuleFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules()
        );
        StaticsGenesisIntegrationInit init = new StaticsGenesisIntegrationInit();
        LibGenesisIntegration.InitArgs memory args = LibGenesisIntegration.InitArgs(
            nft, vault, registry, receiver, token, IStaticsFeeReceiver(receiver).numeraire(), 4000
        );
        IDiamondCut(candidate)
            .diamondCut(cut, address(init), abi.encodeCall(StaticsGenesisIntegrationInit.initialize, (args)));
    }
}
