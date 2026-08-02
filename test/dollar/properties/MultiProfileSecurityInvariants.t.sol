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
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreInsuranceFacet} from "src/dollar/core/facets/CoreInsuranceFacet.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract MultiProfileSecurityHandler is Test, IERC1155Receiver {
    uint256 internal constant WETH_PROFILE = 1;
    uint256 internal constant USDC_PROFILE = 2;
    uint256 internal constant WETH_SERIES = 1;

    CanonicalWETH9 internal immutable weth;
    MockUSDC internal immutable usdc;
    MockETHUSDOracle internal immutable wethOracle;
    MockETHUSDOracle internal immutable usdcOracle;
    StaticsDollar internal immutable staticsDollar;
    StaticsDollarRiskShares internal immutable staticsDollarRisk;
    CoreMintFacet internal immutable mintFacet;
    CoreHealthFacet internal immutable healthFacet;
    CoreInsuranceFacet internal immutable insuranceFacet;
    CoreViewFacet internal immutable viewFacet;
    address internal immutable core;

    constructor(
        CanonicalWETH9 weth_,
        MockUSDC usdc_,
        MockETHUSDOracle wethOracle_,
        MockETHUSDOracle usdcOracle_,
        StaticsDollarStackDeployment memory deployment
    ) {
        weth = weth_;
        usdc = usdc_;
        wethOracle = wethOracle_;
        usdcOracle = usdcOracle_;
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        mintFacet = CoreMintFacet(deployment.core);
        healthFacet = CoreHealthFacet(deployment.core);
        insuranceFacet = CoreInsuranceFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        core = deployment.core;
    }

    function depositWeth(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e12, 2 ether);
        try mintFacet.previewDeposit(WETH_PROFILE, amount) returns (
            IStaticsDollarCoreTypes.DepositPreview memory preview
        ) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.approve(core, amount);
            mintFacet.depositCollateral(
                WETH_PROFILE, amount, preview.staticsDollarMinted, preview.sharesMinted, address(this), address(this)
            );
        } catch {}
    }

    function mintUsdc(uint256 rawAmount) external {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(USDC_PROFILE);
        if (
            profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active
                || profile.seniorOutstanding >= profile.debtCeiling
        ) return;
        uint256 remaining = profile.debtCeiling - profile.seniorOutstanding;
        if (remaining < 1e12) return;
        uint256 amount = bound(rawAmount, 1e12, remaining);
        try mintFacet.previewPeggedMint(USDC_PROFILE, amount) returns (
            IStaticsDollarCoreTypes.PeggedMintPreview memory preview
        ) {
            usdc.mint(address(this), preview.totalCollateralIn);
            usdc.approve(core, preview.totalCollateralIn);
            mintFacet.mintPegged(USDC_PROFILE, amount, preview.totalCollateralIn, address(this));
        } catch {}
    }

    function setWethPrice(uint256 rawPrice) external {
        wethOracle.setPriceWad(bound(rawPrice, 1_000e18, 4_000e18));
        wethOracle.setUpdatedAt(block.timestamp);
    }

    function setUsdcPrice(uint256 rawPrice) external {
        usdcOracle.setPriceWad(bound(rawPrice, 0.9e18, 1.1e18));
        usdcOracle.setUpdatedAt(block.timestamp);
    }

    function syncHealth() external {
        healthFacet.syncGlobalHealth();
    }

    function topUpWethInsurance(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e12, 1 ether);
        vm.deal(address(this), address(this).balance + amount);
        weth.deposit{value: amount}();
        weth.approve(core, amount);
        insuranceFacet.topUpInsurance(WETH_PROFILE, amount);
    }

    function topUpUsdcInsurance(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1, 1_000e6);
        usdc.mint(address(this), amount);
        usdc.approve(core, amount);
        insuranceFacet.topUpInsurance(USDC_PROFILE, amount);
    }

    function recombineWeth(uint256 rawAmount) external {
        _recombine(WETH_SERIES, rawAmount);
    }

    function redeemUsdc(uint256 rawAmount) external {
        uint256 available = staticsDollar.balanceOf(address(this));
        uint256 profileSenior = viewFacet.profileSeniorLiabilities(USDC_PROFILE);
        if (profileSenior < available) available = profileSenior;
        if (available < 1e12) return;
        uint256 amount = bound(rawAmount, 1e12, available);
        try mintFacet.redeemPegged(USDC_PROFILE, amount, 0, address(this)) returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 collateralOut
        ) {
            if (status == IStaticsDollarCoreTypes.ExitStatus.Available) {
                assertGt(collateralOut, 0);
            } else {
                assertEq(collateralOut, 0);
            }
        } catch {}
    }

    function _recombine(uint256 seriesId, uint256 rawAmount) internal {
        uint256 available = staticsDollar.balanceOf(address(this));
        uint256 riskBalance = staticsDollarRisk.balanceOf(address(this), seriesId);
        if (riskBalance < available) available = riskBalance;
        if (available < 1e12) return;
        uint256 amount = bound(rawAmount, 1e12, available);
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase,,,) = healthFacet.globalImpairment();
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            mintFacet.recombine(seriesId, amount, amount, 0, address(this));
        if (phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy) {
            assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        } else {
            assertTrue(status != IStaticsDollarCoreTypes.ExitStatus.Available);
            assertEq(collateralOut, 0);
        }
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

contract MultiProfileSecurityInvariants is StdInvariant, Test {
    CanonicalWETH9 internal weth;
    MockUSDC internal usdc;
    MockETHUSDOracle internal wethOracle;
    MockETHUSDOracle internal usdcOracle;
    StaticsDollar internal staticsDollar;
    CoreViewFacet internal viewFacet;
    CoreHealthFacet internal healthFacet;
    address internal core;
    MultiProfileSecurityHandler internal handler;

    function setUp() public {
        weth = new CanonicalWETH9();
        usdc = new MockUSDC();
        wethOracle = new MockETHUSDOracle(2_500e18, type(uint256).max);
        usdcOracle = new MockETHUSDOracle(1e18, type(uint256).max);

        StaticsDollarLocalConfig memory config;
        config.owner = address(this);
        config.profileGuardian = address(this);
        config.weth = address(weth);
        config.oracle = address(wethOracle);
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployLocal(config);
        core = deployment.core;
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        viewFacet = CoreViewFacet(core);
        healthFacet = CoreHealthFacet(core);
        _activateUsdcProfile(deployment);

        handler = new MultiProfileSecurityHandler(weth, usdc, wethOracle, usdcOracle, deployment);
        targetContract(address(handler));
    }

    function invariant_SeniorSupplyAndProfileLiabilitiesRemainConserved() public view {
        uint256 lastSeries = viewFacet.nextSeriesId() - 1;
        uint256 summedSenior;
        uint256 wethSenior;
        uint256 usdcSenior;
        for (uint256 seriesId = 1; seriesId <= lastSeries; ++seriesId) {
            IStaticsDollarCoreTypes.RiskSeries memory series = viewFacet.riskSeries(seriesId);
            summedSenior += series.seniorOutstanding;
            assertEq(series.seniorOutstanding, series.riskSharesOutstanding);
            if (series.profileId == 1) wethSenior += series.seniorOutstanding;
        }
        usdcSenior = viewFacet.profileSeniorLiabilities(2);
        summedSenior += usdcSenior;
        assertEq(summedSenior, staticsDollar.totalSupply());
        assertEq(summedSenior, viewFacet.seniorLiabilities());
        assertEq(wethSenior, viewFacet.profileSeniorLiabilities(1));
        assertEq(usdcSenior, viewFacet.profileSeniorLiabilities(2));
    }

    function invariant_AllProfileCollateralIsCustodied() public view {
        assertEq(weth.balanceOf(core), viewFacet.totalCollateral(address(weth)));
        assertEq(usdc.balanceOf(core), viewFacet.totalCollateral(address(usdc)));
    }

    function invariant_GlobalHealthBitmapMatchesIndependentProfiles() public view {
        IStaticsDollarCoreTypes.ProfileSolvency memory wethSolvency = healthFacet.profileSolvency(1);
        IStaticsDollarCoreTypes.ProfileSolvency memory usdcSolvency = healthFacet.profileSolvency(2);
        (, uint256 bitmap, uint256 deficit,) = healthFacet.globalImpairment();
        uint256 expectedBitmap;
        uint256 expectedDeficit;
        if (!wethSolvency.healthy) {
            expectedBitmap |= uint256(1) << 1;
            expectedDeficit += wethSolvency.seniorDeficitWad;
        }
        if (!usdcSolvency.healthy) {
            expectedBitmap |= uint256(1) << 2;
            expectedDeficit += usdcSolvency.seniorDeficitWad;
        }
        assertEq(bitmap, expectedBitmap);
        assertEq(deficit, expectedDeficit);
    }

    function _activateUsdcProfile(StaticsDollarStackDeployment memory deployment) private {
        CoreGovernanceFacet governance = CoreGovernanceFacet(core);
        uint256 nextSeriesId = CoreViewFacet(deployment.core).nextSeriesId();
        uint256 profileId = governance.createPeggedCollateralProfile(
            address(usdc), address(usdcOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18
        );
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
        assertEq(CoreViewFacet(deployment.core).collateralProfile(profileId).activeSeriesId, 0);
        assertEq(CoreViewFacet(deployment.core).profileSeriesCount(profileId), 0);
        assertEq(CoreViewFacet(deployment.core).nextSeriesId(), nextSeriesId);
    }
}
