// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract BasketLiquidityDecommissionTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    uint256 private basketId;
    address private basketToken;
    address private constituent;
    PoolKey private canonicalKey;

    function setUp() public override {
        super.setUp();
        constituent = address(new MockERC20("Constituent", "C", 18));
        (basketId, basketToken) = _createSingleAssetBasket();
        _mintBasket(100 ether);
        IStaticsBasketLiquidity.CanonicalPoolView memory configured =
            basketLiquidity.canonicalPool(basketId, constituent);
        canonicalKey = PoolKey({
            currency0: Currency.wrap(configured.currency0),
            currency1: Currency.wrap(configured.currency1),
            fee: configured.lpFee,
            tickSpacing: configured.tickSpacing,
            hooks: IHooks(configured.hook)
        });
        _seedAndSwap();
        vm.warp(block.timestamp + 1 hours);
    }

    function testExitOnlyReleasesPolAndRoutesItToGlobalTreasury() public {
        uint128 lockedBefore = swapFeeHook.lockedLiquidity(canonicalKey.toId());
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        uint256 vaultBefore = baskets.vaultBalance(basketId, constituent);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(constituent);
        assertGt(lockedBefore, 0);

        governance.decommissionBasket(basketId);
        vm.prank(bob);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        assertTrue(basketLiquidity.basketLiquidityUnwound(basketId, constituent));
        assertTrue(swapFeeHook.poolDecommissioned(canonicalKey.toId()));
        assertEq(swapFeeHook.lockedLiquidity(canonicalKey.toId()), 0);
        assertLt(IERC20(basketToken).totalSupply(), supplyBefore);
        assertLt(baskets.vaultBalance(basketId, constituent), vaultBefore);
        assertGt(globalRewards.treasuryAccrued(constituent), treasuryBefore);
    }

    function testPoolCannotUnwindEarlyOrSwapAfterDecommission() public {
        vm.expectPartialRevert(BasketLiquidityFacet.BasketNotExitOnly.selector);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        governance.decommissionBasket(basketId);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);
        vm.expectRevert();
        v4Router.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: canonicalKey.currency0 == Currency.wrap(basketToken),
                amountSpecified: -int256(0.0001 ether),
                sqrtPriceLimitX96: canonicalKey.currency0 == Currency.wrap(basketToken)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function testGovernanceCanUpdateCappedFeeConfiguration() public {
        IStaticsBasketLiquidity.SwapFeeConfiguration memory configuration = IStaticsBasketLiquidity.SwapFeeConfiguration({
            inputFeeBps: 40,
            outputFeeBps: 60,
            polShareBps: 6_000,
            liquidityProviderShareBps: 1_000,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 2_000,
            treasuryShareBps: 1_000
        });
        basketLiquidity.setSwapFeeConfiguration(configuration);
        IStaticsBasketLiquidity.SwapFeeConfiguration memory stored = basketLiquidity.swapFeeConfiguration();
        assertEq(stored.inputFeeBps, 40);
        assertEq(stored.outputFeeBps, 60);
        assertEq(stored.polShareBps, 6_000);
        assertEq(stored.liquidityProviderShareBps, 1_000);
    }

    function _seedAndSwap() private {
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, constituent);
        vm.startPrank(alice);
        v4Router.modifyLiquidity(
            canonicalKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(10 ether), salt: bytes32(0)})
        );
        bool basketIsCurrency0 = canonicalKey.currency0 == Currency.wrap(basketToken);
        v4Router.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: basketIsCurrency0,
                amountSpecified: -int256(0.001 ether),
                sqrtPriceLimitX96: basketIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();
    }

    function _createSingleAssetBasket() private returns (uint256 createdBasketId, address createdToken) {
        address[] memory assets = new address[](1);
        assets[0] = constituent;
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Exit Basket",
            symbol: "sEXIT",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) = _fundDefaultLaunch(assets, alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        return baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);
    }

    function _mintBasket(uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        MockERC20(constituent).mint(alice, quote[0] + 1 ether);
        vm.startPrank(alice);
        IERC20(constituent).approve(address(diamond), quote[0]);
        baskets.mint(basketId, shares, alice, quote);
        vm.stopPrank();
    }
}
