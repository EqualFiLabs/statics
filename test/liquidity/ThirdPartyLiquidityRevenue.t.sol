// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract ThirdPartyLiquidityRevenueTest is CanonicalPoolTestBase {
    StaticsLiquidityManager private liquidityManagerContract;
    uint256 private basketId;
    address private basketToken;
    address private constituent;
    PoolKey private poolKey;

    function setUp() public override {
        super.setUp();
        IAllowanceTransfer permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        IPositionManager positionManagerContract = IPositionManager(
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
            name: "Third Party LP Basket",
            symbol: "s3LP",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
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
        MockERC20(constituent).mint(alice, 20 ether);
        poolKey = _poolKey();
        _approveV4Router(alice, constituent);
        _approveV4Router(alice, basketToken);
    }

    function testThirdPartyLpKeepsItsV4FeesWhileProtocolReceivesOnlyHookRevenue() public {
        ModifyLiquidityParams memory add = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidityDelta: int256(10 ether),
            salt: bytes32(0)
        });
        vm.prank(alice);
        v4Router.modifyLiquidity(poolKey, add);

        vm.startPrank(alice);
        v4Router.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        v4Router.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();

        (uint256 pendingBasket, uint256 pendingConstituent) =
            basketLiquidity.pendingCanonicalHookFees(basketId, constituent);
        assertGt(pendingBasket, 0);
        assertGt(pendingConstituent, 0);
        assertEq(liquidityManagerContract.protocolPositionId(basketId, constituent), 0);
        IStaticsBasketLiquidity.ProtocolLpFeeTotals memory protocolFees =
            basketLiquidity.cumulativeProtocolLpFees(basketId, constituent);
        assertEq(protocolFees.basketTokenCollected, 0);
        assertEq(protocolFees.constituentCollected, 0);

        uint256 basketBefore = IERC20(basketToken).balanceOf(alice);
        uint256 constituentBefore = IERC20(constituent).balanceOf(alice);
        ModifyLiquidityParams memory remove = ModifyLiquidityParams({
            tickLower: add.tickLower, tickUpper: add.tickUpper, liquidityDelta: -add.liquidityDelta, salt: bytes32(0)
        });
        vm.prank(alice);
        v4Router.modifyLiquidity(poolKey, remove);
        assertGt(IERC20(basketToken).balanceOf(alice), basketBefore);
        assertGt(IERC20(constituent).balanceOf(alice), constituentBefore);

        uint256 revenueBefore = basketAdmin.protocolRevenue(basketId, constituent);
        basketLiquidity.settleCanonicalHookFees(basketId, constituent);
        assertGt(basketAdmin.protocolRevenue(basketId, constituent), revenueBefore);
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
