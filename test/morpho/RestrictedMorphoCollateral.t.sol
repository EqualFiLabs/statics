// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorphoBlue, MorphoMarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {MorphoSettlementFacet} from "../../src/facets/MorphoSettlementFacet.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface UpstreamMorphoSetup is IMorphoBlue {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function createMarket(MorphoMarketParams calldata params) external;
    function supply(
        MorphoMarketParams calldata params,
        uint256 assets,
        uint256 shares,
        address receiver,
        bytes calldata data
    ) external returns (uint256, uint256);
}

contract RestrictedCollateralOracle {
    uint256 public price = 1e36;

    function setPrice(uint256 next) external {
        price = next;
    }
}

/// @dev Executes pinned upstream Morpho 0.8.19 bytecode locally, not MockMorphoBlue.
contract RestrictedMorphoCollateralTest is PreparedBasketTestBase {
    UpstreamMorphoSetup private realMorpho;
    MockERC20 private usd;
    RestrictedCollateralOracle private oracle;
    IStaticsMorpho private morphoApi;
    MorphoMarketParams private market;
    bytes32 private marketId;
    uint256 private collateralBasket;
    uint256 private collateralPosition;
    address private collateralToken;

    function setUp() public override {
        super.setUp();
        _queueFirst();
        (collateralBasket, collateralToken) = _createDefaultBasket(0, 0);
        realMorpho = UpstreamMorphoSetup(
            deployCode("out/UpstreamMorphoCompilation.sol/UpstreamMorphoCompilation.json", abi.encode(address(this)))
        );
        usd = new MockERC20("USD", "USD", 18);
        oracle = new RestrictedCollateralOracle();
        morphoApi = IStaticsMorpho(address(diamond));
        morphoApi.initializeMorphoIntegration(address(realMorpho), address(usd), 0);
        realMorpho.enableIrm(address(0));
        realMorpho.enableLltv(0.77 ether);
        market = MorphoMarketParams(address(usd), collateralToken, address(oracle), address(0), 0.77 ether);
        realMorpho.createMarket(market);
        marketId = morphoApi.registerMorphoMarket(
            market, IStaticsMorpho.CollateralKind.Basket, collateralBasket, IStaticsMorpho.MarketMode.Active
        );
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 100 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (collateralPosition,) =
            basketCollateral.createAndMintBasketCollateral(collateralBasket, 100 ether, alice, quote);
        vm.prank(alice);
        morphoApi.deployMorphoCollateral(collateralPosition, marketId, 80 ether);
        usd.mint(address(this), 1000 ether);
        usd.approve(address(realMorpho), 1000 ether);
        realMorpho.supply(market, 1000 ether, 0, address(this), "");
        vm.prank(alice);
        morphoApi.borrowMorphoUsd(collateralPosition, marketId, 50 ether, type(uint256).max, alice);
        assertEq(StaticsRestrictedBasketToken(collateralToken).morpho(), address(realMorpho));
    }

    function testTrackedIngressAndRecallWithActualMorpho() public {
        vm.prank(alice);
        morphoApi.recallMorphoCollateral(collateralPosition, marketId, 5 ether);
        assertEq(morphoApi.morphoPositionMarket(collateralPosition, marketId).trackedCollateral, 75 ether);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(collateralPosition, collateralBasket, 10 ether, alice);
        assertEq(IERC20(collateralToken).balanceOf(alice), 10 ether);
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        vm.startPrank(alice);
        IERC20(collateralToken).approve(address(realMorpho), 1 ether);
        vm.expectRevert();
        realMorpho.supplyCollateral(market, 1 ether, account, "");
        vm.expectRevert();
        IERC20(collateralToken).transfer(account, 1);
        vm.stopPrank();
    }

    function testDirectLiquidationHasNoDiamondDependencyAndLiquidatorCanRedeem() public {
        oracle.setPrice(0.5e36);
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        usd.mint(bob, 100 ether);
        vm.prank(bob);
        usd.approve(address(realMorpho), 100 ether);
        bytes memory code = address(diamond).code;
        vm.etch(address(diamond), hex"00");
        vm.prank(bob);
        (uint256 seized,) = realMorpho.liquidate(market, account, 20 ether, 0, "");
        assertEq(seized, 20 ether);
        assertEq(IERC20(collateralToken).balanceOf(bob), seized);
        vm.etch(address(diamond), code);
        vm.prank(bob);
        baskets.redeem(collateralBasket, seized, bob, new uint256[](2));
        assertEq(IERC20(collateralToken).balanceOf(bob), 0);
        assertGt(assetA.balanceOf(bob), 0);
    }

    function testAccountRecoveryUsesAnExactDiamondMovementNotAnAccountBypass() public {
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 1 ether, account, quote);
        vm.prank(account);
        vm.expectRevert();
        IERC20(collateralToken).transfer(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 1 ether);
        vm.prank(alice);
        assertEq(
            morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 1 ether), 1 ether
        );
        assertEq(IERC20(collateralToken).balanceOf(account), 0);
        assertEq(IERC20(collateralToken).balanceOf(bob), 1 ether);
    }

    function testAccountRecoveryMinimumIsIndependentOfExactDebitLimit() public {
        (address account,) = morphoApi.morphoAccount(collateralPosition);
        uint256[] memory quote = baskets.quoteMint(collateralBasket, 3 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(collateralBasket, 3 ether, account, quote);
        uint256 diamondBefore = IERC20(collateralToken).balanceOf(address(diamond));

        vm.prank(alice);
        assertEq(morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0), 1 ether);
        vm.prank(alice);
        assertEq(
            morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0.5 ether), 1 ether
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSettlementFacet.MinimumRecoveryNotMet.selector, collateralToken, 2 ether, 1 ether
            )
        );
        vm.prank(alice);
        morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 2 ether);
        assertEq(IERC20(collateralToken).balanceOf(account), 1 ether);
        assertEq(IERC20(collateralToken).balanceOf(bob), 2 ether);
        assertEq(IERC20(collateralToken).balanceOf(address(diamond)), diamondBefore);
        vm.prank(alice);
        assertEq(morphoApi.recoverMorphoAccountToken(collateralPosition, collateralToken, 1 ether, bob, 0), 1 ether);
        assertEq(IERC20(collateralToken).balanceOf(account), 0);
    }
}
