// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStaticsDollarCore} from "../../src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "../../src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "../../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "../../script/dollar/DeployStaticsDollar.s.sol";

contract LocalPeggedProfileTest is Test {
    function testLocalPeggedProfileMintsAndRedeemsThroughGateway() public {
        DeployStaticsDollar script = new DeployStaticsDollar();
        StaticsDollarLocalConfig memory config;
        config.owner = address(script);
        config.profileGuardian = address(script);
        config.treasury = address(script);
        config.creationFeeAmount = 1 ether;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.mockOracleMaxStaleness = 30 days;
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://local-statics-dollar-risk";

        StaticsDollarStackDeployment memory deployment = script.deployLocal(config);
        address user = makeAddr("user");
        deployment = script.deployLocalPeggedProfile(deployment, user);

        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            IStaticsDollarCore(deployment.core).collateralProfile(deployment.usdgProfileId);
        assertEq(profile.collateralToken, deployment.usdg);
        assertEq(uint256(profile.kind), uint256(IStaticsDollarCoreTypes.ProfileKind.Pegged));
        assertEq(uint256(profile.mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Active));

        IStaticsDollarGateway gateway = IStaticsDollarGateway(deployment.diamond);
        uint256 dollarAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview =
            gateway.previewPeggedMint(deployment.usdgProfileId, dollarAmount);

        vm.startPrank(user);
        IERC20(deployment.usdg).approve(deployment.diamond, mintPreview.totalCollateralIn);
        gateway.mintPegged(deployment.usdgProfileId, dollarAmount, mintPreview.totalCollateralIn, user);
        assertEq(IERC20(deployment.staticsDollar).balanceOf(user), dollarAmount);

        IERC20(deployment.staticsDollar).approve(deployment.diamond, dollarAmount);
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory redemptionPreview =
            gateway.previewPeggedRedemption(deployment.usdgProfileId, dollarAmount);
        uint256 usdgBefore = IERC20(deployment.usdg).balanceOf(user);
        gateway.redeemPegged(deployment.usdgProfileId, dollarAmount, redemptionPreview.collateralOut, user);
        vm.stopPrank();

        assertEq(IERC20(deployment.staticsDollar).balanceOf(user), 0);
        assertEq(IERC20(deployment.usdg).balanceOf(user), usdgBefore + redemptionPreview.collateralOut);
    }
}
