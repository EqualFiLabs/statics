// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

import {ConfigureStaticsLiquidity, StaticsLiquidityConfig} from "../../script/ConfigureStaticsLiquidity.s.sol";
import {GenesisBasketLaunchConfig, LaunchGenesisBasket} from "../../script/LaunchGenesisBasket.s.sol";
import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract LaunchGenesisBasketBatchTest is Test {
    function testBatchApprovesEveryAssetBeforeTypedBasketCreation() public {
        LaunchGenesisBasket ceremony = new LaunchGenesisBasket();
        address diamond = makeAddr("diamond");
        GenesisBasketLaunchConfig memory config = _config(makeAddr("assetA"), makeAddr("assetB"));

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, config);

        assertEq(targets.length, 3);
        assertEq(values.length, 3);
        assertEq(payloads.length, 3);
        assertEq(targets[0], config.basket.assets[0]);
        assertEq(targets[1], config.basket.assets[1]);
        assertEq(targets[2], diamond);
        assertEq(values[0], 0);
        assertEq(values[1], 0);
        assertEq(values[2], 0);
        assertEq(_selector(payloads[0]), IERC20.approve.selector);
        assertEq(_selector(payloads[1]), IERC20.approve.selector);
        assertEq(_selector(payloads[2]), IStaticsBasket.createBasket.selector);
        assertEq(_addressArgument(payloads[0], 0), diamond);
        assertEq(_addressArgument(payloads[1], 0), diamond);
        assertEq(_uintArgument(payloads[0], 1), config.maxAmountsIn[0]);
        assertEq(_uintArgument(payloads[1], 1), config.maxAmountsIn[1]);
    }

    function testExampleManifestLoadsCompleteLaunchConfiguration() public {
        LaunchGenesisBasket ceremony = new LaunchGenesisBasket();
        GenesisBasketLaunchConfig memory config = ceremony.loadConfig("script/config/genesis-basket.example.json");

        assertEq(config.basket.name, "Statics Genesis Basket");
        assertEq(config.basket.symbol, "sGEN");
        assertEq(config.basket.assets.length, 2);
        assertEq(config.basket.bundleAmounts.length, 2);
        assertEq(config.basket.mintFeeTiers.length, 1);
        assertEq(config.basket.redemptionFeeTiers.length, 1);
        assertEq(config.pools.length, 2);
        assertEq(config.maxAmountsIn.length, 2);
        assertEq(config.expectedBasketId, 0);
        assertEq(config.launchDeadline, 2_000_000_000);
    }

    function _config(address assetA, address assetB) private pure returns (GenesisBasketLaunchConfig memory config) {
        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 1 ether;
        bundleAmounts[1] = 2 ether;
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](2);
        pools[0] = IStaticsBasket.PoolLaunchParams({sqrtPriceAssetPerBasketX96: 1 << 96, pairedAssetAmount: 1 ether});
        pools[1] = IStaticsBasket.PoolLaunchParams({sqrtPriceAssetPerBasketX96: 1 << 96, pairedAssetAmount: 2 ether});
        uint256[] memory maximums = new uint256[](2);
        maximums[0] = 10 ether;
        maximums[1] = 20 ether;
        config = GenesisBasketLaunchConfig({
            basket: IStaticsBasket.CreateBasketParams({
                name: "Genesis Basket",
                symbol: "sGEN",
                assets: assets,
                bundleAmounts: bundleAmounts,
                mintFeeTiers: new IStaticsBasket.FeeTier[](0),
                redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
                flashFeeBps: 0,
                originationFeeBps: 0,
                extensionFeeBps: 0,
                ltvBps: 9_000,
                recoveryPenaltyBps: 500,
                loanDuration: 30 days
            }),
            pools: pools,
            maxAmountsIn: maximums,
            expectedBasketId: 0,
            launchDeadline: 2_000_000_000
        });
    }

    function _selector(bytes memory payload) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(payload, 0x20))
        }
    }

    function _addressArgument(bytes memory payload, uint256 index) private pure returns (address value) {
        assembly ("memory-safe") {
            value := mload(add(add(payload, 0x24), mul(index, 0x20)))
        }
    }

    function _uintArgument(bytes memory payload, uint256 index) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(payload, 0x24), mul(index, 0x20)))
        }
    }
}

contract LaunchGenesisBasketIntegrationTest is Test {
    LaunchGenesisBasket private ceremony;
    StaticsTimelock private timelock;
    StaticsDollarStackDeployment private deployment;

    function setUp() public {
        ceremony = new LaunchGenesisBasket();
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: address(ceremony),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            partnerRecipient: address(0),
            creationFeeAmount: 0,
            positionCreationFeeAmount: 0
        });
        DeployStatics.V4Config memory v4 = _v4Config();
        (deployment, timelock) = deployer.deployWithLiquidity(config, v4);
        _installLiquidity(v4);
    }

    function testTimelockFundsAndLaunchesAllGenesisPoolsInOneBatch() public {
        MockERC20 assetA = new MockERC20("Genesis A", "GENA", 18);
        MockERC20 assetB = new MockERC20("Genesis B", "GENB", 18);
        assetA.mint(address(timelock), 10 ether);
        assetB.mint(address(timelock), 10 ether);
        GenesisBasketLaunchConfig memory config = _launchConfig(address(assetA), address(assetB));
        bytes32 salt = keccak256("launch Statics genesis basket");

        uint256 earliestExecution = block.timestamp + timelock.getMinDelay();
        GenesisBasketLaunchConfig memory expiringConfig = config;
        expiringConfig.launchDeadline = earliestExecution - 1;
        vm.expectPartialRevert(LaunchGenesisBasket.LaunchDeadlineTooSoon.selector);
        ceremony.schedule(deployment.diamond, expiringConfig, keccak256("expired genesis launch"));
        config.launchDeadline = block.timestamp + 1 days;

        bytes32 operationId = ceremony.schedule(deployment.diamond, config, salt);

        assertTrue(timelock.isOperationPending(operationId));
        assertEq(IStaticsBasket(deployment.diamond).basketCount(), 0);
        assertEq(assetA.allowance(address(timelock), deployment.diamond), 0);
        assertEq(assetB.allowance(address(timelock), deployment.diamond), 0);

        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(deployment.diamond, config, salt);

        IStaticsBasket baskets = IStaticsBasket(deployment.diamond);
        IStaticsBasket.BasketView memory launched = baskets.basket(0);
        assertEq(baskets.basketCount(), 1);
        assertEq(launched.creator, address(timelock));
        assertGt(IERC20(launched.token).totalSupply(), 0);
        assertGt(baskets.vaultBalance(0, address(assetA)), 0);
        assertGt(baskets.vaultBalance(0, address(assetB)), 0);
        _assertLaunchedPool(launched.token, address(assetA));
        _assertLaunchedPool(launched.token, address(assetB));
    }

    function _installLiquidity(DeployStatics.V4Config memory v4) private {
        ConfigureStaticsLiquidity installer = new ConfigureStaticsLiquidity();
        StaticsLiquidityConfig memory liquidity = StaticsLiquidityConfig({
            poolManager: v4.poolManager,
            positionManager: v4.positionManager,
            permit2: v4.permit2,
            hook: deployment.swapFeeHook,
            manager: deployment.liquidityManager,
            inputFeeBps: v4.inputFeeBps,
            outputFeeBps: v4.outputFeeBps,
            poolManagerCodeHash: v4.poolManagerCodeHash,
            positionManagerCodeHash: v4.positionManagerCodeHash,
            permit2CodeHash: v4.permit2CodeHash
        });
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            installer.buildBatch(deployment.diamond, liquidity);
        bytes32 salt = keccak256("install liquidity before genesis");
        uint256 delay = timelock.getMinDelay();
        vm.prank(address(ceremony));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _launchConfig(address assetA, address assetB)
        private
        view
        returns (GenesisBasketLaunchConfig memory config)
    {
        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 1 ether;
        bundleAmounts[1] = 1 ether;
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](2);
        pools[0] = IStaticsBasket.PoolLaunchParams({sqrtPriceAssetPerBasketX96: 1 << 96, pairedAssetAmount: 1 ether});
        pools[1] = IStaticsBasket.PoolLaunchParams({sqrtPriceAssetPerBasketX96: 1 << 96, pairedAssetAmount: 1 ether});
        uint256[] memory maximums = new uint256[](2);
        maximums[0] = 10 ether;
        maximums[1] = 10 ether;
        config = GenesisBasketLaunchConfig({
            basket: IStaticsBasket.CreateBasketParams({
                name: "Statics Genesis Basket",
                symbol: "sGEN",
                assets: assets,
                bundleAmounts: bundleAmounts,
                mintFeeTiers: new IStaticsBasket.FeeTier[](0),
                redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
                flashFeeBps: 5,
                originationFeeBps: 25,
                extensionFeeBps: 10,
                ltvBps: 9_000,
                recoveryPenaltyBps: 500,
                loanDuration: 30 days
            }),
            pools: pools,
            maxAmountsIn: maximums,
            expectedBasketId: 0,
            launchDeadline: block.timestamp + 1 days
        });
    }

    function _assertLaunchedPool(address basketToken, address asset) private view {
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(deployment.diamond);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(0, asset);
        (, address hook,) = liquidity.liquidityIntegration();
        assertEq(pool.basketToken, basketToken);
        assertEq(pool.asset, asset);
        assertEq(pool.hook, hook);
        assertGt(IStaticsSwapFeeHook(hook).lockedLiquidity(pool.poolId), 0);
        IStaticsProtocolPools.ProtocolPoolView memory protocolPool =
            IStaticsProtocolPools(deployment.diamond).protocolPool(pool.poolId);
        assertEq(uint256(protocolPool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
        assertEq(protocolPool.basketId, 0);
        assertEq(protocolPool.basketAsset, asset);
        assertFalse(protocolPool.decommissioned);
    }

    function _v4Config() private returns (DeployStatics.V4Config memory config) {
        IPoolManager poolManager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        IAllowanceTransfer permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        IPositionManager positionManager = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        config = DeployStatics.V4Config({
            poolManager: address(poolManager),
            positionManager: address(positionManager),
            permit2: address(permit2Contract),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2Contract).codehash
        });
    }
}
