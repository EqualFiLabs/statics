// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

interface IRobinhoodUSDG is IERC20Metadata, IERC20Permit {
    function PERMIT_TYPEHASH() external view returns (bytes32);
}

contract RobinhoodUSDGPermitForkTest is Test {
    string private constant MANIFEST_PATH = "deployments/robinhood-chain-4663.json";
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 private constant MAX_STALENESS = 1 hours;

    string private manifest;
    IRobinhoodUSDG private usdg;
    IStaticsDollarCore private core;
    IStaticsDollarGateway private gateway;
    StaticsDollar private staticsDollar;
    uint256 private profileId;
    address private owner;
    uint256 private aliceKey;
    address private alice;

    function setUp() public {
        manifest = vm.readFile(MANIFEST_PATH);
        _selectFork();
        owner = makeAddr("owner");
        (alice, aliceKey) = makeAddrAndKey("alice");
        usdg = IRobinhoodUSDG(vm.parseJsonAddress(manifest, ".contracts.usdg.address"));

        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle wethOracle = new MockETHUSDOracle(2_500e18, MAX_STALENESS);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.stakingToken = address(usdg);
        config.initialOracle = address(wethOracle);
        config.weth = address(weth);
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = type(uint256).max;
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(config);
        core = IStaticsDollarCore(deployment.core);
        gateway = IStaticsDollarGateway(deployment.diamond);
        staticsDollar = StaticsDollar(deployment.staticsDollar);

        MockETHUSDOracle pegOracle = new MockETHUSDOracle(1e18, MAX_STALENESS);
        vm.prank(owner);
        profileId = CoreGovernanceFacet(address(core))
            .createPeggedCollateralProfile(address(usdg), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(address(core)).setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }

    function testCanonicalUSDGCodeAndPermitMetadataMatchManifest() public view {
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.usdg.runtimeCodeHash");

        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        assertEq(address(usdg).codehash, expectedCodeHash);
        assertEq(usdg.name(), "Global Dollar");
        assertEq(usdg.symbol(), "USDG");
        assertEq(usdg.decimals(), 6);
        assertEq(usdg.PERMIT_TYPEHASH(), PERMIT_TYPEHASH);
        assertTrue(usdg.DOMAIN_SEPARATOR() != bytes32(0));
    }

    function testLiveUSDGPermitMintsAndRedeemsThroughStatics() public {
        uint256 staticsDollarAmount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview =
            core.previewPeggedMint(profileId, staticsDollarAmount);
        deal(address(usdg), alice, mintPreview.totalCollateralIn, false);
        IStaticsDollarGateway.PermitSignature memory mintPermit =
            _signPermit(usdg, mintPreview.totalCollateralIn, block.timestamp + 20 minutes);

        vm.prank(alice);
        uint256 collateralIn = gateway.mintPeggedWithPermit(
            profileId, staticsDollarAmount, mintPreview.totalCollateralIn, alice, mintPermit
        );

        assertEq(collateralIn, mintPreview.totalCollateralIn);
        assertEq(usdg.nonces(alice), 1);
        assertEq(usdg.allowance(alice, address(gateway)), 0);
        assertEq(staticsDollar.balanceOf(alice), staticsDollarAmount);

        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory redemptionPreview =
            core.previewPeggedRedemption(profileId, staticsDollarAmount);
        IStaticsDollarGateway.PermitSignature memory redemptionPermit =
            _signPermit(staticsDollar, staticsDollarAmount, block.timestamp + 20 minutes);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) = gateway.redeemPeggedWithPermit(
            profileId, staticsDollarAmount, redemptionPreview.collateralOut, alice, redemptionPermit
        );

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, redemptionPreview.collateralOut);
        assertEq(staticsDollar.nonces(alice), 1);
        assertEq(staticsDollar.allowance(alice, address(gateway)), 0);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(alice), redemptionPreview.collateralOut);
    }

    function _selectFork() private {
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        if (block.chainid == vm.parseJsonUint(manifest, ".chainId")) {
            assertEq(block.number, forkBlock, "selected fork is not pinned");
            return;
        }

        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_MAINNET is not configured");
            return;
        }

        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        assertEq(block.number, forkBlock);
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
        signature.deadline = deadline;
    }
}
