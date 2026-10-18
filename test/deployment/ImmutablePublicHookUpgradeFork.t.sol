// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsPublicHookReleaseInit} from "../../src/diamond/StaticsPublicHookReleaseInit.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsBasketToken} from "../../src/tokens/StaticsBasketToken.sol";
import {StaticsProtocolPlan} from "../../script/libraries/StaticsProtocolPlan.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsPublicHookPolicy} from "../../src/interfaces/IStaticsPublicHookPolicy.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsMarketTape} from "../../src/interfaces/IStaticsMarketTape.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {DeployStaticsProtocol} from "../../script/dollar/DeployStaticsProtocol.s.sol";
import {PrepareStaticsPublicHookUpgrade} from "../../script/PrepareStaticsPublicHookUpgrade.s.sol";
import {StaticsProtocolParts} from "../../script/libraries/StaticsProtocolPlan.sol";
import {CanonicalPoolTestBase, CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PublicHookCandidateDeployer is DeployStaticsProtocol {
    function deployParts() external returns (StaticsProtocolParts memory parts) {
        parts = _deployPhaseOneProtocolParts();
        return _deployPhaseTwoProtocolParts(parts);
    }
}

/// @notice Opt-in, read-only RPC fork; every deployment/cut/transaction below occurs only in the local EVM.
contract ImmutablePublicHookUpgradeForkTest is CanonicalPoolTestBase {
    address private constant DIAMOND = 0x612aC07E3A60e16F1CC7B2c1Fd3DbEB474515DAa;
    uint256 private constant BLOCK = 88_780_151;
    address private owner;
    IStaticsProtocolPools private pools;
    StaticsBasketHook private basketHook;
    string private fixture;
    string private evidenceOutput;

    function setUp() public override {
        if (!vm.envOr("STATICS_PUBLIC_HOOK_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envString("ROBINHOOD_MAINNET"), BLOCK);
        assertEq(block.chainid, 4663);
        fixture = vm.readFile("test/fixtures/immutable-hooks-phase-one.json");
        assertEq(vm.parseJsonUint(fixture, ".block"), BLOCK);
        assertEq(vm.parseJsonAddress(fixture, ".diamond"), DIAMOND);
        owner = IERC173(DIAMOND).owner();
        assertEq(owner, vm.parseJsonAddress(fixture, ".owner"));
        _checkOldTopology();
        diamond = StaticsDiamond(payable(DIAMOND));
        pools = IStaticsProtocolPools(DIAMOND);
        baskets = IStaticsBasket(DIAMOND);
        basketAdmin = IStaticsBasketAdmin(DIAMOND);
        globalRewards = IStaticsGlobalRewards(DIAMOND);
        basketLiquidity = IStaticsBasketLiquidity(DIAMOND);
        custody = IStaticsCustody(DIAMOND);
        (address manager, address hook,) = basketLiquidity.liquidityIntegration();
        poolManager = IPoolManager(manager);
        swapFeeHook = StaticsSwapFeeHook(payable(hook));
        v4Router = new CanonicalV4Router(poolManager);
        assetA = new MockERC20("Fork A", "FA", 18);
        assetB = new MockERC20("Fork B", "FB", 18);
        vm.deal(address(this), 1_000 ether);
        vm.deal(alice, 1_000 ether);
        assertEq(pools.poolCreationFee(), 0);
        assertEq(
            address(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed).codehash,
            bytes32(0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f)
        );
        // No etching: the actual fork's pinned CreateX deploys restricted tokens.
    }

    function _checkOldTopology() private view {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(DIAMOND).facets();
        assertEq(facets.length, 32);
        uint256 selectors;
        for (uint256 i; i < facets.length; ++i) {
            string memory path = string.concat(".facets[", vm.toString(i), "]");
            assertEq(facets[i].facetAddress, vm.parseJsonAddress(fixture, string.concat(path, ".address")));
            assertEq(
                facets[i].facetAddress.codehash, vm.parseJsonBytes32(fixture, string.concat(path, ".runtimeCodeHash"))
            );
            for (uint256 j; j < facets[i].functionSelectors.length; ++j) {
                bytes4 expected =
                    bytes4(vm.parseJsonBytes(fixture, string.concat(path, ".selectors[", vm.toString(j), "]")));
                assertEq(facets[i].functionSelectors[j], expected);
                ++selectors;
            }
        }
        assertEq(selectors, 226);
    }

    function _deployStandaloneHooks() private {
        // Deploy against the original Diamond before adding any Phase 2 selectors.
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        bytes memory hookArgs = abi.encode(poolManager, DIAMOND, uint16(0), uint16(0), swapFeeHook.weth());
        (address expectedHook, bytes32 hookSalt) =
            HookMiner.find(address(this), flags, type(StaticsBasketHook).creationCode, hookArgs);
        basketHook = new StaticsBasketHook{salt: hookSalt}(poolManager, DIAMOND, 0, 0, swapFeeHook.weth());
        assertEq(address(basketHook), expectedHook);
    }

    function _upgrade() private {
        _deployStandaloneHooks();
        bytes memory hookArgs = abi.encode(poolManager, DIAMOND, uint16(0), uint16(0), swapFeeHook.weth());
        _localBasketFactory = new StaticsBasketTokenFactory(DIAMOND, poolManager);
        (address previous,) = basketLiquidity.liquidityManager();
        IStaticsLiquidityManager old = IStaticsLiquidityManager(previous);
        address manager =
            address(new StaticsLiquidityManager(DIAMOND, old.positionManager(), address(poolManager), old.permit2()));
        StaticsProtocolParts memory parts = new PublicHookCandidateDeployer().deployParts();
        PrepareStaticsPublicHookUpgrade.Configuration memory config = PrepareStaticsPublicHookUpgrade.Configuration(
            DIAMOND,
            address(new StaticsPublicHookReleaseInit()),
            address(basketHook),
            address(_localBasketFactory),
            manager,
            0,
            5
        );
        PrepareStaticsPublicHookUpgrade builder = new PrepareStaticsPublicHookUpgrade();
        (address[] memory targets,, bytes[] memory payloads) = builder.build(config, parts);
        string memory safeJson = builder.buildSafeJson(config, parts);
        assertEq(vm.parseJsonAddress(safeJson, ".transactions[0].to"), DIAMOND);
        assertEq(vm.parseJsonBytes(safeJson, ".transactions[0].data"), payloads[0]);
        if (bytes(evidenceOutput).length != 0) vm.writeJson(safeJson, evidenceOutput, ".safeTransactionBuilder");
        _record("StaticsBasketHook", address(basketHook), hookArgs, type(StaticsBasketHook).creationCode);
        _record(
            "StaticsBasketTokenFactory",
            address(_localBasketFactory),
            abi.encode(DIAMOND, poolManager),
            type(StaticsBasketTokenFactory).creationCode
        );
        _record(
            "StaticsLiquidityManager",
            manager,
            abi.encode(DIAMOND, old.positionManager(), address(poolManager), old.permit2()),
            type(StaticsLiquidityManager).creationCode
        );
        _record("StaticsPublicHookReleaseInit", config.initializer, "", type(StaticsPublicHookReleaseInit).creationCode);
        _recordFacets(parts);
        assertEq(_localBasketFactory.tokenCreationCodeHash(), keccak256(type(StaticsBasketToken).creationCode));
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(owner);
            (bool success, bytes memory result) = targets[i].call(payloads[i]);
            if (!success) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
        IDiamondCut.FacetCut[] memory expected = StaticsProtocolPlan.cumulative(parts, 2);
        for (uint256 i; i < expected.length; ++i) {
            for (uint256 j; j < expected[i].functionSelectors.length; ++j) {
                assertEq(
                    IDiamondLoupe(DIAMOND).facetAddress(expected[i].functionSelectors[j]), expected[i].facetAddress
                );
            }
        }
        (address installed,) = basketLiquidity.liquidityManager();
        assertEq(installed, manager);
        assertEq(pools.poolCreationFee(), 0);
        assertEq(IERC173(DIAMOND).owner(), owner);
        (address b, address f) = IStaticsPublicHookPolicy(DIAMOND).basketHookConfiguration();
        assertEq(b, address(basketHook));
        assertEq(f, address(_localBasketFactory));
        assertEq(IDiamondLoupe(DIAMOND).facetAddress(bytes4(keccak256("weth()"))), address(0));
        assertEq(IDiamondLoupe(DIAMOND).facetAddress(bytes4(keccak256("morpho()"))), address(0));
    }

    function testPinnedCutPreservesAllSixPoolsAndCreatesConnectedRestrictedBasket() public {
        _startEvidence();
        bytes32[6] memory oldViews;
        bytes32[6] memory oldClaims;
        for (uint256 i; i < 6; ++i) {
            PoolId id = _oldId(i);
            PoolKey memory key = pools.protocolPool(id).key;
            assertEq(address(key.hooks), address(swapFeeHook));
            oldViews[i] = keccak256(abi.encode(pools.protocolPool(id)));
            oldClaims[i] = _claims(key);
        }
        address weth = swapFeeHook.weth();
        uint256 unfunded = globalRewards.unfundedSwapRewards(weth);
        uint256 reserved = custody.globalReservedByToken(weth);
        _upgrade();
        assertEq(globalRewards.unfundedSwapRewards(weth), unfunded);
        assertEq(custody.globalReservedByToken(weth), reserved);
        for (uint256 i; i < 6; ++i) {
            PoolId id = _oldId(i);
            assertEq(keccak256(abi.encode(pools.protocolPool(id))), oldViews[i]);
            assertEq(_claims(pools.protocolPool(id).key), oldClaims[i]);
        }
        _newGeneralFlow();
        _newBasketFlow();
        if (bytes(evidenceOutput).length != 0) vm.writeJson("true", evidenceOutput, ".completed");
    }

    struct LegacyPosition {
        uint256 position;
        PoolId poolId;
        address manager;
        uint256 posmTokenId;
        uint256 sequence;
        uint256 pending;
    }

    function testApprovedDistributorTransfersPreserveSettlementAfterUpgrade() public {
        _upgrade();
        IERC20 token = IERC20(_newBasketFlow());
        assertFalse(basketAdmin.isBasketDistributor(owner));
        assertFalse(basketAdmin.isBasketDistributor(DIAMOND));
        assertFalse(basketAdmin.isBasketDistributor(bob));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, alice, bob, 0.2 ether)
        );
        token.transfer(bob, 0.2 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, alice, owner, 0.2 ether)
        );
        token.transfer(owner, 0.2 ether);

        vm.prank(owner);
        basketAdmin.setBasketDistributor(bob, true);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0.2 ether));
        vm.prank(bob);
        assertTrue(token.transfer(alice, 0.1 ether));
        assertEq(token.balanceOf(bob), 0.1 ether);
        vm.prank(owner);
        basketAdmin.setBasketDistributor(address(poolManager), true);
        vm.prank(bob);
        vm.expectRevert(StaticsBasketToken.PoolManagerLocked.selector);
        token.transfer(address(poolManager), 1);

        vm.prank(owner);
        basketAdmin.setBasketDistributor(bob, false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketToken.TransferNotAuthorized.selector, bob, alice, 0.1 ether)
        );
        token.transfer(alice, 0.1 ether);
        assertEq(IDiamondLoupe(DIAMOND).facetAddress(bytes4(keccak256("morpho()"))), address(0));
    }

    function testPreUpgradeStakeAndManagedPositionRemainLiveAcrossTheCut() public {
        LegacyPosition memory old = _openLegacyStakeAndPosition();
        _upgrade();
        IStaticsRangeGauge gauges = IStaticsRangeGauge(DIAMOND);
        assertEq(globalRewards.stakePosition(old.position).stakedBalance, 10 ether);
        assertEq(globalRewards.unfundedSwapRewards(swapFeeHook.weth()), old.pending);
        assertEq(gauges.lpLeg(old.position, old.poolId).manager, old.manager);
        assertEq(gauges.lpLeg(old.position, old.poolId).posmTokenId, old.posmTokenId);
        assertEq(IStaticsMarketTape(DIAMOND).canonicalMarketState(old.poolId).sequence, old.sequence + 1);
        globalRewards.settlePublicSwapRewards(swapFeeHook.weth(), type(uint256).max);
        assertGt(_claimWeth(old.position), 0);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory exited =
            gauges.exitLiquidity(old.position, old.poolId, 0, 0, block.timestamp);
        assertGt(exited.received0, 0);
        assertEq(gauges.lpLeg(old.position, old.poolId).liquidity, 0);
        _newGeneralFlow();
        globalRewards.settlePublicSwapRewards(swapFeeHook.weth(), type(uint256).max);
        assertGt(_claimWeth(old.position), 0);
        assertEq(globalRewards.unfundedSwapRewards(swapFeeHook.weth()), 0);
    }

    function _claimWeth(uint256 position) private returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = swapFeeHook.weth();
        vm.prank(alice);
        uint256[] memory claimed = globalRewards.claimRewards(position, assets, alice, new uint256[](1));
        return claimed[0];
    }

    function _openLegacyStakeAndPosition() private returns (LegacyPosition memory old) {
        address stakeToken = globalRewards.stakingToken();
        address[] memory assets = new address[](1);
        assets[0] = swapFeeHook.weth();
        deal(stakeToken, alice, 10 ether);
        vm.startPrank(alice);
        IERC20(stakeToken).approve(DIAMOND, 10 ether);
        old.position = globalRewards.createAndStake{value: IStaticsPositionFees(DIAMOND).positionCreationFee()}(
            10 ether, alice, assets
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        old.poolId = _oldId(0);
        PoolKey memory key = pools.protocolPool(old.poolId).key;
        address paired = Currency.unwrap(key.currency1);
        // USDG uses 6 decimals and bounded balances; seed only the local wallet.
        deal(paired, alice, 1_000_000e6);
        vm.prank(alice);
        IERC20(paired).approve(DIAMOND, 1_000_000e6);
        IStaticsRangeGauge gauges = IStaticsRangeGauge(DIAMOND);
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory opened = gauges.provideLiquidity{value: 1 ether}(
            old.position,
            IStaticsRangeGauge.ProvideLiquidityParams(
                old.poolId,
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                1e12,
                1 ether,
                1_000_000e6,
                block.timestamp
            )
        );
        old.manager = gauges.lpLeg(old.position, old.poolId).manager;
        old.posmTokenId = opened.posmTokenId;
        old.sequence = IStaticsMarketTape(DIAMOND).canonicalMarketState(old.poolId).sequence;
        vm.prank(alice);
        v4Router.swap{value: 0.001 ether}(key, SwapParams(true, -int256(0.001 ether), TickMath.MIN_SQRT_PRICE + 1));
        assertGt(swapFeeHook.pendingStakerRewards(Currency.wrap(address(0))), 0);
        old.pending = globalRewards.unfundedSwapRewards(swapFeeHook.weth());
        assertGt(old.pending, 0);
    }

    function _oldId(uint256 i) private view returns (PoolId) {
        return PoolId.wrap(vm.parseJsonBytes32(fixture, string.concat(".legacyPools[", vm.toString(i), "].poolId")));
    }

    function _claims(PoolKey memory key) private view returns (bytes32) {
        return
            keccak256(abi.encode(swapFeeHook.claimLiability(key.currency0), swapFeeHook.claimLiability(key.currency1)));
    }

    function _newGeneralFlow() private {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams(
            address(0),
            address(assetA),
            3_000,
            10,
            1 << 96,
            IStaticsProtocolPools.PoolSwapFeeRate(2_500, 2_500),
            owner,
            false,
            0,
            type(uint256).max
        );
        vm.prank(alice);
        vm.expectRevert();
        pools.createPool(params, "");
        vm.prank(owner);
        PoolId id = pools.createPool(params, "");
        PoolKey memory key = pools.protocolPool(id).key;
        assertEq(address(key.hooks), address(swapFeeHook));
        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(address(key.hooks)));
        assertEq(hook.staticsDiamond(), DIAMOND);
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.weth(), swapFeeHook.weth());
        assertTrue(hook.poolRegistration(id).registered);
        assertEq(hook.poolRegistration(id).creator, owner);
        assetA.mint(alice, 1 ether);
        vm.prank(alice);
        assetA.approve(address(v4Router), 1 ether);
        vm.prank(alice);
        v4Router.modifyLiquidity{value: 0.2 ether}(
            key, ModifyLiquidityParams(-887270, 887270, int256(0.2 ether), bytes32(0))
        );
        vm.prank(alice);
        v4Router.swap{value: 0.01 ether}(key, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        vm.prank(alice);
        v4Router.swap(key, SwapParams(false, -int256(0.005 ether), TickMath.MAX_SQRT_PRICE - 1));
        assertGt(IStaticsSwapFeeHook(address(key.hooks)).claimLiability(Currency.wrap(address(0))), 0);
        pools.settleProtocolPoolRevenue(id, address(0));
        assertGe(IERC20(swapFeeHook.weth()).balanceOf(DIAMOND), custody.globalReservedByToken(swapFeeHook.weth()));
    }

    function _record(string memory name, address deployed, bytes memory args, bytes memory creation) private {
        if (bytes(evidenceOutput).length == 0) return;
        string memory object = string.concat("contract-", name);
        vm.serializeAddress(object, "address", deployed);
        vm.serializeBytes(object, "constructorArgs", args);
        vm.serializeBytes32(object, "creationKeccak", keccak256(creation));
        vm.serializeBytes32(object, "initCodeKeccak", keccak256(bytes.concat(creation, args)));
        vm.serializeBytes32(object, "runtimeKeccak", deployed.codehash);
        string memory item = vm.serializeBytes(object, "runtime", deployed.code);
        vm.writeJson(item, evidenceOutput, string.concat(".contracts.", name));
    }

    function _recordFacets(StaticsProtocolParts memory parts) private {
        if (bytes(evidenceOutput).length == 0) return;
        IDiamondCut.FacetCut[] memory desired = StaticsProtocolPlan.cumulative(parts, 2);
        for (uint256 i; i < desired.length; ++i) {
            string memory name = string.concat("facet-", vm.toString(i));
            vm.serializeAddress(name, "address", desired[i].facetAddress);
            vm.serializeBytes32(name, "runtimeKeccak", desired[i].facetAddress.codehash);
            string[] memory selectors = new string[](desired[i].functionSelectors.length);
            for (uint256 j; j < selectors.length; ++j) {
                selectors[j] = vm.toString(abi.encodePacked(desired[i].functionSelectors[j]));
            }
            vm.serializeString(name, "selectors", selectors);
            string memory item = vm.serializeUint(name, "runtimeBytes", desired[i].facetAddress.code.length);
            vm.writeJson(item, evidenceOutput, string.concat(".contracts.", name));
        }
    }

    function _startEvidence() private {
        evidenceOutput = vm.envOr("STATICS_PUBLIC_HOOK_REPORT", string(""));
        if (bytes(evidenceOutput).length == 0) return;
        vm.serializeJson("dry-run", '{"contracts":{},"completed":false}');
        vm.serializeString("dry-run", "kind", "local-fork-simulation");
        vm.serializeString("dry-run", "sourceCommit", vm.envString("STATICS_RELEASE_COMMIT"));
        vm.serializeUint("dry-run", "chainId", block.chainid);
        vm.serializeUint("dry-run", "forkBlock", BLOCK);
        vm.serializeAddress("dry-run", "diamond", DIAMOND);
        vm.serializeAddress("dry-run", "owner", owner);
        string memory result = vm.serializeBool("dry-run", "prepared", true);
        vm.writeJson(result, evidenceOutput);
    }

    function _newBasketFlow() private returns (address token) {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory launch, uint256[] memory maxAmounts) =
            _fundDefaultLaunch(params.assets, owner);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PermissionlessPoolCreationDisabled()"));
        baskets.createBasket(params, launch, maxAmounts, type(uint256).max);
        uint256 activationFee = pools.protocolPolActivationFee() * launch.length;
        vm.deal(owner, owner.balance + activationFee);
        vm.prank(owner);
        (uint256 id, address deployedToken) =
            baskets.createBasket{value: activationFee}(params, launch, maxAmounts, type(uint256).max);
        token = deployedToken;
        assertEq(baskets.basket(id).token, token);
        assertGt(token.code.length, 0);
        assertEq(StaticsBasketToken(token).protocol(), DIAMOND);
        assertEq(StaticsBasketToken(token).basketId(), id);
        assertEq(address(StaticsBasketToken(token).poolManager()), address(poolManager));
        _record(
            "StaticsBasketToken",
            token,
            abi.encode(params.name, params.symbol, DIAMOND, id, poolManager),
            type(StaticsBasketToken).creationCode
        );
        for (uint256 i; i < params.assets.length; ++i) {
            PoolKey memory key = pools.protocolPool(basketLiquidity.canonicalPool(id, params.assets[i]).poolId).key;
            StaticsBasketHook hook = StaticsBasketHook(payable(address(key.hooks)));
            assertEq(hook.staticsDiamond(), DIAMOND);
            assertEq(address(hook.poolManager()), address(poolManager));
            assertEq(hook.weth(), swapFeeHook.weth());
            PoolId poolId = basketLiquidity.canonicalPool(id, params.assets[i]).poolId;
            assertTrue(hook.poolRegistration(poolId).registered);
            assertEq(hook.poolRegistration(poolId).creator, owner);
        }
        IStaticsBasketLiquidity.CanonicalPoolView memory market = basketLiquidity.canonicalPool(id, address(assetA));
        assertTrue(address(pools.protocolPool(market.poolId).key.hooks) != address(swapFeeHook));
        _fundAndApprove(alice, 10 ether, 30 ether);
        uint256[] memory amounts = baskets.quoteMint(id, 1 ether);
        vm.prank(alice);
        baskets.mint(id, 1 ether, alice, amounts);
        vm.prank(alice);
        baskets.redeem(id, 0.1 ether, alice, new uint256[](2));
        assertGe(IERC20(token).balanceOf(DIAMOND), custody.globalReservedByToken(token));
    }
}
