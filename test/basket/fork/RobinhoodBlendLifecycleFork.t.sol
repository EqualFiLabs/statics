// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBlendBasket, RobinhoodBlendBasketForkBase} from "./RobinhoodBlendBasketFork.t.sol";

interface IBlendLifecycleBasket is IBlendBasket {
    function previewMint(uint256 shares)
        external
        view
        returns (address[] memory tokens, uint256[] memory required, uint256[] memory fees);
    function mint(uint256 shares, address to) external;
    function redeem(uint256 shares, address to) external;
    function protocolFees(address token) external view returns (uint256);
}

/// @notice Complete non-flash lifecycle through live Blend and fork-deployed Statics contracts.
///
/// NVDA + GOOGL + MSFT -> Blend AI -> sBAI -> Blend AI -> NVDA + GOOGL + MSFT
contract RobinhoodBlendLifecycleForkTest is RobinhoodBlendBasketForkBase {
    uint256 private constant BOOTSTRAP_REDEEM_SHARES = 3 ether;
    uint256 private constant BLEND_MINT_SHARES = 2 ether;
    uint256 private constant STATICS_MINT_SHARES = 1 ether;

    struct TokenSnapshot {
        uint256 userBalance;
        uint256 rawVaultBalance;
        uint256 backing;
        uint256 protocolFees;
    }

    struct BlendEntryResult {
        uint256 supplyBefore;
        uint256 bootstrapRedeemGas;
        uint256 mintGas;
    }

    struct StaticsRoundTripResult {
        uint256 supplyBefore;
        uint256 returnedBlendShares;
        uint256 mintInput;
        uint256 mintGas;
        uint256 redeemGas;
    }

    function testCompleteBlendToStaticsLifecycleConservesBothBooks() public {
        IBlendLifecycleBasket blend = IBlendLifecycleBasket(BLEND_AI);
        address actor = bob;
        address[] memory constituents = blend.constituents();
        BlendEntryResult memory blendEntry = _redeemAndRemintBlend(blend, constituents, actor);
        StaticsRoundTripResult memory staticsRoundTrip = _roundTripThroughStatics(blend, actor);

        TokenSnapshot[] memory beforeFinalBlendRedeem = _snapshots(blend, constituents, actor);
        uint256 finalBlendRedeemGas = _redeemBlend(blend, actor, staticsRoundTrip.returnedBlendShares);
        _assertRedeemConservation(blend, constituents, actor, beforeFinalBlendRedeem);
        assertEq(
            blend.totalSupply(),
            blendEntry.supplyBefore - BOOTSTRAP_REDEEM_SHARES + BLEND_MINT_SHARES - staticsRoundTrip.returnedBlendShares
        );
        assertEq(blend.balanceOf(actor), BLEND_MINT_SHARES - staticsRoundTrip.mintInput);

        emit log("Complete lifecycle: stocks -> live Blend AI -> Statics sBAI -> Blend AI -> stocks");
        emit log_named_uint("Blend bootstrap redemption gas", blendEntry.bootstrapRedeemGas);
        emit log_named_uint("Ordinary Blend mint gas", blendEntry.mintGas);
        emit log_named_uint("Statics mint gas", staticsRoundTrip.mintGas);
        emit log_named_uint("Statics redemption gas", staticsRoundTrip.redeemGas);
        emit log_named_uint("Final Blend redemption gas", finalBlendRedeemGas);
    }

    function _redeemAndRemintBlend(IBlendLifecycleBasket blend, address[] memory constituents, address actor)
        private
        returns (BlendEntryResult memory result)
    {
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).transfer(actor, BOOTSTRAP_REDEEM_SHARES));
        result.supplyBefore = blend.totalSupply();
        TokenSnapshot[] memory beforeBootstrap = _snapshots(blend, constituents, actor);
        result.bootstrapRedeemGas = _redeemBlend(blend, actor, BOOTSTRAP_REDEEM_SHARES);
        _assertRedeemConservation(blend, constituents, actor, beforeBootstrap);
        assertEq(blend.balanceOf(actor), 0);
        assertEq(blend.totalSupply(), result.supplyBefore - BOOTSTRAP_REDEEM_SHARES);

        (address[] memory mintTokens, uint256[] memory required, uint256[] memory fees) =
            blend.previewMint(BLEND_MINT_SHARES);
        assertEq(mintTokens, constituents);
        TokenSnapshot[] memory beforeBlendMint = _snapshots(blend, constituents, actor);
        _approveBlendConstituents(constituents, actor, required, fees);
        result.mintGas = _mintBlend(blend, actor, BLEND_MINT_SHARES);
        _assertMintConservation(blend, constituents, actor, beforeBlendMint, required, fees);
        assertEq(blend.balanceOf(actor), BLEND_MINT_SHARES);
        assertEq(blend.totalSupply(), result.supplyBefore - BOOTSTRAP_REDEEM_SHARES + BLEND_MINT_SHARES);
    }

    function _roundTripThroughStatics(IBlendLifecycleBasket blend, address actor)
        private
        returns (StaticsRoundTripResult memory result)
    {
        vm.prank(actor);
        assertTrue(IERC20(BLEND_AI).approve(address(diamond), type(uint256).max));
        result.supplyBefore = IERC20(staticsBasketToken).totalSupply();
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, STATICS_MINT_SHARES);
        result.mintInput = mintQuote[0];
        result.mintGas = _mintStatics(actor, mintQuote);
        assertEq(IERC20(staticsBasketToken).balanceOf(actor), STATICS_MINT_SHARES);
        assertEq(IERC20(staticsBasketToken).totalSupply(), result.supplyBefore + STATICS_MINT_SHARES);

        uint256 blendBeforeRedeem = blend.balanceOf(actor);
        uint256[] memory redeemQuote = baskets.quoteRedeem(staticsBasketId, STATICS_MINT_SHARES);
        result.redeemGas = _redeemStatics(actor, redeemQuote);
        result.returnedBlendShares = blend.balanceOf(actor) - blendBeforeRedeem;
        assertEq(result.returnedBlendShares, redeemQuote[0]);
        assertEq(IERC20(staticsBasketToken).balanceOf(actor), 0);
        assertEq(IERC20(staticsBasketToken).totalSupply(), result.supplyBefore);
    }

    function _approveBlendConstituents(
        address[] memory constituents,
        address actor,
        uint256[] memory required,
        uint256[] memory fees
    ) private {
        for (uint256 i; i < constituents.length; ++i) {
            uint256 maximum = required[i] + fees[i];
            assertGe(IERC20(constituents[i]).balanceOf(actor), maximum);
            vm.prank(actor);
            assertTrue(IERC20(constituents[i]).approve(BLEND_AI, maximum));
        }
    }

    function _mintBlend(IBlendLifecycleBasket blend, address actor, uint256 shares)
        private
        returns (uint256 executionGas)
    {
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        blend.mint(shares, actor);
        executionGas = gasBefore - gasleft();
    }

    function _redeemBlend(IBlendLifecycleBasket blend, address actor, uint256 shares)
        private
        returns (uint256 executionGas)
    {
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        blend.redeem(shares, actor);
        executionGas = gasBefore - gasleft();
    }

    function _mintStatics(address actor, uint256[] memory quote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        baskets.mint(staticsBasketId, STATICS_MINT_SHARES, actor, quote);
        executionGas = gasBefore - gasleft();
    }

    function _redeemStatics(address actor, uint256[] memory quote) private returns (uint256 executionGas) {
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        baskets.redeem(staticsBasketId, STATICS_MINT_SHARES, actor, quote);
        executionGas = gasBefore - gasleft();
    }

    function _snapshots(IBlendLifecycleBasket blend, address[] memory tokens, address actor)
        private
        view
        returns (TokenSnapshot[] memory snapshots)
    {
        snapshots = new TokenSnapshot[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            snapshots[i] = TokenSnapshot({
                userBalance: IERC20(token).balanceOf(actor),
                rawVaultBalance: IERC20(token).balanceOf(BLEND_AI),
                backing: blend.backing(token),
                protocolFees: blend.protocolFees(token)
            });
            assertEq(snapshots[i].rawVaultBalance, snapshots[i].backing + snapshots[i].protocolFees);
        }
    }

    function _assertMintConservation(
        IBlendLifecycleBasket blend,
        address[] memory tokens,
        address actor,
        TokenSnapshot[] memory beforeAction,
        uint256[] memory required,
        uint256[] memory fees
    ) private view {
        TokenSnapshot[] memory afterAction = _snapshots(blend, tokens, actor);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(beforeAction[i].userBalance - afterAction[i].userBalance, required[i] + fees[i]);
            assertEq(afterAction[i].rawVaultBalance - beforeAction[i].rawVaultBalance, required[i] + fees[i]);
            assertEq(afterAction[i].backing - beforeAction[i].backing, required[i]);
            assertEq(afterAction[i].protocolFees - beforeAction[i].protocolFees, fees[i]);
            assertEq(IERC20(tokens[i]).allowance(actor, BLEND_AI), 0);
        }
    }

    function _assertRedeemConservation(
        IBlendLifecycleBasket blend,
        address[] memory tokens,
        address actor,
        TokenSnapshot[] memory beforeAction
    ) private view {
        TokenSnapshot[] memory afterAction = _snapshots(blend, tokens, actor);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 received = afterAction[i].userBalance - beforeAction[i].userBalance;
            uint256 backingReduction = beforeAction[i].backing - afterAction[i].backing;
            uint256 feeIncrease = afterAction[i].protocolFees - beforeAction[i].protocolFees;
            assertGt(received, 0);
            assertEq(beforeAction[i].rawVaultBalance - afterAction[i].rawVaultBalance, received);
            assertEq(backingReduction, received + feeIncrease);
        }
    }
}
