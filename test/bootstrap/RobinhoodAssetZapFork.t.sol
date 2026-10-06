// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StaticsAssetZap} from "../../src/periphery/StaticsAssetZap.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "../../src/bootstrap/BasketBootstrapFactory.sol";
import {BasketPreparationFacet} from "../../src/facets/BasketPreparationFacet.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {IStaticsBasketDelegation} from "../../src/interfaces/IStaticsBasketDelegation.sol";
import {RobinhoodStaticsLiquidityForkTest} from "../liquidity/fork/RobinhoodStaticsLiquidityFork.t.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Candidate contracts are local to a pinned fork; deployed v4/CreateX dependencies are never etched.
contract RobinhoodAssetZapForkTest is RobinhoodStaticsLiquidityForkTest {
    uint256 private constant CREATOR_KEY = 0xC0FFEE;
    BasketBootstrapFactory private campaigns;
    StaticsAssetZap private zap;
    MockERC20 private input;
    MockERC20 private project;
    IPoolManager private deployedManager;
    StaticsAssetZap.Route[] private routes;

    function setUp() public override {
        super.setUp();
        string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");
        (address manager,,) = basketLiquidity.liquidityIntegration();
        deployedManager = IPoolManager(manager);
        assertEq(manager.codehash, vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"));
        address weth = vm.parseJsonAddress(manifest, ".contracts.weth.address");
        assertEq(weth.codehash, vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash"));
        assertEq(
            _localBasketFactory.CREATE_X().codehash, 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f
        );
        campaigns = new BasketBootstrapFactory(address(diamond));
        zap = new StaticsAssetZap(address(diamond), weth, campaigns);
        input = new MockERC20("Fork input", "USDG", 18);
        project = new MockERC20("Fork project", "PRJ", 18);
        CanonicalV4Router router = new CanonicalV4Router(deployedManager);
        input.mint(address(this), 100_000 ether);
        input.approve(address(router), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? address(assetA) : address(assetB);
            MockERC20(asset).mint(address(this), 100_000 ether);
            IERC20(asset).approve(address(router), type(uint256).max);
            PoolKey memory key = PoolKey(
                Currency.wrap(address(input) < asset ? address(input) : asset),
                Currency.wrap(address(input) < asset ? asset : address(input)),
                3000,
                60,
                IHooks(address(0))
            );
            deployedManager.initialize(key, uint160(1 << 96));
            router.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, int256(10_000 ether), bytes32(0)));
            routes.push();
            routes[i].currencies.push(address(input));
            routes[i].currencies.push(asset);
            routes[i].pools.push(key);
            routes[i].maximumInput = 25 ether;
        }
        input.mint(alice, 100 ether);
        vm.prank(alice);
        input.approve(address(zap), 100 ether);
    }

    function _input() private view returns (StaticsAssetZap.Input memory) {
        return StaticsAssetZap.Input(address(input), 25 ether, alice, block.timestamp + 1 hours);
    }

    function testPinnedRobinhoodV4ZapMintsDirectlyAndIsolatesBalances() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        input.mint(address(zap), 7 ether);
        uint256 beforeBalance = input.balanceOf(alice);
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        vm.prank(alice);
        uint256 spent = zap.mintBasket(_input(), id, 1 ether, quote, routes);
        assertEq(beforeBalance - input.balanceOf(alice), spent);
        assertEq(input.balanceOf(address(zap)), 7 ether);
        assertEq(IERC20(token).balanceOf(alice), 1 ether);
        assertEq(IERC20(token).balanceOf(address(zap)), 0);
        assertEq(assetA.allowance(address(zap), address(diamond)), 0);
    }

    function _prepare(BasketBootstrapCampaign campaign, BasketBootstrapCampaign.Terms memory terms) private {
        BasketPreparationFacet preparation = BasketPreparationFacet(address(diamond));
        StaticsBasketFactory factory = StaticsBasketFactory(preparation.basketFactory());
        bytes32 configuration =
            preparation.basketCreationConfigurationHash(terms.basket, terms.pools, terms.maximums, terms.deadline);
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(address(campaign), terms.creator, configuration, terms.deadline, 1);
        bytes32[] memory salts = new bytes32[](2);
        uint256[] memory nonces = new uint256[](2);
        (nonces[0], salts[0]) = _minePreparedTestHook(factory, intent, 0);
        (nonces[1], salts[1]) = _minePreparedTestHook(factory, intent, nonces[0] + 1);
        IStaticsBasketDelegation.Authorization memory auth = IStaticsBasketDelegation.Authorization(
            terms.creator,
            address(campaign),
            factory.preparationId(intent, factory.preparedSaltFor(intent, 0), salts),
            configuration,
            513,
            terms.deadline,
            1 ether
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(CREATOR_KEY, IStaticsBasketDelegation(address(diamond)).creationAuthorizationDigest(auth));
        campaign.prepare(0, nonces, auth, abi.encodePacked(r, s, v));
    }

    function testPinnedRobinhoodV4ZapSettlesFirmCampaignPurchase() public {
        BasketBootstrapCampaign.Terms memory terms;
        terms.creator = vm.addr(CREATOR_KEY);
        terms.beneficiary = bob;
        terms.projectToken = address(project);
        terms.deadline = block.timestamp + 7 days;
        terms.basket = _defaultParams(0, 0);
        (terms.pools, terms.maximums) = _fundDefaultLaunch(terms.basket.assets, alice);
        terms.auctions = new BasketBootstrapCampaign.AuctionTerms[](2);
        for (uint256 i; i < 2; ++i) {
            terms.auctions[i] =
                BasketBootstrapCampaign.AuctionTerms(100 ether, 1e18, 2e18, block.timestamp, terms.deadline, 1 ether);
        }
        terms.adapters = new address[](0);
        BasketBootstrapCampaign campaign = BasketBootstrapCampaign(campaigns.create(terms, keccak256("fork")));
        _prepare(campaign, terms);
        project.mint(alice, 100 ether);
        vm.startPrank(alice);
        project.approve(address(campaign), 100 ether);
        campaign.fundPayment(100 ether);
        vm.stopPrank();
        campaign.activateAuction(0);
        campaign.activateAuction(1);
        StaticsAssetZap.Purchase[] memory orders = new StaticsAssetZap.Purchase[](2);
        orders[0] = StaticsAssetZap.Purchase(0, 1 ether, 1 ether);
        orders[1] = StaticsAssetZap.Purchase(1, 1 ether, 1 ether);
        uint256 beforeProject = project.balanceOf(alice);
        vm.prank(alice);
        (, uint256 paid) = zap.purchaseCampaign(_input(), address(campaign), orders, 2 ether, routes);
        assertEq(project.balanceOf(alice) - beforeProject, paid);
        assertEq(paid, 2 ether);
        (,, uint256 funded,) = campaign.inventory(0);
        assertEq(funded, 1 ether);
        assertEq(assetA.allowance(address(zap), address(campaign)), 0);
        assertEq(project.balanceOf(address(zap)), 0);
    }
}
