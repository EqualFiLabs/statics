// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {
    FormalDistributorSink,
    FormalFeeSource,
    FormalReserveVault,
    FormalToken,
    FormalWrappedNative
} from "./mocks/FormalGenesisMocks.sol";

contract StaticsFeeReceiverHalmosTest is SymTest, Test {
    FormalToken private statics;
    FormalWrappedNative private weth;
    FormalFeeSource private feeSource;
    StaticsFeeReceiver private receiver;
    FormalReserveVault private reserveVault;
    FormalDistributorSink private distributor;

    function setUp() public {
        statics = new FormalToken("Formal STATICS", "FSTATICS");
        weth = new FormalWrappedNative();
        feeSource = new FormalFeeSource();
        receiver = new StaticsFeeReceiver(address(feeSource), address(weth), address(this));
        feeSource.configure(statics, weth, address(receiver));
        receiver.bindMarket(address(statics), keccak256("formal-pool"));
        reserveVault = new FormalReserveVault(address(statics));
        receiver.bindReserveVault(address(reserveVault));
        distributor = new FormalDistributorSink();
        receiver.proposeDistributor(address(distributor));
        distributor.accept(receiver);
    }

    function check_exactHarvestConservation(uint96 staticsAmount, uint96 wethAmount, uint16 reserveShareBps) public {
        vm.assume(reserveShareBps <= receiver.BPS());
        receiver.setReserveShareBps(reserveShareBps);
        _queue(staticsAmount, wethAmount);
        receiver.harvest();

        uint256 reserveAllocation = receiver.cumulativeReserveWeth();
        uint256 distributorWeth = receiver.cumulativeDistributorWeth();
        assertEq(receiver.cumulativeHarvested(address(statics)), staticsAmount);
        assertEq(receiver.cumulativeHarvested(address(weth)), wethAmount);
        assertEq(reserveAllocation + distributorWeth, wethAmount);
        assertEq(receiver.distributorClaimable(address(distributor), address(statics)), staticsAmount);
        assertEq(receiver.distributorClaimable(address(distributor), address(weth)), distributorWeth);
        assertEq(receiver.totalDistributorLiability(address(statics)), staticsAmount);
        assertEq(receiver.totalDistributorLiability(address(weth)), distributorWeth);
        _assertLiabilitiesCovered();
    }

    function check_directDonationsAreNeverHarvested(uint96 donation, uint96 harvested) public {
        statics.mint(address(receiver), donation);
        _queue(harvested, 0);
        receiver.harvest();
        assertEq(receiver.cumulativeHarvested(address(statics)), harvested);
        assertEq(receiver.totalDistributorLiability(address(statics)), harvested);
        assertEq(statics.balanceOf(address(receiver)), uint256(donation) + harvested);
        _assertLiabilitiesCovered();
    }

    function check_reserveShareChangeUsesPreviousShare(uint96 grossWeth, bool oldShareAllReserve, uint16 newShare)
        public
    {
        vm.assume(newShare <= receiver.BPS());
        uint16 oldShare = oldShareAllReserve ? receiver.BPS() : 0;
        receiver.setReserveShareBps(oldShare);
        _queue(0, grossWeth);
        receiver.setReserveShareBps(newShare);

        uint256 expectedReserve = oldShareAllReserve ? grossWeth : 0;
        assertEq(receiver.cumulativeReserveWeth(), expectedReserve);
        assertEq(receiver.cumulativeDistributorWeth(), uint256(grossWeth) - expectedReserve);
        assertEq(receiver.reserveShareBps(), newShare);
        _assertLiabilitiesCovered();
    }

    function check_distributorRotationAttributesPendingFeesToOldDistributor(uint96 staticsAmount, uint96 wethAmount)
        public
    {
        FormalDistributorSink nextDistributor = new FormalDistributorSink();
        _queue(staticsAmount, wethAmount);
        receiver.proposeDistributor(address(nextDistributor));
        nextDistributor.accept(receiver);

        assertEq(receiver.activeDistributor(), address(nextDistributor));
        assertEq(receiver.distributorClaimable(address(distributor), address(statics)), staticsAmount);
        assertEq(receiver.distributorClaimable(address(distributor), address(weth)), wethAmount);
        assertEq(receiver.distributorClaimable(address(nextDistributor), address(statics)), 0);
        assertEq(receiver.distributorClaimable(address(nextDistributor), address(weth)), 0);
        _assertLiabilitiesCovered();
    }

    function check_recoverSurplusCannotTouchLiability(uint96 liability, uint96 donation) public {
        _queue(liability, 0);
        receiver.harvest();
        statics.mint(address(receiver), donation);
        receiver.recoverSurplus(address(statics), address(this), donation);
        assertEq(receiver.totalDistributorLiability(address(statics)), liability);
        assertEq(statics.balanceOf(address(receiver)), liability);
        _assertLiabilitiesCovered();
    }

    function check_claimReducesCustodyAndLiabilityTogether(uint96 amount) public {
        vm.assume(amount > 0);
        _queue(amount, 0);
        receiver.harvest();
        uint256 claimed = distributor.claim(receiver, address(statics), address(this));
        assertEq(claimed, amount);
        assertEq(receiver.totalDistributorLiability(address(statics)), 0);
        assertEq(statics.balanceOf(address(receiver)), 0);
        _assertLiabilitiesCovered();
    }

    function _queue(uint256 staticsAmount, uint256 wethAmount) private {
        if (staticsAmount != 0) statics.mint(address(feeSource), staticsAmount);
        if (wethAmount != 0) {
            weth.mint(address(feeSource), wethAmount);
            vm.deal(address(weth), wethAmount);
        }
        feeSource.queue(staticsAmount, wethAmount);
    }

    function _assertLiabilitiesCovered() private view {
        assertGe(statics.balanceOf(address(receiver)), receiver.totalDistributorLiability(address(statics)));
        assertGe(weth.balanceOf(address(receiver)), receiver.totalDistributorLiability(address(weth)));
    }
}
