// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
import {IStaticsPositionFees} from "src/interfaces/IStaticsPosition.sol";
import {MockAdversarialPeggedCollateral} from "../helpers/MockAdversarialPeggedCollateral.sol";
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
        uint256 positionFee = 0.001 ether;
        vm.prank(owner);
        IStaticsPositionFees(diamond).setPositionCreationFee(positionFee);
        uint256 treasuryBefore = owner.balance;
        vm.startPrank(alice);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        uint256 positionId = staking.createAndStakeRiskShares{value: positionFee}(SERIES_ONE, 1e18, alice);
        vm.stopPrank();

        assertEq(IERC721(diamond).ownerOf(positionId), alice);
        assertEq(staking.riskLiquidity(positionId, SERIES_ONE).effectiveShares, 1e18);
        assertEq(owner.balance, treasuryBefore + positionFee);

        vm.prank(alice);
        staking.stakeRiskShares(positionId, SERIES_ONE, 1e18);
        assertEq(owner.balance, treasuryBefore + positionFee);
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

    function testPeggedMintWithPermitPreservesReusableCollateralAllowance() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, type(uint256).max, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 collateralIn =
            gateway.mintPeggedWithPermit(profileId, 100e18, preview.totalCollateralIn, alice, signature);

        assertEq(collateralIn, preview.totalCollateralIn);
        assertEq(usdc.nonces(alice), 1);
        assertEq(usdc.allowance(alice, diamond), type(uint256).max);
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

    function testPeggedRedemptionWithPermitPreservesReusableDollarAllowance() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = pool.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, mintPreview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, mintPreview.totalCollateralIn);
        gateway.mintPegged(profileId, 100e18, mintPreview.totalCollateralIn, alice);
        vm.stopPrank();
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview = pool.previewPeggedRedemption(profileId, 100e18);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signPermit(type(uint256).max, block.timestamp + 1 hours);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            gateway.redeemPeggedWithPermit(profileId, 100e18, preview.collateralOut, receiver, signature);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, preview.collateralOut);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, diamond), type(uint256).max);
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

    function testAtomicPeggedMintAndRecombinePreservesSupplyAndMigratesSeniorLiability() public {
        _depositToAliceThroughGateway(1 ether);
        uint256 riskAmount = 100e18;
        uint256 aliceDollarBalance = staticsDollar.balanceOf(alice);
        vm.prank(alice);
        staticsDollar.transfer(staticsDollarReceiver, aliceDollarBalance);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();

        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview =
            pool.previewPeggedMint(peggedProfileId, riskAmount);
        IStaticsDollarCoreTypes.RedemptionPreview memory recombinationPreview =
            pool.previewRecombine(SERIES_ONE, riskAmount);
        assertTrue(quote.eligible);
        assertEq(quote.staticsDollarAmount, riskAmount);
        assertEq(quote.peggedCollateralPrincipal, mintPreview.principalCollateral);
        assertEq(quote.peggedMintFee, mintPreview.feeAmount);
        assertEq(quote.totalPeggedCollateralIn, mintPreview.totalCollateralIn);
        assertEq(quote.volatileCollateralOut, recombinationPreview.collateralOut);
        assertEq(quote.volatileRecombinationFee, recombinationPreview.feeAmount);

        usdc.mint(alice, quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, quote.totalPeggedCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();

        uint256 supplyBefore = staticsDollar.totalSupply();
        uint256 totalSeniorBefore = pool.seniorLiabilities();
        uint256 peggedSeniorBefore = pool.collateralProfile(peggedProfileId).seniorOutstanding;
        IStaticsDollarCoreTypes.RiskSeries memory seriesBefore = pool.riskSeries(SERIES_ONE);
        uint256 riskBefore = staticsDollarRisk.balanceOf(alice, SERIES_ONE);
        uint256 dollarReservationBefore = custody.globalReservedByToken(address(staticsDollar));
        uint256 wethReservationBefore = custody.globalReservedByToken(address(weth));

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 peggedCollateralIn, uint256 volatileCollateralOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            riskAmount,
            quote.totalPeggedCollateralIn,
            quote.volatileCollateralOut,
            receiver
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(peggedCollateralIn, quote.totalPeggedCollateralIn);
        assertEq(volatileCollateralOut, quote.volatileCollateralOut);
        assertEq(weth.balanceOf(receiver), quote.volatileCollateralOut);
        assertEq(staticsDollar.totalSupply(), supplyBefore);
        assertEq(pool.seniorLiabilities(), totalSeniorBefore);
        assertEq(pool.collateralProfile(peggedProfileId).seniorOutstanding, peggedSeniorBefore + riskAmount);
        assertEq(pool.riskSeries(SERIES_ONE).seniorOutstanding, seriesBefore.seniorOutstanding - riskAmount);
        assertEq(pool.riskSeries(SERIES_ONE).riskSharesOutstanding, seriesBefore.riskSharesOutstanding - riskAmount);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), riskBefore - riskAmount);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(staticsDollar.allowance(alice, diamond), 0);
        assertEq(usdc.balanceOf(address(pool)), quote.peggedCollateralPrincipal);
        assertEq(usdc.balanceOf(address(pool)) + usdc.balanceOf(diamond), quote.totalPeggedCollateralIn);
        assertEq(globalRewards.treasuryAccrued(address(usdc)), quote.peggedMintFee);
        assertEq(globalRewards.treasuryAccrued(address(weth)), quote.volatileRecombinationFee);
        assertEq(custody.globalReservedByToken(address(staticsDollar)), dollarReservationBefore);
        assertEq(custody.globalReservedByToken(address(weth)), wethReservationBefore + quote.volatileRecombinationFee);
        assertEq(usdc.allowance(diamond, address(pool)), 0);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
    }

    function testAtomicRouteMatchesSeparatePeggedMintAndOrdinaryRecombination() public {
        _depositToAliceThroughGateway(1 ether);
        uint256 riskAmount = 100e18;
        uint256 aliceDollarBalance = staticsDollar.balanceOf(alice);
        vm.prank(alice);
        staticsDollar.transfer(staticsDollarReceiver, aliceDollarBalance);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, quote.totalPeggedCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();
        uint256 state = vm.snapshotState();

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status,, uint256 atomicOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, quote.totalPeggedCollateralIn, 0, receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        bytes32 atomicState = keccak256(
            abi.encode(
                staticsDollar.totalSupply(),
                pool.collateralProfile(peggedProfileId),
                pool.riskSeries(SERIES_ONE),
                usdc.balanceOf(address(pool)),
                usdc.balanceOf(diamond),
                weth.balanceOf(address(pool)),
                weth.balanceOf(receiver),
                globalRewards.treasuryAccrued(address(usdc)),
                globalRewards.treasuryAccrued(address(weth))
            )
        );

        assertTrue(vm.revertToState(state));
        vm.startPrank(alice);
        gateway.mintPegged(peggedProfileId, riskAmount, quote.totalPeggedCollateralIn, alice);
        staticsDollar.approve(diamond, riskAmount);
        (, uint256 separateOut) = gateway.recombineToWETH(SERIES_ONE, riskAmount, riskAmount, receiver, 0);
        vm.stopPrank();
        bytes32 separateState = keccak256(
            abi.encode(
                staticsDollar.totalSupply(),
                pool.collateralProfile(peggedProfileId),
                pool.riskSeries(SERIES_ONE),
                usdc.balanceOf(address(pool)),
                usdc.balanceOf(diamond),
                weth.balanceOf(address(pool)),
                weth.balanceOf(receiver),
                globalRewards.treasuryAccrued(address(usdc)),
                globalRewards.treasuryAccrued(address(weth))
            )
        );

        assertEq(atomicOut, separateOut);
        assertEq(atomicState, separateState);
    }

    function testAtomicRouteEnforcesDebtCeilingAndPegHealthBeforeCustody() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc, MockETHUSDOracle pegOracle) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.prank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        _approveRiskClaims(alice);

        vm.prank(owner);
        CoreGovernanceFacet(address(pool)).reduceDebtCeiling(peggedProfileId, riskAmount - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreMintFacet.DebtCeilingExceeded.selector, peggedProfileId, riskAmount, riskAmount - 1
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(usdc.balanceOf(alice), preview.totalCollateralIn);

        pegOracle.setPriceWad(0.99e18);
        pegOracle.setUpdatedAt(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CoreMintFacet.PegOutOfBounds.selector, peggedProfileId, 0.99e18, 0.995e18, 1.005e18)
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(usdc.balanceOf(alice), preview.totalCollateralIn);
    }

    function testAtomicRouteDefersAndPersistsImpairmentWithoutTakingCustody() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();
        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);

        vm.expectEmit(true, true, true, true, diamond);
        emit IStaticsDollarGateway.PeggedMintAndRecombineDeferred(
            alice,
            receiver,
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            IStaticsDollarCoreTypes.ExitStatus.Impaired,
            uint256(1) << WETH_PROFILE
        );
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 peggedCollateralIn, uint256 volatileCollateralOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(peggedCollateralIn, 0);
        assertEq(volatileCollateralOut, 0);
        assertTrue(pool.globalImpairmentLatched());
        assertEq(usdc.balanceOf(alice), preview.totalCollateralIn);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT);
        assertEq(staticsDollar.balanceOf(diamond), custody.globalReservedByToken(address(staticsDollar)));
    }

    function testAtomicDeferralRejectsStructurallyInvalidRequests() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId,,) = _activatePeggedProfile();
        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);

        vm.prank(alice);
        vm.expectRevert(IStaticsDollarGateway.ZeroAmount.selector);
        gateway.mintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, 0, type(uint256).max, 0, receiver);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.InvalidProfileKind.selector,
                WETH_PROFILE,
                IStaticsDollarCoreTypes.ProfileKind.Pegged,
                IStaticsDollarCoreTypes.ProfileKind.Volatile
            )
        );
        gateway.mintPeggedAndRecombine(WETH_PROFILE, WETH_PROFILE, SERIES_ONE, 100e18, type(uint256).max, 0, receiver);

        vm.prank(owner);
        CoreGovernanceFacet(address(pool)).enterReduceOnly(peggedProfileId);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.InvalidProfileMode.selector,
                peggedProfileId,
                IStaticsDollarCoreTypes.ProfileMode.ReduceOnly
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, 100e18, type(uint256).max, 0, receiver
        );
    }

    function testAtomicSelectedPeggedProfileImpairmentStartsFullRecoveryDelay() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc, MockETHUSDOracle pegOracle) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        usdc.mint(alice, preview.totalCollateralIn * 2);
        vm.startPrank(alice);
        usdc.approve(diamond, type(uint256).max);
        gateway.mintPegged(peggedProfileId, riskAmount, preview.totalCollateralIn, alice);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();

        uint256 collateralBefore = usdc.balanceOf(alice);
        uint256 riskBefore = staticsDollarRisk.balanceOf(alice, SERIES_ONE);
        pegOracle.setPriceWad(0.99e18);
        pegOracle.setUpdatedAt(block.timestamp);

        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        assertFalse(quote.eligible);
        assertEq(uint8(quote.exitStatus), uint8(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(quote.peggedCollateralToken, address(usdc));

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralIn, uint256 collateralOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(collateralIn, 0);
        assertEq(collateralOut, 0);
        assertTrue(pool.globalImpairmentLatched());
        assertEq(usdc.balanceOf(alice), collateralBefore);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), riskBefore);

        pegOracle.setPriceWad(1e18);
        pegOracle.setUpdatedAt(block.timestamp);
        vm.prank(alice);
        (status,,) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Recovering));

        vm.warp(block.timestamp + 48 hours - 1);
        oracle.setUpdatedAt(block.timestamp);
        pegOracle.setUpdatedAt(block.timestamp);
        quote = gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        assertFalse(quote.eligible);
        assertEq(uint8(quote.exitStatus), uint8(IStaticsDollarCoreTypes.ExitStatus.Recovering));

        vm.warp(block.timestamp + 1);
        oracle.setUpdatedAt(block.timestamp);
        pegOracle.setUpdatedAt(block.timestamp);
        quote = gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        assertTrue(quote.eligible);
        assertEq(uint8(quote.exitStatus), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
    }

    function testAtomicQuoteMatchesCheckpointWhenGlobalRecoveryMatures() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc, MockETHUSDOracle pegOracle) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.stopPrank();

        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status,,) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Impaired));

        oracle.setPriceWad(PRICE_WAD);
        oracle.setUpdatedAt(block.timestamp);
        vm.prank(alice);
        (status,,) = gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Recovering));
        assertTrue(pool.globalImpairmentLatched());

        vm.warp(block.timestamp + 48 hours);
        oracle.setUpdatedAt(block.timestamp);
        pegOracle.setUpdatedAt(block.timestamp);
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        assertTrue(quote.eligible);
        assertEq(uint8(quote.exitStatus), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));

        uint256 peggedCollateralIn;
        uint256 volatileCollateralOut;
        vm.prank(alice);
        (status, peggedCollateralIn, volatileCollateralOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            riskAmount,
            preview.totalCollateralIn,
            quote.volatileCollateralOut,
            receiver
        );
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(peggedCollateralIn, preview.totalCollateralIn);
        assertEq(volatileCollateralOut, quote.volatileCollateralOut);
        assertFalse(pool.globalImpairmentLatched());
    }

    function testAtomicRouteRejectsWrongProfileMissingApprovalAndOrdinaryLifecycleMismatch() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.prank(alice);
        usdc.approve(diamond, preview.totalCollateralIn);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.UnexpectedCollateralProfile.selector, peggedProfileId, WETH_PROFILE
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, peggedProfileId, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, diamond, alice));
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );

        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);
        CoreTransitionFacet(address(pool)).startSeriesTransition(WETH_PROFILE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.SeriesUnavailableForOrdinaryRecombination.selector,
                SERIES_ONE,
                IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
    }

    function testAtomicRouteRejectsInactiveVolatileProfileBeforeCustody() public {
        (uint256 peggedProfileId,,) = _activatePeggedProfile();
        CanonicalWETH9 inactiveCollateral = new CanonicalWETH9();
        MockETHUSDOracle inactiveOracle = new MockETHUSDOracle(PRICE_WAD, MAX_STALENESS);
        vm.prank(owner);
        (uint256 inactiveProfileId, uint256 inactiveSeriesId) = CoreGovernanceFacet(address(pool))
            .createCollateralProfile(
                address(inactiveCollateral),
                address(inactiveOracle),
                COLLATERAL_RATIO_BPS,
                PRICE_BAND_BPS,
                0,
                0,
                type(uint256).max
            );

        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, inactiveProfileId, inactiveSeriesId, 100e18);
        assertFalse(quote.eligible);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.InvalidProfileMode.selector,
                inactiveProfileId,
                IStaticsDollarCoreTypes.ProfileMode.Inactive
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, inactiveProfileId, inactiveSeriesId, 100e18, type(uint256).max, 0, receiver
        );
    }

    function testAtomicRouteEnforcesBothInputAndObservedOutputBounds() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, quote.totalPeggedCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.CollateralAboveMaximum.selector,
                quote.totalPeggedCollateralIn,
                quote.totalPeggedCollateralIn - 1
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, quote.totalPeggedCollateralIn - 1, 0, receiver
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.OutputBelowMinimum.selector,
                quote.volatileCollateralOut,
                quote.volatileCollateralOut + 1
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            riskAmount,
            quote.totalPeggedCollateralIn,
            quote.volatileCollateralOut + 1,
            receiver
        );
        vm.stopPrank();
    }

    function testAtomicPermitToleratesFrontrunAndInvalidPermitNeedsAllowance() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        _approveRiskClaims(alice);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, quote.totalPeggedCollateralIn, block.timestamp + 1 hours);

        vm.prank(receiver);
        usdc.permit(
            alice, diamond, quote.totalPeggedCollateralIn, signature.deadline, signature.v, signature.r, signature.s
        );
        vm.prank(alice);
        gateway.mintPeggedAndRecombineWithPermit(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, quote.totalPeggedCollateralIn, 0, receiver, signature
        );
        assertEq(usdc.nonces(alice), 1);
        assertEq(usdc.allowance(alice, diamond), 0);

        uint256 secondAmount = 50e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory secondQuote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, secondAmount);
        usdc.mint(alice, secondQuote.totalPeggedCollateralIn);
        IStaticsDollarGateway.PermitSignature memory expired =
            _signTokenPermit(usdc, secondQuote.totalPeggedCollateralIn, block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, diamond, 0, secondQuote.totalPeggedCollateralIn
            )
        );
        gateway.mintPeggedAndRecombineWithPermit(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            secondAmount,
            secondQuote.totalPeggedCollateralIn,
            0,
            receiver,
            expired
        );
    }

    function testAtomicPermitConsumesFreshSignatureForAvailableExit() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        _approveRiskClaims(alice);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, quote.totalPeggedCollateralIn, block.timestamp + 1 hours);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 peggedCollateralIn, uint256 volatileCollateralOut) = gateway.mintPeggedAndRecombineWithPermit(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            riskAmount,
            quote.totalPeggedCollateralIn,
            quote.volatileCollateralOut,
            receiver,
            signature
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(peggedCollateralIn, quote.totalPeggedCollateralIn);
        assertEq(volatileCollateralOut, quote.volatileCollateralOut);
        assertEq(usdc.nonces(alice), 1);
        assertEq(usdc.allowance(alice, diamond), 0);
    }

    function testAtomicPermitDeferralPreservesSignatureAndImpairmentLatch() public {
        _depositToAliceThroughGateway(1 ether);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 riskAmount = 100e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        _approveRiskClaims(alice);
        IStaticsDollarGateway.PermitSignature memory signature =
            _signTokenPermit(usdc, quote.totalPeggedCollateralIn, block.timestamp + 1 hours);
        oracle.setPriceWad(1_500e18);
        oracle.setUpdatedAt(block.timestamp);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 peggedCollateralIn, uint256 volatileCollateralOut) = gateway.mintPeggedAndRecombineWithPermit(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, quote.totalPeggedCollateralIn, 0, receiver, signature
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(peggedCollateralIn, 0);
        assertEq(volatileCollateralOut, 0);
        assertEq(usdc.nonces(alice), 0);
        assertEq(usdc.allowance(alice, diamond), 0);
        assertTrue(pool.globalImpairmentLatched());
        assertEq(usdc.balanceOf(alice), quote.totalPeggedCollateralIn);
    }

    function testAtomicRouteRejectsFeeOnTransferPeggedCollateralByMeasuredIngress() public {
        _depositToAliceThroughGateway(1 ether);
        MockAdversarialPeggedCollateral token = new MockAdversarialPeggedCollateral();
        (uint256 peggedProfileId,) = _activatePeggedProfileFor(address(token));
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        token.mint(alice, preview.totalCollateralIn);
        token.setTransferFeeBps(100);
        vm.startPrank(alice);
        token.approve(diamond, preview.totalCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        uint256 observed = preview.totalCollateralIn - ((preview.totalCollateralIn * 100) / 10_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsDollarGateway.InsufficientTransferReceived.selector,
                address(token),
                preview.totalCollateralIn,
                observed
            )
        );
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        vm.stopPrank();
    }

    function testAtomicRouteRejectsPeggedCollateralReentrancy() public {
        _depositToAliceThroughGateway(1 ether);
        MockAdversarialPeggedCollateral token = new MockAdversarialPeggedCollateral();
        (uint256 peggedProfileId,) = _activatePeggedProfileFor(address(token));
        uint256 riskAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = pool.previewPeggedMint(peggedProfileId, riskAmount);
        token.mint(alice, preview.totalCollateralIn);
        bytes memory callback = abi.encodeCall(
            IStaticsDollarGateway.mintPeggedAndRecombine,
            (peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver)
        );
        token.setCallback(diamond, callback, true);
        vm.startPrank(alice);
        token.approve(diamond, preview.totalCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        gateway.mintPeggedAndRecombine(
            peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount, preview.totalCollateralIn, 0, receiver
        );
        vm.stopPrank();
    }

    function testFuzzAtomicRouteMatchesQuotesAcrossRoundingBoundaries(uint128 rawAmount) public {
        _depositToAliceThroughGateway(1 ether);
        uint256 riskAmount = bound(uint256(rawAmount), 1e12, 500e18);
        (uint256 peggedProfileId, MockUSDC usdc,) = _activatePeggedProfile();
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE, SERIES_ONE, riskAmount);
        assertTrue(quote.eligible);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        usdc.approve(diamond, quote.totalPeggedCollateralIn);
        staticsDollarRisk.setApprovalForAll(diamond, true);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralIn, uint256 collateralOut) = gateway.mintPeggedAndRecombine(
            peggedProfileId,
            WETH_PROFILE,
            SERIES_ONE,
            riskAmount,
            quote.totalPeggedCollateralIn,
            quote.volatileCollateralOut,
            receiver
        );
        vm.stopPrank();
        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralIn, quote.totalPeggedCollateralIn);
        assertEq(collateralOut, quote.volatileCollateralOut);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ONE), ONE_ETH_MINT - riskAmount);
        assertEq(usdc.allowance(diamond, address(pool)), 0);
        _assertNoUnreservedGatewayResidue(SERIES_ONE);
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
        signature.value = amount;
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
        signature.value = amount;
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
        (profileId, pegOracle) = _activatePeggedProfileFor(address(usdc));
    }

    function _activatePeggedProfileFor(address collateralToken)
        internal
        returns (uint256 profileId, MockETHUSDOracle pegOracle)
    {
        pegOracle = new MockETHUSDOracle(1e18, MAX_STALENESS);
        vm.prank(owner);
        profileId = CoreGovernanceFacet(address(pool))
            .createPeggedCollateralProfile(collateralToken, address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(address(pool)).setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }
}
