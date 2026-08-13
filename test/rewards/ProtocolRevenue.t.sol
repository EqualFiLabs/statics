// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibProtocolRevenue} from "../../src/libraries/LibProtocolRevenue.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20, MockOutboundFeeERC20} from "../mocks/MockERC20.sol";

contract MockRevertingOutboundERC20 is MockERC20 {
    address internal blockedSender;

    error OutboundTransferBlocked();

    constructor() MockERC20("Reverting Reward", "RRWD", 18) {}

    function setBlockedSender(address sender) external {
        blockedSender = sender;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blockedSender != address(0) && from == blockedSender && to != address(0)) {
            revert OutboundTransferBlocked();
        }
        super._update(from, to, value);
    }
}

contract ProtocolRevenueAccrualHarness {
    function accruePartner(address recipient, address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibProtocolRevenue.creditPartner(recipient, asset, amount);
    }

    function accrueCreator(address creator, address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibProtocolRevenue.creditCreator(creator, asset, amount);
    }
}

contract ProtocolRevenueTest is StaticsTestBase {
    IStaticsProtocolRevenue internal revenue;
    ProtocolRevenueAccrualHarness internal accrualHarness;

    function setUp() public override {
        super.setUp();
        revenue = IStaticsProtocolRevenue(address(diamond));
        ProtocolRevenueAccrualHarness implementation = new ProtocolRevenueAccrualHarness();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ProtocolRevenueAccrualHarness.accruePartner.selector;
        selectors[1] = ProtocolRevenueAccrualHarness.accrueCreator.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(implementation), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        accrualHarness = ProtocolRevenueAccrualHarness(address(diamond));
    }

    function test_CanonicalSwapIngressSnapshotsPartnerAndCreditsBasketCreator() public {
        revenue.setPartnerRecipient(bob);
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        PoolId poolId = basketLiquidity.canonicalPool(basketId, address(assetA)).poolId;
        (, StaticsSwapFeeHook hook) = _localLiquidity();
        uint256 partnerAmount = 10 ether;
        uint256 creatorAmount = 5 ether;
        uint256 treasuryAmount = 20 ether;
        uint256 total = partnerAmount + creatorAmount + treasuryAmount;
        assetA.mint(address(hook), total);
        vm.prank(address(hook));
        assetA.approve(address(diamond), total);
        vm.prank(address(hook));
        IStaticsLiquidityRewards(address(diamond))
            .routeCanonicalSwapFees(poolId, address(assetA), 0, 0, 0, partnerAmount, creatorAmount, treasuryAmount);

        assertEq(revenue.creatorRewardCredit(alice, address(assetA)), creatorAmount);
        assertEq(revenue.partnerAccrued(bob, address(assetA)), partnerAmount);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), treasuryAmount);

        vm.prank(alice);
        assertEq(revenue.claimCreatorRevenue(address(assetA), alice, creatorAmount), creatorAmount);
        address caller = makeAddr("caller");
        vm.prank(caller);
        (uint256 distributed, uint256 tip) = revenue.distributePartnerRevenue(bob, address(assetA));
        assertEq(distributed, 9.9 ether);
        assertEq(tip, 0.1 ether);
        assertEq(assetA.balanceOf(bob), distributed);
        assertEq(assetA.balanceOf(caller), tip);
    }

    function test_PartnerAccrualRemainsWithHistoricalRecipientAfterConfigurationChange() public {
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        address nextPartner = makeAddr("nextPartner");
        reward.mint(address(this), 20 ether);
        reward.approve(address(diamond), 20 ether);
        revenue.setPartnerRecipient(bob);
        accrualHarness.accruePartner(bob, address(reward), 10 ether);
        revenue.setPartnerRecipient(nextPartner);
        accrualHarness.accruePartner(nextPartner, address(reward), 10 ether);

        assertEq(revenue.partnerAccrued(bob, address(reward)), 10 ether);
        assertEq(revenue.partnerAccrued(nextPartner, address(reward)), 10 ether);
    }

    function test_PermissionlessPartnerDistributionReturnsZeroForEmptyAsset() public {
        assertEq(revenue.partnerAccrued(bob, address(assetA)), 0);
        (uint256 distributed, uint256 tip) = revenue.distributePartnerRevenue(bob, address(assetA));
        assertEq(distributed, 0);
        assertEq(tip, 0);
    }

    function test_GovernancePartnerTipIsBoundedAtFivePercent() public {
        vm.expectRevert(abi.encodeWithSelector(LibProtocolRevenue.InvalidPartnerTip.selector, 501));
        revenue.setPartnerDistributionTipBps(501);

        revenue.setPartnerDistributionTipBps(500);
        assertEq(revenue.partnerDistributionTipBps(), 500);
    }

    function test_GovernanceCannotConfigureDiamondAsPartnerRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(LibProtocolRevenue.InvalidPartnerRecipient.selector, address(diamond)));
        revenue.setPartnerRecipient(address(diamond));
    }

    function test_IncompatiblePartnerTokenRevertsWithoutClearingAccrual() public {
        MockRevertingOutboundERC20 reward = new MockRevertingOutboundERC20();
        reward.mint(address(this), 10 ether);
        reward.approve(address(diamond), 10 ether);
        accrualHarness.accruePartner(bob, address(reward), 10 ether);
        reward.setBlockedSender(address(diamond));

        (bool success, bytes memory returnData) = address(revenue)
            .call(abi.encodeCall(IStaticsProtocolRevenue.distributePartnerRevenue, (bob, address(reward))));
        assertFalse(success);
        assertEq(bytes4(returnData), MockRevertingOutboundERC20.OutboundTransferBlocked.selector);
        assertEq(revenue.partnerAccrued(bob, address(reward)), 10 ether);
    }

    function test_CreatorCanPullTaxedAssetWithMinimumReceivedProtection() public {
        MockOutboundFeeERC20 reward = new MockOutboundFeeERC20();
        reward.mint(address(this), 10 ether);
        reward.approve(address(diamond), 10 ether);
        accrualHarness.accrueCreator(alice, address(reward), 10 ether);
        reward.setTaxedSender(address(diamond));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolRevenueFacet.MinimumOutputNotMet.selector, address(reward), 9.9 ether, 10 ether
            )
        );
        revenue.claimCreatorRevenue(address(reward), alice, 10 ether);
        assertEq(revenue.creatorRewardCredit(alice, address(reward)), 10 ether);

        vm.prank(alice);
        assertEq(revenue.claimCreatorRevenue(address(reward), alice, 9.9 ether), 9.9 ether);
        assertEq(reward.balanceOf(alice), 9.9 ether);
        assertEq(revenue.creatorRewardCredit(alice, address(reward)), 0);
    }
}
