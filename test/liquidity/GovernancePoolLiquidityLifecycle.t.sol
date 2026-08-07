// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {LiquidityRewardsFacet} from "../../src/facets/LiquidityRewardsFacet.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract GovernancePoolLiquidityLifecycleTest is BorrowLiquidityTestBase {
    IStaticsProtocolPools private protocolPools;
    IStaticsLiquidityRewards private liquidityRewards;
    MockERC20 private tokenA;
    MockERC20 private tokenB;

    function setUp() public override {
        super.setUp();
        protocolPools = IStaticsProtocolPools(address(diamond));
        liquidityRewards = IStaticsLiquidityRewards(address(diamond));
        tokenA = new MockERC20("Governance A", "gA", 18);
        tokenB = new MockERC20("Governance B", "gB", 6);
        _createReadyBasket(1);
    }

    function testGovernancePoolSupportsRewardsIncreaseDecommissionClaimAndExit() public {
        (PoolId poolId, PoolKey memory key) = _createPool();
        assertFalse(liquidityRewards.canAccrueBasketRewards(poolId));
        protocolPools.setProtocolPoolFeeConfiguration(
            poolId,
            IStaticsBasketLiquidity.SwapFeeConfiguration({
                inputFeeBps: 40,
                outputFeeBps: 60,
                polShareBps: 0,
                liquidityProviderShareBps: 10_000,
                basketStakerShareBps: 0,
                staticsStakerShareBps: 0,
                treasuryShareBps: 0
            })
        );

        uint256 tokenId = _mintExternalPosition(key, 5 ether);
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        liquidityRewards.stakeLiquidityPosition(basketPositionId, tokenId);
        vm.stopPrank();
        IStaticsLiquidityRewards.StakedLiquidityView memory pending = liquidityRewards.stakedLiquidityPosition(tokenId);
        assertEq(pending.basketId, 0);
        assertEq(pending.asset, address(0));
        assertEq(PoolId.unwrap(pending.poolId), PoolId.unwrap(poolId));
        assertTrue(
            IModularPositionNFT(address(diamond))
                .isLegActive(basketPositionId, LibPosition.liquidityLegKey(address(diamond)))
        );

        vm.roll(block.number + 1);
        liquidityRewards.activateLiquidityPosition(tokenId);
        assertTrue(liquidityRewards.canAccrueLiquidityRewards(poolId));
        _swap(key, address(tokenA), 0.01 ether);
        _swap(key, address(tokenB), 10_000);

        vm.prank(alice);
        (, uint256 reward0,, uint256 reward1) = liquidityRewards.pendingLiquidityRewards(basketPositionId, tokenId);
        assertGt(reward0, 0);
        assertGt(reward1, 0);

        _increasePosition(tokenId);
        IStaticsLiquidityRewards.StakedLiquidityView memory increased =
            liquidityRewards.stakedLiquidityPosition(tokenId);
        assertEq(increased.eligibleLiquidity, 5 ether);
        assertEq(increased.pendingLiquidity, 1 ether);
        assertEq(positionManagerContract.getPositionLiquidity(tokenId), 6 ether);
        assertEq(tokenA.balanceOf(address(liquidityManagerContract)), 0);
        assertEq(tokenB.balanceOf(address(liquidityManagerContract)), 0);
        uint256 unstakedTokenId = _mintExternalPosition(key, 1 ether);

        protocolPools.decommissionGovernancePool(poolId);
        assertTrue(protocolPools.protocolPool(poolId).decommissioned);
        _expectDecommissionedSwapRevert(key, address(tokenA), 0.001 ether);

        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).approve(address(diamond), unstakedTokenId);
        vm.expectRevert(abi.encodeWithSelector(LiquidityRewardsFacet.PoolDecommissioned.selector, poolId));
        liquidityRewards.stakeLiquidityPosition(basketPositionId, unstakedTokenId);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(unstakedTokenId), alice);

        vm.startPrank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        IStaticsLiquidityRewards.IncreaseRequest memory request = IStaticsLiquidityRewards.IncreaseRequest({
            liquidityDelta: 1 ether, amount0Max: 10 ether, amount1Max: 10 ether, deadline: block.timestamp + 1 hours
        });
        vm.expectPartialRevert(StaticsLiquidityManager.ProtocolPoolDecommissioned.selector);
        liquidityRewards.increaseStakedLiquidity(basketPositionId, tokenId, request, alice);
        liquidityRewards.unstakeLiquidityPosition(basketPositionId, tokenId, alice);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);

        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeB = tokenB.balanceOf(alice);
        (uint256 claimed0, uint256 claimed1) =
            liquidityRewards.claimLiquidityRewards(basketPositionId, tokenId, alice, 0, 0);
        vm.stopPrank();
        uint256 claimedA = address(tokenA) == Currency.unwrap(key.currency0) ? claimed0 : claimed1;
        uint256 claimedB = address(tokenB) == Currency.unwrap(key.currency0) ? claimed0 : claimed1;
        assertEq(tokenA.balanceOf(alice) - beforeA, claimedA);
        assertEq(tokenB.balanceOf(alice) - beforeB, claimedB);
        assertGt(claimedA, 0);
        assertGt(claimedB, 0);
    }

    function _createPool() private returns (PoolId poolId, PoolKey memory key) {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = IStaticsProtocolPools.CreateGovernancePoolParams({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            amountAMax: 100 ether,
            amountBMax: 100_000_000,
            minLiquidity: 1,
            payer: alice,
            deadline: block.timestamp + 1 days
        });
        tokenA.mint(alice, params.amountAMax * 2);
        tokenB.mint(alice, params.amountBMax * 2);
        vm.startPrank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
        (key, poolId,,,,) = protocolPools.quoteGovernancePool(params);
        protocolPools.createGovernancePool(params);
    }

    function _mintExternalPosition(PoolKey memory key, uint256 liquidity) private returns (uint256 tokenId) {
        uint256 amount0Max = 10 ether;
        uint256 amount1Max = 10 ether;
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        MockERC20(currency0).mint(alice, amount0Max);
        MockERC20(currency1).mint(alice, amount1Max);
        uint48 deadline = uint48(block.timestamp + 1 hours);
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
        IERC20(currency0).approve(address(permit2Contract), amount0Max);
        IERC20(currency1).approve(address(permit2Contract), amount1Max);
        permit2Contract.approve(currency0, address(positionManagerContract), uint160(amount0Max), deadline);
        permit2Contract.approve(currency1, address(positionManagerContract), uint160(amount1Max), deadline);
        positionManagerContract.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function _increasePosition(uint256 tokenId) private {
        tokenA.mint(alice, 20 ether);
        tokenB.mint(alice, 20 ether);
        vm.startPrank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
        tokenB.approve(address(diamond), type(uint256).max);
        liquidityRewards.increaseStakedLiquidity(
            basketPositionId,
            tokenId,
            IStaticsLiquidityRewards.IncreaseRequest({
                liquidityDelta: 1 ether, amount0Max: 10 ether, amount1Max: 10 ether, deadline: block.timestamp + 1 hours
            }),
            alice
        );
        vm.stopPrank();
    }

    function _swap(PoolKey memory key, address input, uint256 amount) private {
        MockERC20(input).mint(alice, amount);
        _approveV4Router(alice, input);
        bool zeroForOne = input == Currency.unwrap(key.currency0);
        vm.prank(alice);
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _expectDecommissionedSwapRevert(PoolKey memory key, address input, uint256 amount) private {
        MockERC20(input).mint(alice, amount);
        _approveV4Router(alice, input);
        bool zeroForOne = input == Currency.unwrap(key.currency0);
        vm.prank(alice);
        vm.expectRevert();
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }
}
