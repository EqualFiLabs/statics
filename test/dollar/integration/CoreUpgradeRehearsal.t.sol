// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {LibCoreStorage} from "src/dollar/core/libraries/LibCoreStorage.sol";
import {DiamondKernel} from "src/diamond/DiamondKernel.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

/// @notice Benign replacement used to prove that a production Core selector can be
/// upgraded without moving or rewriting namespaced accounting state.
contract CoreSeniorLiabilitiesUpgradeFacet {
    function seniorLiabilities() external view returns (uint256) {
        return LibCoreStorage.s().totalSeniorOutstanding;
    }
}

contract CoreDishonestLiabilitiesFacet {
    function seniorLiabilities() external pure returns (uint256) {
        return 0;
    }
}

contract CoreUpgradeRehearsalTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal alice = makeAddr("alice");
    address internal executor = makeAddr("executor");

    CanonicalWETH9 internal weth;
    CoreBootstrapDeployment internal deployment;
    IDiamondCut internal cut;
    IDiamondLoupe internal loupe;
    CoreMintFacet internal mintFacet;
    CoreViewFacet internal viewFacet;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;

    function setUp() public {
        weth = new CanonicalWETH9();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.initialOracle = address(oracle);
        config.weth = address(weth);
        config.partnerRecipient = address(0);
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(config);
        cut = IDiamondCut(deployment.core);
        loupe = IDiamondLoupe(deployment.core);
        mintFacet = CoreMintFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
    }

    function test_BenignFacetUpgradePreservesLiveCollateralAndAccounting() public {
        (uint256 minted, uint256 shares) = _depositOneWeth();
        (bytes32 beforeManifest, uint256 beforeSelectors) = _manifestDigest();
        address oldFacet = loupe.facetAddress(CoreViewFacet.seniorLiabilities.selector);

        CoreSeniorLiabilitiesUpgradeFacet replacement = new CoreSeniorLiabilitiesUpgradeFacet();
        IDiamondCut.FacetCut[] memory replacementCut = _singleCut(
            address(replacement), IDiamondCut.FacetCutAction.Replace, CoreViewFacet.seniorLiabilities.selector
        );
        _execute(replacementCut);

        (bytes32 afterManifest, uint256 afterSelectors) = _manifestDigest();
        assertTrue(beforeManifest != afterManifest);
        assertEq(beforeSelectors, afterSelectors);
        assertTrue(oldFacet != address(replacement));
        assertEq(loupe.facetAddress(CoreViewFacet.seniorLiabilities.selector), address(replacement));
        assertEq(CoreSeniorLiabilitiesUpgradeFacet(deployment.core).seniorLiabilities(), minted);
        assertEq(staticsDollar.totalSupply(), minted);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), shares);
        assertEq(weth.balanceOf(deployment.core), 1e18);
        assertEq(viewFacet.totalCollateral(address(weth)), 1e18);

        _recombineAll(minted, shares);
    }

    function test_NonOwnerCannotInstallDishonestReplacement() public {
        (uint256 minted,) = _depositOneWeth();
        address oldFacet = loupe.facetAddress(CoreViewFacet.seniorLiabilities.selector);
        CoreDishonestLiabilitiesFacet dishonest = new CoreDishonestLiabilitiesFacet();
        IDiamondCut.FacetCut[] memory dishonestCut = _singleCut(
            address(dishonest), IDiamondCut.FacetCutAction.Replace, CoreViewFacet.seniorLiabilities.selector
        );

        vm.expectRevert();
        vm.prank(executor);
        cut.diamondCut(dishonestCut, address(0), "");
        assertEq(loupe.facetAddress(CoreViewFacet.seniorLiabilities.selector), oldFacet);
        assertEq(viewFacet.seniorLiabilities(), minted);
        assertEq(weth.balanceOf(deployment.core), 1e18);
    }

    function test_FinalRemovalManifestKeepsValuePathsAndCannotRestoreUpgrades() public {
        vm.createDir("artifacts/diamond-manifests", true);
        (uint256 minted, uint256 shares) = _depositOneWeth();
        (bytes32 beforeManifest, uint256 beforeSelectors) =
            _writeManifest("pre-finalization", "artifacts/diamond-manifests/core-rehearsal-pre-finalization.json");
        bytes4[] memory cutMutations = new bytes4[](1);
        cutMutations[0] = IDiamondCut.diamondCut.selector;
        bytes4[] memory ownershipMutations = new bytes4[](1);
        ownershipMutations[0] = OwnershipFacet.transferOwnership.selector;
        IDiamondCut.FacetCut[] memory finalCut = new IDiamondCut.FacetCut[](2);
        finalCut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, cutMutations);
        finalCut[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, ownershipMutations);

        _execute(finalCut);

        (bytes32 afterManifest, uint256 afterSelectors) =
            _writeManifest("post-finalization", "artifacts/diamond-manifests/core-rehearsal-post-finalization.json");
        assertTrue(beforeManifest != afterManifest);
        assertEq(afterSelectors, beforeSelectors - cutMutations.length - ownershipMutations.length);
        for (uint256 i; i < cutMutations.length; i++) {
            assertEq(loupe.facetAddress(cutMutations[i]), address(0));
        }
        for (uint256 i; i < ownershipMutations.length; i++) {
            assertEq(loupe.facetAddress(ownershipMutations[i]), address(0));
        }
        for (uint256 i; i < cutMutations.length; i++) {
            _assertMissingSelector(cutMutations[i]);
        }
        for (uint256 i; i < ownershipMutations.length; i++) {
            _assertMissingSelector(ownershipMutations[i]);
        }
        assertEq(viewFacet.seniorLiabilities(), minted);
        assertEq(weth.balanceOf(deployment.core), 1e18);

        CoreDishonestLiabilitiesFacet dishonest = new CoreDishonestLiabilitiesFacet();
        IDiamondCut.FacetCut[] memory reinstall = _singleCut(
            address(dishonest), IDiamondCut.FacetCutAction.Replace, CoreViewFacet.seniorLiabilities.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(DiamondKernel.FunctionNotFound.selector, IDiamondCut.diamondCut.selector)
        );
        cut.diamondCut(reinstall, address(0), "");

        _recombineAll(minted, shares);
    }

    function _depositOneWeth() internal returns (uint256 minted, uint256 shares) {
        vm.deal(alice, 1e18);
        vm.prank(alice);
        weth.deposit{value: 1e18}();
        vm.prank(alice);
        weth.approve(deployment.core, 1e18);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1e18);
        vm.prank(alice);
        (, minted, shares) =
            mintFacet.depositCollateral(1, 1e18, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);
    }

    function _recombineAll(uint256 minted, uint256 shares) internal {
        IStaticsDollarCoreTypes.RedemptionPreview memory preview = mintFacet.previewRecombine(1, minted);
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            mintFacet.recombine(1, minted, shares, preview.collateralOut, alice);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, 1e18);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(weth.balanceOf(deployment.core), 0);
    }

    function _execute(IDiamondCut.FacetCut[] memory directCut) internal {
        vm.prank(owner);
        cut.diamondCut(directCut, address(0), "");
    }

    function _manifestDigest() internal view returns (bytes32 digest, uint256 selectorCount) {
        IDiamondLoupe.Facet[] memory installed = loupe.facets();
        digest = keccak256("statics-dollar-core-selector-manifest-v1");
        for (uint256 i; i < installed.length; i++) {
            address facet = installed[i].facetAddress;
            bytes32 runtimeHash = facet.codehash;
            digest = keccak256(abi.encode(digest, i, facet, runtimeHash, installed[i].functionSelectors));
            selectorCount += installed[i].functionSelectors.length;
        }
    }

    function _writeManifest(string memory phase, string memory path)
        internal
        returns (bytes32 digest, uint256 selectorCount)
    {
        IDiamondLoupe.Facet[] memory installed = loupe.facets();
        address[] memory facetAddresses = new address[](installed.length);
        bytes32[] memory runtimeHashes = new bytes32[](installed.length);
        for (uint256 i; i < installed.length; i++) {
            selectorCount += installed[i].functionSelectors.length;
        }

        bytes[] memory selectors = new bytes[](selectorCount);
        uint256[] memory selectorFacetIndexes = new uint256[](selectorCount);
        digest = keccak256("statics-dollar-core-selector-manifest-v1");
        uint256 selectorCursor;
        for (uint256 i; i < installed.length; i++) {
            address facet = installed[i].facetAddress;
            bytes32 runtimeHash = facet.codehash;
            facetAddresses[i] = facet;
            runtimeHashes[i] = runtimeHash;
            digest = keccak256(abi.encode(digest, i, facet, runtimeHash, installed[i].functionSelectors));
            for (uint256 j; j < installed[i].functionSelectors.length; j++) {
                selectors[selectorCursor] = abi.encodePacked(installed[i].functionSelectors[j]);
                selectorFacetIndexes[selectorCursor] = i;
                ++selectorCursor;
            }
        }

        string memory objectKey = string.concat("core-rehearsal-", phase);
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeString(objectKey, "phase", phase);
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "diamond", deployment.core);
        vm.serializeUint(objectKey, "selectorCount", selectorCount);
        vm.serializeAddress(objectKey, "facetAddresses", facetAddresses);
        vm.serializeBytes32(objectKey, "facetRuntimeHashes", runtimeHashes);
        vm.serializeUint(objectKey, "selectorFacetIndexes", selectorFacetIndexes);
        vm.serializeBytes(objectKey, "selectors", selectors);
        string memory json = vm.serializeBytes32(objectKey, "digest", digest);
        vm.writeJson(json, path);
    }

    function _assertMissingSelector(bytes4 selector) internal {
        (bool success, bytes memory reason) = deployment.core.call(abi.encodePacked(selector));
        assertFalse(success);
        assertGe(reason.length, 4);
        bytes4 actual;
        assembly ("memory-safe") {
            actual := mload(add(reason, 0x20))
        }
        assertEq(actual, DiamondKernel.FunctionNotFound.selector);
    }

    function _singleCut(address facet, IDiamondCut.FacetCutAction action, bytes4 selector)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory entries)
    {
        entries = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        entries[0] = IDiamondCut.FacetCut(facet, action, selectors);
    }
}
