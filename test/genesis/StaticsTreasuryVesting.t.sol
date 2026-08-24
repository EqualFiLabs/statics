// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";
import {MockGenesisFeeReceiver} from "../mocks/MockGenesisCreditDependencies.sol";

contract RejectingGenesisRecipient {
    fallback() external {
        revert("REJECTED");
    }
}

contract ReentrantGenesisRecipient is IERC721Receiver {
    StaticsTreasuryVesting public immutable vesting;
    bool public reentryRejected;

    constructor(StaticsTreasuryVesting vesting_) {
        vesting = vesting_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        try vesting.releaseGenesis(1) {}
        catch {
            reentryRejected = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract StaticsTreasuryVestingTest is Test {
    address private governance;
    address private treasury;
    address private successor;
    MockDopplerToken private statics;
    GenesisActivationRegistry private registry;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;
    StaticsTreasuryVesting private vesting;

    function setUp() public {
        governance = makeAddr("governance-safe");
        treasury = makeAddr("treasury-safe");
        successor = makeAddr("successor-safe");
        vesting = new StaticsTreasuryVesting(address(this), governance, treasury);
        statics = new MockDopplerToken(address(this));
        registry = new GenesisActivationRegistry(statics, address(this), governance, treasury);
        MockGenesisFeeReceiver feeReceiver = new MockGenesisFeeReceiver(address(statics));
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: 0.003 ether,
            extensionFee: 0.003 ether,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(vesting), governance, block.timestamp + 365 days, creditConfig);
        genesis = new StaticsGenesis(
            address(vault),
            address(vesting),
            address(registry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            governance,
            treasury,
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        statics.transfer(address(vesting), vesting.PROTOCOL_ALLOCATION());
        vesting.finalizeBootstrap(address(statics), address(vault), address(genesis));
    }

    function testBootstrapCommitsExactReserveAndVestingCustody() public view {
        assertEq(address(vesting.statics()), address(statics));
        assertEq(address(vesting.genesisVault()), address(vault));
        assertEq(address(vesting.genesis()), address(genesis));
        assertEq(vesting.bootstrapper(), address(0));
        assertEq(statics.balanceOf(address(vesting)), 100_100_000 ether);
        assertEq(statics.balanceOf(address(vault)), 99_900_000 ether);
        assertEq(vault.tokenBacking(), 99_900_000 ether);
        assertEq(vault.requiredBacking(), 99_900_000 ether);
        assertEq(vault.circulatingGenesis(), 555);
        assertEq(vault.vaultInventory(), 5_000);
        assertEq(genesis.balanceOf(address(vesting)), 555);
        assertEq(genesis.ownerOf(5_001), address(vesting));
        assertEq(genesis.ownerOf(5_555), address(vesting));
        assertEq(vesting.releasableStatics(), 0);
        assertEq(vesting.releasableGenesis(), 0);
    }

    function testBootstrapRoutesResidualAsUnaccountedVaultSurplus() public {
        StaticsTreasuryVesting residualVesting = new StaticsTreasuryVesting(address(this), governance, treasury);
        MockDopplerToken residualToken = new MockDopplerToken(address(this));
        GenesisActivationRegistry residualRegistry =
            new GenesisActivationRegistry(residualToken, address(this), governance, treasury);
        MockGenesisFeeReceiver receiver = new MockGenesisFeeReceiver(address(residualToken));
        GenesisCreditConfig memory config = GenesisCreditConfig({
            feeReceiver: address(receiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        StaticsGenesisVault residualVault = new StaticsGenesisVault(
            residualToken, address(residualVesting), governance, block.timestamp + 365 days, config
        );
        StaticsGenesis residualGenesis = new StaticsGenesis(
            address(residualVault),
            address(residualVesting),
            address(residualRegistry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            governance,
            treasury,
            "ipfs://contract.json",
            "https://statics.finance/genesis/"
        );
        residualRegistry.bindGenesisCollection(address(residualGenesis));
        residualToken.transfer(address(residualVesting), 200_000_007 ether);

        uint256 residual =
            residualVesting.finalizeBootstrap(address(residualToken), address(residualVault), address(residualGenesis));

        assertEq(residual, 7 ether);
        assertEq(residualToken.balanceOf(address(residualVesting)), 100_100_000 ether);
        assertEq(residualToken.balanceOf(address(residualVault)), 99_900_007 ether);
        assertEq(residualVault.tokenBacking(), 99_900_000 ether);
    }

    function testVestingBoundariesAndExactStaticsRelease() public {
        uint256 start = vesting.vestingStart();
        assertEq(vesting.vestedStaticsAt(start), 0);
        assertEq(vesting.vestedGenesisAt(start), 0);

        vm.warp(start + 30 days);
        assertEq(vesting.vestedStaticsAt(block.timestamp), 50_050_000 ether);
        assertEq(vesting.vestedGenesisAt(block.timestamp), 277);
        uint256 released = vesting.releaseStatics();
        assertEq(released, 50_050_000 ether);
        assertEq(statics.balanceOf(treasury), released);
        vm.expectRevert(StaticsTreasuryVesting.NothingToRelease.selector);
        vesting.releaseStatics();

        vm.warp(start + 60 days);
        assertEq(vesting.vestedStaticsAt(block.timestamp), 100_100_000 ether);
        assertEq(vesting.vestedGenesisAt(block.timestamp), 555);
        assertEq(vesting.releaseStatics(), 50_050_000 ether);
        assertEq(statics.balanceOf(treasury), 100_100_000 ether);
    }

    function testGenesisReleaseClampsToFiftyAndUsesAscendingIds() public {
        vm.warp(vesting.vestingStart() + 30 days);
        assertEq(vesting.releaseGenesis(500), 50);
        assertEq(vesting.releasedGenesis(), 50);
        assertEq(vesting.nextGenesisId(), 5_051);
        assertEq(genesis.ownerOf(5_001), treasury);
        assertEq(genesis.ownerOf(5_050), treasury);
        assertEq(genesis.ownerOf(5_051), address(vesting));
    }

    function testGovernanceRotationOnlyChangesFutureDestination() public {
        vm.warp(vesting.vestingStart() + 30 days);
        vesting.releaseGenesis(1);
        vm.prank(governance);
        vesting.setWithdrawalRecipient(successor);
        vesting.releaseGenesis(1);

        assertEq(genesis.ownerOf(5_001), treasury);
        assertEq(genesis.ownerOf(5_002), successor);
        assertEq(vesting.releasedGenesis(), 2);
        assertEq(vesting.vestedGenesisAt(block.timestamp), 277);
    }

    function testNonAdminCannotRotateRecipient() public {
        vm.expectRevert(
            abi.encodeWithSelector(StaticsTreasuryVesting.UnauthorizedRecipientAdmin.selector, address(this))
        );
        vesting.setWithdrawalRecipient(successor);
    }

    function testZeroBatchReverts() public {
        vm.warp(vesting.vestingStart() + 60 days);
        vm.expectRevert(StaticsTreasuryVesting.InvalidBatchSize.selector);
        vesting.releaseGenesis(0);
    }

    function testRejectingRecipientRollsBackGenesisCounter() public {
        RejectingGenesisRecipient rejecting = new RejectingGenesisRecipient();
        vm.prank(governance);
        vesting.setWithdrawalRecipient(address(rejecting));
        vm.warp(vesting.vestingStart() + 60 days);

        vm.expectRevert();
        vesting.releaseGenesis(1);
        assertEq(vesting.releasedGenesis(), 0);
        assertEq(genesis.ownerOf(5_001), address(vesting));
    }

    function testGenesisRecipientCannotReenterRelease() public {
        ReentrantGenesisRecipient recipient = new ReentrantGenesisRecipient(vesting);
        vm.prank(governance);
        vesting.setWithdrawalRecipient(address(recipient));
        vm.warp(vesting.vestingStart() + 60 days);

        assertEq(vesting.releaseGenesis(1), 1);
        assertTrue(recipient.reentryRejected());
        assertEq(vesting.releasedGenesis(), 1);
        assertEq(genesis.ownerOf(5_001), address(recipient));
    }

    function testAllScheduledAssetsCanBeReleasedAfterEnd() public {
        vm.warp(vesting.vestingStart() + 60 days);
        vesting.releaseStatics();
        while (vesting.releasableGenesis() != 0) vesting.releaseGenesis(50);

        assertEq(vesting.releasedStatics(), 100_100_000 ether);
        assertEq(vesting.releasedGenesis(), 555);
        assertTrue(vesting.vestingComplete());
        assertEq(statics.balanceOf(address(vesting)), 0);
        assertEq(genesis.balanceOf(address(vesting)), 0);
    }
}
