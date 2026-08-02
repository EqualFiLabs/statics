// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {CanonicalPoolTestBase} from "./CanonicalPoolTestBase.sol";

abstract contract LiquidityManagerTestBase is CanonicalPoolTestBase {
    IAllowanceTransfer internal permit2Contract;
    IPositionManager internal positionManagerContract;
    StaticsLiquidityManager internal liquidityManager;
    uint256 internal basketId;
    address internal basketToken;
    PoolKey internal canonicalKey;

    function setUp() public virtual override {
        super.setUp();
        permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        positionManagerContract = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        liquidityManager = new StaticsLiquidityManager(
            address(this), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );

        (basketId, basketToken) = _createDefaultBasket(0, 0);
        canonicalKey = _canonicalKey();
        liquidityManager.registerCanonicalPool(basketId, address(assetA), canonicalKey);

        uint256[] memory quote = baskets.quoteMint(basketId, 200 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, 200 ether, alice, quote);
        assetA.mint(alice, 200 ether);
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(assetA));
    }

    function _request(uint256 liquidity, uint256 amount0Limit, uint256 amount1Limit)
        internal
        view
        returns (IStaticsLiquidityManager.PositionRequest memory request)
    {
        request = IStaticsLiquidityManager.PositionRequest({
            basketId: basketId,
            asset: address(assetA),
            poolKey: canonicalKey,
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidity: liquidity,
            amount0Limit: amount0Limit,
            amount1Limit: amount1Limit,
            deadline: block.timestamp + 1 hours
        });
    }

    function _creditInventory(uint256 basketAmount, uint256 assetAmount) internal {
        vm.startPrank(alice);
        IERC20(basketToken).transfer(address(liquidityManager), basketAmount);
        assetA.transfer(address(liquidityManager), assetAmount);
        vm.stopPrank();
        liquidityManager.creditProtocolInventory(basketId, basketToken, basketAmount);
        liquidityManager.creditProtocolInventory(basketId, address(assetA), assetAmount);
    }

    function _transferUserInventory(uint256 basketAmount, uint256 assetAmount) internal {
        vm.startPrank(alice);
        IERC20(basketToken).transfer(address(liquidityManager), basketAmount);
        assetA.transfer(address(liquidityManager), assetAmount);
        vm.stopPrank();
    }

    function _canonicalKey() private view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }
}
