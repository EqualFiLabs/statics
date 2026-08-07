// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasket} from "../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";

struct GenesisBasketLaunchConfig {
    IStaticsBasket.CreateBasketParams basket;
    IStaticsBasket.PoolLaunchParams[] pools;
    uint256[] maxAmountsIn;
    uint256 expectedBasketId;
    uint256 launchDeadline;
}

/// @notice Timelock ceremony for funding and atomically launching the first Statics basket.
contract LaunchGenesisBasket is Script {
    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error PermissionlessCreationOpen(uint256 creationFee);
    error UnexpectedBasketCount(uint256 expected, uint256 actual);
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidLaunchConfiguration();
    error LaunchDeadlineTooSoon(uint256 deadline, uint256 earliestExecution);
    error ConfigurationValueOutOfRange(string field, uint256 value, uint256 maximum);
    error GenesisLaunchFailed(uint256 basketId);
    error InvalidLaunchedPool(uint256 basketId, address asset);

    event GenesisBasketBatchPrepared(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        uint256 expectedBasketId,
        uint256 launchDeadline,
        uint256 delay
    );
    event GenesisBasketLaunchValidated(
        uint256 indexed basketId, address indexed basketToken, address indexed timelock, uint256 poolCount
    );

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        string memory configPath = vm.envString("STATICS_GENESIS_BASKET_CONFIG");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_TIMELOCK_SALT");
        GenesisBasketLaunchConfig memory config = loadConfig(configPath);

        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        string memory configPath = vm.envString("STATICS_GENESIS_BASKET_CONFIG");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_TIMELOCK_SALT");
        GenesisBasketLaunchConfig memory config = loadConfig(configPath);

        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function schedule(address diamond, GenesisBasketLaunchConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validatePreLaunch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        uint256 earliestExecution = block.timestamp + delay;
        if (config.launchDeadline < earliestExecution) {
            revert LaunchDeadlineTooSoon(config.launchDeadline, earliestExecution);
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit GenesisBasketBatchPrepared(
            operationId, diamond, address(timelock), config.expectedBasketId, config.launchDeadline, delay
        );
    }

    function execute(address diamond, GenesisBasketLaunchConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validatePreLaunch(diamond, config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validateLaunch(diamond, address(timelock), config);
    }

    function buildBatch(address diamond, GenesisBasketLaunchConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        _validateShape(config);
        uint256 assetCount = config.basket.assets.length;
        uint256 callCount = assetCount + 1;
        targets = new address[](callCount);
        values = new uint256[](callCount);
        payloads = new bytes[](callCount);

        for (uint256 i; i < assetCount; ++i) {
            targets[i] = config.basket.assets[i];
            payloads[i] = abi.encodeCall(IERC20.approve, (diamond, config.maxAmountsIn[i]));
        }

        targets[assetCount] = diamond;
        payloads[assetCount] = abi.encodeCall(
            IStaticsBasket.createBasket, (config.basket, config.pools, config.maxAmountsIn, config.launchDeadline)
        );
    }

    function loadConfig(string memory path) public view returns (GenesisBasketLaunchConfig memory config) {
        string memory json = vm.readFile(path);
        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        uint256[] memory bundleAmounts = vm.parseJsonUintArray(json, ".bundleAmounts");
        uint256[] memory mintMinimums = vm.parseJsonUintArray(json, ".mintFeeMinimumShares");
        uint256[] memory mintFees = vm.parseJsonUintArray(json, ".mintFeeShares");
        uint256[] memory redemptionMinimums = vm.parseJsonUintArray(json, ".redemptionFeeMinimumShares");
        uint256[] memory redemptionFees = vm.parseJsonUintArray(json, ".redemptionFeeShares");
        uint256[] memory sqrtPrices = vm.parseJsonUintArray(json, ".sqrtPriceAssetPerBasketX96");
        uint256[] memory pairedAmounts = vm.parseJsonUintArray(json, ".pairedAssetAmounts");

        config.basket = IStaticsBasket.CreateBasketParams({
            name: vm.parseJsonString(json, ".name"),
            symbol: vm.parseJsonString(json, ".symbol"),
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _feeTiers(mintMinimums, mintFees),
            redemptionFeeTiers: _feeTiers(redemptionMinimums, redemptionFees),
            flashFeeBps: _uint16(json, ".flashFeeBps"),
            originationFeeBps: _uint16(json, ".originationFeeBps"),
            extensionFeeBps: _uint16(json, ".extensionFeeBps"),
            ltvBps: _uint16(json, ".ltvBps"),
            recoveryPenaltyBps: _uint16(json, ".recoveryPenaltyBps"),
            loanDuration: _uint40(json, ".loanDuration")
        });
        config.pools = _poolParams(sqrtPrices, pairedAmounts);
        config.maxAmountsIn = vm.parseJsonUintArray(json, ".maxAmountsIn");
        config.expectedBasketId = vm.parseJsonUint(json, ".expectedBasketId");
        config.launchDeadline = vm.parseJsonUint(json, ".launchDeadline");
        _validateShape(config);
    }

    function _validatePreLaunch(address diamond, GenesisBasketLaunchConfig memory config)
        private
        view
        returns (TimelockController timelock)
    {
        _validateShape(config);
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));

        uint256 creationFee = IStaticsBasketAdmin(diamond).creationFee();
        if (creationFee != 0) revert PermissionlessCreationOpen(creationFee);
        uint256 basketCount = IStaticsBasket(diamond).basketCount();
        if (basketCount != config.expectedBasketId) {
            revert UnexpectedBasketCount(config.expectedBasketId, basketCount);
        }
        (,, bool integrationInstalled) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        if (!integrationInstalled) revert LiquidityIntegrationNotInstalled();
        (, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (!managerInstalled) revert LiquidityManagerNotInstalled();
    }

    function _validateLaunch(address diamond, address timelock, GenesisBasketLaunchConfig memory config) private {
        IStaticsBasket baskets = IStaticsBasket(diamond);
        uint256 basketId = config.expectedBasketId;
        if (baskets.basketCount() != basketId + 1) revert GenesisLaunchFailed(basketId);
        IStaticsBasket.BasketView memory launched = baskets.basket(basketId);
        if (
            launched.creator != timelock || launched.token.code.length == 0 || IERC20(launched.token).totalSupply() == 0
                || launched.assets.length != config.basket.assets.length
        ) revert GenesisLaunchFailed(basketId);

        (, address hook, bool integrationInstalled) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (!integrationInstalled || !managerInstalled) revert GenesisLaunchFailed(basketId);

        uint256 assetCount = config.basket.assets.length;
        for (uint256 i; i < assetCount; ++i) {
            address asset = config.basket.assets[i];
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                IStaticsBasketLiquidity(diamond).canonicalPool(basketId, asset);
            IStaticsProtocolPools.ProtocolPoolView memory protocolPool =
                IStaticsProtocolPools(diamond).protocolPool(pool.poolId);
            if (
                launched.assets[i] != asset || launched.bundleAmounts[i] != config.basket.bundleAmounts[i]
                    || baskets.vaultBalance(basketId, asset) == 0 || pool.asset != asset
                    || pool.basketToken != launched.token || pool.hook != hook
                    || IStaticsSwapFeeHook(hook).lockedLiquidity(pool.poolId) == 0
                    || protocolPool.kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
                    || protocolPool.basketId != basketId || protocolPool.basketAsset != asset
                    || protocolPool.decommissioned
            ) revert InvalidLaunchedPool(basketId, asset);
        }
        emit GenesisBasketLaunchValidated(basketId, launched.token, timelock, assetCount);
    }

    function _validateShape(GenesisBasketLaunchConfig memory config) private pure {
        uint256 assetCount = config.basket.assets.length;
        if (
            assetCount == 0 || config.basket.bundleAmounts.length != assetCount || config.pools.length != assetCount
                || config.maxAmountsIn.length != assetCount || bytes(config.basket.name).length == 0
                || bytes(config.basket.symbol).length == 0 || config.launchDeadline == 0
        ) revert InvalidLaunchConfiguration();
    }

    function _feeTiers(uint256[] memory minimums, uint256[] memory fees)
        private
        pure
        returns (IStaticsBasket.FeeTier[] memory tiers)
    {
        if (minimums.length != fees.length) revert InvalidLaunchConfiguration();
        tiers = new IStaticsBasket.FeeTier[](minimums.length);
        for (uint256 i; i < minimums.length; ++i) {
            tiers[i] = IStaticsBasket.FeeTier({minActionShares: minimums[i], feeShares: fees[i]});
        }
    }

    function _poolParams(uint256[] memory sqrtPrices, uint256[] memory pairedAmounts)
        private
        pure
        returns (IStaticsBasket.PoolLaunchParams[] memory pools)
    {
        if (sqrtPrices.length != pairedAmounts.length) revert InvalidLaunchConfiguration();
        pools = new IStaticsBasket.PoolLaunchParams[](sqrtPrices.length);
        for (uint256 i; i < sqrtPrices.length; ++i) {
            uint256 sqrtPrice = sqrtPrices[i];
            if (sqrtPrice > type(uint160).max) {
                revert ConfigurationValueOutOfRange("sqrtPriceAssetPerBasketX96", sqrtPrice, type(uint160).max);
            }
            pools[i] = IStaticsBasket.PoolLaunchParams({
                sqrtPriceAssetPerBasketX96: uint160(sqrtPrice), pairedAssetAmount: pairedAmounts[i]
            });
        }
    }

    function _uint16(string memory json, string memory key) private pure returns (uint16 narrowed) {
        uint256 value = vm.parseJsonUint(json, key);
        if (value > type(uint16).max) {
            revert ConfigurationValueOutOfRange(key, value, type(uint16).max);
        }
        narrowed = uint16(value);
    }

    function _uint40(string memory json, string memory key) private pure returns (uint40 narrowed) {
        uint256 value = vm.parseJsonUint(json, key);
        if (value > type(uint40).max) {
            revert ConfigurationValueOutOfRange(key, value, type(uint40).max);
        }
        narrowed = uint40(value);
    }
}
