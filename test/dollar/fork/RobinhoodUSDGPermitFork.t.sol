// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {RobinhoodDollarFork} from "test/dollar/helpers/RobinhoodDollarFork.sol";

import {StaticsDollarStackDeployment} from "script/dollar/DeployStaticsDollar.s.sol";
import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";

interface IRobinhoodUSDG is IERC20Metadata, IERC20Permit {
    function PERMIT_TYPEHASH() external view returns (bytes32);
}

contract RobinhoodUSDGPermitForkTest is RobinhoodDollarFork {
    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    string private manifest;
    IRobinhoodUSDG private usdg;
    IStaticsDollarCore private core;
    IStaticsDollarGateway private gateway;
    StaticsDollar private staticsDollar;
    uint256 private profileId;
    address private owner;
    uint256 private aliceKey;
    address private alice;

    function setUp() public override {
        super.setUp();
        manifest = vm.readFile(MANIFEST_PATH);
        owner = makeAddr("robinhoodProductionOwner");
        (alice, aliceKey) = makeAddrAndKey("alice");
        usdg = IRobinhoodUSDG(RH_USDG);

        StaticsDollarStackDeployment memory deployment = deployProduction(_productionConfig());
        core = IStaticsDollarCore(deployment.core);
        gateway = IStaticsDollarGateway(deployment.diamond);
        staticsDollar = StaticsDollar(deployment.staticsDollar);

        ChainlinkUsdOracle pegOracle =
            new ChainlinkUsdOracle(RH_USDG_USD, FEED_MAX_AGE, 0.9e18, 1.1e18, RH_SEQUENCER, SEQUENCER_GRACE);
        vm.prank(owner);
        profileId = CoreGovernanceFacet(address(core))
            .createPeggedCollateralProfile(address(usdg), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(address(core)).setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }

    function testCanonicalUSDGCodeAndPermitMetadataMatchManifest() public view {
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.usdg.runtimeCodeHash");

        assertEq(address(usdg), vm.parseJsonAddress(manifest, ".contracts.usdg.address"));
        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        assertEq(address(usdg).codehash, expectedCodeHash);
        assertEq(usdg.name(), "Global Dollar");
        assertEq(usdg.symbol(), "USDG");
        assertEq(usdg.decimals(), 6);
        assertEq(usdg.PERMIT_TYPEHASH(), PERMIT_TYPEHASH);
        assertTrue(usdg.DOMAIN_SEPARATOR() != bytes32(0));
    }

    function testLiveUSDGReusablePermitMintsAndRedeemsThroughStatics() public {
        // The pinned USDG price is just below $1; back the mint through the real top-up rail.
        deal(address(usdg), alice, 1e6, false);
        vm.startPrank(alice);
        usdg.approve(address(core), 1e6);
        core.topUpInsurance(profileId, 1e6);
        vm.stopPrank();

        uint256 staticsDollarAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview =
            core.previewPeggedMint(profileId, staticsDollarAmount);
        deal(address(usdg), alice, mintPreview.totalCollateralIn, false);
        IStaticsDollarGateway.PermitSignature memory mintPermit =
            _signPermit(usdg, type(uint256).max, block.timestamp + 20 minutes);

        vm.prank(alice);
        uint256 collateralIn = gateway.mintPeggedWithPermit(
            profileId, staticsDollarAmount, mintPreview.totalCollateralIn, alice, mintPermit
        );

        assertEq(collateralIn, mintPreview.totalCollateralIn);
        assertEq(usdg.nonces(alice), 1);
        assertGe(usdg.allowance(alice, address(gateway)), type(uint256).max - mintPreview.totalCollateralIn);
        assertEq(staticsDollar.balanceOf(alice), staticsDollarAmount);

        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory redemptionPreview =
            core.previewPeggedRedemption(profileId, staticsDollarAmount);
        IStaticsDollarGateway.PermitSignature memory redemptionPermit =
            _signPermit(staticsDollar, type(uint256).max, block.timestamp + 20 minutes);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) = gateway.redeemPeggedWithPermit(
            profileId, staticsDollarAmount, redemptionPreview.collateralOut, alice, redemptionPermit
        );

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, redemptionPreview.collateralOut);
        assertEq(staticsDollar.nonces(alice), 1);
        assertGe(staticsDollar.allowance(alice, address(gateway)), type(uint256).max - staticsDollarAmount);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(alice), redemptionPreview.collateralOut);
    }

    function _signPermit(IERC20Permit token, uint256 amount, uint256 deadline)
        private
        view
        returns (IStaticsDollarGateway.PermitSignature memory signature)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, address(gateway), amount, token.nonces(alice), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (signature.v, signature.r, signature.s) = vm.sign(aliceKey, digest);
        signature.value = amount;
        signature.deadline = deadline;
    }
}
