// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract RevertingUnsubscribeSubscriber is ISubscriber {
    function notifySubscribe(uint256, bytes memory) external pure {}

    function notifyUnsubscribe(uint256) external pure {
        revert("unsubscribe rejected");
    }

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {}

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}
}

contract StaticsLiquidityManagerRangeGaugeTest is LiquidityManagerTestBase {
    using PoolIdLibrary for PoolKey;

    function testConstructorRejectsZeroImmutableBindings() public {
        address diamondBinding = address(this);
        address posmBinding = address(positionManagerContract);
        address poolBinding = address(poolManager);
        address permitBinding = address(permit2Contract);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.InvalidBinding.selector, address(0)));
        new StaticsLiquidityManager(address(0), posmBinding, poolBinding, permitBinding);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.InvalidBinding.selector, address(0)));
        new StaticsLiquidityManager(diamondBinding, address(0), poolBinding, permitBinding);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.InvalidBinding.selector, address(0)));
        new StaticsLiquidityManager(diamondBinding, posmBinding, address(0), permitBinding);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.InvalidBinding.selector, address(0)));
        new StaticsLiquidityManager(diamondBinding, posmBinding, poolBinding, address(0));
    }

    function testManagedMintAndIncreaseRetainCustodyWithoutInventoryOrApprovals() public {
        IStaticsLiquidityManager.ManagedPositionMovement memory minted = _mintManaged(5 ether, 6 ether);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(minted.tokenId), address(liquidityManager));
        assertEq(minted.liquidityAfter, 5 ether);
        assertEq(minted.spent0 + minted.refund0, 6 ether + minted.received0);
        assertEq(minted.spent1 + minted.refund1, 6 ether + minted.received1);
        _assertNoManagerResidue();

        _transferUserInventory(3 ether, 3 ether);
        IStaticsLiquidityManager.ManagedPositionMovement memory increased =
            liquidityManager.increaseManagedPosition(_managedRequest(minted.tokenId, 2 ether, 3 ether, 3 ether, alice));

        assertEq(increased.liquidityBefore, 5 ether);
        assertEq(increased.liquidityAfter, 7 ether);
        assertEq(increased.spent0 + increased.refund0, 3 ether + increased.received0);
        assertEq(increased.spent1 + increased.refund1, 3 ether + increased.received1);
        assertEq(positionManagerContract.getPositionLiquidity(minted.tokenId), 7 ether);
        _assertNoManagerResidue();
    }

    function testAttachmentRequiresActualOwnerAndAutomaticallyUnsubscribes() public {
        uint256 tokenId = _mintUserPosition(alice);
        RevertingUnsubscribeSubscriber hostile = new RevertingUnsubscribeSubscriber();
        vm.prank(alice);
        positionManagerContract.subscribe(tokenId, address(hostile), "");
        assertEq(address(positionManagerContract.subscriber(tokenId)), address(hostile));

        vm.prank(alice);
        IERC721(address(positionManagerContract)).setApprovalForAll(bob, true);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsLiquidityManager.PositionOwnershipMismatch.selector, tokenId, bob, alice)
        );
        liquidityManager.attachManagedPosition(bob, canonicalKey.toId(), tokenId);

        vm.prank(alice);
        IERC721(address(positionManagerContract)).approve(address(liquidityManager), tokenId);
        IStaticsLiquidityManager.ManagedPositionState memory state =
            liquidityManager.attachManagedPosition(alice, canonicalKey.toId(), tokenId);

        assertEq(state.owner, address(liquidityManager));
        assertEq(state.subscriber, address(0));
        assertEq(address(positionManagerContract.subscriber(tokenId)), address(0));
        assertEq(state.liquidity, 5 ether);
    }

    function testAttachmentRejectsWrongAndPermissionedPools() public {
        IStaticsLiquidityManager.ManagedPositionMovement memory managed = _mintManaged(5 ether, 6 ether);
        uint256 tokenId = _mintUserPosition(alice);
        vm.prank(alice);
        IERC721(address(positionManagerContract)).approve(address(liquidityManager), tokenId);

        PoolId wrongPoolId = PoolId.wrap(keccak256("wrong pool"));
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.PositionPoolMismatch.selector,
                tokenId,
                PoolId.unwrap(wrongPoolId),
                PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.attachManagedPosition(alice, wrongPoolId, tokenId);

        IStaticsProtocolPools.ProtocolPoolView memory registered = _registeredPool();
        registered.kind = IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral;
        _setManagerPoolOverride(registered);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.PublicProtocolPoolRequired.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.attachManagedPosition(alice, canonicalKey.toId(), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.PublicProtocolPoolRequired.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.mintManagedPosition(_request(1 ether, 2 ether, 2 ether), alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.PublicProtocolPoolRequired.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.collectManagedPositionFees(_managedRequest(managed.tokenId, 0, 0, 0, alice));
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function testSafeTransferIntoManagerIsRejected() public {
        uint256 tokenId = _mintUserPosition(alice);
        vm.prank(alice);
        vm.expectRevert();
        IERC721(address(positionManagerContract)).safeTransferFrom(alice, address(liquidityManager), tokenId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), alice);
    }

    function testUnboundForcedTransferCanBeRecoveredButBoundPositionCannot() public {
        uint256 unbound = _mintUserPosition(alice);
        vm.prank(alice);
        IERC721(address(positionManagerContract)).transferFrom(alice, address(liquidityManager), unbound);
        liquidityManager.recoverUnboundPosition(unbound, bob);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(unbound), bob);

        uint256 bound = _mintUserPosition(alice);
        vm.prank(alice);
        IERC721(address(positionManagerContract)).transferFrom(alice, address(liquidityManager), bound);
        bytes32 binding = keccak256("bound position");
        _setManagerPosmBinding(bound, binding);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.BoundPositionRecovery.selector, bound, binding));
        liquidityManager.recoverUnboundPosition(bound, bob);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(bound), address(liquidityManager));
    }

    function testPartialDecreaseAndFeeCollectionRemainAvailableAfterDecommission() public {
        IStaticsLiquidityManager.ManagedPositionMovement memory minted = _mintManaged(5 ether, 6 ether);
        uint256 attachTokenId = _mintUserPosition(alice);
        vm.prank(alice);
        IERC721(address(positionManagerContract)).approve(address(liquidityManager), attachTokenId);
        vm.prank(alice);
        v4Router.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(0.01 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        IStaticsProtocolPools.ProtocolPoolView memory registered = _registeredPool();
        registered.decommissioned = true;
        _setManagerPoolOverride(registered);

        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.ProtocolPoolDecommissioned.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.mintManagedPosition(_request(1 ether, 2 ether, 2 ether), alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.ProtocolPoolDecommissioned.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.attachManagedPosition(alice, canonicalKey.toId(), attachTokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsLiquidityManager.ProtocolPoolDecommissioned.selector, PoolId.unwrap(canonicalKey.toId())
            )
        );
        liquidityManager.increaseManagedPosition(_managedRequest(minted.tokenId, 1 ether, 2 ether, 2 ether, alice));

        uint256 alice0Before = IERC20(Currency.unwrap(canonicalKey.currency0)).balanceOf(alice);
        uint256 alice1Before = IERC20(Currency.unwrap(canonicalKey.currency1)).balanceOf(alice);
        IStaticsLiquidityManager.ManagedPositionMovement memory collected =
            liquidityManager.collectManagedPositionFees(_managedRequest(minted.tokenId, 0, 0, 0, alice));
        assertGt(collected.received0 + collected.received1, 0);
        assertEq(collected.liquidityAfter, 5 ether);

        IStaticsLiquidityManager.ManagedPositionMovement memory decreased =
            liquidityManager.decreaseManagedPosition(_managedRequest(minted.tokenId, 2 ether, 0, 0, alice));
        assertEq(decreased.liquidityAfter, 3 ether);
        assertEq(positionManagerContract.getPositionLiquidity(minted.tokenId), 3 ether);
        assertEq(
            IERC20(Currency.unwrap(canonicalKey.currency0)).balanceOf(alice) - alice0Before,
            collected.received0 + decreased.received0
        );
        assertEq(
            IERC20(Currency.unwrap(canonicalKey.currency1)).balanceOf(alice) - alice1Before,
            collected.received1 + decreased.received1
        );
        _assertNoManagerResidue();
    }

    function testBurnAndExitUseOnlyTypedPositionOperations() public {
        IStaticsLiquidityManager.ManagedPositionMovement memory first = _mintManaged(5 ether, 6 ether);
        liquidityManager.decreaseManagedPosition(_managedRequest(first.tokenId, 5 ether, 0, 0, alice));
        liquidityManager.burnManagedPosition(_managedRequest(first.tokenId, 0, 0, 0, alice));
        vm.expectRevert();
        IERC721(address(positionManagerContract)).ownerOf(first.tokenId);

        IStaticsLiquidityManager.ManagedPositionMovement memory second = _mintManaged(5 ether, 6 ether);
        IStaticsLiquidityManager.ManagedPositionMovement memory exited =
            liquidityManager.exitManagedPosition(_managedRequest(second.tokenId, 0, 0, 0, alice));
        assertEq(exited.liquidityBefore, 5 ether);
        assertEq(exited.liquidityAfter, 0);
        vm.expectRevert();
        IERC721(address(positionManagerContract)).ownerOf(second.tokenId);
        _assertNoManagerResidue();
    }

    function testManagedMethodsRemainDiamondOnly() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.inspectManagedPosition(1);
    }

    function _mintManaged(uint256 liquidity, uint256 maximum)
        private
        returns (IStaticsLiquidityManager.ManagedPositionMovement memory movement)
    {
        _transferUserInventory(maximum, maximum);
        movement = liquidityManager.mintManagedPosition(_request(liquidity, maximum, maximum), alice);
    }

    function _mintUserPosition(address owner) private returns (uint256 tokenId) {
        _transferUserInventory(6 ether, 6 ether);
        (IStaticsLiquidityManager.PositionMovement memory movement,,) =
            liquidityManager.mintUserPosition(_request(5 ether, 6 ether, 6 ether), owner, alice);
        tokenId = movement.tokenId;
    }

    function _managedRequest(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Limit,
        uint256 amount1Limit,
        address receiver
    ) private view returns (IStaticsLiquidityManager.ManagedLiquidityRequest memory request) {
        request = IStaticsLiquidityManager.ManagedLiquidityRequest({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Limit: amount0Limit,
                amount1Limit: amount1Limit,
                deadline: block.timestamp + 1 hours,
                receiver: receiver
            });
    }

    function _registeredPool() private view returns (IStaticsProtocolPools.ProtocolPoolView memory pool) {
        pool = IStaticsProtocolPools(address(diamond)).protocolPool(canonicalKey.toId());
    }

    function _assertNoManagerResidue() private view {
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        assertEq(IERC20(token0).balanceOf(address(liquidityManager)), 0);
        assertEq(IERC20(token1).balanceOf(address(liquidityManager)), 0);
        assertEq(IERC20(token0).allowance(address(liquidityManager), address(permit2Contract)), 0);
        assertEq(IERC20(token1).allowance(address(liquidityManager), address(permit2Contract)), 0);
        (uint160 permit0,,) =
            permit2Contract.allowance(address(liquidityManager), token0, address(positionManagerContract));
        (uint160 permit1,,) =
            permit2Contract.allowance(address(liquidityManager), token1, address(positionManagerContract));
        assertEq(permit0, 0);
        assertEq(permit1, 0);
    }
}
