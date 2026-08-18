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

interface IDopplerFeeShares {
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256 shares);
    function poolManager() external view returns (IPoolManager);
}

/// @notice Current-network integration proof against official Doppler deployments.
contract DopplerGenesisLaunchForkTest is Test {
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

    function _deployAndAssert() private {
        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        _assertCode(modules.airlock);
        _assertCode(modules.tokenFactory);
        _assertCode(modules.governanceFactory);
        _assertCode(modules.poolInitializer);
        _assertCode(modules.noOpMigrator);

        address governance = makeAddr("forkGovernance");
        address treasury = makeAddr("forkTreasury");
        MockDopplerToken weth = new MockDopplerToken(address(this));
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
            tokenURI: "ipfs://statics/token.json",
            contractURI: "ipfs://statics-genesis/contract.json",
            externalURLBase: "https://statics.finance/genesis/"
        });

        StaticsGenesisDeployment memory deployment = deployer.deploy(config, address(deployer));
        IERC20 statics = IERC20(deployment.statics);
        StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
        StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
        StaticsFeeReceiver receiver = StaticsFeeReceiver(deployment.feeReceiver);
        GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
        GenesisLaunchDistributor distributor = GenesisLaunchDistributor(deployment.genesisDistributor);

        assertEq(statics.totalSupply(), 1_000_000_000 ether);
        assertEq(statics.balanceOf(treasury), 200_000_000 ether);
        assertLe(statics.balanceOf(deployment.genesisVault), deployer.MAX_MULTICURVE_RESIDUAL());
        assertEq(genesis.balanceOf(address(vault)), 5_555);
        assertEq(vault.requiredBacking(), 0);
        assertEq(receiver.statics(), deployment.statics);
        assertEq(receiver.poolInitializer(), modules.poolInitializer);
        assertEq(IDopplerFeeShares(modules.poolInitializer).getShares(deployment.poolId, address(receiver)), 0.95 ether);
        assertEq(receiver.activeDistributor(), address(distributor));
        assertEq(registry.activeConsumer(), address(distributor));
        assertEq(receiver.pendingOwner(), governance);

        vm.deal(treasury, 1 ether);
        vm.startPrank(treasury);
        statics.approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: vault.nativeAcquisitionFee()}(1, treasury);
        distributor.registerGenesis(1);
        vm.stopPrank();
        assertEq(genesis.ownerOf(1), treasury);
        assertEq(vault.requiredBacking(), vault.GENESIS_PRICE());

        PoolKey memory key = _poolKey(deployment.statics, address(weth), modules.poolInitializer, config.fee);
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

        (, uint256 wethFees) = distributor.accrue();
        assertGt(wethFees, 0, "standard Doppler fee collection returned no WETH");
        assertEq(receiver.cumulativeHarvested(address(weth)), wethFees);
        assertGt(distributor.pendingGenesis(1, address(weth)), 0, "registered Genesis earned no launch rewards");
        assertGt(distributor.rewardBook(address(weth)).treasuryClaimable, 0, "treasury earned no launch revenue");
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
