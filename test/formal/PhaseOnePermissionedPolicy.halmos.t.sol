// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

import {
    PhaseOnePermissionedFeeMathHarness,
    PhaseOneRewardPolicyHarness
} from "./harness/PhaseOneRewardPolicyHarness.sol";

contract PhaseOnePermissionedPolicyHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    address private constant ASSET = address(0xC0FFEE);

    PhaseOneRewardPolicyHarness private policy;
    PhaseOnePermissionedFeeMathHarness private feeMath;

    function setUp() public {
        policy = new PhaseOneRewardPolicyHarness();
        feeMath = new PhaseOnePermissionedFeeMathHarness();
    }

    function testRepresentativeRewardRestrictionAuthority() public {
        check_onlyGuardianOrOwnerCanAddRewardRestriction(address(0xCAFE));
    }

    function testRepresentativeRewardRestrictionRemoval() public {
        check_onlyOwnerCanRemoveRewardRestriction(address(0xCAFE));
    }

    function testRepresentativeBothRestrictedDistribution() public {
        check_bothRestrictedDistributionConservesFee(1_000_003);
    }

    function testRepresentativeGrossFeeCeiling() public view {
        check_minimumGrossFeeCeiling(1);
    }

    function check_onlyGuardianOrOwnerCanAddRewardRestriction(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != address(policy));
        vm.prank(caller);
        (bool success,) = address(policy).call(abi.encodeCall(policy.addRewardRestriction, (ASSET)));

        bool authorized = caller == policy.OWNER() || caller == policy.GUARDIAN();
        assertEq(success, authorized);
        assertEq(policy.rewardRestricted(ASSET), authorized);
    }

    function check_onlyOwnerCanRemoveRewardRestriction(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != address(policy));
        vm.prank(policy.GUARDIAN());
        policy.addRewardRestriction(ASSET);

        vm.prank(caller);
        (bool success,) = address(policy).call(abi.encodeCall(policy.removeRewardRestriction, (ASSET)));

        bool authorized = caller == policy.OWNER();
        assertEq(success, authorized);
        assertEq(policy.rewardRestricted(ASSET), !authorized);
    }

    function check_bothRestrictedDistributionConservesFee(uint128 rawFee) public view {
        uint256 fee = uint256(rawFee);
        (uint256 creator, uint256 treasury, uint256 staticsStaker, uint256 basketStaker) =
            feeMath.bothRestrictedDistribution(rawFee);

        assertEq(creator + treasury, fee);
        assertEq(staticsStaker, 0);
        assertEq(basketStaker, 0);
        assertEq(creator, fee * 8_000 / BPS);
        assertEq(treasury, fee - creator);
    }

    function check_minimumGrossFeeCeiling(uint128 grossOutput) public view {
        uint256 fee = feeMath.feeFromGross(grossOutput, 1);
        uint256 expected = uint256(grossOutput) / BPS;
        if (grossOutput % BPS != 0) ++expected;
        assertEq(fee, expected);
        if (grossOutput != 0) assertGe(fee, 1);
    }
}
