// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract BasketLiquidityDecommissionTest is CanonicalPoolTestBase {
    IPositionManager private positionManagerContract;
    StaticsLiquidityManager private liquidityManagerContract;
    uint256 private basketId;
    address private basketToken;
    address private constituent;

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
        (basketId, basketToken) = _createSingleAssetBasket(20 ether);
        basketLiquidity.initializeCanonicalPool(basketId, constituent, SQRT_PRICE_1_1);
        _mintBasket(basketId, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(basketId, constituent);
        basketLiquidity.compoundBasketLiquidity(basketId);
    }

    function testExitOnlyUnwindBurnsProtocolTokensAndNormalizesRevenue() public {
        uint256 positionTokenId = liquidityManagerContract.protocolPositionId(basketId, constituent);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        uint256 revenueBefore = basketAdmin.protocolRevenue(basketId, constituent);

        governance.decommissionBasket(basketId);
        vm.prank(bob);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        assertTrue(basketLiquidity.basketLiquidityUnwound(basketId, constituent));
        assertEq(liquidityManagerContract.protocolPositionId(basketId, constituent), 0);
        assertEq(liquidityManagerContract.protocolInventory(basketId, constituent), 0);
        assertEq(liquidityManagerContract.protocolInventory(basketId, basketToken), 0);
        assertEq(basketLiquidity.liquidityReserve(basketId, constituent), 0);
        assertLt(IERC20(basketToken).totalSupply(), supplyBefore);
        // v4 rounds full-range removal down by at most one unit; that unit remains
        // physically pool-custodied and retains its exact basket backing.
        assertLe(IERC20(basketToken).totalSupply() - IERC20(basketToken).balanceOf(alice), 1);
        assertEq(baskets.vaultBalance(basketId, constituent), IERC20(basketToken).totalSupply());
        assertGt(basketAdmin.protocolRevenue(basketId, constituent), revenueBefore);
        vm.expectRevert();
        IERC721(address(positionManagerContract)).ownerOf(positionTokenId);

        uint256 userShares = IERC20(basketToken).balanceOf(alice);
        uint256[] memory quote = baskets.quoteRedeem(basketId, userShares);
        vm.prank(alice);
        baskets.redeem(basketId, userShares, alice, quote);
        assertLe(IERC20(basketToken).totalSupply(), 1);
        assertEq(baskets.vaultBalance(basketId, constituent), IERC20(basketToken).totalSupply());
    }

    function testPauseAndQuarantineAllowFeeCollectionButNotExposureOrUnwind() public {
        vm.prank(guardian);
        governance.pause(LibGovernance.PAUSE_LIQUIDITY);
        basketLiquidity.collectProtocolLpFees(basketId, constituent);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.ActionPaused.selector, LibGovernance.PAUSE_LIQUIDITY)
        );
        basketLiquidity.compoundBasketLiquidity(basketId);
        vm.expectPartialRevert(BasketLiquidityFacet.BasketNotExitOnly.selector);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        governance.unpause(LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(guardian);
        governance.quarantineBasket(basketId);
        basketLiquidity.collectProtocolLpFees(basketId, constituent);
        vm.expectPartialRevert(LibBasket.BasketNotActive.selector);
        basketLiquidity.compoundBasketLiquidity(basketId);
        vm.expectPartialRevert(BasketLiquidityFacet.BasketNotExitOnly.selector);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        governance.decommissionBasket(basketId);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.BasketLiquidityAlreadyUnwound.selector, basketId, constituent)
        );
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);
    }

    function testExitOnlyReclassifiesReserveEvenWithoutCanonicalPool() public {
        (uint256 unpooledBasket,) = _createSingleAssetBasket(20 ether);
        _mintBasket(unpooledBasket, 100 ether);
        uint256 reserve = basketLiquidity.liquidityReserve(unpooledBasket, constituent);
        uint256 revenueBefore = basketAdmin.protocolRevenue(unpooledBasket, constituent);
        governance.decommissionBasket(unpooledBasket);

        basketLiquidity.unwindBasketLiquidity(unpooledBasket, constituent);

        assertTrue(basketLiquidity.basketLiquidityUnwound(unpooledBasket, constituent));
        assertEq(basketLiquidity.liquidityReserve(unpooledBasket, constituent), 0);
        assertEq(basketAdmin.protocolRevenue(unpooledBasket, constituent), revenueBefore + reserve);
    }

    function testSharedAssetSiblingBasketRemainsActiveAndAccounted() public {
        (uint256 siblingBasket, address siblingToken) = _createSingleAssetBasket(20 ether);
        basketLiquidity.initializeCanonicalPool(siblingBasket, constituent, SQRT_PRICE_1_1);
        _mintBasket(siblingBasket, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        basketLiquidity.activateCanonicalPool(siblingBasket, constituent);
        basketLiquidity.compoundBasketLiquidity(siblingBasket);
        uint256 siblingPosition = liquidityManagerContract.protocolPositionId(siblingBasket, constituent);
        uint256 siblingReserve = basketLiquidity.liquidityReserve(siblingBasket, constituent);
        uint256 siblingInventory = liquidityManagerContract.protocolInventory(siblingBasket, siblingToken);

        governance.decommissionBasket(basketId);
        basketLiquidity.unwindBasketLiquidity(basketId, constituent);

        assertEq(uint8(baskets.basketStatus(siblingBasket)), uint8(IStaticsBasket.BasketStatus.Active));
        assertEq(liquidityManagerContract.protocolPositionId(siblingBasket, constituent), siblingPosition);
        assertEq(basketLiquidity.liquidityReserve(siblingBasket, constituent), siblingReserve);
        assertEq(liquidityManagerContract.protocolInventory(siblingBasket, siblingToken), siblingInventory);
        assertGt(positionManagerContract.getPositionLiquidity(siblingPosition), 0);
    }

    function _createSingleAssetBasket(uint256 mintFeeShares)
        private
        returns (uint256 createdBasketId, address createdToken)
    {
        address[] memory assets = new address[](1);
        assets[0] = constituent;
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Exit Basket",
            symbol: "sEXIT",
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

    function _mintBasket(uint256 targetBasketId, uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(targetBasketId, shares);
        MockERC20(constituent).mint(alice, quote[0]);
        vm.startPrank(alice);
        IERC20(constituent).approve(address(diamond), type(uint256).max);
        baskets.mint(targetBasketId, shares, alice, quote);
        vm.stopPrank();
    }
}
