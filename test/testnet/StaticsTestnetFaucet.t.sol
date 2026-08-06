// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStaticsTestnetFaucet} from "../../script/DeployStaticsTestnetFaucet.s.sol";
import {StaticsTestnetFaucet} from "../../src/testnet/StaticsTestnetFaucet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StaticsTestnetFaucetTest is Test {
    StaticsTestnetFaucet private faucet;
    MockERC20[5] private tokens;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        tokens[0] = new MockERC20("USDG", "USDG", 6);
        tokens[1] = new MockERC20("Statics", "STATICS", 18);
        tokens[2] = new MockERC20("Tesla", "TSLA", 18);
        tokens[3] = new MockERC20("Palantir", "PLTR", 18);
        tokens[4] = new MockERC20("AMD", "AMD", 18);

        address[5] memory assets;
        for (uint256 i; i < assets.length; ++i) {
            assets[i] = address(tokens[i]);
        }

        faucet = new DeployStaticsTestnetFaucet().deploy(assets);
        _fundClaims(3);
        vm.warp(10 days);
    }

    function testDeploysFixedFixtureConfiguration() public view {
        assertEq(faucet.ASSET_COUNT(), 5);
        assertEq(faucet.COOLDOWN(), 1 days);

        for (uint256 i; i < 5; ++i) {
            (address token, uint256 amount) = faucet.asset(i);
            assertEq(token, address(tokens[i]));
            assertEq(amount, _amount(i));
        }
    }

    function testDeploymentScriptLoadsConfiguredAssetsAndRejectsMissingCode() public {
        _configureDeploymentAssets();

        DeployStaticsTestnetFaucet deployment = new DeployStaticsTestnetFaucet();
        address[5] memory assets = deployment.loadAssets();

        for (uint256 i; i < assets.length; ++i) {
            assertEq(assets[i], address(tokens[i]));
        }

        vm.setEnv("STATICS_FAUCET_AMD", vm.toString(address(0xBEEF)));

        vm.expectRevert(abi.encodeWithSelector(DeployStaticsTestnetFaucet.InvalidAsset.selector, 4, address(0xBEEF)));
        deployment.loadAssets();

        _configureDeploymentAssets();
        vm.setEnv("STATICS_FAUCET_AMD", vm.toString(address(tokens[3])));
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsTestnetFaucet.DuplicateAsset.selector, 4, 3, address(tokens[3]))
        );
        deployment.loadAssets();

        _configureDeploymentAssets();
        vm.setEnv("STATICS_FAUCET_USDG", vm.toString(address(tokens[1])));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsTestnetFaucet.InvalidAssetDecimals.selector, 0, address(tokens[1]), 6, 18
            )
        );
        deployment.loadAssets();
    }

    function testClaimTransfersCompleteBundleAndStartsCooldown() public {
        vm.prank(alice);
        faucet.claim();

        for (uint256 i; i < 5; ++i) {
            assertEq(tokens[i].balanceOf(alice), _amount(i));
        }
        assertEq(faucet.lastClaimAt(alice), block.timestamp);
        assertEq(faucet.nextClaimAt(alice), block.timestamp + 1 days);
    }

    function testDifferentWalletCanClaimDuringAnotherWalletCooldown() public {
        vm.prank(alice);
        faucet.claim();

        vm.prank(bob);
        faucet.claim();

        for (uint256 i; i < 5; ++i) {
            assertEq(tokens[i].balanceOf(alice), _amount(i));
            assertEq(tokens[i].balanceOf(bob), _amount(i));
        }
    }

    function testClaimRevertsBeforeCooldownExpires() public {
        vm.prank(alice);
        faucet.claim();

        uint256 nextClaim = block.timestamp + 1 days;
        vm.warp(nextClaim - 1);
        vm.expectRevert(abi.encodeWithSelector(StaticsTestnetFaucet.ClaimNotReady.selector, nextClaim));
        vm.prank(alice);
        faucet.claim();
    }

    function testClaimSucceedsAtExactCooldownBoundary() public {
        vm.prank(alice);
        faucet.claim();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        faucet.claim();

        for (uint256 i; i < 5; ++i) {
            assertEq(tokens[i].balanceOf(alice), _amount(i) * 2);
        }
    }

    function testUnderfundedBundleRevertsBeforeAnyTransferOrCooldown() public {
        uint256 available = tokens[4].balanceOf(address(faucet));
        vm.prank(address(faucet));
        tokens[4].transfer(address(1), available);

        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsTestnetFaucet.FaucetUnderfunded.selector, address(tokens[4]), 0, faucet.STOCK_AMOUNT()
            )
        );
        vm.prank(alice);
        faucet.claim();

        for (uint256 i; i < 5; ++i) {
            assertEq(tokens[i].balanceOf(alice), 0);
        }
        assertEq(faucet.lastClaimAt(alice), 0);
    }

    function testFuzzClaimRemainsUnavailableUntilExactBoundary(uint40 elapsed) public {
        vm.prank(alice);
        faucet.claim();

        elapsed = uint40(bound(elapsed, 0, 1 days - 1));
        uint256 nextClaim = block.timestamp + 1 days;
        vm.warp(block.timestamp + elapsed);

        vm.expectRevert(abi.encodeWithSelector(StaticsTestnetFaucet.ClaimNotReady.selector, nextClaim));
        vm.prank(alice);
        faucet.claim();
    }

    function _fundClaims(uint256 count) private {
        for (uint256 i; i < 5; ++i) {
            tokens[i].mint(address(faucet), _amount(i) * count);
        }
    }

    function _configureDeploymentAssets() private {
        vm.setEnv("STATICS_FAUCET_USDG", vm.toString(address(tokens[0])));
        vm.setEnv("STATICS_FAUCET_STATICS", vm.toString(address(tokens[1])));
        vm.setEnv("STATICS_FAUCET_TSLA", vm.toString(address(tokens[2])));
        vm.setEnv("STATICS_FAUCET_PLTR", vm.toString(address(tokens[3])));
        vm.setEnv("STATICS_FAUCET_AMD", vm.toString(address(tokens[4])));
    }

    function _amount(uint256 index) private view returns (uint256) {
        if (index == 0) return faucet.USDG_AMOUNT();
        if (index == 1) return faucet.STATICS_AMOUNT();
        return faucet.STOCK_AMOUNT();
    }
}
