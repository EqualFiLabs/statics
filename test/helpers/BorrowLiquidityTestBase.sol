// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "./CanonicalPoolTestBase.sol";

abstract contract BorrowLiquidityTestBase is CanonicalPoolTestBase {
    IAllowanceTransfer internal permit2Contract;
    IPositionManager internal positionManagerContract;
    StaticsLiquidityManager internal liquidityManagerContract;
    IStaticsBorrowLiquidity internal borrowLiquidity;
    uint256 internal basketId;
    address internal basketToken;
    uint256 internal basketPositionId;
    address[] internal basketAssets;

    function setUp() public virtual override {
        super.setUp();
        permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
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
        borrowLiquidity = IStaticsBorrowLiquidity(address(diamond));
    }

    function _createReadyBasket(uint256 count) internal {
        address[] memory assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(new MockERC20("Constituent", "C", 18));
        }
        _createReadyBasket(assets);
    }

    function _createReadyBasket(address[] memory assets) internal {
        uint256 count = assets.length;
        uint256[] memory bundleAmounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            bundleAmounts[i] = 1 ether;
            basketAssets.push(assets[i]);
        }
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Borrow LP Basket",
            symbol: "sBLP",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0.2 ether),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        (basketId, basketToken) = baskets.createBasket{value: basketAdmin.creationFee()}(params);

        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        vm.startPrank(alice);
        for (uint256 i; i < count; ++i) {
            MockERC20(assets[i]).mint(alice, quote[i]);
            IERC20(assets[i]).approve(address(diamond), type(uint256).max);
        }
        (basketPositionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 100 ether, alice, quote);
        vm.stopPrank();

        for (uint256 i; i < count; ++i) {
            basketLiquidity.initializeCanonicalPool(basketId, assets[i], SQRT_PRICE_1_1);
        }
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < count; ++i) {
            basketLiquidity.activateCanonicalPool(basketId, assets[i]);
        }
    }

    function _poolParams(uint256 liquidity)
        internal
        view
        returns (IStaticsBorrowLiquidity.LiquidityParams[] memory params)
    {
        uint256 length = basketAssets.length;
        params = new IStaticsBorrowLiquidity.LiquidityParams[](length);
        for (uint256 i; i < length; ++i) {
            params[i] = IStaticsBorrowLiquidity.LiquidityParams({
                asset: basketAssets[i],
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: liquidity,
                amount0Max: 100 ether,
                amount1Max: 100 ether,
                deadline: block.timestamp + 1 hours
            });
        }
    }
}
