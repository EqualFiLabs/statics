// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract PerpetualSeriesHandler is Test, IERC1155Receiver {
    CanonicalWETH9 internal immutable weth;
    MockETHUSDOracle internal immutable oracle;
    StaticsDollar internal immutable staticsDollar;
    StaticsDollarRiskShares internal immutable staticsDollarRisk;
    CoreMintFacet internal immutable mintFacet;
    CoreTransitionFacet internal immutable transitionFacet;
    CoreViewFacet internal immutable viewFacet;
    address internal immutable core;

    constructor(StaticsDollarStackDeployment memory deployment) {
        weth = CanonicalWETH9(payable(deployment.weth));
        oracle = MockETHUSDOracle(deployment.oracle);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        mintFacet = CoreMintFacet(deployment.core);
        transitionFacet = CoreTransitionFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        core = deployment.core;
        staticsDollarRisk.setApprovalForAll(core, true);
    }

    function deposit(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e12, 10 ether);
        try mintFacet.previewDeposit(1, amount) returns (IStaticsDollarCoreTypes.DepositPreview memory preview) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.approve(core, amount);
            mintFacet.depositCollateral(
                1, amount, preview.staticsDollarMinted, preview.sharesMinted, address(this), address(this)
            );
        } catch {}
    }

    function recombine(uint256 rawSeriesId, uint256 rawAmount) external {
        uint256 lastSeries = viewFacet.nextSeriesId() - 1;
        uint256 seriesId = bound(rawSeriesId, 1, lastSeries);
        uint256 riskBalance = staticsDollarRisk.balanceOf(address(this), seriesId);
        uint256 stableBalance = staticsDollar.balanceOf(address(this));
        uint256 available = riskBalance < stableBalance ? riskBalance : stableBalance;
        if (available < 1e12) return;
        uint256 amount = bound(rawAmount, 1e12, available);
        mintFacet.recombine(seriesId, amount, amount, 0, address(this));
    }

    function transition(uint256 direction) external {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        uint256 seriesId = profile.activeSeriesId;
        IStaticsDollarCoreTypes.RiskSeries memory active = viewFacet.riskSeries(seriesId);
        if (active.status != IStaticsDollarCoreTypes.SeriesStatus.Active) return;
        uint256 price = direction % 2 == 0
            ? viewFacet.seriesDownsideTriggerPriceWad(seriesId)
            : viewFacet.seriesUpsideTriggerPriceWad(seriesId);
        oracle.setPriceWad(price);
        oracle.setUpdatedAt(block.timestamp);
        transitionFacet.startSeriesTransition(1);
        vm.warp(block.timestamp + transitionFacet.SERIES_TRANSITION_DELAY());
        oracle.setUpdatedAt(block.timestamp);
        transitionFacet.finalizeSeriesTransition(seriesId);
    }

    function transitionWithReturn(uint256 direction, uint256 rawShares) external {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        uint256 seriesId = profile.activeSeriesId;
        uint256 balance = staticsDollarRisk.balanceOf(address(this), seriesId);
        if (balance < 1e12) return;
        uint256 price = direction % 2 == 0
            ? viewFacet.seriesDownsideTriggerPriceWad(seriesId)
            : viewFacet.seriesUpsideTriggerPriceWad(seriesId);
        oracle.setPriceWad(price);
        oracle.setUpdatedAt(block.timestamp);
        transitionFacet.startSeriesTransition(1);
        transitionFacet.returnRiskShares(seriesId, bound(rawShares, 1e12, balance));
        vm.warp(block.timestamp + transitionFacet.SERIES_TRANSITION_DELAY());
        oracle.setUpdatedAt(block.timestamp);
        transitionFacet.finalizeSeriesTransition(seriesId);
    }

    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

contract PerpetualSeriesInvariants is StdInvariant, Test {
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;
    CoreViewFacet internal viewFacet;
    PerpetualSeriesHandler internal handler;
    address internal core;
    CanonicalWETH9 internal weth;

    function setUp() public {
        StaticsDollarLocalConfig memory config;
        config.owner = address(this);
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOracleMaxStaleness = type(uint256).max;
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployLocal(config);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        viewFacet = CoreViewFacet(deployment.core);
        core = deployment.core;
        weth = CanonicalWETH9(payable(deployment.weth));
        handler = new PerpetualSeriesHandler(deployment);
        targetContract(address(handler));
    }

    function invariant_SeniorAndRiskAccountingRemainMatched() public view {
        uint256 lastSeries = viewFacet.nextSeriesId() - 1;
        uint256 summedSenior;
        for (uint256 seriesId = 1; seriesId <= lastSeries; ++seriesId) {
            IStaticsDollarCoreTypes.RiskSeries memory series = viewFacet.riskSeries(seriesId);
            IStaticsDollarCoreTypes.SeriesRecoveryState memory recovery = viewFacet.seriesRecoveryState(seriesId);
            summedSenior += series.seniorOutstanding + recovery.seniorRecoveryOutstanding;
            assertEq(series.seniorOutstanding, series.riskSharesOutstanding);
            assertEq(series.riskSharesOutstanding, staticsDollarRisk.balanceOf(address(handler), seriesId));
            if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
                (uint256 bookShares, uint256 bookCollateral,,) = viewFacet.expiredRecoveryBook(seriesId);
                assertEq(bookShares, series.seniorOutstanding);
                assertEq(bookCollateral, series.accountedCollateral);
            }
            if (
                series.status == IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                    || series.status == IStaticsDollarCoreTypes.SeriesStatus.Retired
            ) {
                (uint256 bookShares, uint256 bookCollateral, uint256 bookSenior, uint256 bookBounty) =
                    viewFacet.expiredRecoveryBook(seriesId);
                bool hasEconomicState = series.seniorOutstanding != 0 || series.riskSharesOutstanding != 0
                    || series.accountedCollateral != 0 || recovery.seniorRecoveryOutstanding != 0
                    || recovery.seniorRecoveryCollateral != 0 || recovery.juniorRecoveryShares != 0
                    || recovery.juniorRecoveryCollateral != 0 || bookShares != 0 || bookCollateral != 0
                    || bookSenior != 0 || bookBounty != 0;
                assertTrue(hasEconomicState);
            }
        }
        assertEq(summedSenior, viewFacet.seniorLiabilities());
        assertEq(summedSenior, staticsDollar.totalSupply());
        assertEq(summedSenior, viewFacet.profileSeniorLiabilities(1));
    }

    function test_HandlerCanExerciseDepositAndRecombine() public {
        handler.deposit(1 ether);
        assertGt(staticsDollar.totalSupply(), 0);
        handler.recombine(1, staticsDollar.totalSupply() / 2);
        assertGt(staticsDollar.totalSupply(), 0);
    }

    function invariant_AllTrackedCollateralIsActuallyHeld() public view {
        assertEq(weth.balanceOf(core), viewFacet.totalCollateral(address(weth)));
    }
}
