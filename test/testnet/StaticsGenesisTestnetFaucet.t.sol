// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStaticsGenesisTestnetFaucet} from "../../script/DeployStaticsGenesisTestnetFaucet.s.sol";
import {StaticsGenesisTestnetFaucet} from "../../src/testnet/StaticsGenesisTestnetFaucet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StaticsGenesisTestnetFaucetTest is Test {
    MockERC20 private statics;
    StaticsGenesisTestnetFaucet private faucet;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        statics = new MockERC20("Statics", "STATICS", 18);
        faucet = new DeployStaticsGenesisTestnetFaucet().deploy(address(statics));
        statics.mint(address(faucet), faucet.CLAIM_AMOUNT() * 3);
        vm.warp(10 days);
    }

    function testDeploysOwnerlessFixedConfiguration() public view {
        assertEq(address(faucet.STATICS()), address(statics));
        assertEq(faucet.CLAIM_AMOUNT(), 200_000e18);
        assertEq(faucet.COOLDOWN(), 1 days);

        (bool success,) = address(faucet).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(success);
    }

    function testClaimTransfersBundleAndStartsPerWalletCooldown() public {
        vm.prank(alice);
        faucet.claim();
        vm.prank(bob);
        faucet.claim();

        assertEq(statics.balanceOf(alice), 200_000e18);
        assertEq(statics.balanceOf(bob), 200_000e18);
        assertEq(faucet.nextClaimAt(alice), block.timestamp + 1 days);
    }

    function testClaimRevertsUntilExactCooldownBoundary() public {
        vm.prank(alice);
        faucet.claim();
        uint256 nextClaim = block.timestamp + 1 days;

        vm.warp(nextClaim - 1);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisTestnetFaucet.ClaimNotReady.selector, nextClaim));
        vm.prank(alice);
        faucet.claim();

        vm.warp(nextClaim);
        vm.prank(alice);
        faucet.claim();
        assertEq(statics.balanceOf(alice), 400_000e18);
    }

    function testUnderfundedClaimRevertsWithoutStartingCooldown() public {
        uint256 available = statics.balanceOf(address(faucet));
        vm.prank(address(faucet));
        statics.transfer(address(1), available);

        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisTestnetFaucet.FaucetUnderfunded.selector, 0, faucet.CLAIM_AMOUNT())
        );
        vm.prank(alice);
        faucet.claim();

        assertEq(faucet.lastClaimAt(alice), 0);
        assertEq(statics.balanceOf(alice), 0);
    }

    function testDeploymentRejectsMissingCodeAndWrongDecimals() public {
        DeployStaticsGenesisTestnetFaucet deployment = new DeployStaticsGenesisTestnetFaucet();
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsGenesisTestnetFaucet.InvalidDependency.selector, address(0xBEEF))
        );
        deployment.deploy(address(0xBEEF));

        MockERC20 wrongDecimals = new MockERC20("Wrong", "WRONG", 6);
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsGenesisTestnetFaucet.InvalidStaticsDecimals.selector, uint8(6))
        );
        deployment.deploy(address(wrongDecimals));
    }

    function testFundingQuoteAddsOnePercentAndEnforcesNativeCap() public {
        DeployStaticsGenesisTestnetFaucet deployment = new DeployStaticsGenesisTestnetFaucet();
        assertEq(deployment.maximumInputForQuote(0.01 ether), 0.0101 ether);
        assertEq(deployment.maximumInputForQuote(1), 2);

        uint256 quoteAboveCap = deployment.MAX_NATIVE_INPUT();
        uint256 overCap = (quoteAboveCap * deployment.MAX_INPUT_BPS() + 9_999) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesisTestnetFaucet.NativeInputAboveCap.selector, overCap, deployment.MAX_NATIVE_INPUT()
            )
        );
        deployment.maximumInputForQuote(quoteAboveCap);
    }

    function testFuzzClaimRemainsUnavailableBeforeBoundary(uint40 elapsed) public {
        vm.prank(alice);
        faucet.claim();
        elapsed = uint40(bound(elapsed, 0, 1 days - 1));
        uint256 nextClaim = block.timestamp + 1 days;
        vm.warp(block.timestamp + elapsed);

        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisTestnetFaucet.ClaimNotReady.selector, nextClaim));
        vm.prank(alice);
        faucet.claim();
    }
}
