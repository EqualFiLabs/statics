// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract PeggedMintAndRecombineHandler is Test {
    IStaticsDollarGateway internal immutable gateway;
    StaticsDollarRiskShares internal immutable risk;
    MockUSDC internal immutable usdc;
    address internal immutable actor;
    uint256 internal immutable peggedProfileId;
    uint256 public successfulCalls;

    constructor(
        IStaticsDollarGateway gateway_,
        StaticsDollarRiskShares risk_,
        MockUSDC usdc_,
        address actor_,
        uint256 peggedProfileId_
    ) {
        gateway = gateway_;
        risk = risk_;
        usdc = usdc_;
        actor = actor_;
        peggedProfileId = peggedProfileId_;
    }

    function mintPeggedAndRecombine(uint256 rawAmount) external {
        uint256 availableRisk = risk.balanceOf(actor, 1);
        if (availableRisk < 1e12) return;
        uint256 amount = bound(rawAmount, 1e12, availableRisk);
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, 1, 1, amount);
        if (!quote.eligible || usdc.balanceOf(actor) < quote.totalPeggedCollateralIn) return;
        vm.prank(actor);
        (IStaticsDollarCoreTypes.ExitStatus status,,) = gateway.mintPeggedAndRecombine(
            peggedProfileId, 1, 1, amount, quote.totalPeggedCollateralIn, quote.volatileCollateralOut, actor
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        ++successfulCalls;
    }
}

contract PeggedMintAndRecombineInvariantTest is Test {
    address internal owner = makeAddr("owner");
    address internal actor = makeAddr("actor");

    IStaticsDollarCore internal core;
    IStaticsDollarGateway internal gateway;
    IStaticsCustody internal custody;
    StaticsDollar internal dollar;
    StaticsDollarRiskShares internal risk;
    CanonicalWETH9 internal weth;
    MockUSDC internal usdc;
    uint256 internal peggedProfileId;
    uint256 internal initialSupply;
    uint256 internal initialSeniorLiabilities;
    address internal diamond;
    PeggedMintAndRecombineHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new CanonicalWETH9();
        MockETHUSDOracle wethOracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.initialOracle = address(wethOracle);
        config.weth = address(weth);
        config.partnerRecipient = address(0);
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = type(uint256).max;
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(config);
        core = IStaticsDollarCore(deployment.core);
        gateway = IStaticsDollarGateway(deployment.diamond);
        custody = IStaticsCustody(deployment.diamond);
        dollar = StaticsDollar(deployment.staticsDollar);
        risk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        diamond = deployment.diamond;

        usdc = new MockUSDC();
        MockETHUSDOracle pegOracle = new MockETHUSDOracle(1e18, 1 hours);
        vm.prank(owner);
        peggedProfileId = CoreGovernanceFacet(deployment.core)
            .createPeggedCollateralProfile(address(usdc), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(deployment.core).setProfileMode(peggedProfileId, IStaticsDollarCoreTypes.ProfileMode.Active);

        vm.deal(actor, 10 ether);
        vm.prank(actor);
        gateway.depositETH{value: 10 ether}(actor, actor, 0, 0);
        usdc.mint(actor, 1_000_000e6);
        vm.startPrank(actor);
        usdc.approve(diamond, type(uint256).max);
        risk.setApprovalForAll(diamond, true);
        vm.stopPrank();

        initialSupply = dollar.totalSupply();
        initialSeniorLiabilities = core.seniorLiabilities();
        handler = new PeggedMintAndRecombineHandler(gateway, risk, usdc, actor, peggedProfileId);
        targetContract(address(handler));
    }

    function invariant_GlobalDollarSupplyAndSeniorLiabilitiesRemainConstant() public view {
        assertEq(dollar.totalSupply(), initialSupply);
        assertEq(core.seniorLiabilities(), initialSeniorLiabilities);
        assertEq(
            core.collateralProfile(1).seniorOutstanding + core.collateralProfile(peggedProfileId).seniorOutstanding,
            initialSeniorLiabilities
        );
    }

    function invariant_SharedReservationsRemainFullyBackedAndTransientBalancesClear() public view {
        assertGe(weth.balanceOf(diamond), custody.globalReservedByToken(address(weth)));
        assertGe(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
        assertEq(dollar.balanceOf(diamond), custody.globalReservedByToken(address(dollar)));
        assertEq(risk.balanceOf(diamond, 1), 0);
        assertEq(IERC20(address(usdc)).allowance(diamond, address(core)), 0);
    }

    function afterInvariant() public view {
        assertGt(handler.successfulCalls(), 0);
    }
}
