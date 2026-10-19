// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StaticsBasketToken} from "../../src/tokens/StaticsBasketToken.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsMarketTape} from "../../src/interfaces/IStaticsMarketTape.sol";
import {PublicHookUpgradeForkBase} from "../helpers/PublicHookUpgradeForkBase.sol";

contract ImmutablePublicHookUpgradeForkTest is PublicHookUpgradeForkBase {
    function testPinnedCutPreservesAllSixPoolsAndCreatesConnectedRestrictedBasket() public {
        _startEvidence();
        bytes32[6] memory oldViews;
        bytes32[6] memory oldClaims;
        for (uint256 i; i < 6; ++i) {
            PoolId id = _oldId(i);
            PoolKey memory key = pools.protocolPool(id).key;
            assertEq(address(key.hooks), address(swapFeeHook));
            oldViews[i] = keccak256(abi.encode(pools.protocolPool(id)));
            oldClaims[i] = _claims(key);
        }
        address weth = swapFeeHook.weth();
        uint256 unfunded = globalRewards.unfundedSwapRewards(weth);
        uint256 reserved = custody.globalReservedByToken(weth);
        _upgrade();
        assertEq(globalRewards.unfundedSwapRewards(weth), unfunded);
        assertEq(custody.globalReservedByToken(weth), reserved);
        for (uint256 i; i < 6; ++i) {
            PoolId id = _oldId(i);
            assertEq(keccak256(abi.encode(pools.protocolPool(id))), oldViews[i]);
            assertEq(_claims(pools.protocolPool(id).key), oldClaims[i]);
        }
        _newGeneralFlow();
        _newBasketFlow();
        if (bytes(evidenceOutput).length != 0) vm.writeJson("true", evidenceOutput, ".completed");
    }

    function testApprovedDistributorTransfersPreserveSettlementAfterUpgrade() public {
        _upgrade();
        IERC20 token = IERC20(_newBasketFlow());
        assertFalse(basketAdmin.isBasketDistributor(owner));
        assertFalse(basketAdmin.isBasketDistributor(DIAMOND));
        assertFalse(basketAdmin.isBasketDistributor(bob));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, alice, bob, 0.2 ether)
        );
        token.transfer(bob, 0.2 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, alice, owner, 0.2 ether)
        );
        token.transfer(owner, 0.2 ether);

        vm.prank(owner);
        basketAdmin.setBasketDistributor(bob, true);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0.2 ether));
        vm.prank(bob);
        assertTrue(token.transfer(alice, 0.1 ether));
        assertEq(token.balanceOf(bob), 0.1 ether);
        vm.prank(owner);
        basketAdmin.setBasketDistributor(address(poolManager), true);
        vm.prank(bob);
        vm.expectRevert(StaticsBasketToken.PoolManagerLocked.selector);
        token.transfer(address(poolManager), 1);

        vm.prank(owner);
        basketAdmin.setBasketDistributor(bob, false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, bob, alice, 0.1 ether)
        );
        token.transfer(alice, 0.1 ether);
        assertEq(IDiamondLoupe(DIAMOND).facetAddress(bytes4(keccak256("morpho()"))), address(0));
    }

    function testPreUpgradeStakeAndManagedPositionRemainLiveAcrossTheCut() public {
        LegacyPosition memory old = _openLegacyStakeAndPosition();
        _upgrade();
        IStaticsRangeGauge gauges = IStaticsRangeGauge(DIAMOND);
        assertEq(globalRewards.stakePosition(old.position).stakedBalance, 10 ether);
        assertEq(globalRewards.unfundedSwapRewards(swapFeeHook.weth()), old.pending);
        assertEq(gauges.lpLeg(old.position, old.poolId).manager, old.manager);
        assertEq(gauges.lpLeg(old.position, old.poolId).posmTokenId, old.posmTokenId);
        assertEq(IStaticsMarketTape(DIAMOND).canonicalMarketState(old.poolId).sequence, old.sequence + 1);
        globalRewards.settlePublicSwapRewards(swapFeeHook.weth(), type(uint256).max);
        assertGt(_claimWeth(old.position), 0);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory exited =
            gauges.exitLiquidity(old.position, old.poolId, 0, 0, block.timestamp);
        assertGt(exited.received0, 0);
        assertEq(gauges.lpLeg(old.position, old.poolId).liquidity, 0);
        _newGeneralFlow();
        globalRewards.settlePublicSwapRewards(swapFeeHook.weth(), type(uint256).max);
        assertGt(_claimWeth(old.position), 0);
        assertEq(globalRewards.unfundedSwapRewards(swapFeeHook.weth()), 0);
    }
}
