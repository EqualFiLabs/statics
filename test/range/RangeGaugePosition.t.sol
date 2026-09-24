// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugePositionTest is RangeGaugeFeatureTestBase {
    using PoolIdLibrary for PoolKey;

    uint128 private constant INITIAL_LIQUIDITY = 5 ether;
    uint256 private constant TOKEN_MAXIMUM = 10 ether;

    function testProvideEnforcesOneLegPerPoolAndSupportsManyPoolsPerPosition() public {
        PoolId firstPool = _createRangeGaugePool(alice);
        MockERC20 assetC = new MockERC20("Asset C", "C", 18);
        PoolId secondPool = _createRangeGaugePool(alice, address(assetA), address(assetC));
        uint256 positionId = _createPosition(alice);

        IStaticsRangeGauge.LiquidityMovement memory first =
            _provide(positionId, firstPool, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY, alice);
        assertEq(first.liquidity, INITIAL_LIQUIDITY);
        assertEq(rangeGauge.gaugePool(firstPool).activeGaugeLiquidity, INITIAL_LIQUIDITY);
        assertEq(rangeGauge.lpLeg(positionId, firstPool).manager, address(rangeLiquidityManager));
        assertEq(rangeGauge.posmBinding(first.posmTokenId), LibRangeGauge.bindingFor(positionId, firstPool));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.ManagedLegAlreadyExists.selector, positionId, firstPool)
        );
        rangeGauge.provideLiquidity(positionId, _provideParams(firstPool, _fullLower(), _fullUpper(), 1 ether));

        IStaticsRangeGauge.LiquidityMovement memory second =
            _provide(positionId, secondPool, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY, alice);
        assertTrue(second.posmTokenId != first.posmTokenId);
        (PoolId[] memory pools, uint256 nextCursor) = rangeGauge.positionGaugePools(positionId, 0, 10);
        assertEq(pools.length, 2);
        assertEq(nextCursor, 2);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(positionId), 2);
    }

    function testProvideRejectsTokenDebitAboveCallerMaximum() public {
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        MockERC20 paired = new MockERC20("Paired", "PAIR", 18);
        PoolId poolId = _createRangeGaugePool(alice, address(taxed), address(paired));
        PoolKey memory key = _poolKey(poolId);
        uint256 positionId = _createPosition(alice);

        taxed.mint(alice, TOKEN_MAXIMUM * 2);
        paired.mint(alice, TOKEN_MAXIMUM * 2);
        taxed.setTaxedSender(alice);
        vm.startPrank(alice);
        taxed.approve(address(diamond), type(uint256).max);
        paired.approve(address(diamond), type(uint256).max);
        vm.expectPartialRevert(IStaticsRangeGauge.InputDebitExceedsMaximum.selector);
        rangeGauge.provideLiquidity(positionId, _provideParams(poolId, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY));
        vm.stopPrank();

        (PoolId[] memory pools,) = rangeGauge.positionGaugePools(positionId, 0, 1);
        assertEq(pools.length, 0);
        assertEq(rangeGauge.gaugePool(poolId).managedLegCount, 0);
        assertEq(taxed.balanceOf(address(diamond)), 0);
        assertEq(paired.balanceOf(address(diamond)), 0);
        assertTrue(Currency.unwrap(key.currency0) == address(taxed) || Currency.unwrap(key.currency1) == address(taxed));
    }

    function testOutOfRangeProvideAndAttachmentStartWithZeroActiveWeight() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 providedPosition = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided =
            _provide(providedPosition, poolId, 10, 20, INITIAL_LIQUIDITY, alice);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 0);
        assertEq(rangeGauge.gaugeBoundary(poolId, 10).grossLiquidity, INITIAL_LIQUIDITY);
        assertEq(rangeGauge.gaugeBoundary(poolId, 20).grossLiquidity, INITIAL_LIQUIDITY);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(provided.posmTokenId), address(rangeLiquidityManager));

        uint256 attachedPosition = _createPosition(alice);
        uint256 posmTokenId = _mintUserPosition(key, alice, -20, -10, INITIAL_LIQUIDITY);
        vm.prank(alice);
        IERC721(address(rangePositionManager)).approve(address(rangeLiquidityManager), posmTokenId);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory attached =
            rangeGauge.attachLiquidity(attachedPosition, poolId, posmTokenId);
        assertEq(attached.liquidity, INITIAL_LIQUIDITY);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 0);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(posmTokenId), address(rangeLiquidityManager));
    }

    function testAttachmentRequiresPosmOwnerEvenForApprovedPnftOperator() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 positionId = _createPosition(alice);
        uint256 posmTokenId = _mintUserPosition(key, alice, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY);
        vm.prank(alice);
        IERC721(address(diamond)).approve(bob, positionId);
        vm.prank(alice);
        IERC721(address(rangePositionManager)).setApprovalForAll(bob, true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.NotPosmOwner.selector, posmTokenId, bob, alice));
        rangeGauge.attachLiquidity(positionId, poolId, posmTokenId);

        vm.prank(alice);
        IERC721(address(rangePositionManager)).approve(address(rangeLiquidityManager), posmTokenId);
        vm.prank(alice);
        rangeGauge.attachLiquidity(positionId, poolId, posmTokenId);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(posmTokenId), address(rangeLiquidityManager));
    }

    function testIncreaseAndPartialDecreaseSettleOldWeightBeforeMutation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY, alice);
        _fundStatics(poolId, 700 ether);

        vm.warp(block.timestamp + 1 days);
        _fundAndApprovePoolAssets(_poolKey(poolId), alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory increased = rangeGauge.increaseLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.IncreaseLiquidityParams({
                liquidity: 2 ether,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
        IStaticsRangeGauge.LpLegView memory afterIncrease = rangeGauge.lpLeg(positionId, poolId);
        assertEq(increased.liquidity, 7 ether);
        assertEq(afterIncrease.claimable[1], 100 ether);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 7 ether);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory decreased = rangeGauge.decreaseLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.DecreaseLiquidityParams({
                liquidity: 3 ether, amount0Minimum: 0, amount1Minimum: 0, deadline: block.timestamp + 1 hours
            })
        );
        IStaticsRangeGauge.LpLegView memory afterDecrease = rangeGauge.lpLeg(positionId, poolId);
        assertEq(decreased.liquidity, 4 ether);
        assertEq(afterDecrease.claimable[1], 200 ether - 1);
        assertGt(afterDecrease.rewardRemainderRay[1], 0);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 4 ether);
    }

    function testNativeFeeCollectionDoesNotMutateGaugeTopology() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY, alice);
        _fundAndApprovePoolAssets(key, bob, 1 ether);
        vm.prank(bob);
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        bytes32 legBefore = keccak256(abi.encode(rangeGauge.lpLeg(positionId, poolId)));
        bytes32 poolBefore = keccak256(abi.encode(rangeGauge.gaugePool(poolId)));
        bytes32 lowerBefore = keccak256(abi.encode(rangeGauge.gaugeBoundary(poolId, _fullLower())));
        bytes32 upperBefore = keccak256(abi.encode(rangeGauge.gaugeBoundary(poolId, _fullUpper())));
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory collected =
            rangeGauge.collectNativeFees(positionId, poolId, 0, 0, block.timestamp + 1 hours);
        assertGt(collected.received0 + collected.received1, 0);
        assertEq(keccak256(abi.encode(rangeGauge.lpLeg(positionId, poolId))), legBefore);
        assertEq(keccak256(abi.encode(rangeGauge.gaugePool(poolId))), poolBefore);
        assertEq(keccak256(abi.encode(rangeGauge.gaugeBoundary(poolId, _fullLower()))), lowerBefore);
        assertEq(keccak256(abi.encode(rangeGauge.gaugeBoundary(poolId, _fullUpper()))), upperBefore);
    }

    function testPnftTransferChangesAuthorizationWithoutChangingGaugeOrCustody() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided =
            _provide(positionId, poolId, _fullLower(), _fullUpper(), INITIAL_LIQUIDITY, alice);
        bytes32 legBefore = keccak256(abi.encode(rangeGauge.lpLeg(positionId, poolId)));
        bytes32 poolBefore = keccak256(abi.encode(rangeGauge.gaugePool(poolId)));
        bytes32 streamBefore = keccak256(abi.encode(rangeGauge.poolRewardStream(poolId, 0)));

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(provided.posmTokenId), address(rangeLiquidityManager));
        assertEq(keccak256(abi.encode(rangeGauge.lpLeg(positionId, poolId))), legBefore);
        assertEq(keccak256(abi.encode(rangeGauge.gaugePool(poolId))), poolBefore);
        assertEq(keccak256(abi.encode(rangeGauge.poolRewardStream(poolId, 0))), streamBefore);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibPosition.NotPositionOwnerOrApproved.selector, positionId, alice));
        rangeGauge.collectNativeFees(positionId, poolId, 0, 0, block.timestamp + 1 hours);
        vm.prank(bob);
        rangeGauge.collectNativeFees(positionId, poolId, 0, 0, block.timestamp + 1 hours);
    }

    function _provide(
        uint256 positionId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address payer
    ) private returns (IStaticsRangeGauge.LiquidityMovement memory movement) {
        _fundAndApprovePoolAssets(_poolKey(poolId), payer, TOKEN_MAXIMUM);
        vm.prank(payer);
        movement = rangeGauge.provideLiquidity(positionId, _provideParams(poolId, tickLower, tickUpper, liquidity));
    }

    function _provideParams(PoolId poolId, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        view
        returns (IStaticsRangeGauge.ProvideLiquidityParams memory params)
    {
        params = IStaticsRangeGauge.ProvideLiquidityParams({
            poolId: poolId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0Maximum: TOKEN_MAXIMUM,
            amount1Maximum: TOKEN_MAXIMUM,
            deadline: block.timestamp + 1 hours
        });
    }

    function _mintUserPosition(PoolKey memory key, address owner, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        returns (uint256 tokenId)
    {
        _fundAndApprovePoolAssets(key, owner, TOKEN_MAXIMUM);
        uint48 deadline = uint48(block.timestamp + 1 hours);
        tokenId = rangePositionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(TOKEN_MAXIMUM),
            uint128(TOKEN_MAXIMUM),
            owner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.startPrank(owner);
        IERC20(Currency.unwrap(key.currency0)).approve(address(rangePermit2), TOKEN_MAXIMUM);
        IERC20(Currency.unwrap(key.currency1)).approve(address(rangePermit2), TOKEN_MAXIMUM);
        rangePermit2.approve(
            Currency.unwrap(key.currency0), address(rangePositionManager), uint160(TOKEN_MAXIMUM), deadline
        );
        rangePermit2.approve(
            Currency.unwrap(key.currency1), address(rangePositionManager), uint160(TOKEN_MAXIMUM), deadline
        );
        rangePositionManager.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
    }

    function _fundAndApprovePoolAssets(PoolKey memory key, address user, uint256 amount) private {
        MockERC20(Currency.unwrap(key.currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(key.currency0)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key.currency0)).approve(address(v4Router), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(v4Router), type(uint256).max);
        vm.stopPrank();
    }

    function _fundStatics(PoolId poolId, uint256 amount) private {
        vm.prank(alice);
        uint8 slot = rangeGauge.appendPoolRewardAsset(poolId, address(stakingAsset));
        stakingAsset.mint(alice, amount);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), amount);
        rangeGauge.fundPoolReward(poolId, slot, amount, uint40(7 days));
        vm.stopPrank();
    }

    function _createPosition(address owner) private returns (uint256 positionId) {
        vm.prank(owner);
        positionId = IStaticsPosition(address(diamond)).createPosition(owner);
    }

    function _poolKey(PoolId poolId) private view returns (PoolKey memory key) {
        key = IStaticsProtocolPools(address(diamond)).protocolPool(poolId).key;
    }

    function _fullLower() private pure returns (int24) {
        return TickMath.minUsableTick(10);
    }

    function _fullUpper() private pure returns (int24) {
        return TickMath.maxUsableTick(10);
    }
}
