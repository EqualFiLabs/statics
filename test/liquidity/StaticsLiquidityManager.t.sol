// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockReentrantERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract StaticsLiquidityManagerTest is LiquidityManagerTestBase {
    function testProtocolPositionMintsIncreasesCollectsAndRemovesWithIsolatedInventory() public {
        _creditInventory(40 ether, 40 ether);
        IStaticsLiquidityManager.PositionRequest memory request = _request(10 ether, 11 ether, 11 ether);
        IStaticsLiquidityManager.PositionMovement memory minted = liquidityManager.mintProtocolPosition(request);

        assertEq(IERC721(address(positionManagerContract)).ownerOf(minted.tokenId), address(liquidityManager));
        assertEq(liquidityManager.protocolPositionId(basketId, address(assetA)), minted.tokenId);
        assertEq(positionManagerContract.getPositionLiquidity(minted.tokenId), 10 ether);
        _assertInventoryConserved(minted.spent0, minted.spent1, 40 ether, 40 ether);
        _assertApprovalsCleared();

        _creditInventory(20 ether, 20 ether);
        request = _request(5 ether, 6 ether, 6 ether);
        IStaticsLiquidityManager.PositionMovement memory increased = liquidityManager.increaseProtocolPosition(request);
        assertEq(positionManagerContract.getPositionLiquidity(minted.tokenId), 15 ether);
        assertEq(increased.tokenId, minted.tokenId);
        _assertApprovalsCleared();

        _swap(canonicalKey, true, 2 ether);
        _swap(canonicalKey, false, 2 ether);
        uint256 inventory0Before = liquidityManager.protocolInventory(basketId, Currency.unwrap(canonicalKey.currency0));
        uint256 inventory1Before = liquidityManager.protocolInventory(basketId, Currency.unwrap(canonicalKey.currency1));
        IStaticsLiquidityManager.PositionMovement memory collected =
            liquidityManager.collectProtocolPosition(basketId, address(assetA), block.timestamp + 1 hours);
        assertEq(collected.received0, 0);
        assertEq(collected.received1, 0);
        assertEq(
            liquidityManager.protocolInventory(basketId, Currency.unwrap(canonicalKey.currency0)),
            inventory0Before + collected.received0
        );
        assertEq(
            liquidityManager.protocolInventory(basketId, Currency.unwrap(canonicalKey.currency1)),
            inventory1Before + collected.received1
        );

        IStaticsLiquidityManager.PositionMovement memory removed = liquidityManager.removeProtocolLiquidity(
            basketId, address(assetA), 15 ether, 0, 0, block.timestamp + 1 hours
        );
        assertEq(positionManagerContract.getPositionLiquidity(minted.tokenId), 0);
        assertTrue(removed.received0 != 0 && removed.received1 != 0);
        _assertManagerSolvent(Currency.unwrap(canonicalKey.currency0));
        _assertManagerSolvent(Currency.unwrap(canonicalKey.currency1));
    }

    function testInventoryReturnMeasuresReceiptAndCannotDebitAnotherBasket() public {
        _creditInventory(10 ether, 10 ether);
        uint256 diamondBefore = assetA.balanceOf(address(this));
        (uint256 spent, uint256 received) = liquidityManager.returnProtocolInventory(basketId, address(assetA), 4 ether);
        assertEq(spent, 4 ether);
        assertEq(received, 4 ether);
        assertEq(assetA.balanceOf(address(this)) - diamondBefore, 4 ether);
        assertEq(liquidityManager.protocolInventory(basketId, address(assetA)), 6 ether);
        assertEq(liquidityManager.totalProtocolInventory(address(assetA)), 6 ether);
    }

    function testOnlyDiamondCanRegisterCreditOrOperate() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.creditProtocolInventory(basketId, address(assetA), 0);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.registerCanonicalPool(999, address(assetA), canonicalKey);
        vm.expectRevert(abi.encodeWithSelector(StaticsLiquidityManager.OnlyStaticsDiamond.selector, bob));
        liquidityManager.mintProtocolPosition(_request(1 ether, 2 ether, 2 ether));
        vm.stopPrank();
    }

    function testCanonicalKeyCannotBeSubstituted() public {
        _creditInventory(10 ether, 10 ether);
        IStaticsLiquidityManager.PositionRequest memory request = _request(5 ether, 6 ether, 6 ether);
        request.poolKey.fee = 3_000;
        vm.expectPartialRevert(StaticsLiquidityManager.CanonicalPoolMismatch.selector);
        liquidityManager.mintProtocolPosition(request);
        assertEq(liquidityManager.protocolPositionId(basketId, address(assetA)), 0);
    }

    function testProtocolPositionCanTransferOnlyThroughTypedMigration() public {
        _creditInventory(10 ether, 10 ether);
        IStaticsLiquidityManager.PositionMovement memory movement =
            liquidityManager.mintProtocolPosition(_request(5 ether, 6 ether, 6 ether));
        uint256 tokenId = liquidityManager.transferProtocolPosition(basketId, address(assetA), bob);
        assertEq(tokenId, movement.tokenId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), bob);
        assertEq(liquidityManager.protocolPositionId(basketId, address(assetA)), 0);
    }

    function testProtocolPositionBurnReturnsInventoryAndClearsCustody() public {
        _creditInventory(10 ether, 10 ether);
        IStaticsLiquidityManager.PositionMovement memory minted =
            liquidityManager.mintProtocolPosition(_request(5 ether, 6 ether, 6 ether));

        IStaticsLiquidityManager.PositionMovement memory burned =
            liquidityManager.burnProtocolPosition(basketId, address(assetA), 0, 0, block.timestamp + 1 hours);

        assertEq(burned.tokenId, minted.tokenId);
        assertTrue(burned.received0 != 0 && burned.received1 != 0);
        assertEq(liquidityManager.protocolPositionId(basketId, address(assetA)), 0);
        vm.expectRevert();
        IERC721(address(positionManagerContract)).ownerOf(minted.tokenId);
        _assertManagerSolvent(Currency.unwrap(canonicalKey.currency0));
        _assertManagerSolvent(Currency.unwrap(canonicalKey.currency1));
    }

    function testSenderExtraInventoryReturnCannotConsumeSiblingBasketBook() public {
        MockSenderExtraFeeERC20 taxed = new MockSenderExtraFeeERC20();
        taxed.mint(address(liquidityManager), 20 ether);
        liquidityManager.creditProtocolInventory(basketId, address(taxed), 10 ether);
        liquidityManager.creditProtocolInventory(basketId + 1, address(taxed), 10 ether);
        taxed.setTaxedSender(address(liquidityManager));

        vm.expectPartialRevert(StaticsLiquidityManager.ExcessiveTokenDebit.selector);
        liquidityManager.returnProtocolInventory(basketId, address(taxed), 10 ether);
        assertEq(liquidityManager.protocolInventory(basketId, address(taxed)), 10 ether);
        assertEq(liquidityManager.protocolInventory(basketId + 1, address(taxed)), 10 ether);
        assertEq(taxed.balanceOf(address(liquidityManager)), 20 ether);
    }

    function testInventoryReturnCannotReenterManager() public {
        MockReentrantERC20 reentrant = new MockReentrantERC20();
        reentrant.mint(address(liquidityManager), 10 ether);
        liquidityManager.creditProtocolInventory(basketId, address(reentrant), 10 ether);
        reentrant.setCallback(
            address(liquidityManager),
            address(liquidityManager),
            abi.encodeCall(liquidityManager.returnProtocolInventory, (basketId, address(reentrant), 1 ether))
        );

        liquidityManager.returnProtocolInventory(basketId, address(reentrant), 2 ether);
        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(liquidityManager.protocolInventory(basketId, address(reentrant)), 8 ether);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amount) private {
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

    function _assertInventoryConserved(uint256 spent0, uint256 spent1, uint256 initial0, uint256 initial1)
        private
        view
    {
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        assertEq(liquidityManager.protocolInventory(basketId, token0), initial0 - spent0);
        assertEq(liquidityManager.protocolInventory(basketId, token1), initial1 - spent1);
        _assertManagerSolvent(token0);
        _assertManagerSolvent(token1);
    }

    function _assertManagerSolvent(address token) private view {
        assertGe(IERC20(token).balanceOf(address(liquidityManager)), liquidityManager.totalProtocolInventory(token));
    }

    function _assertApprovalsCleared() private view {
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        assertEq(IERC20(token0).allowance(address(liquidityManager), address(permit2Contract)), 0);
        assertEq(IERC20(token1).allowance(address(liquidityManager), address(permit2Contract)), 0);
        (uint160 amount0,,) =
            permit2Contract.allowance(address(liquidityManager), token0, address(positionManagerContract));
        (uint160 amount1,,) =
            permit2Contract.allowance(address(liquidityManager), token1, address(positionManagerContract));
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }
}
