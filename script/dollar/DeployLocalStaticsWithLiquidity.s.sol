// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {DeployStaticsDollar, StaticsDollarLocalConfig, StaticsDollarStackDeployment} from "./DeployStaticsDollar.s.sol";

/// @notice Complete local-only Statics deployment for browser and integration rehearsals.
contract DeployLocalStaticsWithLiquidity is DeployStaticsDollar {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    address private constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error HookAddressMismatch(address expected, address actual);
    error DependencyDeploymentFailed(bytes32 dependency);

    function runLocalWithLiquidity() external returns (StaticsDollarStackDeployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        StaticsDollarLocalConfig memory config;
        config.owner = deployer;
        config.profileGuardian = deployer;
        config.treasury = deployer;
        config.creationFeeAmount = 1 ether;
        config.poolCreationFeeAmount = 0.05 ether;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.mockOracleMaxStaleness = 30 days;
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://local-statics-dollar-risk";

        vm.startBroadcast(privateKey);
        deployment = _deployLocal(config, deployer);
        deployment = deployLocalPeggedProfile(deployment, deployer);

        address poolManager = _deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(deployer), "POOL_MANAGER");
        address permit2 = _deployCode("out/Permit2.sol/Permit2.json", bytes(""), "PERMIT2");
        address positionManager = _deployCode(
            "out/PositionManager.sol/PositionManager.json",
            abi.encode(poolManager, permit2, uint256(100_000), address(0), address(0)),
            "POSITION_MANAGER"
        );
        address stateView = _deployCode("out/StateView.sol/StateView.json", abi.encode(poolManager), "STATE_VIEW");

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), deployment.diamond, uint16(25), uint16(25));
        (address expectedHook, bytes32 salt) = HookMiner.find(
            FOUNDRY_CREATE2_DEPLOYER, REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs
        );
        StaticsSwapFeeHook hook =
            new StaticsSwapFeeHook{salt: salt}(IPoolManager(poolManager), deployment.diamond, 25, 25);
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));
        StaticsLiquidityManager liquidityManager =
            new StaticsLiquidityManager(deployment.diamond, positionManager, poolManager, permit2);

        IStaticsBasketLiquidity(deployment.diamond).installCanonicalPoolIntegration(poolManager, address(hook));
        IStaticsBasketLiquidity(deployment.diamond).installLiquidityManager(address(liquidityManager));
        vm.stopBroadcast();

        deployment.poolManager = poolManager;
        deployment.positionManager = positionManager;
        deployment.permit2 = permit2;
        deployment.swapFeeHook = address(hook);
        deployment.liquidityManager = address(liquidityManager);
        deployment.stateView = stateView;
        _logLocalDeployment(deployment);
    }

    function _deployCode(string memory artifact, bytes memory constructorArgs, bytes32 dependency)
        private
        returns (address deployed)
    {
        bytes memory creationCode = abi.encodePacked(vm.getCode(artifact), constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (deployed == address(0)) revert DependencyDeploymentFailed(dependency);
    }
}
