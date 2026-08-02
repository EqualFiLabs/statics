// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract CoreStorageProbeV1 {
    bytes32 internal constant PROBE_SLOT = keccak256("statics.dollar.test.core.storage.probe");

    function writeProbe(uint256 newValue) external {
        bytes32 slot = PROBE_SLOT;
        assembly {
            sstore(slot, newValue)
        }
    }

    function probe() external view returns (uint256 result) {
        bytes32 slot = PROBE_SLOT;
        assembly {
            result := sload(slot)
        }
    }
}

contract CoreStorageProbeV2 {
    bytes32 internal constant PROBE_SLOT = keccak256("statics.dollar.test.core.storage.probe");

    function writeProbe(uint256 newValue) external {
        bytes32 slot = PROBE_SLOT;
        assembly {
            sstore(slot, newValue)
        }
    }

    function probe() external view returns (uint256 result) {
        bytes32 slot = PROBE_SLOT;
        assembly {
            result := add(sload(slot), 1)
        }
    }
}

contract CoreGuardFacetA is ReentrancyGuard {
    function enterThenCallB() external nonReentrant {
        (bool success, bytes memory reason) = address(this).call(abi.encodeCall(CoreGuardFacetB.guardedB, ()));
        if (!success) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract CoreGuardFacetB is ReentrancyGuard {
    function guardedB() external nonReentrant {}
}

contract CoreDiamondStorageTest is Test {
    bytes32 internal constant PROBE_SLOT = keccak256("statics.dollar.test.core.storage.probe");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal core;
    IDiamondCut internal cut;

    function setUp() public {
        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapConfig memory config;
        config.owner = address(this);
        config.profileGuardian = profileGuardian;
        config.initialOracle = address(oracle);
        config.weth = address(weth);
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(config);
        core = deployment.core;
        cut = IDiamondCut(core);
    }

    function test_RawNamespacedStorageSurvivesFacetReplacement() public {
        CoreStorageProbeV1 v1 = new CoreStorageProbeV1();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = CoreStorageProbeV1.writeProbe.selector;
        selectors[1] = CoreStorageProbeV1.probe.selector;
        _execute(_singleCut(address(v1), IDiamondCut.FacetCutAction.Add, selectors));
        CoreStorageProbeV1(core).writeProbe(77);
        assertEq(uint256(vm.load(core, PROBE_SLOT)), 77);
        assertEq(CoreStorageProbeV1(core).probe(), 77);

        CoreStorageProbeV2 v2 = new CoreStorageProbeV2();
        _execute(_singleCut(address(v2), IDiamondCut.FacetCutAction.Replace, selectors));
        assertEq(uint256(vm.load(core, PROBE_SLOT)), 77);
        assertEq(CoreStorageProbeV2(core).probe(), 78);
    }

    function test_AllCoreFacetsShareOpenZeppelinReentrancyGuard() public {
        CoreGuardFacetA facetA = new CoreGuardFacetA();
        CoreGuardFacetB facetB = new CoreGuardFacetB();
        IDiamondCut.FacetCut[] memory additions = new IDiamondCut.FacetCut[](2);
        bytes4[] memory selectorA = new bytes4[](1);
        selectorA[0] = CoreGuardFacetA.enterThenCallB.selector;
        bytes4[] memory selectorB = new bytes4[](1);
        selectorB[0] = CoreGuardFacetB.guardedB.selector;
        additions[0] = IDiamondCut.FacetCut(address(facetA), IDiamondCut.FacetCutAction.Add, selectorA);
        additions[1] = IDiamondCut.FacetCut(address(facetB), IDiamondCut.FacetCutAction.Add, selectorB);
        _execute(additions);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        CoreGuardFacetA(core).enterThenCallB();
        CoreGuardFacetB(core).guardedB();
    }

    function _execute(IDiamondCut.FacetCut[] memory diamondCut) internal {
        cut.diamondCut(diamondCut, address(0), "");
    }

    function _singleCut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory diamondCut)
    {
        diamondCut = new IDiamondCut.FacetCut[](1);
        diamondCut[0] = IDiamondCut.FacetCut(facet, action, selectors);
    }
}
