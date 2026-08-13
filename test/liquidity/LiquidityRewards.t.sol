// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {LibLiquidityRewards} from "../../src/libraries/LibLiquidityRewards.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {LiquidityRewardsFacet} from "../../src/facets/LiquidityRewardsFacet.sol";
import {MockERC20, MockOutboundFeeERC20} from "../mocks/MockERC20.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract LiquidityRewardsTest is BorrowLiquidityTestBase {
    IStaticsLiquidityRewards private liquidityRewards;

    function setUp() public override {
        super.setUp();
        liquidityRewards = IStaticsLiquidityRewards(address(diamond));
        _createReadyBasket(1);
    }

    function testCanonicalPositionActivatesNextBlockEarnsAndExitsWithoutCooldown() public {
        uint256 tokenId = _mintFullRangePositionToAlice(5 ether);
        PoolId poolId = basketLiquidity.canonicalPool(basketId, basketAssets[0]).poolId;

        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.expectPartialRevert(LibLiquidityRewards.LiquidityNotActivatable.selector);
        liquidityRewards.activateLiquidityPosition(tokenId);
        vm.stopPrank();

        IStaticsLiquidityRewards.StakedLiquidityView memory pending = liquidityRewards.stakedLiquidityPosition(tokenId);
        assertEq(pending.eligibleLiquidity, 0);
        assertEq(pending.pendingLiquidity, 5 ether);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(diamond));
        assertFalse(liquidityRewards.canAccrueLiquidityRewards(poolId));
        assertTrue(
            IModularPositionNFT(address(diamond))
                .isLegActive(basketPositionId, LibPosition.liquidityLegKey(address(diamond)))
        );

        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);
        assertTrue(liquidityRewards.canAccrueLiquidityRewards(poolId));
        assertEq(liquidityRewards.poolLiquidityRewards(poolId).totalEligibleLiquidity, 5 ether);

        _swapConstituentIntoPool(0.001 ether);
        vm.prank(alice);
        (, uint256 pending0,, uint256 pending1) = liquidityRewards.pendingLiquidityRewards(basketPositionId, tokenId);
        assertGt(pending0 + pending1, 0);

        uint256 balance0Before = IERC20(pending.currency0).balanceOf(alice);
        uint256 balance1Before = IERC20(pending.currency1).balanceOf(alice);
        vm.prank(alice);
        (uint256 claimed0, uint256 claimed1) =
            liquidityRewards.claimLiquidityRewards(basketPositionId, tokenId, alice, 0, 0);
        assertEq(IERC20(pending.currency0).balanceOf(alice) - balance0Before, claimed0);
        assertEq(IERC20(pending.currency1).balanceOf(alice) - balance1Before, claimed1);

        vm.prank(alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
        assertEq(liquidityRewards.poolLiquidityRewards(poolId).totalEligibleLiquidity, 0);
        assertFalse(
            IModularPositionNFT(address(diamond))
                .isLegActive(basketPositionId, LibPosition.liquidityLegKey(address(diamond)))
        );
    }

    function testBorrowAndStakeAtomicallyEarnsLpAndBasketRewards() public {
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        uint256 constituentBefore = IERC20(basketAssets[0]).balanceOf(alice);

        vm.prank(alice);
        (uint256 loanId, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndStakeLiquidity(basketPositionId, basketId, 20 ether, params);

        assertEq(tokenIds.length, 1);
        uint256 tokenId = tokenIds[0];
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(diamond));
        assertGt(IERC20(basketAssets[0]).balanceOf(alice), constituentBefore);
        IStaticsLiquidityRewards.StakedLiquidityView memory pending = liquidityRewards.stakedLiquidityPosition(tokenId);
        assertEq(pending.positionId, basketPositionId);
        assertEq(pending.pendingLiquidity, 5 ether);
        assertEq(pending.eligibleLiquidity, 0);
        assertTrue(pending.staked);
        assertEq(lending.loan(loanId).positionId, basketPositionId);
        _assertManagerHasNoUserResidue();

        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);
        _swapConstituentIntoPool(0.001 ether);

        vm.prank(alice);
        (, uint256 lpAmount0,, uint256 lpAmount1) = liquidityRewards.pendingLiquidityRewards(basketPositionId, tokenId);
        assertGt(lpAmount0 + lpAmount1, 0);
        (, uint256[] memory basketAmounts) = basketRewards.getBasketRewards(basketPositionId, basketId);
        assertGt(basketAmounts[0] + basketAmounts[1], 0);

        vm.prank(alice);
        liquidityRewards.claimLiquidityRewards(basketPositionId, tokenId, alice, 0, 0);
        vm.prank(alice);
        basketRewards.claimBasketRewards(basketPositionId, basketId, alice);
        vm.prank(alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function testBorrowAndStakeRejectsNonFullRangeBeforeOpeningLoan() public {
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        params[0].tickLower += 10;
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        IStaticsBasketCollateral.BasketCollateralPosition memory collateralBefore =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);

        vm.prank(alice);
        vm.expectPartialRevert(BorrowLiquidityFacet.InvalidLiquidityParameters.selector);
        borrowLiquidity.borrowAndStakeLiquidity(basketPositionId, basketId, 20 ether, params);

        assertEq(IERC20(basketToken).totalSupply(), supplyBefore);
        IStaticsBasketCollateral.BasketCollateralPosition memory collateralAfter =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);
        assertEq(collateralAfter.depositedShares, collateralBefore.depositedShares);
        assertEq(collateralAfter.lockedShares, collateralBefore.lockedShares);
        assertEq(lending.outstandingPrincipal(basketId, basketAssets[0]), 0);
    }

    function testPoolOverrideRoutesBothFeeLegsToEligibleCanonicalLiquidity() public {
        uint256 tokenId = _mintFullRangePositionToAlice(5 ether);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, basketAssets[0]);

        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();
        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);

        basketLiquidity.setCanonicalPoolFeeConfiguration(
            basketId,
            basketAssets[0],
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                lockedLiquidityShareBps: 0,
                liquidityProviderShareBps: 10_000,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                stonkBrokersShareBps: 0,
                indexCreatorShareBps: 0,
                treasuryShareBps: 0
            })
        );
        IStaticsLiquidityRewards.PoolLiquidityRewardView memory beforeRewards =
            liquidityRewards.poolLiquidityRewards(pool.poolId);
        uint128 lockedBefore = swapFeeHook.lockedLiquidity(pool.poolId);
        uint256 pending0Before = swapFeeHook.pendingPermanentLiquidity(pool.poolId, Currency.wrap(pool.currency0));
        uint256 pending1Before = swapFeeHook.pendingPermanentLiquidity(pool.poolId, Currency.wrap(pool.currency1));

        uint256 amountIn = 0.001 ether;
        (BalanceDelta delta, bool zeroForOne) = _swapConstituentIntoPool(amountIn);
        uint256 netOutput = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        uint256 inputFee = Math.mulDiv(amountIn, 40, 10_000, Math.Rounding.Ceil);
        uint256 outputFee = Math.mulDiv(netOutput, 60, 10_000 - 60, Math.Rounding.Ceil);
        IStaticsLiquidityRewards.PoolLiquidityRewardView memory afterRewards =
            liquidityRewards.poolLiquidityRewards(pool.poolId);

        assertEq(afterRewards.indexed0 - beforeRewards.indexed0, zeroForOne ? inputFee : outputFee);
        assertEq(afterRewards.indexed1 - beforeRewards.indexed1, zeroForOne ? outputFee : inputFee);
        assertEq(swapFeeHook.lockedLiquidity(pool.poolId), lockedBefore);
        assertEq(swapFeeHook.pendingPermanentLiquidity(pool.poolId, Currency.wrap(pool.currency0)), pending0Before);
        assertEq(swapFeeHook.pendingPermanentLiquidity(pool.poolId, Currency.wrap(pool.currency1)), pending1Before);
        vm.prank(alice);
        (, uint256 pending0,, uint256 pending1) = liquidityRewards.pendingLiquidityRewards(basketPositionId, tokenId);
        assertGt(pending0, 0);
        assertGt(pending1, 0);
    }

    function testPoolOverrideRoutesBasketTokenAndConstituentFeesToBasketPosition() public {
        _mintDirectFullRangePositionToAlice(5 ether);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, basketAssets[0]);
        assertTrue(liquidityRewards.canAccrueBasketRewards(pool.poolId));
        basketLiquidity.setCanonicalPoolFeeConfiguration(
            basketId,
            basketAssets[0],
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                lockedLiquidityShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 10_000,
                staticsStakerShareBps: 0,
                stonkBrokersShareBps: 0,
                indexCreatorShareBps: 0,
                treasuryShareBps: 0
            })
        );

        _swapConstituentIntoPool(0.001 ether);
        (address[] memory assets, uint256[] memory pending) = basketRewards.getBasketRewards(basketPositionId, basketId);
        assertEq(assets[0], basketToken);
        assertEq(assets[1], basketAssets[0]);
        assertGt(pending[0], 0);
        assertGt(pending[1], 0);

        vm.roll(block.number + 1);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(basketPositionId, basketId, 100 ether, alice);
        (uint256[] memory retainedBasketIds,) = positionPortfolio.basketIdsOfPosition(basketPositionId, 0, 100);
        assertEq(retainedBasketIds.length, 1);
        assertEq(retainedBasketIds[0], basketId);

        uint256 basketBefore = IERC20(basketToken).balanceOf(alice);
        uint256 constituentBefore = IERC20(basketAssets[0]).balanceOf(alice);
        vm.prank(alice);
        (, uint256[] memory claimed) = basketRewards.claimBasketRewards(basketPositionId, basketId, alice);
        assertEq(IERC20(basketToken).balanceOf(alice) - basketBefore, claimed[0]);
        assertEq(IERC20(basketAssets[0]).balanceOf(alice) - constituentBefore, claimed[1]);
        assertEq(claimed, pending);
        (uint256[] memory clearedBasketIds,) = positionPortfolio.basketIdsOfPosition(basketPositionId, 0, 100);
        assertEq(clearedBasketIds.length, 0);
    }

    function testBasketRewardClaimRejectsOutboundTransferShortfall() public {
        delete basketAssets;
        MockOutboundFeeERC20 taxedAsset = new MockOutboundFeeERC20();
        address[] memory assets = new address[](1);
        assets[0] = address(taxedAsset);
        _createReadyBasket(assets);

        basketLiquidity.setCanonicalPoolFeeConfiguration(
            basketId,
            address(taxedAsset),
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                lockedLiquidityShareBps: 0,
                liquidityProviderShareBps: 0,
                basketStakerShareBps: 10_000,
                staticsStakerShareBps: 0,
                stonkBrokersShareBps: 0,
                indexCreatorShareBps: 0,
                treasuryShareBps: 0
            })
        );
        _swapConstituentIntoPool(0.001 ether);

        (, uint256[] memory pending) = basketRewards.getBasketRewards(basketPositionId, basketId);
        uint256 expected = pending[1];
        assertGt(expected, 100);
        taxedAsset.setTaxedSender(address(diamond));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketRewardsFacet.IncompatibleRewardTransfer.selector,
                address(taxedAsset),
                expected,
                expected - expected / 100
            )
        );
        basketRewards.claimBasketRewards(basketPositionId, basketId, alice);

        (, uint256[] memory afterRevert) = basketRewards.getBasketRewards(basketPositionId, basketId);
        assertEq(afterRevert, pending);
    }

    function testPositionMintedDirectlyThroughPositionManagerCanStake() public {
        uint256 tokenId = _mintDirectFullRangePositionToAlice(5 ether);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();

        IStaticsLiquidityRewards.StakedLiquidityView memory position = liquidityRewards.stakedLiquidityPosition(tokenId);
        assertTrue(position.staked);
        assertEq(position.pendingLiquidity, 5 ether);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(diamond));
    }

    function testIncreaseKeepsExistingWeightAndDelaysOnlyAddedLiquidity() public {
        uint256 tokenId = _mintFullRangePositionToAlice(5 ether);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();
        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);

        _mintBasketTokens(alice, 20 ether);
        MockERC20(basketAssets[0]).mint(alice, 20 ether);
        vm.startPrank(alice);
        IERC20(basketToken).approve(address(diamond), type(uint256).max);
        IERC20(basketAssets[0]).approve(address(diamond), type(uint256).max);
        IStaticsLiquidityRewards.IncreaseRequest memory request = IStaticsLiquidityRewards.IncreaseRequest({
            liquidityDelta: 1 ether, amount0Max: 10 ether, amount1Max: 10 ether, deadline: block.timestamp + 1 hours
        });
        liquidityRewards.increaseStakedLiquidity(basketPositionId, tokenId, request, alice);
        vm.stopPrank();

        IStaticsLiquidityRewards.StakedLiquidityView memory position = liquidityRewards.stakedLiquidityPosition(tokenId);
        assertEq(position.eligibleLiquidity, 5 ether);
        assertEq(position.pendingLiquidity, 1 ether);
        assertEq(positionManagerContract.getPositionLiquidity(tokenId), 6 ether);
        assertEq(liquidityRewards.poolLiquidityRewards(position.poolId).totalEligibleLiquidity, 5 ether);

        vm.prank(alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function testExitCrystallizesRewardsAndPositionTransferMovesClaimAuthority() public {
        uint256 tokenId = _mintFullRangePositionToAlice(5 ether);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();
        (uint256[] memory stakedIds,) = positionPortfolio.liquidityPositionIdsOfPosition(basketPositionId, 0, 100);
        assertEq(stakedIds.length, 1);
        assertEq(stakedIds[0], tokenId);
        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);
        _swapConstituentIntoPool(0.001 ether);

        vm.prank(alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
        (uint256[] memory retainedIds,) = positionPortfolio.liquidityPositionIdsOfPosition(basketPositionId, 0, 100);
        assertEq(retainedIds.length, 1);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, basketPositionId);

        vm.prank(alice);
        vm.expectRevert();
        liquidityRewards.claimLiquidityRewards(basketPositionId, tokenId, alice, 0, 0);
        vm.prank(bob);
        (uint256 amount0, uint256 amount1) =
            liquidityRewards.claimLiquidityRewards(basketPositionId, tokenId, bob, 0, 0);
        assertGt(amount0 + amount1, 0);
        assertEq(liquidityRewards.stakedLiquidityPosition(tokenId).positionId, 0);
        (uint256[] memory clearedIds,) = positionPortfolio.liquidityPositionIdsOfPosition(basketPositionId, 0, 100);
        assertEq(clearedIds.length, 0);
    }

    function testSameBlockStakeSwapAndExitEarnsNoLiquidityReward() public {
        uint256 tokenId = _mintFullRangePositionToAlice(5 ether);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();
        _swapConstituentIntoPool(0.001 ether);
        vm.prank(alice);
        (, uint256 amount0,, uint256 amount1) = liquidityRewards.pendingLiquidityRewards(basketPositionId, tokenId);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        vm.prank(alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function testNonFullRangePositionCannotStake() public {
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        params[0].tickLower = TickMath.minUsableTick(10) + 10;
        vm.prank(alice);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, alice);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenIds[0]);
        vm.expectPartialRevert(LiquidityRewardsFacet.PositionRangeNotFull.selector);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenIds[0]);
        vm.stopPrank();
    }

    function _mintFullRangePositionToAlice(uint256 liquidity) private returns (uint256 tokenId) {
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(liquidity);
        vm.prank(alice);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, alice);
        return tokenIds[0];
    }

    function _mintDirectFullRangePositionToAlice(uint256 liquidity) private returns (uint256 tokenId) {
        IStaticsBasketLiquidity.CanonicalPoolView memory view_ =
            basketLiquidity.canonicalPool(basketId, basketAssets[0]);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(view_.currency0),
            currency1: Currency.wrap(view_.currency1),
            fee: view_.lpFee,
            tickSpacing: view_.tickSpacing,
            hooks: IHooks(view_.hook)
        });
        uint256 amount0Max = 10 ether;
        uint256 amount1Max = 10 ether;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        _mintBasketTokens(alice, 20 ether);
        MockERC20(basketAssets[0]).mint(alice, 20 ether);
        tokenId = positionManagerContract.nextTokenId();
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidity,
            uint128(amount0Max),
            uint128(amount1Max),
            alice,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.startPrank(alice);
        IERC20(view_.currency0).approve(address(permit2Contract), amount0Max);
        IERC20(view_.currency1).approve(address(permit2Contract), amount1Max);
        permit2Contract.approve(view_.currency0, address(positionManagerContract), uint160(amount0Max), deadline);
        permit2Contract.approve(view_.currency1, address(positionManagerContract), uint160(amount1Max), deadline);
        positionManagerContract.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function _swapConstituentIntoPool(uint256 amount) private returns (BalanceDelta delta, bool zeroForOne) {
        IStaticsBasketLiquidity.CanonicalPoolView memory view_ =
            basketLiquidity.canonicalPool(basketId, basketAssets[0]);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(view_.currency0),
            currency1: Currency.wrap(view_.currency1),
            fee: view_.lpFee,
            tickSpacing: view_.tickSpacing,
            hooks: IHooks(view_.hook)
        });
        zeroForOne = view_.currency0 == basketAssets[0];
        MockERC20(basketAssets[0]).mint(alice, amount);
        _approveV4Router(alice, basketAssets[0]);
        vm.prank(alice);
        delta = v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _mintBasketTokens(address receiver, uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        MockERC20(basketAssets[0]).mint(receiver, quote[0]);
        vm.startPrank(receiver);
        IERC20(basketAssets[0]).approve(address(diamond), quote[0]);
        baskets.mint(basketId, shares, receiver, quote);
        vm.stopPrank();
    }
}
