// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../../script/DeployStaticsGenesis.s.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsDopplerLaunchConfig} from "../../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../../mocks/MockDopplerToken.sol";
import {MockWrappedNative} from "../../mocks/MockWrappedNative.sol";

interface IDopplerFeeShares {
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256 shares);
    function poolManager() external view returns (IPoolManager);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Current-network integration proof against official Doppler deployments.
contract DopplerGenesisLaunchForkTest is Test {
    using Planner for Plan;

    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    bytes1 private constant WRAP_ETH_COMMAND = 0x0b;
    bytes1 private constant UNWRAP_WETH_COMMAND = 0x0c;
    string private constant ROBINHOOD_MANIFEST = "deployments/robinhood-chain-4663.json";

    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    receive() external payable {}

    function testRobinhoodDopplerLaunchEncodingAndWiring() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 4_663);
        _deployAndAssert();
    }

    function testBaseSepoliaDopplerLaunchEncodingAndWiring() public {
        string memory rpcUrl = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("BASE_SEPOLIA_RPC_URL is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, 84_532);
        _deployAndAssert();
    }

    function testRobinhoodDopplerLaunchRejectsRuntimeCodeDrift() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.dopplerPoolInitializer.runtimeCodeHash");
        vm.etch(modules.poolInitializer, hex"60006000fd");

        DeployStaticsGenesis deployer = new DeployStaticsGenesis();
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: makeAddr("driftGovernance"),
            treasury: makeAddr("driftTreasury"),
            numeraire: vm.parseJsonAddress(manifest, ".contracts.weth.address"),
            integrator: address(0),
            modules: modules,
            salt: keccak256("STATICS_DOPPLER_DRIFT_PROOF"),
            fee: 15_000,
            genesisRewardShareBps: 5_000,
            reserveShareBps: 5_000,
            creditOriginationFee: 0.003 ether,
            creditExtensionFee: 0.003 ether,
            recoveryCallerShareBps: 2_000,
            genesisEpochEnd: block.timestamp + 30 days,
            tokenURI: deployer.staticsTokenURI(),
            contractURI: "ipfs://statics-genesis/contract.json",
            externalURLBase: "https://statics.finance/genesis/"
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesis.InvalidRobinhoodDependencyCodeHash.selector,
                modules.poolInitializer,
                expectedCodeHash,
                modules.poolInitializer.codehash
            )
        );
        deployer.deploy(config, address(deployer));
    }

    function _deployAndAssert() private {
        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        _assertCode(modules.airlock);
        _assertCode(modules.tokenFactory);
        _assertCode(modules.governanceFactory);
        _assertCode(modules.poolInitializer);
        _assertCode(modules.noOpMigrator);

        IERC20 weth;
        StaticsGenesisDeployment memory deployment;
        GenesisLaunchDistributor distributor;
        StaticsFeeReceiver receiver;
        StaticsGenesisVault vault;
        address treasury = makeAddr("forkTreasury");

        {
            address governance = makeAddr("forkGovernance");
            if (block.chainid == 4_663) {
                string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
                weth = IERC20(vm.parseJsonAddress(manifest, ".contracts.weth.address"));
                vm.deal(address(this), 20 ether);
                IWETH(address(weth)).deposit{value: 10 ether}();
            } else {
                MockWrappedNative mockWeth = new MockWrappedNative();
                vm.deal(address(this), 20 ether);
                mockWeth.deposit{value: 10 ether}();
                weth = IERC20(address(mockWeth));
            }
            DeployStaticsGenesis deployer = new DeployStaticsGenesis();
            StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
                governance: governance,
                treasury: treasury,
                numeraire: address(weth),
                integrator: address(0),
                modules: modules,
                salt: keccak256(abi.encode("STATICS_DOPPLER_FORK", block.chainid, block.number)),
                fee: 30_000,
                genesisRewardShareBps: 5_000,
                reserveShareBps: 5_000,
                creditOriginationFee: 0.003 ether,
                creditExtensionFee: 0.003 ether,
                recoveryCallerShareBps: 2_000,
                genesisEpochEnd: block.timestamp + 7 days,
                tokenURI: "ipfs://statics/token.json",
                contractURI: "ipfs://statics-genesis/contract.json",
                externalURLBase: "https://statics.finance/genesis/"
            });

            deployment = deployer.deploy(config, address(deployer));
            IERC20 statics = IERC20(deployment.statics);
            StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
            vault = StaticsGenesisVault(deployment.genesisVault);
            receiver = StaticsFeeReceiver(payable(deployment.feeReceiver));
            GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
            distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

            assertEq(statics.totalSupply(), 1_000_000_000 ether);
            assertEq(statics.balanceOf(treasury), 200_000_000 ether);
            assertLe(statics.balanceOf(deployment.genesisVault), deployer.MAX_MULTICURVE_RESIDUAL());
            assertEq(genesis.balanceOf(address(vault)), 5_555);
            assertEq(vault.requiredBacking(), 0);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolInitializer(), modules.poolInitializer);
            assertEq(receiver.reserveVault(), address(vault));
            assertEq(receiver.reserveShareBps(), 5_000);
            assertTrue(vault.epochActive());
            assertEq(
                IDopplerFeeShares(modules.poolInitializer).getShares(deployment.poolId, address(receiver)), 0.95 ether
            );
            assertEq(receiver.activeDistributor(), address(distributor));
            assertEq(registry.activeConsumer(), address(distributor));
            assertEq(receiver.pendingOwner(), governance);

            // Genesis Epoch acquisition costs exactly 180,000 STATICS and requires zero native ETH.
            vm.startPrank(treasury);
            statics.approve(address(vault), vault.GENESIS_PRICE());
            vault.buyGenesis(1, treasury);
            distributor.registerGenesis(1);
            vm.stopPrank();
            assertEq(genesis.ownerOf(1), treasury);
            assertEq(vault.requiredBacking(), vault.GENESIS_PRICE());
            assertEq(vault.reserveETH(), 0);
        }

        {
            PoolKey memory key = _poolKey(deployment.statics, address(weth), modules.poolInitializer, 30_000);
            PoolSwapTest router = new PoolSwapTest(IDopplerFeeShares(modules.poolInitializer).poolManager());
            weth.approve(address(router), type(uint256).max);
            bool zeroForOne = address(weth) < deployment.statics;
            router.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(1 ether),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                bytes("")
            );

            if (block.chainid == 4_663) {
                _assertNativeRouterRoutes(key, deployment.statics, address(weth));
            }
        }

        _assertReserveHarvest(vault, receiver, distributor, weth);
        _assertPostEpochReserveFlows(vault, IERC20(deployment.statics), StaticsGenesis(deployment.genesis));
    }

    function _assertReserveHarvest(
        StaticsGenesisVault vault,
        StaticsFeeReceiver receiver,
        GenesisLaunchDistributor distributor,
        IERC20 weth
    ) private {
        // Harvest routes gross WETH into the reserve (50%) and the distributor remainder (50%).
        uint256 reserveBefore = vault.reserveETH();
        (, uint256 distributorWeth) = distributor.accrue();
        assertGt(distributorWeth, 0, "standard Doppler fee collection returned no distributor WETH");
        uint256 reserveWeth = receiver.cumulativeReserveWeth();
        assertGt(reserveWeth, 0, "reserve allocation received no WETH");
        uint256 grossWeth = reserveWeth + distributorWeth;
        assertEq(receiver.cumulativeReserveWeth() + receiver.cumulativeDistributorWeth(), grossWeth);
        assertEq(receiver.cumulativeHarvested(address(weth)), grossWeth);
        assertEq(vault.reserveETH() - reserveBefore, reserveWeth);
        assertEq(address(vault).balance, vault.reserveETH());
        assertGt(distributor.pendingGenesis(1, address(weth)), 0, "registered Genesis earned no launch rewards");
        assertGt(distributor.rewardBook(address(weth)).treasuryClaimable, 0, "treasury earned no launch revenue");

        // Reserve stays dormant during the epoch: redemption/acquisition ignore reserveETH.
        assertTrue(vault.epochActive());
        assertEq(vault.reserveBuyIn(), 0);
        assertEq(vault.reserveRedemptionPayout(), 0);
    }

    /// @dev Proves epoch transition, exact floor redemption payout, and ceil post-epoch buy-in.
    function _assertPostEpochReserveFlows(StaticsGenesisVault vault, IERC20 statics, StaticsGenesis genesis) private {
        address treasury = makeAddr("forkTreasury");

        // Advance past the immutable epoch end; the accumulated reserve becomes active with no keeper.
        vm.warp(vault.genesisEpochEnd());
        assertFalse(vault.epochActive());
        uint256 activeReserve = vault.reserveETH();
        assertGt(activeReserve, 0, "reserve did not accumulate during the epoch");
        assertEq(vault.reserveRedemptionPayout(), activeReserve / vault.RESERVE_DENOMINATOR());
        assertEq(
            vault.reserveBuyIn(),
            (activeReserve + vault.RESERVE_BUY_IN_DENOMINATOR() - 1) / vault.RESERVE_BUY_IN_DENOMINATOR()
        );

        // Post-epoch redemption returns 180,000 STATICS plus the exact reserve share.
        uint256 expectedPayout = vault.reserveRedemptionPayout();
        uint256 treasuryEthBefore = treasury.balance;
        vm.startPrank(treasury);
        genesis.approve(address(vault), 1);
        vault.redeemGenesis(1, treasury);
        vm.stopPrank();
        assertEq(treasury.balance - treasuryEthBefore, expectedPayout);
        assertEq(vault.reserveETH(), activeReserve - expectedPayout);

        // Post-epoch acquisition requires the current reserve buy-in and the native fee.
        uint256 required = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
        vm.deal(treasury, required);
        vm.startPrank(treasury);
        statics.approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: required}(1, treasury);
        vm.stopPrank();
        assertEq(genesis.ownerOf(1), treasury);
        assertEq(vault.reserveETH(), activeReserve - expectedPayout + required);
    }

    function _assertNativeRouterRoutes(PoolKey memory key, address statics, address weth) private {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        address router = vm.parseJsonAddress(manifest, ".contracts.universalRouter.address");
        _assertCode(router);
        uint256 staticsReceived = _nativeBuy(key, statics, weth, router);
        _nativeSell(key, statics, weth, router, staticsReceived);
    }

    function _forkQuoter() private view returns (IV4Quoter quoter) {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        _assertCode(address(quoter));
    }

    function _forkPermit2() private view returns (address permit2) {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        permit2 = vm.parseJsonAddress(manifest, ".contracts.permit2.address");
        _assertCode(permit2);
    }

    function _exactInSingleCalldata(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minimumOut)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            RouterExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minimumOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
    }

    function _nativeBuy(PoolKey memory key, address statics, address weth, address router)
        private
        returns (uint256 staticsReceived)
    {
        IV4Quoter quoter = _forkQuoter();
        uint128 buyAmount = 0.01 ether;
        bool buyZeroForOne = weth < statics;
        (uint256 quotedBuy,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: buyZeroForOne, exactAmount: buyAmount, hookData: bytes("")
            })
        );
        uint128 minimumBuy = uint128((quotedBuy * 99) / 100);
        uint256 staticsBefore = IERC20(statics).balanceOf(address(this));

        Plan memory buyPlan = Planner.init();
        buyPlan.add(Actions.SWAP_EXACT_IN_SINGLE, _exactInSingleCalldata(key, buyZeroForOne, buyAmount, minimumBuy));
        buyPlan.add(Actions.SETTLE, abi.encode(Currency.wrap(weth), buyAmount, false));
        buyPlan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(statics), minimumBuy));
        bytes[] memory buyInputs = new bytes[](2);
        buyInputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, buyAmount);
        buyInputs[1] = buyPlan.encode();
        IUniversalRouter(router).execute{value: buyAmount}(
            abi.encodePacked(WRAP_ETH_COMMAND, V4_SWAP_COMMAND), buyInputs, block.timestamp + 1
        );
        staticsReceived = IERC20(statics).balanceOf(address(this)) - staticsBefore;
        assertGe(staticsReceived, minimumBuy, "native buy missed quoted minimum");
    }

    function _nativeSell(PoolKey memory key, address statics, address weth, address router, uint256 staticsReceived)
        private
    {
        address permit2 = _forkPermit2();
        uint128 sellAmount = uint128(staticsReceived / 2);
        IERC20(statics).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(statics, router, type(uint160).max, type(uint48).max);

        uint128 minimumSell;
        {
            bool buyZeroForOne = weth < statics;
            (uint256 quotedSell,) = _forkQuoter()
                .quoteExactInputSingle(
                    IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: !buyZeroForOne, exactAmount: sellAmount, hookData: bytes("")
                })
                );
            minimumSell = uint128((quotedSell * 99) / 100);
        }
        uint256 ethBefore = address(this).balance;

        Plan memory sellPlan = Planner.init();
        sellPlan.add(
            Actions.SWAP_EXACT_IN_SINGLE, _exactInSingleCalldata(key, !(weth < statics), sellAmount, minimumSell)
        );
        sellPlan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(statics), sellAmount));
        sellPlan.add(Actions.TAKE, abi.encode(Currency.wrap(weth), ActionConstants.ADDRESS_THIS, 0));
        bytes[] memory sellInputs = new bytes[](2);
        sellInputs[0] = sellPlan.encode();
        sellInputs[1] = abi.encode(ActionConstants.MSG_SENDER, minimumSell);
        IUniversalRouter(router)
            .execute(abi.encodePacked(V4_SWAP_COMMAND, UNWRAP_WETH_COMMAND), sellInputs, block.timestamp + 1);
        assertGe(address(this).balance - ethBefore, minimumSell, "native sell missed quoted minimum");
    }

    function _poolKey(address statics, address numeraire, address initializer, uint24 fee)
        private
        pure
        returns (PoolKey memory key)
    {
        (address currency0, address currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: 100,
            hooks: IHooks(initializer)
        });
    }

    function _assertCode(address target) private view {
        assertGt(target.code.length, 0, "missing official Doppler module");
    }
}
