// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract BasketLiquidityCompoundingTest is CanonicalPoolTestBase {
    IAllowanceTransfer private permit2Contract;
    IPositionManager private positionManagerContract;
    StaticsLiquidityManager private liquidityManagerContract;

    function setUp() public override {
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
    }

    function testSingleConstituentRealFlowCreatesProtocolPosition() public {
        _assertRealCompoundingFlow(1);
    }

    function testThreeConstituentRealFlowCreatesProtocolPositions() public {
        _assertRealCompoundingFlow(3);
    }

    function testSixteenConstituentRealFlowCreatesProtocolPositions() public {
        _assertRealCompoundingFlow(16);
    }

    function testEpochAndYoungPoolCapsAdvanceOnlyAfterSuccessfulMovement() public {
        address[] memory assets = _newAssets(1);
        (uint256 basketId, address basketToken) = _createBasket(assets, 20 ether);
        _initializeMintAndActivate(basketId, assets, 100 ether);

        uint256 first = basketLiquidity.compoundBasketLiquidity(basketId);
        assertEq(first, 0.45 ether);
        IStaticsBasketLiquidity.BasketLiquidityStateView memory state = basketLiquidity.basketLiquidityState(basketId);
        assertEq(state.lastCompoundAt, block.timestamp);
        assertEq(state.nextCompoundAt, block.timestamp + 24 hours);
        assertEq(state.cumulativeSharesMinted, first);

        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.LiquidityEpochNotReady.selector, basketId, state.nextCompoundAt)
        );
        basketLiquidity.compoundBasketLiquidity(basketId);

        vm.warp(block.timestamp + 24 hours);
        uint256 second = basketLiquidity.compoundBasketLiquidity(basketId);
        assertEq(second, 0.405 ether);

        vm.warp(block.timestamp + 7 days);
        uint256 uncapped = basketLiquidity.compoundBasketLiquidity(basketId);
        assertEq(uncapped, 3.645 ether);
        assertEq(IERC20(basketToken).totalSupply(), 104.5 ether);
    }

    function testBelowMinimumReserveCannotAdvanceEpochOrMoveValue() public {
        address[] memory assets = _newAssets(1);
        (uint256 basketId,) = _createBasket(assets, 0.00001 ether);
        _initializeMintAndActivate(basketId, assets, 1 ether);
        uint256 reserveBefore = basketLiquidity.liquidityReserve(basketId, assets[0]);

        vm.expectPartialRevert(BasketLiquidityFacet.CompoundAmountBelowMinimum.selector);
        basketLiquidity.compoundBasketLiquidity(basketId);

        IStaticsBasketLiquidity.BasketLiquidityStateView memory state = basketLiquidity.basketLiquidityState(basketId);
        assertEq(state.lastCompoundAt, 0);
        assertEq(state.nextCompoundAt, 0);
        assertEq(basketLiquidity.liquidityReserve(basketId, assets[0]), reserveBefore);
        assertEq(liquidityManagerContract.protocolPositionId(basketId, assets[0]), 0);
    }

    function testSharedConstituentReservesAndManagerInventoryRemainBasketIsolated() public {
        address sharedAsset = address(new MockERC20("Shared", "SHARED", 18));
        address[] memory firstAssets = new address[](1);
        address[] memory secondAssets = new address[](1);
        firstAssets[0] = sharedAsset;
        secondAssets[0] = sharedAsset;
        (uint256 firstBasket,) = _createBasket(firstAssets, 20 ether);
        (uint256 secondBasket,) = _createBasket(secondAssets, 20 ether);
        _initializeAndMint(firstBasket, firstAssets, 100 ether);
        _initializeAndMint(secondBasket, secondAssets, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(firstBasket, sharedAsset);
        basketLiquidity.activateCanonicalPool(secondBasket, sharedAsset);
        uint256 secondReserveBefore = basketLiquidity.liquidityReserve(secondBasket, sharedAsset);

        basketLiquidity.compoundBasketLiquidity(firstBasket);

        assertEq(basketLiquidity.liquidityReserve(secondBasket, sharedAsset), secondReserveBefore);
        assertEq(liquidityManagerContract.protocolInventory(secondBasket, sharedAsset), 0);
        assertEq(liquidityManagerContract.protocolPositionId(secondBasket, sharedAsset), 0);
        assertGt(liquidityManagerContract.protocolPositionId(firstBasket, sharedAsset), 0);
    }

    function testManagerInstallAndPreexistingPoolSyncAreOneTime() public {
        vm.expectRevert(BasketLiquidityFacet.LiquidityManagerAlreadyInstalled.selector);
        basketLiquidity.installLiquidityManager(address(liquidityManagerContract));

        address[] memory assets = _newAssets(1);
        (uint256 basketId,) = _createBasket(assets, 0);
        basketLiquidity.initializeCanonicalPool(basketId, assets[0], SQRT_PRICE_1_1);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.CanonicalPoolAlreadySynced.selector, basketId, assets[0])
        );
        basketLiquidity.syncCanonicalPoolToManager(basketId, assets[0]);
    }

    function _assertRealCompoundingFlow(uint256 count) private {
        address[] memory assets = _newAssets(count);
        (uint256 basketId, address basketToken) = _createBasket(assets, 20 ether);
        _initializeMintAndActivate(basketId, assets, 100 ether);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();

        uint256 shares = basketLiquidity.compoundBasketLiquidity(basketId);

        assertGt(shares, 0);
        assertEq(IERC20(basketToken).totalSupply(), supplyBefore + shares);
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = liquidityManagerContract.protocolPositionId(basketId, assets[i]);
            assertGt(tokenId, 0);
            assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(liquidityManagerContract));
            assertGt(positionManagerContract.getPositionLiquidity(tokenId), 0);
            assertLt(basketLiquidity.liquidityReserve(basketId, assets[i]), 9 ether);
            assertGt(baskets.vaultBalance(basketId, assets[i]), 100 ether);
            (uint256 spent, uint256 received) = basketLiquidity.cumulativeLiquidityFunding(basketId, assets[i]);
            assertGt(spent, 0);
            assertGt(received, 0);
            assertGe(
                IERC20(assets[i]).balanceOf(address(liquidityManagerContract)),
                liquidityManagerContract.totalProtocolInventory(assets[i])
            );
        }
        assertGe(
            IERC20(basketToken).balanceOf(address(liquidityManagerContract)),
            liquidityManagerContract.totalProtocolInventory(basketToken)
        );
    }

    function _initializeMintAndActivate(uint256 basketId, address[] memory assets, uint256 shares) private {
        _initializeAndMint(basketId, assets, shares);
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < assets.length; ++i) {
            basketLiquidity.activateCanonicalPool(basketId, assets[i]);
        }
    }

    function _initializeAndMint(uint256 basketId, address[] memory assets, uint256 shares) private {
        for (uint256 i; i < assets.length; ++i) {
            basketLiquidity.initializeCanonicalPool(basketId, assets[i], SQRT_PRICE_1_1);
        }
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        vm.startPrank(alice);
        for (uint256 i; i < assets.length; ++i) {
            MockERC20(assets[i]).mint(alice, quote[i]);
            IERC20(assets[i]).approve(address(diamond), type(uint256).max);
        }
        baskets.mint(basketId, shares, alice, quote);
        vm.stopPrank();
    }

    function _createBasket(address[] memory assets, uint256 mintFeeShares)
        private
        returns (uint256 basketId, address basketToken)
    {
        uint256[] memory bundleAmounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            bundleAmounts[i] = 1 ether;
        }
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "POL Basket",
            symbol: "sPOL",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(mintFeeShares),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        return baskets.createBasket{value: basketAdmin.creationFee()}(params);
    }

    function _newAssets(uint256 count) private returns (address[] memory assets) {
        assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(new MockERC20("Constituent", "C", 18));
        }
    }
}
