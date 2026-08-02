// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract ProtocolLpFeeCompoundingTest is CanonicalPoolTestBase {
    IPositionManager private positionManagerContract;
    StaticsLiquidityManager private liquidityManagerContract;
    uint256 private basketId;
    address private basketToken;
    address private constituent;
    PoolKey private poolKey;

    function setUp() public override {
        super.setUp();
        IAllowanceTransfer permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        positionManagerContract = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        liquidityManagerContract = new StaticsLiquidityManager(
            address(diamond), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installLiquidityManager(address(liquidityManagerContract));

        constituent = address(new MockERC20("Constituent", "C", 18));
        address[] memory assets = new address[](1);
        assets[0] = constituent;
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "LP Fee Basket",
            symbol: "sLPF",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(20 ether),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        (basketId, basketToken) = baskets.createBasket{value: basketAdmin.creationFee()}(params);
        basketLiquidity.initializeCanonicalPool(basketId, constituent, SQRT_PRICE_1_1);
        _mintBasket(100 ether);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(basketId, constituent);
        basketLiquidity.compoundBasketLiquidity(basketId);
        poolKey = _poolKey();

        MockERC20(constituent).mint(alice, 100 ether);
        _approveV4Router(alice, constituent);
        _approveV4Router(alice, basketToken);
    }

    function testProtocolPositionFeesSplitNinetyTenWithoutChangingPrincipal() public {
        uint256 positionTokenId = liquidityManagerContract.protocolPositionId(basketId, constituent);
        uint256 positionLiquidityBefore = positionManagerContract.getPositionLiquidity(positionTokenId);
        uint256 basketInventoryBefore = liquidityManagerContract.protocolInventory(basketId, basketToken);
        uint256 assetInventoryBefore = liquidityManagerContract.protocolInventory(basketId, constituent);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        uint256 revenueBefore = basketAdmin.protocolRevenue(basketId, constituent);

        _tradeBothDirections();
        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory fees =
            basketLiquidity.collectProtocolLpFees(basketId, constituent);

        assertGt(fees.constituentCollected, 0);
        assertGt(fees.basketTokenCollected, 0);
        assertEq(fees.constituentPolRetained + fees.constituentRevenueDebit, fees.constituentCollected);
        assertEq(fees.basketTokenPolRetained + fees.basketTokenRevenueDebit, fees.basketTokenCollected);
        assertEq(fees.constituentRevenue, fees.constituentRevenueDebit);
        assertEq(fees.basketTokensBurned, fees.basketTokenRevenueDebit);
        assertEq(
            liquidityManagerContract.protocolInventory(basketId, constituent),
            assetInventoryBefore + fees.constituentPolRetained
        );
        assertEq(
            liquidityManagerContract.protocolInventory(basketId, basketToken),
            basketInventoryBefore + fees.basketTokenPolRetained
        );
        assertEq(IERC20(basketToken).totalSupply(), supplyBefore - fees.basketTokensBurned);
        assertGt(basketAdmin.protocolRevenue(basketId, constituent), revenueBefore + fees.constituentRevenue);
        assertEq(positionManagerContract.getPositionLiquidity(positionTokenId), positionLiquidityBefore);

        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory cumulative =
            basketLiquidity.cumulativeProtocolLpFees(basketId, constituent);
        assertEq(cumulative.constituentCollected, fees.constituentCollected);
        assertEq(cumulative.basketTokenCollected, fees.basketTokenCollected);

        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory empty =
            basketLiquidity.collectProtocolLpFees(basketId, constituent);
        assertEq(empty.constituentCollected, 0);
        assertEq(empty.basketTokenCollected, 0);
    }

    function testRetainedLpFeesRemainAvailableToTheNextCompoundEpoch() public {
        _tradeBothDirections();
        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory fees =
            basketLiquidity.collectProtocolLpFees(basketId, constituent);
        assertGt(fees.constituentPolRetained, 0);
        assertGt(fees.basketTokenPolRetained, 0);
        uint256 inventoryBefore = liquidityManagerContract.protocolInventory(basketId, constituent);
        uint256 liquidityBefore = positionManagerContract.getPositionLiquidity(
            liquidityManagerContract.protocolPositionId(basketId, constituent)
        );

        vm.warp(block.timestamp + 24 hours);
        basketLiquidity.compoundBasketLiquidity(basketId);

        assertGt(
            positionManagerContract.getPositionLiquidity(
                liquidityManagerContract.protocolPositionId(basketId, constituent)
            ),
            liquidityBefore
        );
        assertLt(liquidityManagerContract.protocolInventory(basketId, constituent), inventoryBefore + 0.405 ether);
    }

    function testRepeatedDustCollectionsPreserveCumulativeNinetyTenSplit() public {
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            v4Router.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(10_000), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                })
            );
            IStaticsBasketLiquidity.ProtocolLpFeeTotals memory collected =
                basketLiquidity.collectProtocolLpFees(basketId, constituent);
            assertLt(collected.constituentCollected + collected.basketTokenCollected, 10);
        }

        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory cumulative =
            basketLiquidity.cumulativeProtocolLpFees(basketId, constituent);
        assertEq(
            cumulative.constituentRevenueDebit,
            cumulative.constituentCollected * 1_000 / 10_000,
            "constituent split depends on collection frequency"
        );
        assertEq(
            cumulative.basketTokenRevenueDebit,
            cumulative.basketTokenCollected * 1_000 / 10_000,
            "basket-token split depends on collection frequency"
        );
        assertGt(cumulative.constituentRevenueDebit + cumulative.basketTokenRevenueDebit, 0);
    }

    function testLpFeeAllocationIsFixed() public view {
        (uint16 polShareBps, uint16 revenueShareBps) = basketLiquidity.protocolLpFeeAllocation();
        assertEq(polShareBps, 9_000);
        assertEq(revenueShareBps, 1_000);
    }

    function _tradeBothDirections() private {
        vm.startPrank(alice);
        v4Router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        v4Router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();
    }

    function _mintBasket(uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        MockERC20(constituent).mint(alice, quote[0]);
        vm.startPrank(alice);
        IERC20(constituent).approve(address(diamond), type(uint256).max);
        baskets.mint(basketId, shares, alice, quote);
        vm.stopPrank();
    }

    function _poolKey() private view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, constituent);
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }
}
