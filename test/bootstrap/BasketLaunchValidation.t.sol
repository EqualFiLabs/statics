// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketDelegation} from "../../src/interfaces/IStaticsBasketDelegation.sol";
import {BasketCreationFacet} from "../../src/facets/BasketCreationFacet.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";

contract BasketLaunchValidationTest is CampaignTestBase {
    function testInvalidImmutableDefinitionsCannotEnterCampaignFunding() public {
        for (uint256 variant; variant < 10; ++variant) {
            BasketBootstrapCampaign.Terms memory terms = _terms(false);
            bytes memory reason = _invalidate(terms.basket, variant);
            BasketBootstrapCampaign campaign = BasketBootstrapCampaign(campaignFactory.create(terms, bytes32(variant)));

            // Wrap the full preparation workflow so expectRevert covers the actual
            // campaign call rather than an earlier digest or mining view call.
            vm.expectRevert(reason);
            this.prepareCampaign(campaign, terms);
            assertFalse(campaign.prepared());
            assertFalse(campaign.ready());
            assertEq(uint256(campaign.state()), uint256(BasketBootstrapCampaign.State.Unprepared));
            assertFalse(IStaticsBasketDelegation(address(diamond)).creationNonceUsed(terms.creator, 513));
            vm.expectRevert(BasketBootstrapCampaign.CampaignNotFunding.selector);
            campaign.fundNative{value: 1}();
            vm.expectRevert(BasketBootstrapCampaign.CampaignNotFunding.selector);
            campaign.fund(0, 1);
            vm.expectRevert(BasketBootstrapCampaign.CampaignNotFunding.selector);
            campaign.fundPayment(1);
            vm.expectRevert(BasketBootstrapCampaign.CampaignNotFunding.selector);
            campaign.activateAuction(0);
        }
    }

    function testPreviewAndDirectCreationRejectIdenticalInvalidDefinitions() public {
        for (uint256 variant; variant < 10; ++variant) {
            BasketBootstrapCampaign.Terms memory terms = _terms(false);
            bytes memory reason = _invalidate(terms.basket, variant);
            bytes32 id = _reservePreview(terms);
            vm.expectRevert(reason);
            preparation.previewBasketLaunch(id, terms.basket, terms.pools, terms.maximums, terms.deadline);
            vm.prank(alice);
            vm.expectRevert(reason);
            baskets.createBasket{value: 1 ether}(terms.basket, terms.pools, terms.maximums, terms.deadline);
            vm.prank(alice);
            vm.expectRevert(reason);
            baskets.createBasketPrepared{value: 1 ether}(terms.basket, terms.pools, terms.maximums, terms.deadline, id);
        }
    }

    function prepareCampaign(BasketBootstrapCampaign campaign, BasketBootstrapCampaign.Terms calldata terms) external {
        require(msg.sender == address(this));
        _prepareCampaign(campaign, terms);
    }

    function _reservePreview(BasketBootstrapCampaign.Terms memory terms) private returns (bytes32 id) {
        bytes32 configuration =
            preparation.basketCreationConfigurationHash(terms.basket, terms.pools, terms.maximums, terms.deadline);
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(alice, alice, configuration, terms.deadline, 1);
        uint256[] memory nonces = new uint256[](terms.pools.length);
        uint256 start;
        for (uint256 i; i < nonces.length; ++i) {
            (nonces[i],) = _minePreparedTestHook(factory, intent, start);
            start = nonces[i] + 1;
        }
        vm.prank(alice);
        (id,) = preparation.prepareBasketCreation(terms.basket, terms.pools, terms.maximums, terms.deadline, 0, nonces);
    }

    function _invalidate(IStaticsBasket.CreateBasketParams memory params, uint256 variant)
        private
        pure
        returns (bytes memory reason)
    {
        reason = abi.encodeWithSelector(BasketCreationFacet.InvalidBasketDefinition.selector);
        if (variant == 0) {
            params.bundleAmounts[0] = 0;
        } else if (variant == 1) {
            params.name = "";
        } else if (variant == 2) {
            params.symbol = "";
        } else if (variant == 3) {
            params.loanDuration = 0;
        } else if (variant < 8) {
            if (variant == 4) params.flashFeeBps = 10_001;
            else if (variant == 5) params.originationFeeBps = 10_001;
            else if (variant == 6) params.extensionFeeBps = 10_001;
            else params.recoveryPenaltyBps = 10_001;
            reason = abi.encodeWithSelector(BasketCreationFacet.FeeExceedsCap.selector, uint16(10_001));
        } else if (variant == 8) {
            params.ltvBps = 9_501;
            reason = abi.encodeWithSelector(BasketCreationFacet.LtvExceedsMaximum.selector, uint16(9_501));
        } else {
            params.recoveryPenaltyBps = 1_000;
            reason = abi.encodeWithSelector(
                BasketCreationFacet.InvalidRecoveryParameters.selector, params.ltvBps, params.recoveryPenaltyBps
            );
        }
    }
}
