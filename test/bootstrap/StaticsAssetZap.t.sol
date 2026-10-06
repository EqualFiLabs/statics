// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StaticsAssetZap} from "../../src/periphery/StaticsAssetZap.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {MockERC20, MockReentrantERC20} from "../mocks/MockERC20.sol";

contract ZapRefundAttacker {
    address private target;
    bytes private nestedCall;
    bool public reentered;
    bytes public reentryResult;
    uint256 public refunds;

    function mint(StaticsAssetZap zap, uint256 id, uint256[] calldata maximums, StaticsAssetZap.Route[] calldata routes)
        external
        payable
    {
        StaticsAssetZap.Input memory input =
            StaticsAssetZap.Input(address(0), msg.value, address(this), block.timestamp + 1);
        target = address(zap);
        nestedCall = abi.encodeCall(StaticsAssetZap.mintBasket, (input, id, 1 ether, maximums, routes));
        zap.mintBasket{value: msg.value}(input, id, 1 ether, maximums, routes);
    }

    receive() external payable {
        refunds += msg.value;
        (reentered, reentryResult) = target.call(nestedCall);
    }
}

contract StaticsAssetZapTest is CampaignTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    WETH private wrapped;
    MockERC20 private inputToken;
    MockERC20 private bridge;
    StaticsAssetZap private zap;
    PoolKey private inputBridge;
    PoolKey private bridgeA;
    PoolKey private inputB;
    PoolKey private wrappedA;
    PoolKey private wrappedB;

    function setUp() public override {
        super.setUp();
        _queueFirst();
        inputToken = new MockERC20("USDG input", "USDG", 18);
        bridge = new MockERC20("Intermediate", "MID", 18);
        wrapped = new WETH();
        zap = new StaticsAssetZap(address(diamond), address(wrapped), campaignFactory);
        inputBridge = _seed(address(inputToken), address(bridge));
        bridgeA = _seed(address(bridge), address(assetA));
        inputB = _seed(address(inputToken), address(assetB));
        wrappedA = _seed(address(wrapped), address(assetA));
        wrappedB = _seed(address(wrapped), address(assetB));
        inputToken.mint(alice, 100 ether);
        vm.prank(alice);
        inputToken.approve(address(zap), 100 ether);
    }

    function _seed(address input, address output) private returns (PoolKey memory key) {
        if (input == address(wrapped)) {
            vm.deal(address(this), 2_000_000 ether);
            wrapped.deposit{value: 1_000_000 ether}();
        } else {
            MockERC20(input).mint(address(this), 1_000_000 ether);
        }
        MockERC20(output).mint(address(this), 1_000_000 ether);
        IERC20(input).approve(address(v4Router), type(uint256).max);
        IERC20(output).approve(address(v4Router), type(uint256).max);
        key = PoolKey(
            Currency.wrap(input < output ? input : output),
            Currency.wrap(input < output ? output : input),
            3000,
            60,
            IHooks(address(0))
        );
        poolManager.initialize(key, uint160(1 << 96));
        v4Router.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, int256(10000 ether), bytes32(0)));
    }

    function _routes(bool nativeInput) private view returns (StaticsAssetZap.Route[] memory routes) {
        routes = new StaticsAssetZap.Route[](2);
        address input = nativeInput ? address(wrapped) : address(inputToken);
        routes[0].currencies = new address[](nativeInput ? 2 : 3);
        routes[0].pools = new PoolKey[](nativeInput ? 1 : 2);
        routes[0].currencies[0] = input;
        if (nativeInput) {
            routes[0].currencies[1] = address(assetA);
            routes[0].pools[0] = wrappedA;
        } else {
            routes[0].currencies[1] = address(bridge);
            routes[0].currencies[2] = address(assetA);
            routes[0].pools[0] = inputBridge;
            routes[0].pools[1] = bridgeA;
        }
        routes[0].maximumInput = 25 ether;
        routes[1].currencies = new address[](2);
        routes[1].currencies[0] = input;
        routes[1].currencies[1] = address(assetB);
        routes[1].pools = new PoolKey[](1);
        routes[1].pools[0] = nativeInput ? wrappedB : inputB;
        routes[1].maximumInput = 25 ether;
    }

    function _input(bool nativeInput, uint256 maximum) private view returns (StaticsAssetZap.Input memory) {
        return
            StaticsAssetZap.Input(
                nativeInput ? address(0) : address(inputToken), maximum, alice, block.timestamp + 1 days
            );
    }

    function testActualMultihopExactOutputMintDeliversDirectlyToUserAndRefunds() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        StaticsAssetZap.Route[] memory routes = _routes(false);
        inputToken.mint(address(zap), 7 ether);
        assetA.mint(address(zap), 2 ether);
        assetB.mint(address(zap), 3 ether);
        uint256 beforeBalance = inputToken.balanceOf(alice);
        vm.prank(alice);
        uint256 spent = zap.mintBasket(_input(false, 25 ether), id, 1 ether, quote, routes);
        assertEq(beforeBalance - inputToken.balanceOf(alice), spent);
        assertGt(spent, quote[0] + quote[1]);
        assertEq(IERC20(token).balanceOf(alice), 1 ether);
        assertEq(IERC20(token).balanceOf(address(zap)), 0);
        assertEq(inputToken.balanceOf(address(zap)), 7 ether);
        assertEq(assetA.balanceOf(address(zap)), 2 ether);
        assertEq(assetB.balanceOf(address(zap)), 3 ether);
        assertEq(bridge.balanceOf(address(zap)), 0);
        assertEq(assetA.allowance(address(zap), address(diamond)), 0);
        assertEq(assetB.allowance(address(zap), address(diamond)), 0);
        assertEq(inputToken.allowance(address(zap), address(poolManager)), 0);
    }

    function testActualNativeZapWrapsAndRefundsOnlyCallerFunds() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        StaticsAssetZap.Route[] memory routes = _routes(true);
        vm.deal(alice, 30 ether);
        wrapped.transfer(address(zap), 4 ether);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        uint256 spent = zap.mintBasket{value: 25 ether}(_input(true, 25 ether), id, 1 ether, quote, routes);
        assertEq(beforeBalance - alice.balance, spent);
        assertEq(wrapped.balanceOf(address(zap)), 4 ether);
        assertEq(address(zap).balance, 0);
        assertEq(IERC20(token).balanceOf(alice), 1 ether);
    }

    function testHostileTokenCannotReenterDuringPoolSettlementOrRefund() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        MockReentrantERC20 hostile = new MockReentrantERC20();
        StaticsAssetZap.Route[] memory routes = new StaticsAssetZap.Route[](2);
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? address(assetA) : address(assetB);
            routes[i].currencies = new address[](2);
            routes[i].currencies[0] = address(hostile);
            routes[i].currencies[1] = asset;
            routes[i].pools = new PoolKey[](1);
            routes[i].pools[0] = _seed(address(hostile), asset);
            routes[i].maximumInput = 25 ether;
        }
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        StaticsAssetZap.Input memory input =
            StaticsAssetZap.Input(address(hostile), 25 ether, alice, block.timestamp + 1);
        hostile.setCallback(
            address(zap), address(zap), abi.encodeCall(StaticsAssetZap.mintBasket, (input, id, 1 ether, quote, routes))
        );
        hostile.mint(alice, 25 ether);
        vm.prank(alice);
        hostile.approve(address(zap), 25 ether);
        vm.prank(alice);
        zap.mintBasket(input, id, 1 ether, quote, routes);
        assertFalse(hostile.reentrySucceeded());
        assertEq(bytes4(hostile.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(IERC20(token).balanceOf(alice), 1 ether);
        assertEq(hostile.balanceOf(address(zap)), 0);
    }

    function testHostileNativeRefundReceiverCannotReenterCompletedMint() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        ZapRefundAttacker attacker = new ZapRefundAttacker();
        attacker.mint{value: 25 ether}(zap, id, baskets.quoteMint(id, 1 ether), _routes(true));
        assertGt(attacker.refunds(), 0);
        assertFalse(attacker.reentered());
        assertEq(bytes4(attacker.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(IERC20(token).balanceOf(address(attacker)), 1 ether);
        assertEq(address(zap).balance, 0);
    }

    function testRoundedZeroRequirementMintsThroughActualProtocol() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.bundleAmounts[0] = 1;
        (uint256 id, address token) = _launchBasket(params, alice, 1 ether);
        uint256[] memory quote = baskets.quoteMint(id, 1);
        // Move off an exact backing boundary through a real mint, never synthetic storage.
        vm.prank(alice);
        baskets.mint(id, 1, alice, quote);
        quote = baskets.quoteMint(id, 1);
        assertEq(quote[0], 0);
        assertGt(quote[1], 0);
        uint256 held = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        zap.mintBasket(_input(false, 25 ether), id, 1, quote, _routes(false));
        assertEq(IERC20(token).balanceOf(alice), held + 1);
        assertEq(assetA.balanceOf(address(zap)), 0);
    }

    function _canonicalKey(uint256 id, address asset) private view returns (PoolKey memory) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(id, asset);
        return PoolKey(
            Currency.wrap(pool.currency0),
            Currency.wrap(pool.currency1),
            pool.lpFee,
            pool.tickSpacing,
            IHooks(pool.hook)
        );
    }

    function testRestrictedConstituentAndIntermediateUseActualBilateralHookDeltas() public {
        (uint256 inner, address innerToken) = _createDefaultBasket(0, 0);
        uint256[] memory innerQuote = baskets.quoteMint(inner, 20 ether);
        _fundAndApprove(alice, innerQuote[0], innerQuote[1]);
        vm.prank(alice);
        baskets.mint(inner, 20 ether, alice, innerQuote);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[0] = innerToken;
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = factory.saltFor(7);
        factory.enqueueSalts(tokens, false);
        bytes32[] memory hooks = new bytes32[](2);
        uint88 next;
        (hooks[0], next) = _mineTestHook(factory, uint88(uint256(hookSalts[1])) + 1);
        (hooks[1],) = _mineTestHook(factory, next);
        factory.enqueueSalts(hooks, true);
        uint256[] memory maximums = new uint256[](2);
        maximums[0] = 100 ether;
        maximums[1] = 100 ether;
        assetB.mint(alice, 100 ether);
        vm.startPrank(alice);
        IERC20(innerToken).approve(address(diamond), 100 ether);
        assetB.approve(address(diamond), 100 ether);
        (uint256 outer, address outerToken) =
            baskets.createBasket{value: 1 ether}(params, _defaultPoolLaunchParams(2), maximums, type(uint256).max);
        vm.stopPrank();
        StaticsAssetZap.Route[] memory routes = new StaticsAssetZap.Route[](2);
        for (uint256 i; i < 2; ++i) {
            routes[i].currencies = new address[](i + 2);
            routes[i].pools = new PoolKey[](i + 1);
            routes[i].currencies[0] = address(assetA);
            routes[i].currencies[1] = innerToken;
            routes[i].pools[0] = _canonicalKey(inner, address(assetA));
            routes[i].maximumInput = 1 ether;
        }
        routes[1].currencies[2] = address(assetB);
        routes[1].pools[1] = _canonicalKey(inner, address(assetB));
        uint256[] memory quote = baskets.quoteMint(outer, 0.001 ether);
        assetA.mint(alice, 1 ether);
        vm.prank(alice);
        assetA.approve(address(zap), 1 ether);
        StaticsAssetZap.Input memory input = StaticsAssetZap.Input(address(assetA), 1 ether, alice, block.timestamp + 1);
        vm.prank(alice);
        uint256 spent = zap.mintBasket(input, outer, 0.001 ether, quote, routes);
        assertGt(spent, 0);
        assertEq(IERC20(outerToken).balanceOf(alice), 0.001 ether);
        assertEq(IERC20(innerToken).balanceOf(address(zap)), 0);
        assertEq(IERC20(innerToken).allowance(address(zap), address(diamond)), 0);
    }

    function testInputAsConstituentUsesZeroHopWithoutSpendingStoredBalances() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(id, 0.01 ether);
        StaticsAssetZap.Route[] memory routes = new StaticsAssetZap.Route[](2);
        routes[0].currencies = new address[](1);
        routes[0].currencies[0] = address(assetA);
        routes[0].pools = new PoolKey[](0);
        routes[0].maximumInput = 1 ether;
        routes[1].currencies = new address[](3);
        routes[1].currencies[0] = address(assetA);
        routes[1].currencies[1] = token;
        routes[1].currencies[2] = address(assetB);
        routes[1].pools = new PoolKey[](2);
        routes[1].pools[0] = _canonicalKey(id, address(assetA));
        routes[1].pools[1] = _canonicalKey(id, address(assetB));
        routes[1].maximumInput = 1 ether;
        assetA.mint(alice, 1 ether);
        assetA.mint(address(zap), 5 ether);
        vm.prank(alice);
        assetA.approve(address(zap), 1 ether);
        StaticsAssetZap.Input memory input = StaticsAssetZap.Input(address(assetA), 1 ether, alice, block.timestamp + 1);
        vm.prank(alice);
        uint256 spent = zap.mintBasket(input, id, 0.01 ether, quote, routes);
        assertGt(spent, quote[0]);
        assertEq(assetA.balanceOf(address(zap)), 5 ether);
        assertEq(IERC20(token).balanceOf(alice), 0.01 ether);
    }

    event ZapGasMeasured(uint256 deploymentGas, uint256 runtimeBytes);

    function testZapRetainsDeployableRuntimeAndMeasuresConstructorGas() public {
        bytes memory initCode = bytes.concat(
            vm.getCode("StaticsAssetZap.sol:StaticsAssetZap"),
            abi.encode(address(diamond), address(wrapped), campaignFactory)
        );
        uint256 start = gasleft();
        address deployed;
        // Assembly CREATE avoids Foundry's dynamic-test-linking deployCode rewrite.
        assembly ("memory-safe") { deployed := create(0, add(initCode, 32), mload(initCode)) }
        uint256 used = start - gasleft();
        assertTrue(deployed != address(0));
        assertLt(deployed.code.length, 24577);
        emit ZapGasMeasured(used, deployed.code.length);
    }

    function _purchases() private pure returns (StaticsAssetZap.Purchase[] memory orders) {
        orders = new StaticsAssetZap.Purchase[](2);
        orders[0] = StaticsAssetZap.Purchase(0, 1 ether, 1 ether);
        orders[1] = StaticsAssetZap.Purchase(1, 1 ether, 1 ether);
    }

    function testActualCampaignPurchasePaysProjectTokensDirectlyAndClearsApproval() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("zap purchase"));
        _fundPayment(campaign, 100 ether);
        campaign.activateAuction(0);
        campaign.activateAuction(1);
        uint256 projectBefore = project.balanceOf(alice);
        uint256 inputBefore = inputToken.balanceOf(alice);
        vm.prank(alice);
        (uint256 spent, uint256 payment) =
            zap.purchaseCampaign(_input(false, 25 ether), address(campaign), _purchases(), 2 ether, _routes(false));
        assertEq(project.balanceOf(alice) - projectBefore, payment);
        assertEq(payment, 2 ether);
        assertEq(inputBefore - inputToken.balanceOf(alice), spent);
        assertEq(project.balanceOf(address(zap)), 0);
        assertEq(assetA.balanceOf(address(zap)), 0);
        assertEq(assetB.balanceOf(address(zap)), 0);
        assertEq(assetA.allowance(address(zap), address(campaign)), 0);
        assertEq(assetB.allowance(address(zap), address(campaign)), 0);
        (,, uint256 funded,) = campaign.inventory(0);
        assertEq(funded, 1 ether);
    }

    function testNativeCampaignPurchasePaysUserAndPreservesStoredWeth() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("native purchase"));
        _fundPayment(campaign, 100 ether);
        campaign.activateAuction(0);
        campaign.activateAuction(1);
        wrapped.transfer(address(zap), 4 ether);
        vm.deal(alice, 30 ether);
        uint256 beforeNative = alice.balance;
        uint256 beforeProject = project.balanceOf(alice);
        vm.prank(alice);
        (uint256 spent, uint256 paid) = zap.purchaseCampaign{value: 25 ether}(
            _input(true, 25 ether), address(campaign), _purchases(), 2 ether, _routes(true)
        );
        assertEq(beforeNative - alice.balance, spent);
        assertEq(project.balanceOf(alice) - beforeProject, paid);
        assertEq(paid, 2 ether);
        assertEq(wrapped.balanceOf(address(zap)), 4 ether);
        assertEq(project.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }

    function testLaterConversionFailureRollsBackEarlierSwapAndDestination() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("conversion failure"));
        _fundPayment(campaign, 100 ether);
        campaign.activateAuction(0);
        campaign.activateAuction(1);
        StaticsAssetZap.Route[] memory routes = _routes(false);
        PoolKey memory empty = inputB;
        empty.fee = 500;
        poolManager.initialize(empty, uint160(1 << 96));
        routes[1].pools[0] = empty;
        (uint160 beforePrice,,,) = poolManager.getSlot0(bridgeA.toId());
        uint256 beforeInput = inputToken.balanceOf(alice);
        uint256 beforeProject = project.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(StaticsAssetZap.InvalidRoute.selector);
        zap.purchaseCampaign(_input(false, 25 ether), address(campaign), _purchases(), 2 ether, routes);
        (uint160 afterPrice,,,) = poolManager.getSlot0(bridgeA.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(inputToken.balanceOf(alice), beforeInput);
        assertEq(project.balanceOf(alice), beforeProject);
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 0);
        assertEq(assetA.allowance(address(zap), address(campaign)), 0);
        assertEq(assetA.balanceOf(address(zap)), 0);
        assertEq(inputToken.balanceOf(address(zap)), 0);
    }

    function testMintInputLimitAndChangedQuoteRevertEveryConversion() public {
        (uint256 id, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        uint256 beforeBalance = inputToken.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(StaticsAssetZap.MaximumInputExceeded.selector);
        zap.mintBasket(_input(false, 1), id, 1 ether, quote, _routes(false));
        assertEq(inputToken.balanceOf(alice), beforeBalance);
        assertEq(IERC20(token).balanceOf(alice), 0);
        quote[0]--;
        vm.prank(alice);
        vm.expectRevert(StaticsAssetZap.OutputBoundsExceeded.selector);
        zap.mintBasket(_input(false, 25 ether), id, 1 ether, quote, _routes(false));
        assertEq(inputToken.balanceOf(alice), beforeBalance);
    }

    function testCampaignPaymentBoundRollsBackProcurementAndAllSwaps() public {
        BasketBootstrapCampaign campaign = _campaign(_terms(false), keccak256("rollback"));
        _fundPayment(campaign, 100 ether);
        campaign.activateAuction(0);
        campaign.activateAuction(1);
        uint256 beforeBalance = inputToken.balanceOf(alice);
        uint256 projectBefore = project.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(StaticsAssetZap.OutputBoundsExceeded.selector);
        zap.purchaseCampaign(_input(false, 25 ether), address(campaign), _purchases(), 3 ether, _routes(false));
        assertEq(project.balanceOf(alice), projectBefore);
        assertEq(inputToken.balanceOf(alice), beforeBalance);
        (,, uint256 funded,) = campaign.inventory(0);
        assertEq(funded, 0);
        assertEq(assetA.allowance(address(zap), address(campaign)), 0);
    }

    function testDiscontinuousPathsAndForgedCallbacksReject() public {
        (uint256 id,) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(id, 1 ether);
        StaticsAssetZap.Route[] memory routes = _routes(false);
        routes[0].currencies[1] = address(assetB);
        vm.prank(alice);
        vm.expectRevert(StaticsAssetZap.InvalidRoute.selector);
        zap.mintBasket(_input(false, 25 ether), id, 1 ether, quote, routes);
        vm.expectRevert(StaticsAssetZap.InvalidCallback.selector);
        zap.unlockCallback("");
        vm.prank(address(poolManager));
        vm.expectRevert(StaticsAssetZap.InvalidCallback.selector);
        zap.unlockCallback("");
    }
}
