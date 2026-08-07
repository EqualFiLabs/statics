// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {BasketLiquidityFacet} from "../src/facets/BasketLiquidityFacet.sol";
import {BorrowLiquidityFacet} from "../src/facets/BorrowLiquidityFacet.sol";
import {LiquidityRewardsFacet} from "../src/facets/LiquidityRewardsFacet.sol";
import {ProtocolPoolFacet} from "../src/facets/ProtocolPoolFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";

/// @notice Governed Robinhood testnet ceremony for installing generic Statics protocol pools.
contract UpgradeGovernedProtocolPools is Script {
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;

    struct UpgradeContracts {
        address basketLiquidityFacet;
        address borrowLiquidityFacet;
        address liquidityRewardsFacet;
        address protocolPoolFacet;
        address liquidityManager;
    }

    error UnsupportedChain(uint256 chainId);
    error InvalidDiamond(address diamond);
    error InvalidContract(address target);
    error InvalidFacet(address facet, bytes32 expected, bytes32 actual);
    error InvalidTimelock(address timelock);
    error InvalidProposer(address proposer);
    error InvalidLiquidityIntegration();
    error InvalidManagerBinding(address manager, address expected, address actual);
    error UnexpectedSelectorRoute(bytes4 selector, address expected, address actual);
    error UpgradeAlreadyInstalled();
    error UpgradeOperationExists(bytes32 operationId);
    error UpgradeOperationNotReady(bytes32 operationId);
    error UpgradeValidationFailed();

    event GovernedProtocolPoolsContractsDeployed(
        address indexed basketLiquidityFacet,
        address indexed borrowLiquidityFacet,
        address indexed liquidityRewardsFacet,
        address protocolPoolFacet,
        address liquidityManager
    );
    event GovernedProtocolPoolsUpgradePrepared(
        bytes32 indexed operationId, address indexed diamond, address indexed timelock, uint256 delay
    );
    event GovernedProtocolPoolsUpgradeExecuted(
        bytes32 indexed operationId, address indexed diamond, address indexed liquidityManager
    );

    function runDeploy() external returns (UpgradeContracts memory contracts_) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        (address poolManager,, bool integrationInstalled) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address oldManager, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (!integrationInstalled || !managerInstalled) revert InvalidLiquidityIntegration();
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(oldManager);
        address positionManager = oldBinding.positionManager();
        address permit2 = oldBinding.permit2();

        vm.startBroadcast(privateKey);
        contracts_.basketLiquidityFacet = address(new BasketLiquidityFacet());
        contracts_.borrowLiquidityFacet = address(new BorrowLiquidityFacet());
        contracts_.liquidityRewardsFacet = address(new LiquidityRewardsFacet());
        contracts_.protocolPoolFacet = address(new ProtocolPoolFacet());
        contracts_.liquidityManager =
            address(new StaticsLiquidityManager(diamond, positionManager, poolManager, permit2));
        vm.stopBroadcast();

        _validateContracts(diamond, contracts_);
        emit GovernedProtocolPoolsContractsDeployed(
            contracts_.basketLiquidityFacet,
            contracts_.borrowLiquidityFacet,
            contracts_.liquidityRewardsFacet,
            contracts_.protocolPoolFacet,
            contracts_.liquidityManager
        );
    }

    function runSchedule() external returns (bytes32 operationId) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        UpgradeContracts memory contracts_ = _loadContracts();
        bytes32 salt = vm.envBytes32("GOVERNED_PROTOCOL_POOLS_TIMELOCK_SALT");
        TimelockController timelock = _validateBeforeUpgrade(diamond, contracts_);
        address proposer = vm.addr(privateKey);
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), proposer)) revert InvalidProposer(proposer);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, contracts_);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (timelock.isOperation(operationId)) revert UpgradeOperationExists(operationId);
        uint256 delay = timelock.getMinDelay();

        vm.startBroadcast(privateKey);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.stopBroadcast();

        if (!timelock.isOperationPending(operationId)) revert UpgradeValidationFailed();
        emit GovernedProtocolPoolsUpgradePrepared(operationId, diamond, address(timelock), delay);
    }

    function runExecute() external returns (bytes32 operationId) {
        _enforceRobinhoodTestnet();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        UpgradeContracts memory contracts_ = _loadContracts();
        bytes32 salt = vm.envBytes32("GOVERNED_PROTOCOL_POOLS_TIMELOCK_SALT");
        TimelockController timelock = _timelock(diamond);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, contracts_);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (!timelock.isOperationReady(operationId)) revert UpgradeOperationNotReady(operationId);
        (address oldManager,) = IStaticsBasketLiquidity(diamond).liquidityManager();

        vm.startBroadcast(privateKey);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        validateUpgraded(diamond, contracts_, oldManager);
        emit GovernedProtocolPoolsUpgradeExecuted(operationId, diamond, contracts_.liquidityManager);
    }

    function schedule(address diamond, UpgradeContracts memory contracts_, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateBeforeUpgrade(diamond, contracts_);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, contracts_);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (timelock.isOperation(operationId)) revert UpgradeOperationExists(operationId);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
        if (!timelock.isOperationPending(operationId)) revert UpgradeValidationFailed();
    }

    function execute(address diamond, UpgradeContracts memory contracts_, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _timelock(diamond);
        (address oldManager,) = IStaticsBasketLiquidity(diamond).liquidityManager();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, contracts_);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        if (!timelock.isOperationReady(operationId)) revert UpgradeOperationNotReady(operationId);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        validateUpgraded(diamond, contracts_, oldManager);
    }

    function buildBatch(address diamond, UpgradeContracts memory contracts_)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = diamond;
        targets[1] = diamond;
        payloads[0] = _diamondCutPayload(diamond, contracts_);
        payloads[1] = abi.encodeCall(IStaticsProtocolPools.replaceLiquidityManager, (contracts_.liquidityManager));
    }

    function buildCut(UpgradeContracts memory contracts_) public pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](4);
        cut[0] = _cut(
            contracts_.basketLiquidityFacet, IDiamondCut.FacetCutAction.Replace, StaticsSelectors.basketLiquidity()
        );
        cut[1] = _cut(
            contracts_.borrowLiquidityFacet, IDiamondCut.FacetCutAction.Replace, StaticsSelectors.borrowLiquidity()
        );
        cut[2] = _cut(
            contracts_.liquidityRewardsFacet, IDiamondCut.FacetCutAction.Replace, StaticsSelectors.liquidityRewards()
        );
        cut[3] = _cut(contracts_.protocolPoolFacet, IDiamondCut.FacetCutAction.Add, StaticsSelectors.protocolPools());
    }

    function validateUpgraded(address diamond, UpgradeContracts memory contracts_, address oldManager) public view {
        _validateContracts(diamond, contracts_);
        _validateRoutes(diamond, StaticsSelectors.basketLiquidity(), contracts_.basketLiquidityFacet);
        _validateRoutes(diamond, StaticsSelectors.borrowLiquidity(), contracts_.borrowLiquidityFacet);
        _validateRoutes(diamond, StaticsSelectors.liquidityRewards(), contracts_.liquidityRewardsFacet);
        _validateRoutes(diamond, StaticsSelectors.protocolPools(), contracts_.protocolPoolFacet);
        if (!IERC165(diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId)) {
            revert UpgradeValidationFailed();
        }
        (address installedManager, bool installed) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (!installed || installedManager != contracts_.liquidityManager) revert UpgradeValidationFailed();
        address positionManager = IStaticsLiquidityManager(installedManager).positionManager();
        if (
            IERC721(positionManager).isApprovedForAll(diamond, oldManager)
                || !IERC721(positionManager).isApprovedForAll(diamond, installedManager)
        ) revert UpgradeValidationFailed();
    }

    function _diamondCutPayload(address diamond, UpgradeContracts memory contracts_)
        private
        pure
        returns (bytes memory)
    {
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = type(IStaticsProtocolPools).interfaceId;
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        bytes memory initData = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported));
        return abi.encodeCall(IDiamondCut.diamondCut, (buildCut(contracts_), diamond, initData));
    }

    function _validateBeforeUpgrade(address diamond, UpgradeContracts memory contracts_)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        _validateContracts(diamond, contracts_);
        timelock = _timelock(diamond);
        _validateReplaceableRoutes(diamond, StaticsSelectors.basketLiquidity(), contracts_.basketLiquidityFacet);
        _validateReplaceableRoutes(diamond, StaticsSelectors.borrowLiquidity(), contracts_.borrowLiquidityFacet);
        _validateReplaceableRoutes(diamond, StaticsSelectors.liquidityRewards(), contracts_.liquidityRewardsFacet);
        bytes4[] memory additions = StaticsSelectors.protocolPools();
        for (uint256 i; i < additions.length; ++i) {
            address actual = IDiamondLoupe(diamond).facetAddress(additions[i]);
            if (actual != address(0)) revert UpgradeAlreadyInstalled();
        }
        if (IERC165(diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId)) {
            revert UpgradeAlreadyInstalled();
        }
    }

    function _validateContracts(address diamond, UpgradeContracts memory contracts_) private view {
        _validateFacet(contracts_.basketLiquidityFacet, keccak256(type(BasketLiquidityFacet).runtimeCode));
        _validateFacet(contracts_.borrowLiquidityFacet, keccak256(type(BorrowLiquidityFacet).runtimeCode));
        _validateFacet(contracts_.liquidityRewardsFacet, keccak256(type(LiquidityRewardsFacet).runtimeCode));
        _validateFacet(contracts_.protocolPoolFacet, keccak256(type(ProtocolPoolFacet).runtimeCode));
        if (contracts_.liquidityManager.code.length == 0) revert InvalidContract(contracts_.liquidityManager);
        (address poolManager,, bool integrationInstalled) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address oldManager, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (!integrationInstalled || !managerInstalled) revert InvalidLiquidityIntegration();
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(oldManager);
        IStaticsLiquidityManager replacement = IStaticsLiquidityManager(contracts_.liquidityManager);
        _validateBinding(contracts_.liquidityManager, diamond, replacement.staticsDiamond());
        _validateBinding(contracts_.liquidityManager, poolManager, replacement.poolManager());
        _validateBinding(contracts_.liquidityManager, oldBinding.positionManager(), replacement.positionManager());
        _validateBinding(contracts_.liquidityManager, oldBinding.permit2(), replacement.permit2());
    }

    function _validateReplaceableRoutes(address diamond, bytes4[] memory selectors, address replacement) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address current = loupe.facetAddress(selectors[0]);
        if (current == address(0)) revert UnexpectedSelectorRoute(selectors[0], address(1), address(0));
        if (current == replacement) revert UpgradeAlreadyInstalled();
        for (uint256 i; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != current) revert UnexpectedSelectorRoute(selectors[i], current, actual);
        }
    }

    function _validateRoutes(address diamond, bytes4[] memory selectors, address expected) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        for (uint256 i; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != expected) revert UnexpectedSelectorRoute(selectors[i], expected, actual);
        }
    }

    function _validateFacet(address facet, bytes32 expectedHash) private view {
        bytes32 actualHash = facet.codehash;
        if (facet.code.length == 0 || actualHash != expectedHash) revert InvalidFacet(facet, expectedHash, actualHash);
    }

    function _validateBinding(address manager, address expected, address actual) private pure {
        if (expected != actual) revert InvalidManagerBinding(manager, expected, actual);
    }

    function _timelock(address diamond) private view returns (TimelockController timelock) {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));
    }

    function _loadContracts() private view returns (UpgradeContracts memory contracts_) {
        contracts_ = UpgradeContracts({
            basketLiquidityFacet: vm.envAddress("GOVERNED_PROTOCOL_POOLS_BASKET_LIQUIDITY_FACET"),
            borrowLiquidityFacet: vm.envAddress("GOVERNED_PROTOCOL_POOLS_BORROW_LIQUIDITY_FACET"),
            liquidityRewardsFacet: vm.envAddress("GOVERNED_PROTOCOL_POOLS_LIQUIDITY_REWARDS_FACET"),
            protocolPoolFacet: vm.envAddress("GOVERNED_PROTOCOL_POOLS_FACET"),
            liquidityManager: vm.envAddress("GOVERNED_PROTOCOL_POOLS_LIQUIDITY_MANAGER")
        });
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        private
        pure
        returns (IDiamondCut.FacetCut memory entry)
    {
        entry = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }

    function _enforceRobinhoodTestnet() private view {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
    }
}
