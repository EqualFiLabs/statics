// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {IStaticsDollarCoreTypes} from "../src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {IMorphoBlue, MorphoMarket, MorphoMarketId, MorphoMarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsMorpho} from "../src/interfaces/IStaticsMorpho.sol";
import {TestnetMorphoOracle} from "../src/testnet/TestnetMorphoOracle.sol";

interface IMorphoMarketFactory is IMorphoBlue {
    function createMarket(MorphoMarketParams memory marketParams) external;

    function supply(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
}

struct StaticsMorphoConfig {
    address morpho;
    address usdStx;
    address statics;
    address staticsOracle;
    address basketToken;
    address basketOracle;
    address irm;
    uint256 lltv;
    uint16 syncBountyBps;
    uint256 basketId;
}

/// @notice Creates and registers the two markets used by a full testnet rehearsal.
contract ConfigureStaticsMorpho is Script {
    using SafeERC20 for IERC20;

    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidContract(address target);
    error InvalidMarket(bytes32 marketId);
    error MorphoAlreadyConfigured(address morpho);
    error MorphoConfigurationFailed();
    error InvalidSeedAmount();
    error ConfigurationValueOutOfRange(string field, uint256 value, uint256 maximum);

    event StaticsMorphoBatchPrepared(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        bytes32 staticsMarketId,
        bytes32 basketMarketId,
        uint256 delay
    );

    function runDeployOracles() external returns (address staticsOracle, address basketOracle) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("TESTNET_MORPHO_ORACLE_OWNER");
        uint256 staticsPrice = vm.envUint("TESTNET_MORPHO_STATICS_PRICE");
        uint256 basketPrice = vm.envUint("TESTNET_MORPHO_BASKET_PRICE");

        vm.startBroadcast(privateKey);
        (staticsOracle, basketOracle) = deployOracles(owner, staticsPrice, basketPrice);
        vm.stopBroadcast();

        console2.log("STATICS_MORPHO_STATICS_ORACLE", staticsOracle);
        console2.log("STATICS_MORPHO_BASKET_ORACLE", basketOracle);
    }

    function runCreateMarkets() external returns (bytes32 staticsMarketId, bytes32 basketMarketId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        StaticsMorphoConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        (staticsMarketId, basketMarketId) = createMarkets(config);
        vm.stopBroadcast();
    }

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_MORPHO_TIMELOCK_SALT");
        StaticsMorphoConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_MORPHO_TIMELOCK_SALT");
        StaticsMorphoConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runSeedLiquidity() external returns (uint256 collateralIn) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        uint256 profileId = vm.envUint("STATICS_DOLLAR_USDC_PROFILE_ID");
        uint256 assetsPerMarket = vm.envUint("STATICS_MORPHO_LIQUIDITY_PER_MARKET");
        StaticsMorphoConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        collateralIn = seedLiquidity(diamond, config, profileId, assetsPerMarket, vm.addr(privateKey));
        vm.stopBroadcast();
    }

    function deployOracles(address owner, uint256 staticsPrice, uint256 basketPrice)
        public
        returns (address staticsOracle, address basketOracle)
    {
        staticsOracle = address(new TestnetMorphoOracle(owner, staticsPrice));
        basketOracle = address(new TestnetMorphoOracle(owner, basketPrice));
    }

    function createMarkets(StaticsMorphoConfig memory config)
        public
        returns (bytes32 staticsMarketId, bytes32 basketMarketId)
    {
        _validateContracts(config);
        MorphoMarketParams memory staticsParams = staticsMarketParams(config);
        MorphoMarketParams memory basketParams = basketMarketParams(config);
        staticsMarketId = _createIfMissing(config.morpho, staticsParams);
        basketMarketId = _createIfMissing(config.morpho, basketParams);
    }

    function schedule(address diamond, StaticsMorphoConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateBefore(diamond, config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit StaticsMorphoBatchPrepared(
            operationId,
            diamond,
            address(timelock),
            marketId(staticsMarketParams(config)),
            marketId(basketMarketParams(config)),
            delay
        );
    }

    function execute(address diamond, StaticsMorphoConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validateBefore(diamond, config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        IStaticsMorpho integration = IStaticsMorpho(diamond);
        if (
            integration.morpho() != config.morpho || integration.morphoUsdStx() != config.usdStx
                || integration.morphoSyncBountyBps() != config.syncBountyBps
        ) revert MorphoConfigurationFailed();
        _validateRegisteredMarket(integration, marketId(staticsMarketParams(config)), config, false);
        _validateRegisteredMarket(integration, marketId(basketMarketParams(config)), config, true);
    }

    function buildBatch(address diamond, StaticsMorphoConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](3);
        values = new uint256[](3);
        payloads = new bytes[](3);
        targets[0] = diamond;
        targets[1] = diamond;
        targets[2] = diamond;
        payloads[0] = abi.encodeCall(
            IStaticsMorpho.initializeMorphoIntegration, (config.morpho, config.usdStx, config.syncBountyBps)
        );
        payloads[1] = abi.encodeCall(
            IStaticsMorpho.registerMorphoMarket,
            (
                staticsMarketParams(config),
                IStaticsMorpho.CollateralKind.StakedStatics,
                0,
                IStaticsMorpho.MarketMode.Active
            )
        );
        payloads[2] = abi.encodeCall(
            IStaticsMorpho.registerMorphoMarket,
            (
                basketMarketParams(config),
                IStaticsMorpho.CollateralKind.Basket,
                config.basketId,
                IStaticsMorpho.MarketMode.Active
            )
        );
    }

    function staticsMarketParams(StaticsMorphoConfig memory config) public pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams(config.usdStx, config.statics, config.staticsOracle, config.irm, config.lltv);
    }

    function basketMarketParams(StaticsMorphoConfig memory config) public pure returns (MorphoMarketParams memory) {
        return MorphoMarketParams(config.usdStx, config.basketToken, config.basketOracle, config.irm, config.lltv);
    }

    function marketId(MorphoMarketParams memory params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function seedLiquidity(
        address diamond,
        StaticsMorphoConfig memory config,
        uint256 profileId,
        uint256 assetsPerMarket,
        address lender
    ) public returns (uint256 collateralIn) {
        if (assetsPerMarket == 0) revert InvalidSeedAmount();
        _validateContracts(config);
        IStaticsDollarGateway gateway = IStaticsDollarGateway(diamond);
        uint256 totalAssets = assetsPerMarket * 2;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = gateway.previewPeggedMint(profileId, totalAssets);
        IERC20 collateral = IERC20(preview.collateralToken);
        collateral.forceApprove(diamond, preview.totalCollateralIn);
        collateralIn = gateway.mintPegged(profileId, totalAssets, preview.totalCollateralIn, lender);
        collateral.forceApprove(diamond, 0);

        IERC20(config.usdStx).forceApprove(config.morpho, totalAssets);
        IMorphoMarketFactory factory = IMorphoMarketFactory(config.morpho);
        factory.supply(staticsMarketParams(config), assetsPerMarket, 0, lender, "");
        factory.supply(basketMarketParams(config), assetsPerMarket, 0, lender, "");
        IERC20(config.usdStx).forceApprove(config.morpho, 0);
    }

    function _createIfMissing(address morpho, MorphoMarketParams memory params) private returns (bytes32 id) {
        id = marketId(params);
        IMorphoMarketFactory factory = IMorphoMarketFactory(morpho);
        if (factory.market(MorphoMarketId.wrap(id)).lastUpdate == 0) factory.createMarket(params);
        _validateMarket(factory, params, id);
    }

    function _validateBefore(address diamond, StaticsMorphoConfig memory config)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));
        _validateContracts(config);
        address configured = IStaticsMorpho(diamond).morpho();
        if (configured != address(0)) revert MorphoAlreadyConfigured(configured);
        _validateMarket(IMorphoBlue(config.morpho), staticsMarketParams(config), marketId(staticsMarketParams(config)));
        _validateMarket(IMorphoBlue(config.morpho), basketMarketParams(config), marketId(basketMarketParams(config)));
    }

    function _validateContracts(StaticsMorphoConfig memory config) private view {
        _contract(config.morpho);
        _contract(config.usdStx);
        _contract(config.statics);
        _contract(config.staticsOracle);
        _contract(config.basketToken);
        _contract(config.basketOracle);
        _contract(config.irm);
    }

    function _validateMarket(IMorphoBlue morpho, MorphoMarketParams memory expected, bytes32 id) private view {
        MorphoMarket memory state = morpho.market(MorphoMarketId.wrap(id));
        MorphoMarketParams memory actual = morpho.idToMarketParams(MorphoMarketId.wrap(id));
        if (
            state.lastUpdate == 0 || actual.loanToken != expected.loanToken
                || actual.collateralToken != expected.collateralToken || actual.oracle != expected.oracle
                || actual.irm != expected.irm || actual.lltv != expected.lltv
        ) revert InvalidMarket(id);
    }

    function _validateRegisteredMarket(
        IStaticsMorpho integration,
        bytes32 id,
        StaticsMorphoConfig memory config,
        bool basket
    ) private view {
        IStaticsMorpho.MarketConfigView memory registered = integration.morphoMarket(id);
        IStaticsMorpho.CollateralKind expectedKind =
            basket ? IStaticsMorpho.CollateralKind.Basket : IStaticsMorpho.CollateralKind.StakedStatics;
        uint256 expectedBasketId = basket ? config.basketId : 0;
        if (
            registered.kind != expectedKind || registered.mode != IStaticsMorpho.MarketMode.Active
                || registered.basketId != expectedBasketId
        ) revert MorphoConfigurationFailed();
    }

    function _contract(address target) private view {
        if (target.code.length == 0) revert InvalidContract(target);
    }

    function _loadConfig() private view returns (StaticsMorphoConfig memory config) {
        uint256 syncBountyBps = vm.envUint("STATICS_MORPHO_SYNC_BOUNTY_BPS");
        if (syncBountyBps > type(uint16).max) {
            revert ConfigurationValueOutOfRange("STATICS_MORPHO_SYNC_BOUNTY_BPS", syncBountyBps, type(uint16).max);
        }
        config = StaticsMorphoConfig({
            morpho: vm.envAddress("STATICS_MORPHO_ADDRESS"),
            usdStx: vm.envAddress("STATICS_DOLLAR_TOKEN_ADDRESS"),
            statics: vm.envAddress("STAKING_TOKEN"),
            staticsOracle: vm.envAddress("STATICS_MORPHO_STATICS_ORACLE"),
            basketToken: vm.envAddress("STATICS_MORPHO_BASKET_TOKEN"),
            basketOracle: vm.envAddress("STATICS_MORPHO_BASKET_ORACLE"),
            irm: vm.envAddress("STATICS_MORPHO_IRM_ADDRESS"),
            lltv: vm.envUint("STATICS_MORPHO_LLTV"),
            syncBountyBps: uint16(syncBountyBps),
            basketId: vm.envUint("STATICS_MORPHO_BASKET_ID")
        });
    }
}
