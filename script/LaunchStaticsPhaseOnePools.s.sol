// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";

/// @notice Creates the four approved pools while creation is owner-only, then enables the public fee.
contract LaunchStaticsPhaseOnePools is Script {
    using StateLibrary for IPoolManager;

    uint256 private constant MAINNET_CHAIN_ID = 4663;
    uint256 public constant PUBLIC_CREATION_FEE = 0.01 ether;
    address public constant MAINNET_STATICS = 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    address public constant MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant MAINNET_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address public constant MAINNET_SAFE = 0x603A8A2f22ac1d61E9c932A4F6Fa23170CEcb9Ff;
    bytes32 public constant MAINNET_USDG_CODE_HASH = 0x864cc9ad53b338b82da1f7cab85ab0b3d5c8861acb422b6fec63cf36234f36a6;
    bytes32 public constant MAINNET_NVDA_CODE_HASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;

    struct LaunchSpec {
        address tokenA;
        address tokenB;
        uint24 lpFee;
        uint16 hookFeePips;
        int24 tickSpacing;
        uint160 sqrtPriceBPerAX96;
    }

    struct LaunchConfig {
        address diamond;
        address safe;
        address statics;
        address usdg;
        address nvda;
        address bootstrapOwner;
    }

    error InvalidLaunchAsset(address actual, address expected);
    error InvalidLaunchAssetCode(address token, bytes32 actual, bytes32 expected);
    error InvalidLaunchAssetMetadata(address token);
    error InvalidLaunchSafe(address safe);
    error InvalidLaunchOwner(address actual, address expected);
    error InvalidCreationFee(uint256 actual, uint256 expected);
    error InvalidLaunchPool(PoolId poolId);
    error InvalidLaunchRate(PoolId poolId);
    error InvalidLaunchPrice(PoolId poolId, uint160 actual, uint160 expected);
    error InvalidLaunchInput(uint256 index);

    /// @dev Price is tokenB per tokenA in raw token units. All four prices and tick
    /// spacings are mandatory inputs; production opening prices are never guessed.
    function run() external returns (bytes32[4] memory poolIds) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address safe = vm.envAddress("MULTISIG");
        address statics = vm.envAddress("STAKING_TOKEN");
        address usdg = vm.envAddress("STATICS_LAUNCH_USDG_ADDRESS");
        address nvda = vm.envAddress("STATICS_LAUNCH_NVDA_ADDRESS");
        if (block.chainid == MAINNET_CHAIN_ID) {
            if (statics != MAINNET_STATICS) revert InvalidLaunchAsset(statics, MAINNET_STATICS);
            if (usdg != MAINNET_USDG) revert InvalidLaunchAsset(usdg, MAINNET_USDG);
            if (nvda != MAINNET_NVDA) revert InvalidLaunchAsset(nvda, MAINNET_NVDA);
            if (safe != MAINNET_SAFE) revert InvalidLaunchAsset(safe, MAINNET_SAFE);
            if (safe.code.length == 0) revert InvalidLaunchSafe(safe);
            if (usdg.codehash != MAINNET_USDG_CODE_HASH) {
                revert InvalidLaunchAssetCode(usdg, usdg.codehash, MAINNET_USDG_CODE_HASH);
            }
            if (nvda.codehash != MAINNET_NVDA_CODE_HASH) {
                revert InvalidLaunchAssetCode(nvda, nvda.codehash, MAINNET_NVDA_CODE_HASH);
            }
            if (
                IERC20Metadata(usdg).decimals() != 6
                    || keccak256(bytes(IERC20Metadata(usdg).symbol())) != keccak256("USDG")
            ) revert InvalidLaunchAssetMetadata(usdg);
            if (
                IERC20Metadata(nvda).decimals() != 18
                    || keccak256(bytes(IERC20Metadata(nvda).symbol())) != keccak256("NVDA")
            ) revert InvalidLaunchAssetMetadata(nvda);
        }

        int24[4] memory tickSpacings;
        uint160[4] memory prices;
        tickSpacings[0] = _tickSpacing("STATICS_LAUNCH_ETH_USDG_TICK_SPACING", 0);
        tickSpacings[1] = _tickSpacing("STATICS_LAUNCH_STATICS_USDG_TICK_SPACING", 1);
        tickSpacings[2] = _tickSpacing("STATICS_LAUNCH_STATICS_NVDA_TICK_SPACING", 2);
        tickSpacings[3] = _tickSpacing("STATICS_LAUNCH_NVDA_USDG_TICK_SPACING", 3);
        prices[0] = _price("STATICS_LAUNCH_ETH_USDG_SQRT_PRICE_X96", 0);
        prices[1] = _price("STATICS_LAUNCH_STATICS_USDG_SQRT_PRICE_X96", 1);
        prices[2] = _price("STATICS_LAUNCH_STATICS_NVDA_SQRT_PRICE_X96", 2);
        prices[3] = _price("STATICS_LAUNCH_NVDA_USDG_SQRT_PRICE_X96", 3);

        vm.startBroadcast(privateKey);
        poolIds = launch(LaunchConfig(diamond, safe, statics, usdg, nvda, vm.addr(privateKey)), tickSpacings, prices);
        vm.stopBroadcast();
        for (uint256 i; i < poolIds.length; ++i) {
            console2.log("STATICS_LAUNCH_POOL_INDEX", i);
            console2.log("STATICS_LAUNCH_POOL_ID");
            console2.logBytes32(poolIds[i]);
        }
        string memory allIds = vm.toString(poolIds[0]);
        for (uint256 i = 1; i < poolIds.length; ++i) {
            allIds = string.concat(allIds, ",", vm.toString(poolIds[i]));
        }
        console2.log("STATICS_LAUNCH_PUBLIC_POOL_IDS", allIds);
    }

    /// @notice Resume-safe after a partial broadcast; existing pools must match every approved field.
    function launch(LaunchConfig memory config, int24[4] memory tickSpacings, uint160[4] memory prices)
        public
        returns (bytes32[4] memory poolIds)
    {
        IStaticsProtocolPools pools = IStaticsProtocolPools(config.diamond);
        address owner = IERC173(config.diamond).owner();
        uint256 fee = pools.poolCreationFee();
        if (owner != config.bootstrapOwner && owner != config.safe) {
            revert InvalidLaunchOwner(owner, config.bootstrapOwner);
        }
        if (fee != 0 && fee != PUBLIC_CREATION_FEE) revert InvalidCreationFee(fee, 0);
        if (
            config.safe == address(0) || config.statics == address(0) || config.usdg == address(0)
                || config.nvda == address(0)
        ) {
            revert InvalidLaunchInput(type(uint256).max);
        }
        if (config.statics.code.length == 0 || config.usdg.code.length == 0 || config.nvda.code.length == 0) {
            revert InvalidLaunchInput(type(uint256).max);
        }
        (address poolManager, address hook, bool installed) =
            IStaticsBasketLiquidity(config.diamond).liquidityIntegration();
        if (!installed || poolManager.code.length == 0 || hook.code.length == 0) {
            revert InvalidLaunchInput(type(uint256).max);
        }

        for (uint256 i; i < 4; ++i) {
            LaunchSpec memory spec = launchSpec(i, config.statics, config.usdg, config.nvda, tickSpacings[i], prices[i]);
            poolIds[i] = PoolId.unwrap(_createOrVerify(config, spec, i, IPoolManager(poolManager)));
        }

        if (owner == config.bootstrapOwner) {
            if (fee == 0) pools.setPoolCreationFee(PUBLIC_CREATION_FEE);
            if (pools.poolCreationFee() != PUBLIC_CREATION_FEE) {
                revert InvalidCreationFee(pools.poolCreationFee(), PUBLIC_CREATION_FEE);
            }
            IERC173(config.diamond).transferOwnership(config.safe);
        }
        if (IERC173(config.diamond).owner() != config.safe) {
            revert InvalidLaunchOwner(IERC173(config.diamond).owner(), config.safe);
        }
        if (pools.poolCreationFee() != PUBLIC_CREATION_FEE) {
            revert InvalidCreationFee(pools.poolCreationFee(), PUBLIC_CREATION_FEE);
        }
    }

    function _createOrVerify(LaunchConfig memory config, LaunchSpec memory spec, uint256 index, IPoolManager manager)
        private
        returns (PoolId poolId)
    {
        IStaticsProtocolPools pools = IStaticsProtocolPools(config.diamond);
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: spec.tokenA,
            tokenB: spec.tokenB,
            lpFee: spec.lpFee,
            tickSpacing: spec.tickSpacing,
            sqrtPriceBPerAX96: spec.sqrtPriceBPerAX96,
            initialFeeRate: IStaticsProtocolPools.PoolSwapFeeRate({
                inputFeePips: spec.hookFeePips, outputFeePips: spec.hookFeePips
            }),
            creator: config.safe,
            activateManagedPol: false,
            nonce: index + 1,
            deadline: block.timestamp + 1 days
        });
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        poolId = quote.poolId;
        if (!pools.isProtocolPool(poolId)) {
            if (IERC173(config.diamond).owner() != config.bootstrapOwner) revert InvalidLaunchPool(poolId);
            if (pools.poolCreationFee() != 0) revert InvalidCreationFee(pools.poolCreationFee(), 0);
            PoolId createdPoolId = pools.createPool(params, "");
            if (PoolId.unwrap(createdPoolId) != PoolId.unwrap(poolId)) revert InvalidLaunchPool(createdPoolId);
        }
        // Pin even the pools whose initial rate equals today's default. Their
        // launch rate must not drift when the global default changes later.
        if (!pools.protocolPoolFeeRate(poolId).overridden) {
            if (IERC173(config.diamond).owner() != config.bootstrapOwner) revert InvalidLaunchRate(poolId);
            pools.setProtocolPoolFeeRate(poolId, params.initialFeeRate);
        }
        _verifyPool(pools, manager, quote, spec, config.safe);
    }

    function launchSpec(
        uint256 index,
        address statics,
        address usdg,
        address nvda,
        int24 tickSpacing,
        uint160 sqrtPriceBPerAX96
    ) public pure returns (LaunchSpec memory spec) {
        if (index > 3 || tickSpacing <= 0 || sqrtPriceBPerAX96 == 0) {
            revert InvalidLaunchInput(index);
        }
        spec.tickSpacing = tickSpacing;
        spec.sqrtPriceBPerAX96 = sqrtPriceBPerAX96;
        if (index == 0) spec = LaunchSpec(address(0), usdg, 50, 25, tickSpacing, sqrtPriceBPerAX96);
        if (index == 1) spec = LaunchSpec(statics, usdg, 200, 50, tickSpacing, sqrtPriceBPerAX96);
        if (index == 2) spec = LaunchSpec(statics, nvda, 10_000, 2_500, tickSpacing, sqrtPriceBPerAX96);
        if (index == 3) spec = LaunchSpec(nvda, usdg, 50, 25, tickSpacing, sqrtPriceBPerAX96);
    }

    function _verifyPool(
        IStaticsProtocolPools pools,
        IPoolManager manager,
        IStaticsProtocolPools.GeneralPoolQuote memory quote,
        LaunchSpec memory spec,
        address safe
    ) private view {
        IStaticsProtocolPools.ProtocolPoolView memory pool = pools.protocolPool(quote.poolId);
        if (
            pool.kind != IStaticsProtocolPools.ProtocolPoolKind.General || pool.decommissioned || pool.creator != safe
                || pool.polActivated || Currency.unwrap(pool.key.currency0) != Currency.unwrap(quote.key.currency0)
                || Currency.unwrap(pool.key.currency1) != Currency.unwrap(quote.key.currency1)
                || pool.key.fee != spec.lpFee || pool.key.tickSpacing != spec.tickSpacing
                || address(pool.key.hooks) != address(quote.key.hooks)
        ) revert InvalidLaunchPool(quote.poolId);
        IStaticsProtocolPools.PoolFeeRateView memory rate = pools.protocolPoolFeeRate(quote.poolId);
        if (rate.inputFeePips != spec.hookFeePips || rate.outputFeePips != spec.hookFeePips || !rate.overridden) {
            revert InvalidLaunchRate(quote.poolId);
        }
        (uint160 actualPrice,,,) = manager.getSlot0(quote.poolId);
        if (actualPrice != quote.sqrtPriceX96) {
            revert InvalidLaunchPrice(quote.poolId, actualPrice, quote.sqrtPriceX96);
        }
    }

    function _tickSpacing(string memory name, uint256 index) private view returns (int24 spacing) {
        int256 value = vm.envInt(name);
        if (value <= 0 || value > type(int24).max) revert InvalidLaunchInput(index);
        spacing = int24(value);
    }

    function _price(string memory name, uint256 index) private view returns (uint160 price) {
        uint256 value = vm.envUint(name);
        if (value == 0 || value > type(uint160).max) revert InvalidLaunchInput(index);
        price = uint160(value);
    }
}
