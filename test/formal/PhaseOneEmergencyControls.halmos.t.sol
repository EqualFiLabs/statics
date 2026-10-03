// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PhaseOneGovernanceHarness} from "./harness/PhaseOneGovernanceHarness.sol";

contract PhaseOneEmergencyControlsHalmosTest is SymTest, Test {
    PhaseOneGovernanceHarness private governance;

    function setUp() public {
        governance = new PhaseOneGovernanceHarness();
    }

    function testRepresentativeStopAndRestoreAuthority() public {
        check_onlyGuardianOrOwnerCanStopAllProtocolSwaps(address(0xCAFE));
        check_guardianCannotRestoreProtocolSwaps();
    }

    function testRepresentativePoolIsolation() public {
        check_poolQuarantineRemainsIsolatedUntilGlobalPause();
    }

    function testRepresentativeStakePauseIsNarrow() public {
        check_guardianStakePauseCannotSetOwnerOnlyAction();
    }

    function check_onlyGuardianOrOwnerCanStopAllProtocolSwaps(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != address(governance));
        vm.prank(caller);
        (bool success,) = address(governance).call(abi.encodeCall(governance.pauseProtocolSwaps, ()));

        bool authorized = caller == governance.OWNER() || caller == governance.GUARDIAN();
        assertEq(success, authorized);
        assertEq(governance.protocolSwapsPaused(), authorized);
    }

    function check_guardianCannotRestoreProtocolSwaps() public {
        vm.prank(governance.GUARDIAN());
        governance.pauseProtocolSwaps();

        vm.prank(governance.GUARDIAN());
        (bool guardianRestored,) = address(governance).call(abi.encodeCall(governance.unpauseProtocolSwaps, ()));
        assertFalse(guardianRestored);
        assertTrue(governance.protocolSwapsPaused());

        vm.prank(governance.OWNER());
        governance.unpauseProtocolSwaps();
        assertFalse(governance.protocolSwapsPaused());
    }

    function check_poolQuarantineRemainsIsolatedUntilGlobalPause() public {
        (PoolId first, PoolId second) = governance.poolIds();
        vm.prank(governance.GUARDIAN());
        governance.quarantineProtocolPool(first);
        assertTrue(governance.protocolPoolSwapsBlocked(first));
        assertFalse(governance.protocolPoolSwapsBlocked(second));

        vm.prank(governance.GUARDIAN());
        governance.pauseProtocolSwaps();
        assertTrue(governance.protocolPoolSwapsBlocked(first));
        assertTrue(governance.protocolPoolSwapsBlocked(second));

        vm.prank(governance.OWNER());
        governance.unpauseProtocolSwaps();
        assertTrue(governance.protocolPoolSwapsBlocked(first));
        assertFalse(governance.protocolPoolSwapsBlocked(second));

        vm.prank(governance.OWNER());
        governance.releaseProtocolPoolQuarantine(first);
        assertFalse(governance.protocolPoolSwapsBlocked(first));
    }

    function check_guardianStakePauseCannotSetOwnerOnlyAction() public {
        uint256 stake = governance.pauseStakeMask();
        uint256 redeem = governance.pauseRedeemMask();
        vm.prank(governance.GUARDIAN());
        governance.pause(stake);
        assertTrue(governance.isPaused(stake));
        assertFalse(governance.isPaused(redeem));
        assertEq(governance.pausedActions(), stake);

        vm.prank(governance.GUARDIAN());
        (bool guardianPausedRedeem,) = address(governance).call(abi.encodeCall(governance.pause, (redeem)));
        assertFalse(guardianPausedRedeem);
        assertFalse(governance.isPaused(redeem));
    }
}
