// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IMorphoBlue, MorphoMarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {MorphoSettlementFacet} from "../../src/facets/MorphoSettlementFacet.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface UpstreamMorphoSetup is IMorphoBlue {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function createMarket(MorphoMarketParams calldata params) external;
    function supply(
        MorphoMarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address receiver,
        bytes calldata data
    ) external returns (uint256, uint256);
}

contract RestrictedCollateralOracle {
    uint256 public price = 1e36;

    function setPrice(uint256 next) external {
        price = next;
    }
}

/// @dev Executes pinned upstream Morpho 0.8.19 bytecode locally, not MockMorphoBlue.
contract RestrictedMorphoCollateralTest is PreparedBasketTestBase {
    UpstreamMorphoSetup private realMorpho;
    MockERC20 private usd;
    RestrictedCollateralOracle private oracle;
    IStaticsMorpho private morphoApi;
    MorphoMarketParams private market;
    bytes32 private marketId;
    uint256 private collateralBasket;
    uint256 private collateralPosition;
    address private collateralToken;

    function setUp() public override {
        super.setUp();
        _queueFirst();
        (collateralBasket, collateralToken) = _createDefaultBasket(0, 0);
        realMorpho = UpstreamMorphoSetup(
            deployCode("out/UpstreamMorphoCompilation.sol/UpstreamMorphoCompilation.json", abi.encode(address(this)))
        );
        usd = new MockERC20("USD", "USD", 18);
        oracle = new RestrictedCollateralOracle();
        morphoApi = IStaticsMorpho(address(diamond));
        morphoApi.initializeMorphoIntegration(address(realMorpho), address(usd), 0);
        basketAdmin.setBasketDistributor(address(realMorpho), true);
        realMorpho.enableIrm(address(0));
        realMorpho.enableLltv(0.77 ether);
        market = MorphoMarketParams(address(usd), collateralToken, address(oracle), address(0), 0.77 ether);
        realMorpho.createMarket(market);
        marketId = morphoApi.registerMorphoMarket(
            market, IStaticsMorpho.CollateralKind.Basket, collateralBasket, IStaticsMorpho.MarketMode.Active
        );
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 100 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (collateralPosition,) =
            basketCollateral.createAndMintBasketCollateral(collateralBasket, 100 ether, alice, quote);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(collateralPosition, marketId, 80 ether);
        usd.mint(address(this), 1000 ether);
        usd.approve(address(realMorpho), 1000 ether);
        realMorpho.supply(market, 1000 ether, 0, address(this), "");
        vm.prank(alice);
        morphoApi.borrowMorphoUsd(collateralPosition, marketId, 50 ether, type(uint256).max, alice);
        assertTrue(basketAdmin.isBasketDistributor(address(realMorpho)));
    }

    function testTrackedIngressAndRecallWithActualMorpho() public {
        vm.prank(alice);
        morphoApi.recallMorphoCollateral(collateralPosition, marketId, 5 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 75 ether);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(collateralPosition, collateralBasket, 10 ether, alice);
        assertEq(IERC20(collateralToken).balanceOf(alice), 10 ether);
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        vm.startPrank(alice);
        IERC20(collateralToken).approve(address(realMorpho), 1 ether);
        realMorpho.supplyCollateral(market, 1 ether, account, "");
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 75 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).untrackedSurplus, 1 ether);
        vm.expectRevert();
        IERC20(collateralToken).transfer(account, 1);
        vm.stopPrank();
    }

    function testDirectLiquidationUsesDistributorAndLiquidatorCanRedeem() public {
        oracle.setPrice(0.5e36);
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        usd.mint(bob, 100 ether);
        vm.prank(bob);
        usd.approve(address(realMorpho), 100 ether);
        vm.prank(bob);
        (uint256 seized,) = realMorpho.liquidate(market, account, 20 ether, 0, "");
        assertEq(seized, 20 ether);
        assertEq(IERC20(collateralToken).balanceOf(bob), seized);
        vm.prank(bob);
        baskets.redeem(collateralBasket, seized, bob, new uint256[](2));
        assertEq(IERC20(collateralToken).balanceOf(bob), 0);
        assertGt(assetA.balanceOf(bob), 0);
        morphoApi.syncMorpho(collateralPosition, marketId);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 60 ether);
        assertEq(
            basketCollateral.basketCollateralPosition(collateralPosition, collateralBasket).depositedShares, 80 ether
        );
    }

    function testDirectDepositAndSurplusRecoveryDoNotIncreaseStaticsStake() public {
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 3 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 3 ether, alice, quote);
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        bytes32 stakeBefore =
            keccak256(abi.encode(basketCollateral.basketCollateralPosition(collateralPosition, collateralBasket)));
        (address[] memory rewardAssets, uint256[] memory rewardAmounts) =
            basketRewards.getBasketRewards(collateralPosition, collateralBasket);
        bytes32 rewardsBefore = keccak256(abi.encode(rewardAssets, rewardAmounts));
        vm.startPrank(alice);
        IERC20(collateralToken).approve(address(realMorpho), 3 ether);
        realMorpho.supplyCollateral(market, 3 ether, account, "");
        vm.stopPrank();
        morphoApi.syncMorpho(collateralPosition, marketId);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 80 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).untrackedSurplus, 3 ether);
        assertEq(
            keccak256(abi.encode(basketCollateral.basketCollateralPosition(collateralPosition, collateralBasket))),
            stakeBefore
        );
        (rewardAssets, rewardAmounts) = basketRewards.getBasketRewards(collateralPosition, collateralBasket);
        assertEq(keccak256(abi.encode(rewardAssets, rewardAmounts)), rewardsBefore);
        vm.prank(alice);
        morphoApi.withdrawUntrackedMorphoCollateral(collateralPosition, marketId, 3 ether, alice);
        assertEq(IERC20(collateralToken).balanceOf(alice), 3 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).untrackedSurplus, 0);
    }

    function testDirectDepositDoesNotIncreaseFundedRewardPayout() public {
        // Compare the same funded swap and claim with and without external Morpho surplus.
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 3 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 3 ether, alice, quote);
        vm.warp(block.timestamp + 25 hours);
        uint256 snapshot = vm.snapshotState();
        (address[] memory expectedAssets, uint256[] memory expectedAmounts) = _swapAndClaimRewards();
        uint256 totalClaimed;
        for (uint256 i; i < expectedAmounts.length; ++i) {
            totalClaimed += expectedAmounts[i];
        }
        assertGt(totalClaimed, 0);
        assertTrue(vm.revertToState(snapshot));

        (address account,) = morphoApi.morphoAccount(collateralPosition);
        vm.startPrank(alice);
        IERC20(collateralToken).approve(address(realMorpho), 3 ether);
        realMorpho.supplyCollateral(market, 3 ether, account, "");
        vm.stopPrank();
        morphoApi.syncMorpho(collateralPosition, marketId);
        (address[] memory actualAssets, uint256[] memory actualAmounts) = _swapAndClaimRewards();
        assertEq(actualAssets, expectedAssets);
        assertEq(actualAmounts, expectedAmounts);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 80 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).untrackedSurplus, 3 ether);
    }

    function _swapAndClaimRewards() private returns (address[] memory assets, uint256[] memory amounts) {
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(collateralBasket, address(assetA));
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        PoolKey memory key = pools.protocolPool(canonical.poolId).key;
        assetA.mint(bob, 1 ether);
        _approveV4Router(bob, address(assetA));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(assetA);
        vm.prank(bob);
        v4Router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(0.1 ether), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        pools.settleProtocolPoolRevenue(canonical.poolId, collateralToken);
        pools.settleProtocolPoolRevenue(canonical.poolId, address(assetA));
        vm.prank(alice);
        return basketRewards.claimBasketRewards(collateralPosition, collateralBasket, alice);
    }

    function testAccountRecoveryUsesAnExactDiamondMovementNotAnAccountBypass() public {
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 1 ether, account, quote);
        vm.prank(account);
        vm.expectRevert();
        IERC20(collateralToken).transfer(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 1 ether);
        vm.prank(alice);
        assertEq(
            morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 1 ether), 1 ether
        );
        assertEq(IERC20(collateralToken).balanceOf(account), 0);
        assertEq(IERC20(collateralToken).balanceOf(bob), 1 ether);
    }

    function testAccountRecoveryMinimumIsIndependentOfExactDebitLimit() public {
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 3 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 3 ether, account, quote);
        uint256 diamondBefore = IERC20(collateralToken).balanceOf(address(diamond));

        vm.prank(alice);
        assertEq(morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0), 1 ether);
        vm.prank(alice);
        assertEq(
            morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0.5 ether), 1 ether
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSettlementFacet.MinimumRecoveryNotMet.selector, collateralToken, 2 ether, 1 ether
            )
        );
        vm.prank(alice);
        morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 2 ether);
        assertEq(IERC20(collateralToken).balanceOf(account), 1 ether);
        assertEq(IERC20(collateralToken).balanceOf(bob), 2 ether);
        assertEq(IERC20(collateralToken).balanceOf(address(diamond)), diamondBefore);
        vm.prank(alice);
        assertEq(morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0), 1 ether);
        assertEq(IERC20(collateralToken).balanceOf(account), 0);
    }
}
