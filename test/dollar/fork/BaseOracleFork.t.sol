// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    DeployStaticsDollar,
    StaticsDollarProductionConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {DiamondKernel} from "src/diamond/DiamondKernel.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IWETH9} from "src/dollar/interfaces/IWETH9.sol";

contract BaseFinalizedReplacementFacet {
    function seniorLiabilities() external pure returns (uint256) {
        return 0;
    }
}

contract BaseOracleForkTest is Test {
    uint256 internal constant PINNED_BASE_BLOCK = 32_000_000;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant BASE_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant BASE_SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    function test_BaseFeedsRemainCompatible() public {
        if (!_selectBaseFork(false)) return;

        ChainlinkUsdOracle wethOracle =
            new ChainlinkUsdOracle(BASE_ETH_USD, 1 hours, 100e18, 100_000e18, BASE_SEQUENCER, 1 hours);
        ChainlinkUsdOracle usdcOracle =
            new ChainlinkUsdOracle(BASE_USDC_USD, 25 hours, 0.9e18, 1.1e18, BASE_SEQUENCER, 1 hours);
        assertGt(wethOracle.priceWad(), 100e18);
        assertApproxEqAbs(usdcOracle.priceWad(), 1e18, 0.1e18);
    }

    function test_BaseProductionDeploymentUsesLiveSequencerAwareFeeds() public {
        if (!_selectBaseFork(true)) return;

        StaticsDollarProductionConfig memory config = _baseConfig(1 hours);

        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployProduction(config);
        CoreViewFacet coreView = CoreViewFacet(deployment.core);
        assertEq(coreView.requiredSequencerUptimeFeed(), BASE_SEQUENCER);
        assertEq(coreView.minimumSequencerGracePeriod(), 1 hours);
        assertEq(coreView.collateralProfile(1).oracle, deployment.oracle);
        ChainlinkUsdOracle deployedOracle = ChainlinkUsdOracle(deployment.oracle);
        assertEq(deployedOracle.feed(), BASE_ETH_USD);
        assertEq(deployedOracle.sequencerUptimeFeed(), BASE_SEQUENCER);
        assertGt(deployedOracle.priceWad(), 100e18);
        _exerciseLiveCollateralLifecycles(deployment);
    }

    function test_BaseProductionDeploymentFinalCutPreservesLiveExit() public {
        if (!_selectBaseFork(true)) return;

        // This rehearsal uses a widened heartbeat only so the pinned live
        // Chainlink round remains readable throughout the deployment. The
        // separate production feed test above retains the intended one-hour
        // heartbeat.
        StaticsDollarProductionConfig memory config = _baseConfig(8 days);
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployProduction(config);
        (uint256 seriesId, uint256 minted, uint256 shares, address user) = _depositLiveWeth(deployment);

        _removeCoreUpgradeSelectors(deployment.core, config.owner);
        _assertCoreUpgradeSelectorsRemoved(deployment.core);
        _assertCoreReinstallRejected(deployment.core);
        _recombineAfterCoreFinalCut(deployment, seriesId, minted, shares, user);
    }

    function _removeCoreUpgradeSelectors(address coreDiamond, address owner) private {
        bytes4[] memory cutMutations = new bytes4[](1);
        cutMutations[0] = IDiamondCut.diamondCut.selector;
        bytes4[] memory ownershipMutations = new bytes4[](1);
        ownershipMutations[0] = OwnershipFacet.transferOwnership.selector;
        IDiamondCut.FacetCut[] memory finalCut = new IDiamondCut.FacetCut[](2);
        finalCut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, cutMutations);
        finalCut[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, ownershipMutations);
        vm.prank(owner);
        IDiamondCut(coreDiamond).diamondCut(finalCut, address(0), "");
    }

    function _assertCoreUpgradeSelectorsRemoved(address coreDiamond) private {
        IDiamondLoupe loupe = IDiamondLoupe(coreDiamond);
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        _assertMissingSelector(coreDiamond, IDiamondCut.diamondCut.selector);
        assertEq(loupe.facetAddress(OwnershipFacet.transferOwnership.selector), address(0));
        _assertMissingSelector(coreDiamond, OwnershipFacet.transferOwnership.selector);
    }

    function _assertCoreReinstallRejected(address coreDiamond) private {
        BaseFinalizedReplacementFacet replacement = new BaseFinalizedReplacementFacet();
        IDiamondCut.FacetCut[] memory reinstall = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selector = new bytes4[](1);
        selector[0] = CoreViewFacet.seniorLiabilities.selector;
        reinstall[0] = IDiamondCut.FacetCut(address(replacement), IDiamondCut.FacetCutAction.Replace, selector);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondKernel.FunctionNotFound.selector, IDiamondCut.diamondCut.selector)
        );
        IDiamondCut(coreDiamond).diamondCut(reinstall, address(0), "");
    }

    function _recombineAfterCoreFinalCut(
        StaticsDollarStackDeployment memory deployment,
        uint256 seriesId,
        uint256 minted,
        uint256 shares,
        address user
    ) private {
        CoreMintFacet core = CoreMintFacet(deployment.core);
        IStaticsDollarCoreTypes.RedemptionPreview memory preview = core.previewRecombine(seriesId, minted);
        uint256 beforeBalance = IERC20(BASE_WETH).balanceOf(user);
        vm.prank(user);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            core.recombine(seriesId, minted, shares, preview.collateralOut, user);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, 0.1 ether);
        assertEq(IERC20(BASE_WETH).balanceOf(user), beforeBalance + collateralOut);
        assertEq(IERC20(BASE_WETH).balanceOf(deployment.core), 0);
    }

    function _exerciseLiveCollateralLifecycles(StaticsDollarStackDeployment memory deployment) internal {
        (uint256 wethSeries, uint256 wethMinted, uint256 wethShares, address user) = _depositLiveWeth(deployment);
        CoreMintFacet core = CoreMintFacet(deployment.core);
        vm.startPrank(user);
        uint256 wethBefore = IERC20(BASE_WETH).balanceOf(user);
        core.recombine(wethSeries, wethMinted, wethShares, 0, user);
        assertGt(IERC20(BASE_WETH).balanceOf(user), wethBefore);
        vm.stopPrank();
    }

    function _depositLiveWeth(StaticsDollarStackDeployment memory deployment)
        internal
        returns (uint256 seriesId, uint256 minted, uint256 shares, address user)
    {
        CoreMintFacet core = CoreMintFacet(deployment.core);
        user = makeAddr("baseLifecycleUser");
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        IWETH9(BASE_WETH).deposit{value: 0.1 ether}();
        IERC20(BASE_WETH).approve(deployment.core, 0.1 ether);
        IStaticsDollarCoreTypes.DepositPreview memory preview = core.previewDeposit(1, 0.1 ether);
        (seriesId, minted, shares) =
            core.depositCollateral(1, 0.1 ether, preview.staticsDollarMinted, preview.sharesMinted, user, user);
        vm.stopPrank();
    }

    function _baseConfig(uint256 maxStaleness) internal returns (StaticsDollarProductionConfig memory config) {
        config.owner = makeAddr("baseProductionOwner");
        config.profileGuardian = makeAddr("baseProfileGuardian");
        config.weth = BASE_WETH;
        config.ethUsdFeed = BASE_ETH_USD;
        config.sequencerUptimeFeed = BASE_SEQUENCER;
        config.oracleMaxStaleness = maxStaleness;
        config.oracleMinPriceWad = 100e18;
        config.oracleMaxPriceWad = 100_000e18;
        config.sequencerGracePeriod = 1 hours;
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://risk/{id}.json";
    }

    function _assertMissingSelector(address diamond, bytes4 selector) internal {
        (bool success, bytes memory reason) = diamond.call(abi.encodePacked(selector));
        assertFalse(success);
        assertEq(bytes4(reason), DiamondKernel.FunctionNotFound.selector);
    }

    function _selectBaseFork(bool pinned) internal returns (bool selected) {
        // Prefer a globally selected `--fork-url` fork so the test runner supplies
        // its normal top-level gas budget. Re-selecting a fork from inside this
        // call constrains the deployment helper's many CREATE operations to the
        // remaining gas of the nested call and does not model the broadcast script.
        if (block.chainid == 8453) return true;

        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_BASE_FORK", false)) fail("Base fork required");
            vm.skip(true);
            return false;
        }
        if (pinned) vm.createSelectFork(rpcUrl, PINNED_BASE_BLOCK);
        else vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 8453);
        return true;
    }
}
