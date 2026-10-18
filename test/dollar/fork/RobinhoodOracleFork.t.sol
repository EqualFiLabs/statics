// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RobinhoodDollarFork} from "test/dollar/helpers/RobinhoodDollarFork.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StaticsDollarProductionConfig, StaticsDollarStackDeployment} from "script/dollar/DeployStaticsDollar.s.sol";
import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {DiamondKernel} from "src/diamond/DiamondKernel.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IWETH9} from "src/dollar/interfaces/IWETH9.sol";

interface IRobinhoodSequencerLease {
    function healthyUntil() external view returns (uint256);
}

contract RobinhoodFinalizedReplacementFacet {
    function seniorLiabilities() external pure returns (uint256) {
        return 0;
    }
}

// Run the broadcast script in the harness; the script itself is not an onchain deployment.
contract RobinhoodOracleForkTest is RobinhoodDollarFork {
    function test_RobinhoodFeedsRemainCompatible() public {
        ChainlinkUsdOracle wethOracle =
            new ChainlinkUsdOracle(RH_ETH_USD, FEED_MAX_AGE, 100e18, 100_000e18, RH_SEQUENCER, SEQUENCER_GRACE);
        ChainlinkUsdOracle usdgOracle =
            new ChainlinkUsdOracle(RH_USDG_USD, FEED_MAX_AGE, 0.9e18, 1.1e18, RH_SEQUENCER, SEQUENCER_GRACE);
        assertGt(wethOracle.priceWad(), 100e18);
        assertApproxEqAbs(usdgOracle.priceWad(), 1e18, 0.1e18);
    }

    function test_RobinhoodProductionDeploymentUsesLiveSequencerAwareFeeds() public {
        StaticsDollarProductionConfig memory config = _productionConfig();

        StaticsDollarStackDeployment memory deployment = deployProduction(config);
        CoreViewFacet coreView = CoreViewFacet(deployment.core);
        assertEq(coreView.requiredSequencerUptimeFeed(), RH_SEQUENCER);
        assertEq(coreView.minimumSequencerGracePeriod(), SEQUENCER_GRACE);
        assertEq(coreView.collateralProfile(1).oracle, deployment.oracle);
        ChainlinkUsdOracle deployedOracle = ChainlinkUsdOracle(deployment.oracle);
        assertEq(deployedOracle.feed(), RH_ETH_USD);
        assertEq(deployedOracle.sequencerUptimeFeed(), RH_SEQUENCER);
        assertGt(deployedOracle.priceWad(), 100e18);
        (uint256 seriesId, uint256 minted, uint256 shares, address user) = _depositLiveWeth(deployment);
        _assertSuccessfulRecombine(deployment, seriesId, minted, shares, user);
    }

    function test_RobinhoodProductionDeploymentFinalCutPreservesLiveExit() public {
        StaticsDollarProductionConfig memory config = _productionConfig();
        StaticsDollarStackDeployment memory deployment = deployProduction(config);
        (uint256 seriesId, uint256 minted, uint256 shares, address user) = _depositLiveWeth(deployment);

        _removeCoreUpgradeSelectors(deployment.core, config.owner);
        _assertCoreUpgradeSelectorsRemoved(deployment.core);
        _assertCoreReinstallRejected(deployment.core);
        _assertSuccessfulRecombine(deployment, seriesId, minted, shares, user);
    }

    function test_RobinhoodSequencerLeaseExpiryDefersExitWithoutBurning() public {
        StaticsDollarStackDeployment memory deployment = deployProduction(_productionConfig());
        (uint256 seriesId, uint256 minted, uint256 shares, address user) = _depositLiveWeth(deployment);
        uint256 expiresAt = IRobinhoodSequencerLease(RH_SEQUENCER).healthyUntil();
        assertGt(expiresAt, block.timestamp);
        vm.warp(expiresAt);
        vm.expectRevert(ChainlinkUsdOracle.SequencerDown.selector);
        ChainlinkUsdOracle(deployment.oracle).priceWad();
        _assertUnavailableExit(deployment, seriesId, minted, shares, user);
    }

    function _assertUnavailableExit(
        StaticsDollarStackDeployment memory deployment,
        uint256 seriesId,
        uint256 minted,
        uint256 shares,
        address user
    ) private {
        uint256[4] memory balances = [
            IERC20(RH_WETH).balanceOf(user),
            IERC20(RH_WETH).balanceOf(deployment.core),
            IERC20(deployment.staticsDollar).balanceOf(user),
            IERC1155(deployment.staticsDollarRisk).balanceOf(user, seriesId)
        ];
        vm.prank(user);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            CoreMintFacet(deployment.core).recombine(seriesId, minted, shares, 0, user);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.HealthUnavailable));
        assertEq(collateralOut, 0);
        assertEq(IERC20(RH_WETH).balanceOf(user), balances[0]);
        assertEq(IERC20(RH_WETH).balanceOf(deployment.core), balances[1]);
        assertEq(IERC20(deployment.staticsDollar).balanceOf(user), balances[2]);
        assertEq(IERC1155(deployment.staticsDollarRisk).balanceOf(user, seriesId), balances[3]);
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
        RobinhoodFinalizedReplacementFacet replacement = new RobinhoodFinalizedReplacementFacet();
        IDiamondCut.FacetCut[] memory reinstall = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selector = new bytes4[](1);
        selector[0] = CoreViewFacet.seniorLiabilities.selector;
        reinstall[0] = IDiamondCut.FacetCut(address(replacement), IDiamondCut.FacetCutAction.Replace, selector);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondKernel.FunctionNotFound.selector, IDiamondCut.diamondCut.selector)
        );
        IDiamondCut(coreDiamond).diamondCut(reinstall, address(0), "");
    }

    function _assertSuccessfulRecombine(
        StaticsDollarStackDeployment memory deployment,
        uint256 seriesId,
        uint256 minted,
        uint256 shares,
        address user
    ) private {
        CoreMintFacet core = CoreMintFacet(deployment.core);
        IStaticsDollarCoreTypes.RedemptionPreview memory preview = core.previewRecombine(seriesId, minted);
        uint256 beforeBalance = IERC20(RH_WETH).balanceOf(user);
        vm.prank(user);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            core.recombine(seriesId, minted, shares, preview.collateralOut, user);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, 0.1 ether);
        assertEq(IERC20(RH_WETH).balanceOf(user), beforeBalance + collateralOut);
        assertEq(IERC20(RH_WETH).balanceOf(deployment.core), 0);
        assertEq(IERC20(deployment.staticsDollar).balanceOf(user), 0);
        assertEq(IERC1155(deployment.staticsDollarRisk).balanceOf(user, seriesId), 0);
    }

    function _depositLiveWeth(StaticsDollarStackDeployment memory deployment)
        internal
        returns (uint256 seriesId, uint256 minted, uint256 shares, address user)
    {
        CoreMintFacet core = CoreMintFacet(deployment.core);
        user = makeAddr("robinhoodLifecycleUser");
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        IWETH9(RH_WETH).deposit{value: 0.1 ether}();
        IERC20(RH_WETH).approve(deployment.core, 0.1 ether);
        IStaticsDollarCoreTypes.DepositPreview memory preview = core.previewDeposit(1, 0.1 ether);
        (seriesId, minted, shares) =
            core.depositCollateral(1, 0.1 ether, preview.staticsDollarMinted, preview.sharesMinted, user, user);
        vm.stopPrank();
    }

    function _assertMissingSelector(address diamond, bytes4 selector) internal {
        (bool success, bytes memory reason) = diamond.call(abi.encodePacked(selector));
        assertFalse(success);
        assertEq(bytes4(reason), DiamondKernel.FunctionNotFound.selector);
    }
}
