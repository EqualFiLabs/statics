// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {IStaticsTreasuryVesting} from "../../src/interfaces/IStaticsTreasuryVesting.sol";
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
    uint256 private constant SURPLUS = 1_000_000 ether;

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
        (vesting, statics, registry, vault, genesis) = _deployVesting(0);
    }

    function testBootstrapCommitsExactReserveAndGenesisCustody() public view {
        assertEq(address(vesting.statics()), address(statics));
        assertEq(address(vesting.genesisVault()), address(vault));
        assertEq(address(vesting.genesis()), address(genesis));
        assertEq(vesting.bootstrapper(), address(0));
        assertEq(statics.balanceOf(address(vesting)), 0);
        assertEq(statics.balanceOf(address(vault)), 99_900_000 ether);
        assertEq(vault.tokenBacking(), 99_900_000 ether);
        assertEq(vault.requiredBacking(), 99_900_000 ether);
        assertEq(vault.circulatingGenesis(), 555);
        assertEq(vault.vaultInventory(), 5_000);
        assertEq(genesis.balanceOf(address(vesting)), 555);
        assertEq(genesis.ownerOf(5_001), address(vesting));
        assertEq(genesis.ownerOf(5_555), address(vesting));
        assertEq(vesting.releasableGenesis(), 0);
    }

    function testBootstrapRetainsArbitraryPreBootstrapSurplus() public {
        (StaticsTreasuryVesting surplusVesting, MockDopplerToken surplusToken,, StaticsGenesisVault surplusVault,) =
            _deployVesting(SURPLUS);

        assertEq(surplusToken.balanceOf(address(surplusVesting)), SURPLUS);
        assertEq(surplusToken.balanceOf(address(surplusVault)), 99_900_000 ether);
        assertEq(surplusVault.tokenBacking(), 99_900_000 ether);
        assertEq(surplusVesting.releasedGenesis(), 0);
    }

    function testNonAdminCannotSweepSurplus() public {
        vm.expectRevert(
            abi.encodeWithSelector(StaticsTreasuryVesting.UnauthorizedRecipientAdmin.selector, address(this))
        );
        vesting.sweepStaticsSurplus();
    }

    function testCannotSweepBeforeBootstrap() public {
        StaticsTreasuryVesting unbootstrapped = new StaticsTreasuryVesting(address(this), governance, treasury);
        vm.prank(governance);
        vm.expectRevert(StaticsTreasuryVesting.NotBootstrapped.selector);
        unbootstrapped.sweepStaticsSurplus();
    }

    function testSweepRejectsZeroBalanceAfterBootstrap() public {
        vm.prank(governance);
        vm.expectRevert(StaticsTreasuryVesting.NothingToSweep.selector);
        vesting.sweepStaticsSurplus();
    }

    function testSweepTransfersAllSurplusToCurrentRecipientAfterBootstrap() public {
        (StaticsTreasuryVesting surplusVesting, MockDopplerToken surplusToken,, StaticsGenesisVault surplusVault,) =
            _deployVesting(SURPLUS);
        uint256 start = surplusVesting.vestingStart();
        uint256 vaultBalance = surplusToken.balanceOf(address(surplusVault));
        uint256 tokenBacking = surplusVault.tokenBacking();

        vm.prank(governance);
        surplusVesting.setWithdrawalRecipient(successor);

        vm.expectEmit(true, false, false, true, address(surplusVesting));
        emit IStaticsTreasuryVesting.StaticsSurplusSwept(successor, SURPLUS);
        vm.prank(governance);
        assertEq(surplusVesting.sweepStaticsSurplus(), SURPLUS);

        assertEq(surplusToken.balanceOf(successor), SURPLUS);
        assertEq(surplusToken.balanceOf(treasury), 0);
        assertEq(surplusToken.balanceOf(address(surplusVesting)), 0);
        assertEq(surplusVesting.releasedGenesis(), 0);
        assertEq(surplusVesting.vestingStart(), start);
        assertEq(surplusToken.balanceOf(address(surplusVault)), vaultBalance);
        assertEq(surplusVault.tokenBacking(), tokenBacking);
    }

    function testDonationsAfterBootstrapRemainRecoverable() public {
        statics.transfer(address(vesting), 7 ether);

        vm.prank(governance);
        assertEq(vesting.sweepStaticsSurplus(), 7 ether);
        assertEq(statics.balanceOf(address(vesting)), 0);

        statics.transfer(address(vesting), 9 ether);
        vm.prank(governance);
        assertEq(vesting.sweepStaticsSurplus(), 9 ether);
        assertEq(statics.balanceOf(treasury), 16 ether);
    }

    function testGenesisVestingBoundaries() public {
        uint256 start = vesting.vestingStart();
        assertEq(vesting.vestedGenesisAt(start), 0);

        vm.warp(start + 30 days);
        assertEq(vesting.vestedGenesisAt(block.timestamp), 277);

        vm.warp(start + 60 days);
        assertEq(vesting.vestedGenesisAt(block.timestamp), 555);
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
        while (vesting.releasableGenesis() != 0) vesting.releaseGenesis(50);

        assertEq(vesting.releasedGenesis(), 555);
        assertTrue(vesting.vestingComplete());
        assertEq(statics.balanceOf(address(vesting)), 0);
        assertEq(genesis.balanceOf(address(vesting)), 0);
    }

    function _deployVesting(uint256 surplus)
        private
        returns (
            StaticsTreasuryVesting deployedVesting,
            MockDopplerToken deployedStatics,
            GenesisActivationRegistry deployedRegistry,
            StaticsGenesisVault deployedVault,
            StaticsGenesis deployedGenesis
        )
    {
        deployedVesting = new StaticsTreasuryVesting(address(this), governance, treasury);
        deployedStatics = new MockDopplerToken(address(this));
        deployedRegistry = new GenesisActivationRegistry(deployedStatics, address(this), governance, treasury);
        MockGenesisFeeReceiver feeReceiver = new MockGenesisFeeReceiver(address(deployedStatics));
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: 0.003 ether,
            extensionFee: 0.003 ether,
            recoveryCallerShareBps: 2_000
        });
        deployedVault = new StaticsGenesisVault(
            deployedStatics, address(deployedVesting), governance, block.timestamp + 365 days, creditConfig
        );
        deployedGenesis = new StaticsGenesis(
            address(deployedVault),
            address(deployedVesting),
            address(deployedRegistry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            governance,
            treasury,
            "ipfs://statics-genesis/contract.json"
        );
        deployedRegistry.bindGenesisCollection(address(deployedGenesis));
        deployedStatics.transfer(address(deployedVesting), deployedVesting.GENESIS_BACKING_COMMITMENT() + surplus);
        deployedVesting.finalizeBootstrap(address(deployedStatics), address(deployedVault), address(deployedGenesis));
    }
}
