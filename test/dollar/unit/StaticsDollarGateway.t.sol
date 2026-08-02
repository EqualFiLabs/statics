// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {PairingVaultFacet} from "src/dollar/periphery/facets/PairingVaultFacet.sol";
import {FeeRouterFacet} from "src/dollar/periphery/facets/FeeRouterFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {StaticsDiamond} from "src/diamond/StaticsDiamond.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "src/interfaces/IStaticsGlobalRewards.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract StaticsDollarGatewayTest is Test {
    uint256 internal constant PRICE_WAD = 2_500e18;
    uint256 internal constant MAX_STALENESS = 1 hours;
    uint256 internal constant COLLATERAL_RATIO_BPS = 15_000;
    uint256 internal constant PRICE_BAND_BPS = 15_000;
    uint256 internal constant WETH_PROFILE = 1;
    uint256 internal constant SERIES_ONE = 1;
    uint256 internal constant ONE_PAIR_COLLATERAL = 0.0006 ether;
    uint256 internal constant ONE_ETH_MINT = 1_666_666_666_666_666_666_666;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    CanonicalWETH9 internal weth;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;
    MockETHUSDOracle internal oracle;
    IStaticsDollarCore internal pool;
    IStaticsDollarGateway internal gateway;
    IStaticsCustody internal custody;
    IStaticsGlobalRewards internal globalRewards;
    StakingFacet internal staking;
    PairingVaultFacet internal pairing;
    address internal diamond;

    address internal owner = makeAddr("owner");
    uint256 internal aliceKey;
    address internal alice;
    address internal staticsDollarReceiver = makeAddr("staticsDollarReceiver");
    address internal shareReceiver = makeAddr("shareReceiver");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        vm.warp(1_700_000_000);
        (alice, aliceKey) = makeAddrAndKey("alice");
        weth = new CanonicalWETH9();
        oracle = new MockETHUSDOracle(PRICE_WAD, MAX_STALENESS);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.initialOracle = address(oracle);
        config.weth = address(weth);
        config.stakingToken = address(weth);
        config.collateralRatioBps = COLLATERAL_RATIO_BPS;
        config.priceBandBps = PRICE_BAND_BPS;
        config.debtCeiling = type(uint256).max;
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(config);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        pool = IStaticsDollarCore(deployment.core);
        diamond = deployment.diamond;
        gateway = IStaticsDollarGateway(diamond);
        custody = IStaticsCustody(diamond);
        globalRewards = IStaticsGlobalRewards(diamond);
        staking = StakingFacet(diamond);
        pairing = PairingVaultFacet(diamond);
        vm.deal(alice, 10 ether);
    }

    function testGatewayUsesTheUnifiedDiamondWiring() public view {
        assertEq(address(gateway), diamond);
        assertEq(gateway.pool(), address(pool));
        assertEq(gateway.weth(), address(weth));
        assertEq(gateway.staticsDollar(), address(staticsDollar));
        assertEq(gateway.staticsDollarRisk(), address(staticsDollarRisk));
        assertEq(gateway.wethProfileId(), WETH_PROFILE);
        assertEq(address(staking), address(gateway));
        assertEq(address(pairing), address(gateway));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
    }

    function testDepositETHWrapsAndMintsCurrentSeriesClaims() public {
        IStaticsDollarCoreTypes.DepositPreview memory preview = pool.previewDeposit(WETH_PROFILE, 1 ether);

        vm.prank(alice);
        (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted) = gateway.depositETH{value: 1 ether}(
            staticsDollarReceiver, shareReceiver, preview.staticsDollarMinted, preview.sharesMinted
        );

        assertEq(seriesId, SERIES_ONE);
        assertEq(staticsDollarMinted, preview.staticsDollarMinted);
        assertEq(sharesMinted, preview.sharesMinted);
        assertEq(weth.balanceOf(address(pool)), 1 ether);
        assertEq(staticsDollar.balanceOf(staticsDollarReceiver), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(shareReceiver, SERIES_ONE), ONE_ETH_MINT);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testDepositWETHPullsCollateralAndClearsCoreApproval() public {
        IStaticsDollarCoreTypes.DepositPreview memory preview = pool.previewDeposit(WETH_PROFILE, 2 ether);
        _wrapAndApprove(alice, 2 ether, diamond);

        vm.prank(alice);
        (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted) = gateway.depositWETH(
            2 ether, staticsDollarReceiver, shareReceiver, preview.staticsDollarMinted, preview.sharesMinted
        );

        assertEq(seriesId, SERIES_ONE);
        assertEq(staticsDollarMinted, preview.staticsDollarMinted);
        assertEq(sharesMinted, preview.sharesMinted);
        assertEq(weth.allowance(diamond, address(pool)), 0);
        assertEq(staticsDollar.balanceOf(staticsDollarReceiver), preview.staticsDollarMinted);
        assertEq(staticsDollarRisk.balanceOf(shareReceiver, SERIES_ONE), preview.sharesMinted);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testGatewayMintThenStakeUsesOnlyTheDiamondAddress() public {
        _depositToAliceThroughGateway(1 ether);
        vm.startPrank(alice);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        uint256 positionId = staking.createAndStake(SERIES_ONE, 1e18, alice);
        vm.stopPrank();

        assertEq(IERC721(diamond).ownerOf(positionId), alice);
        assertEq(staking.leg(positionId, SERIES_ONE).pendingPrincipal, 1e18);
    }

    function testRecombineToWETHBurnsClaimsAndTransfersNetCollateral() public {
        _depositToAliceThroughGateway(1 ether);
        _approveClaims(alice, 1e18);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETH(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(wethOut, ONE_PAIR_COLLATERAL);
        assertEq(weth.balanceOf(receiver), ONE_PAIR_COLLATERAL);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT - 1e18);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT - 1e18);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testRecombineToETHBurnsClaimsAndTransfersNetCollateral() public {
        _depositToAliceThroughGateway(1 ether);
        _approveClaims(alice, 1e18);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut) =
            gateway.recombineToETH(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(ethOut, ONE_PAIR_COLLATERAL);
        assertEq(receiver.balance, ONE_PAIR_COLLATERAL);
        assertEq(diamond.balance, 0);
        assertEq(weth.balanceOf(address(pool)), 1 ether - ONE_PAIR_COLLATERAL);
        assertEq(pool.seniorLiabilities(), ONE_ETH_MINT - 1e18);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testRecombineToWETHWithPermitConsumesSignedAllowanceAtomically() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(wethOut, ONE_PAIR_COLLATERAL);
        assertEq(weth.balanceOf(receiver), ONE_PAIR_COLLATERAL);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testRecombineToETHWithPermitConsumesSignedAllowanceAtomically() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 ethOut) =
            gateway.recombineToETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(ethOut, ONE_PAIR_COLLATERAL);
        assertEq(receiver.balance, ONE_PAIR_COLLATERAL);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testPermitRecombinationToleratesFrontrunPermitSubmission() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(receiver);
        staticsDollar.permit(alice, diamond, 1e18, signature.deadline, signature.v, signature.r, signature.s);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(wethOut, ONE_PAIR_COLLATERAL);
        assertEq(weth.balanceOf(receiver), ONE_PAIR_COLLATERAL);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT - 1e18);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testPermitRecombinationRejectsExpiredSignatureWithoutAllowance() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, block.timestamp - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, diamond, 0, 1e18));
        gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
    }

    function testPermitRecombinationUsesCallerExistingAllowanceAfterExpiredPermit() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, block.timestamp - 1);

        vm.prank(alice);
        staticsDollar.approve(diamond, 2e18);
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(wethOut, ONE_PAIR_COLLATERAL);
        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 1e18);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT - 1e18);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testPermitRecombinationCallerCannotConsumeVictimAllowance() public {
        _depositToAliceThroughGateway(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(receiver);
        staticsDollar.permit(alice, diamond, 1e18, signature.deadline, signature.v, signature.r, signature.s);
        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, diamond, 0, 1e18));
        gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 1e18);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
        assertEq(staticsDollar.balanceOf(receiver), 0);
    }

    function testPermitRecombinationRollsBackPermitWhenRiskApprovalIsMissing() public {
        _depositToAliceThroughGateway(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, diamond, alice));
        gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
    }

    function testPermitRecombinationRejectsReplayWithoutAllowance() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);

        vm.prank(alice);
        gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        uint256 staticsDollarBefore = staticsDollar.balanceOf(alice);
        uint256 riskBefore = staticsDollarRisk.balanceOf(alice, SERIES_ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, diamond, 0, 1e18));
        gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.balanceOf(alice), staticsDollarBefore);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), riskBefore);
    }

    function testDeferredPermitRecombinationDoesNotConsumeSignatureOrAllowance() public {
        _depositToAliceThroughGateway(1 ether);
        _approveRiskClaims(alice);
        uint256 deadline = block.timestamp + 1 hours;
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(1e18, deadline);
        oracle.setPriceWad(1_500e18);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETHWithPermit(SERIES_ONE, 1e18, 1e18, receiver, 0, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(wethOut, 0);
        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
    }

    function testOrdinaryDirectAndGatewayRecombinationHaveIdenticalEconomics() public {
        _depositToAliceThroughGateway(1 ether);
        _approveClaims(alice, 1e18);
        IStaticsDollarCoreTypes.RedemptionPreview memory preview = pool.previewRecombine(SERIES_ONE, 0.5e18);

        vm.prank(alice);
        (, uint256 gatewayOut) = gateway.recombineToWETH(SERIES_ONE, 0.5e18, 0.5e18, receiver, 0);
        vm.prank(alice);
        (, uint256 directOut) = pool.recombine(SERIES_ONE, 0.5e18, 0.5e18, 0, alice);

        assertEq(gatewayOut, preview.collateralOut);
        assertEq(directOut, gatewayOut);
    }

    function testManagedRecombinationRejectsEveryCallerExceptTheDiamond() public {
        _depositToAliceThroughGateway(1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoreMintFacet.OnlyManagedPeriphery.selector, alice, diamond));
        pool.recombineManaged(SERIES_ONE, 1e18, 1e18, 0, alice);
    }

    function testPeggedGatewayMatchesDirectEconomicsAndClearsResiduals() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, mintPreview.totalCollateralIn);
        vm.prank(alice);
        usdc.approve(diamond, mintPreview.totalCollateralIn);
        vm.prank(alice);
        uint256 collateralIn = gateway.mintPegged(profileId, 100e18, mintPreview.totalCollateralIn, alice);
        assertEq(collateralIn, mintPreview.totalCollateralIn);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
        assertEq(usdc.allowance(diamond, address(pool)), 0);

        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview = pool.previewPeggedRedemption(profileId, 50e18);
        vm.prank(alice);
        staticsDollar.approve(diamond, 50e18);
        vm.prank(alice);
        (, uint256 gatewayOut) = gateway.redeemPegged(profileId, 50e18, preview.collateralOut, receiver);
        vm.prank(alice);
        (, uint256 directOut) = pool.redeemPegged(profileId, 50e18, preview.collateralOut, alice);

        assertEq(gatewayOut, directOut);
        assertEq(gatewayOut, preview.collateralOut);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
        assertEq(usdc.allowance(diamond, address(pool)), 0);
        assertEq(staticsDollar.balanceOf(diamond), custody.globalReservedByToken(address(staticsDollar)));
        assertEq(globalRewards.treasuryAccrued(address(usdc)), mintPreview.feeAmount + (2 * preview.feeAmount));
    }

    function testPeggedMintWithPermitConsumesExactCollateralAllowance() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, preview.totalCollateralIn, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 collateralIn =
            gateway.mintPeggedWithPermit(profileId, 100e18, preview.totalCollateralIn, alice, signature);

        assertEq(collateralIn, preview.totalCollateralIn);
        assertEq(usdc.nonces(alice), 1);
        assertEq(usdc.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
        assertEq(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
    }

    function testPeggedMintWithPermitToleratesFrontrunPermitSubmission() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, preview.totalCollateralIn, block.timestamp + 1 hours);

        vm.prank(receiver);
        usdc.permit(
            alice, diamond, preview.totalCollateralIn, signature.deadline, signature.v, signature.r, signature.s
        );
        vm.prank(alice);
        uint256 collateralIn =
            gateway.mintPeggedWithPermit(profileId, 100e18, preview.totalCollateralIn, alice, signature);

        assertEq(collateralIn, preview.totalCollateralIn);
        assertEq(usdc.nonces(alice), 1);
        assertEq(usdc.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
        assertEq(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
    }

    function testPeggedMintWithPermitUsesCallerExistingAllowanceAfterExpiredPermit() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        uint256 extraAllowance = 1e6;
        usdc.mint(alice, preview.totalCollateralIn);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, preview.totalCollateralIn, block.timestamp - 1);

        vm.prank(alice);
        usdc.approve(diamond, preview.totalCollateralIn + extraAllowance);
        vm.prank(alice);
        uint256 collateralIn =
            gateway.mintPeggedWithPermit(profileId, 100e18, preview.totalCollateralIn, alice, signature);

        assertEq(collateralIn, preview.totalCollateralIn);
        assertEq(usdc.nonces(alice), 0);
        assertEq(usdc.allowance(alice, diamond), extraAllowance);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
        assertEq(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
    }

    function testPeggedMintWithPermitRollsBackPermitWhenCollateralTransferFails() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, preview.totalCollateralIn, block.timestamp + 1 hours);
        usdc.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(MockUSDC.TokenPaused.selector);
        gateway.mintPeggedWithPermit(profileId, 100e18, preview.totalCollateralIn, alice, signature);

        assertEq(usdc.nonces(alice), 0);
        assertEq(usdc.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 0);
    }

    function testPeggedRedemptionWithPermitConsumesExactDollarAllowance() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, mintPreview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, mintPreview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, mintPreview.totalCollateralIn, alice);
        vm.stopPrank();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview = pool.previewPeggedRedemption(profileId, 100e18);
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(100e18, block.timestamp + 1 hours);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            gateway.redeemPeggedWithPermit(profileId, 100e18, preview.collateralOut, receiver, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, preview.collateralOut);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(receiver), preview.collateralOut);
    }

    function testPeggedRedemptionWithPermitToleratesFrontrunPermitSubmission() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, mintPreview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, mintPreview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, mintPreview.totalCollateralIn, alice);
        vm.stopPrank();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview = pool.previewPeggedRedemption(profileId, 100e18);
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(100e18, block.timestamp + 1 hours);

        vm.prank(receiver);
        staticsDollar.permit(alice, diamond, 100e18, signature.deadline, signature.v, signature.r, signature.s);
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            gateway.redeemPeggedWithPermit(profileId, 100e18, preview.collateralOut, receiver, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, preview.collateralOut);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(receiver), preview.collateralOut);
    }

    function testDeferredPeggedRedemptionDoesNotConsumePermit() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, preview.totalCollateralIn, alice);
        vm.stopPrank();
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(100e18, block.timestamp + 1 hours);
        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);
        CoreTransitionFacet(address(pool)).startSeriesTransition(1);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            gateway.redeemPeggedWithPermit(profileId, 100e18, 0, receiver, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.DownsideTransition));
        assertEq(collateralOut, 0);
        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
    }

    function testPeggedRedemptionWithPermitRollsBackWhenCollateralTransferFails() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, mintPreview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, mintPreview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, mintPreview.totalCollateralIn, alice);
        vm.stopPrank();
        IStaticsDollarGateway.PermitSignature memory signature = _signPermit(100e18, block.timestamp + 1 hours);
        usdc.setBlacklisted(receiver, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AccountBlacklisted.selector, receiver));
        gateway.redeemPeggedWithPermit(profileId, 100e18, 0, receiver, signature);

        assertEq(staticsDollar.nonces(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(staticsDollar.balanceOf(alice), 100e18);
    }

    function testPeggedGatewayDefersBeforeTakingUserCustody() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, preview.totalCollateralIn, alice);
        staticsDollar.approve(diamond, 100e18);
        vm.stopPrank();

        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);
        CoreTransitionFacet(address(pool)).startSeriesTransition(1);
        uint256 aliceBefore = staticsDollar.balanceOf(alice);
        uint256 diamondBefore = staticsDollar.balanceOf(diamond);
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            gateway.redeemPegged(profileId, 100e18, 0, receiver);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.DownsideTransition));
        assertEq(collateralOut, 0);
        assertEq(staticsDollar.balanceOf(alice), aliceBefore);
        assertEq(staticsDollar.balanceOf(diamond), diamondBefore);
    }

    function testAnyoneCanDistributePeggedTreasuryFees() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, preview.totalCollateralIn, alice);
        vm.stopPrank();

        uint256 treasuryBefore = usdc.balanceOf(owner);
        vm.prank(alice);
        uint256 distributed = globalRewards.distributeTreasuryFees(address(usdc));
        assertEq(distributed, preview.feeAmount);
        assertEq(usdc.balanceOf(owner) - treasuryBefore, preview.feeAmount);
        assertEq(globalRewards.treasuryAccrued(address(usdc)), 0);
        assertEq(usdc.balanceOf(diamond), custody.globalReservedByToken(address(usdc)));
    }

    function testImpairedRecombineRecordsLatchWithoutTakingCustody() public {
        _depositToAliceThroughGateway(1 ether);
        _approveClaims(alice, 1e18);
        oracle.setPriceWad(1_500e18);
        uint256 staticsDollarBefore = staticsDollar.balanceOf(alice);
        uint256 riskBefore = staticsDollarRisk.balanceOf(alice, SERIES_ONE);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETH(SERIES_ONE, 1e18, 1e18, receiver, ONE_PAIR_COLLATERAL);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(wethOut, 0);
        assertEq(staticsDollar.balanceOf(alice), staticsDollarBefore);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), riskBefore);
        assertEq(weth.balanceOf(receiver), 0);
        assertTrue(pool.globalImpairmentLatched());
    }

    function testFuzzImpairedGatewayExitPreservesClaims(uint96 rawAmount) public {
        _depositToAliceThroughGateway(1 ether);
        uint256 amount = bound(uint256(rawAmount), 1e18, staticsDollar.balanceOf(alice));
        _approveClaims(alice, amount);
        oracle.setPriceWad(1_500e18);
        uint256 staticsDollarBefore = staticsDollar.balanceOf(alice);
        uint256 riskBefore = staticsDollarRisk.balanceOf(alice, SERIES_ONE);
        IStaticsDollarCoreTypes.RiskSeries memory seriesBefore = pool.riskSeries(SERIES_ONE);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 wethOut) =
            gateway.recombineToWETH(SERIES_ONE, amount, amount, receiver, 0);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(wethOut, 0);
        assertEq(staticsDollar.balanceOf(alice), staticsDollarBefore);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), riskBefore);
        assertEq(pool.riskSeries(SERIES_ONE).seniorOutstanding, seriesBefore.seniorOutstanding);
        assertEq(pool.riskSeries(SERIES_ONE).riskSharesOutstanding, seriesBefore.riskSharesOutstanding);
        assertEq(pool.riskSeries(SERIES_ONE).accountedCollateral, seriesBefore.accountedCollateral);
    }

    function testDepositMinimumAndRecombinationMaximumsAreEnforced() public {
        IStaticsDollarCoreTypes.DepositPreview memory preview = pool.previewDeposit(WETH_PROFILE, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.OutputBelowMinimum.selector,
                preview.staticsDollarMinted,
                preview.staticsDollarMinted + 1
            )
        );
        gateway.depositETH{value: 1 ether}(alice, alice, preview.staticsDollarMinted + 1, 0);

        _depositToAliceThroughGateway(1 ether);
        _approveClaims(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollarGateway.SharesAboveMaximum.selector, 1e18, 1e18 - 1));
        gateway.recombineToETH(SERIES_ONE, 1e18, 1e18 - 1, receiver, 0);
    }

    function testPreexistingUnreservedDustDoesNotGriefGatewayFlows() public {
        vm.deal(diamond, 1);
        weth.deposit{value: 1}();
        weth.transfer(diamond, 1);

        vm.prank(alice);
        gateway.depositETH{value: 1 ether}(alice, alice, 0, 0);

        assertEq(diamond.balance, 1);
        assertEq(weth.balanceOf(diamond) - custody.globalReservedByToken(address(weth)), 1);
        assertEq(staticsDollar.balanceOf(alice), ONE_ETH_MINT);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
    }

    function testUnexpectedNativeTransferIsRejectedByTheDiamond() public {
        (bool ok, bytes memory data) = diamond.call{value: 1}("");

        assertFalse(ok);
        assertEq(bytes4(data), StaticsDiamond.NativeSenderNotAllowed.selector);
    }

    function _depositToAliceThroughGateway(uint256 amount) internal {
        vm.prank(alice);
        gateway.depositETH{value: amount}(alice, alice, 0, 0);
    }

    function _approveClaims(address account, uint256 staticsDollarAmount) internal {
        vm.startPrank(account);
        staticsDollar.approve(diamond, staticsDollarAmount);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();
    }

    function _approveRiskClaims(address account) internal {
        vm.prank(account);
        staticsDollarRisk.setApprovalForAll(diamond, true);
    }

    function _signPermit(uint256 amount, uint256 deadline)
        internal
        view
        returns (IStaticsDollarGateway.PermitSignature memory signature)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, diamond, amount, staticsDollar.nonces(alice), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", staticsDollar.DOMAIN_SEPARATOR(), structHash));
        (signature.v, signature.r, signature.s) = vm.sign(aliceKey, digest);
        signature.deadline = deadline;
    }

    function _signTokenPermit(IERC20Permit token, uint256 amount, uint256 deadline)
        internal
        view
        returns (IStaticsDollarGateway.PermitSignature memory signature)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, diamond, amount, token.nonces(alice), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (signature.v, signature.r, signature.s) = vm.sign(aliceKey, digest);
        signature.deadline = deadline;
    }

    function _wrapAndApprove(address account, uint256 amount, address spender) internal {
        vm.prank(account);
        weth.deposit{value: amount}();
        vm.prank(account);
        weth.approve(spender, amount);
    }

    function _assertNoUnreservedGatewayResidue(uint256 seriesId) internal view {
        assertEq(weth.balanceOf(diamond), custody.globalReservedByToken(address(weth)));
        assertEq(staticsDollar.balanceOf(diamond), custody.globalReservedByToken(address(staticsDollar)));
        assertEq(staticsDollarRisk.balanceOf(diamond, seriesId), 0);
        assertEq(weth.allowance(diamond, address(pool)), 0);
    }

    function _activatePeggedProfile() internal returns (uint256 profileId, MockUSDC usdc, MockETHUSDOracle pegOracle) {
        usdc = new MockUSDC();
        pegOracle = new MockETHUSDOracle(1e18, MAX_STALENESS);
        vm.prank(owner);
        profileId = CoreGovernanceFacet(address(pool))
            .createPeggedCollateralProfile(address(usdc), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(address(pool)).setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }
}
