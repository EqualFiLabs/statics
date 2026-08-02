// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsProtocolInit} from "../../src/diamond/StaticsProtocolInit.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StaticsTestDeployer {
    function deploy(address owner, address guardian, address treasury) external returns (StaticsDiamond diamond) {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](13);
        cut[0] = _cut(address(new DiamondCutFacet()), StaticsSelectors.diamondCut());
        cut[1] = _cut(address(new DiamondLoupeFacet()), StaticsSelectors.diamondLoupe());
        cut[2] = _cut(address(new OwnershipFacet()), StaticsSelectors.ownership());
        cut[3] = _cut(address(new GovernanceFacet()), StaticsSelectors.governance());
        cut[4] = _cut(address(new PositionNFTFacet()), StaticsSelectors.position());
        cut[5] = _cut(address(new CustodyFacet()), StaticsSelectors.custody());
        cut[6] = _cut(address(new BasketFacet()), StaticsSelectors.basket());
        cut[7] = _cut(address(new BasketAdminFacet()), StaticsSelectors.basketAdmin());
        cut[8] = _cut(address(new LendingFacet()), StaticsSelectors.lending());
        cut[9] = _cut(address(new FlashLoanFacet()), StaticsSelectors.flashLoan());
        cut[10] = _cut(address(new BasketRewardsFacet()), StaticsSelectors.basketRewards());
        cut[11] = _cut(address(new BasketLiquidityFacet()), StaticsSelectors.basketLiquidity());
        cut[12] = _cut(address(new BorrowLiquidityFacet()), StaticsSelectors.borrowLiquidity());
        StaticsProtocolInit init = new StaticsProtocolInit();
        diamond = new StaticsDiamond(
            owner,
            cut,
            address(init),
            abi.encodeCall(StaticsProtocolInit.initialize, (guardian, treasury, 1 ether)),
            address(0)
        );
    }

    function _cut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }
}

abstract contract StaticsTestBase is Test {
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    StaticsDiamond internal diamond;
    IStaticsBasket internal baskets;
    IStaticsBasketAdmin internal basketAdmin;
    IStaticsBasketRewards internal basketRewards;
    IStaticsBasketLiquidity internal basketLiquidity;
    IStaticsCustody internal custody;
    IStaticsGovernance internal governance;
    IStaticsLending internal lending;
    IStaticsFlashLoan internal flashLoans;
    MockERC20 internal assetA;
    MockERC20 internal assetB;

    function setUp() public virtual {
        assetA = new MockERC20("Asset A", "A", 18);
        assetB = new MockERC20("Asset B", "B", 18);

        diamond = new StaticsTestDeployer().deploy(address(this), guardian, treasury);

        baskets = IStaticsBasket(address(diamond));
        basketAdmin = IStaticsBasketAdmin(address(diamond));
        basketRewards = IStaticsBasketRewards(address(diamond));
        basketLiquidity = IStaticsBasketLiquidity(address(diamond));
        custody = IStaticsCustody(address(diamond));
        governance = IStaticsGovernance(address(diamond));
        lending = IStaticsLending(address(diamond));
        flashLoans = IStaticsFlashLoan(address(diamond));
        vm.deal(alice, 100 ether);
    }

    function _createDefaultBasket(uint256 mintFeeShares, uint256 redemptionFeeShares)
        internal
        returns (uint256 basketId, address token)
    {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(mintFeeShares, redemptionFeeShares);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        (basketId, token) = baskets.createBasket{value: creationFeeAmount}(params);
    }

    function _defaultParams(uint256 mintFeeShares, uint256 redemptionFeeShares)
        internal
        view
        returns (IStaticsBasket.CreateBasketParams memory params)
    {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 5 ether;
        IStaticsBasket.FeeTier[] memory mintFeeTiers = _singleFeeTier(mintFeeShares);
        IStaticsBasket.FeeTier[] memory redemptionFeeTiers = _singleFeeTier(redemptionFeeShares);
        params = IStaticsBasket.CreateBasketParams({
            name: "Static A-B",
            symbol: "sAB",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: mintFeeTiers,
            redemptionFeeTiers: redemptionFeeTiers,
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
    }

    function _singleFeeTier(uint256 feeShares) internal pure returns (IStaticsBasket.FeeTier[] memory tiers) {
        tiers = new IStaticsBasket.FeeTier[](1);
        tiers[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: feeShares});
    }

    function _fundAndApprove(address user, uint256 amountA, uint256 amountB) internal {
        assetA.mint(user, amountA);
        assetB.mint(user, amountB);
        vm.startPrank(user);
        assetA.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }
}
