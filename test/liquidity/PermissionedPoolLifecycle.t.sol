// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ERC721PermitHash} from "@uniswap/v4-periphery/src/libraries/ERC721PermitHash.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

import {PermissionedPoolAdminFacet} from "../../src/facets/PermissionedPoolAdminFacet.sol";
import {PermissionedPoolCreationFacet} from "../../src/facets/PermissionedPoolCreationFacet.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPermissionedPools} from "../../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedRouter} from "../../src/interfaces/IStaticsPermissionedRouter.sol";
import {IStaticsPermissionedSwapFeeHook} from "../../src/interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {IVenueController} from "../../src/interfaces/IVenueController.sol";
import {StaticsPermissionedSwapFeeHook} from "../../src/liquidity/StaticsPermissionedSwapFeeHook.sol";
import {DefaultVenueController} from "../../src/permissioned/DefaultVenueController.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

interface IPermissionedPositionClaimsTest {
    function forceUnwind(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) external;
    function claim(PoolId poolId, Currency currency, address receiver, uint256 amount) external;
    function creditOf(PoolId poolId, address owner, Currency currency) external view returns (uint256 amount);
}

interface IPermissionedPositionManagerTest is IPositionManager {
    error PositionTransferDisabled();
    error PositionOwnerNotEligible(PoolId poolId, address owner);

    function ownerOf(uint256 tokenId) external view returns (address owner);
    function approve(address spender, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function positionClaims() external view returns (address claims);
}

contract RevertingBurnSubscriber is ISubscriber {
    error BurnRejected();

    function notifySubscribe(uint256, bytes memory) external pure {}
    function notifyUnsubscribe(uint256) external pure {}

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {
        revert BurnRejected();
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external pure {}
}

contract MockReceiverRestrictedERC20 is ERC20 {
    address public blockedReceiver;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setBlockedReceiver(address receiver) external {
        blockedReceiver = receiver;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == blockedReceiver) revert("RECEIVER_RESTRICTED");
        super._update(from, to, value);
    }
}

contract BreakableVenueController is IVenueController, IERC165 {
    address public override operator;
    bool public broken;
    TradingStatus private poolTradingStatus;

    error BrokenController();
    error OnlyOperator(address caller);

    constructor(address operator_) {
        operator = operator_;
    }

    function breakController() external {
        if (msg.sender != operator) revert OnlyOperator(msg.sender);
        broken = true;
    }

    function setPoolStatus(TradingStatus status_) external {
        if (msg.sender != operator) revert OnlyOperator(msg.sender);
        poolTradingStatus = status_;
    }

    function permissions(PoolId, address) external view returns (uint256 flags) {
        _enforceWorking();
        return 0;
    }

    function assetStatus(address) external view returns (TradingStatus status) {
        _enforceWorking();
        return TradingStatus.Active;
    }

    function poolStatus(PoolId) external view returns (TradingStatus status) {
        _enforceWorking();
        return poolTradingStatus;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVenueController).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _enforceWorking() private view {
        if (broken) revert BrokenController();
    }
}

/// @notice Real PoolManager lifecycle coverage for the separate permissioned market primitive.
contract PermissionedPoolLifecycleTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    uint160 private constant PERMISSIONED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    uint256 private constant BPS = 10_000;
    uint256 private constant SWAP_ALLOWED = 1 << 0;
    uint256 private constant LIQUIDITY_ALLOWED = 1 << 1;
    uint256 private constant POSITION_MANAGER_SIZE_LIMIT = 24_576 - 1_024;

    IStaticsPermissionedPools private permissionedPools;
    IStaticsProtocolPools private protocolPools;
    IStaticsProtocolRevenue private revenue;
    IStaticsRewardPolicy private rewardPolicy;
    StaticsPermissionedSwapFeeHook private permissionedHook;
    IStaticsPermissionedRouter private permissionedRouter;
    IPermissionedPositionManagerTest private permissionedPositionManager;
    IPermissionedPositionClaimsTest private positionClaims;
    IAllowanceTransfer private permit2;
    V4Quoter private quoter;

    uint256 private creatorKey;
    address private creator;
    address private lp = makeAddr("permissioned-lp");
    address private trader = makeAddr("permissioned-trader");

    function setUp() public override {
        super.setUp();
        (creator, creatorKey) = makeAddrAndKey("permissioned-creator");
        permissionedPools = IStaticsPermissionedPools(address(diamond));
        protocolPools = IStaticsProtocolPools(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        rewardPolicy = IStaticsRewardPolicy(address(diamond));

        bytes memory constructorArgs = abi.encode(poolManager, address(diamond));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), PERMISSIONED_HOOK_FLAGS, type(StaticsPermissionedSwapFeeHook).creationCode, constructorArgs
        );
        permissionedHook = new StaticsPermissionedSwapFeeHook{salt: salt}(poolManager, address(diamond));
        assertEq(address(permissionedHook), expected);

        permit2 = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        permissionedRouter = IStaticsPermissionedRouter(
            deployCode(
                "out/StaticsPermissionedRouter.sol/StaticsPermissionedRouter.json",
                abi.encode(poolManager, permit2, address(permissionedHook))
            )
        );
        permissionedPositionManager = IPermissionedPositionManagerTest(
            deployCode(
                "out/StaticsPermissionedPositionManager.sol/StaticsPermissionedPositionManager.json",
                abi.encode(
                    poolManager,
                    permit2,
                    uint256(100_000),
                    IPositionDescriptor(address(0)),
                    IWETH9(address(0)),
                    permissionedHook
                )
            )
        );
        positionClaims = IPermissionedPositionClaimsTest(permissionedPositionManager.positionClaims());
        quoter = new V4Quoter(poolManager);

        basketLiquidity.installPermissionedPoolIntegration(
            address(permissionedHook),
            address(permissionedRouter),
            address(permissionedPositionManager),
            address(quoter)
        );
        permissionedPools.setPermissionedTrustedPeriphery(address(permissionedRouter), true);
        permissionedPools.setPermissionedTrustedPeriphery(address(permissionedPositionManager), true);
        permissionedPools.setPermissionedTrustedPeriphery(address(quoter), true);
    }

    function testRewardableOutputRoutesDefaultEightyTenTenByPool() public {
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Permissioned A", "pA", 18)),
            address(new MockERC20("Permissioned B", "pB", 18)),
            3_000,
            100
        );
        uint256 tokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        assertEq(permissionedPositionManager.ownerOf(tokenId), lp);

        address output = Currency.unwrap(key.currency1);
        _stakeForReward(trader, output);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(output);
        uint256 rewardBefore = globalRewards.rewardAsset(output).indexedReserve;
        _swapForOutput(key, controller, trader, output, 1 ether);

        uint256 creatorAmount = revenue.creatorRevenue(poolId, output);
        uint256 treasuryAmount = globalRewards.treasuryAccrued(output) - treasuryBefore;
        uint256 rewardAmount = globalRewards.rewardAsset(output).indexedReserve - rewardBefore;
        uint256 fee = creatorAmount + treasuryAmount + rewardAmount;
        assertGt(fee, 0);
        assertEq(creatorAmount, fee * 8_000 / BPS);
        assertEq(rewardAmount, fee * 1_000 / BPS);
        assertEq(treasuryAmount, fee - creatorAmount - rewardAmount);
        assertEq(swapFeeHook.lockedLiquidity(poolId), 0);
    }

    function testBothRestrictedCurrenciesRouteEightyCreatorTwentyTreasury() public {
        address tokenA = address(new MockERC20("Restricted A", "rA", 18));
        address tokenB = address(new MockERC20("Restricted B", "rB", 18));
        rewardPolicy.addRewardRestriction(tokenA);
        rewardPolicy.addRewardRestriction(tokenB);
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory customEconomics = _economics(100, 7_000, 2_000, 1_000);
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) =
            _createPool(tokenA, tokenB, 3_000, customEconomics);
        _mintFullRangePosition(key, controller, lp, 20 ether);

        address output = Currency.unwrap(key.currency1);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(output);
        _swapForOutput(key, controller, trader, output, 1 ether);

        uint256 creatorAmount = revenue.creatorRevenue(poolId, output);
        uint256 treasuryAmount = globalRewards.treasuryAccrued(output) - treasuryBefore;
        uint256 fee = creatorAmount + treasuryAmount;
        assertGt(fee, 0);
        assertEq(creatorAmount, fee * 8_000 / BPS);
        assertEq(treasuryAmount, fee - creatorAmount);
        assertEq(globalRewards.rewardAsset(tokenA).indexedReserve, 0);
        assertEq(globalRewards.rewardAsset(tokenB).indexedReserve, 0);
    }

    function testCreatorMaskAddsRestrictionWithoutProtocolClassification() public {
        address tokenA = address(new MockERC20("Creator Restricted", "CRS", 18));
        address tokenB = address(new MockERC20("Creator Reward", "CRW", 18));
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory economics = _economics(100, 8_000, 1_000, 1_000);
        economics.additionalRewardRestrictedMask = 2;
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) =
            _createPool(tokenA, tokenB, 3_000, economics);
        _mintFullRangePosition(key, controller, lp, 20 ether);

        address restrictedOutput = Currency.unwrap(key.currency1);
        address rewardablePair = Currency.unwrap(key.currency0);
        _stakeForReward(trader, rewardablePair);
        uint256 rewardBefore = globalRewards.rewardAsset(rewardablePair).indexedReserve;
        _swapForOutput(key, controller, trader, restrictedOutput, 1 ether);

        assertGt(revenue.creatorRevenue(poolId, restrictedOutput), 0);
        assertEq(globalRewards.rewardAsset(restrictedOutput).indexedReserve, 0);
        assertGt(globalRewards.rewardAsset(rewardablePair).indexedReserve - rewardBefore, 0);
        assertFalse(rewardPolicy.rewardRestricted(restrictedOutput));
    }

    function testPublicAndPermissionedMarketsForSamePairRemainDistinct() public {
        address tokenA = address(new MockERC20("Parallel A", "pA", 18));
        address tokenB = address(new MockERC20("Parallel B", "pB", 18));
        IStaticsProtocolPools.CreatePoolParams memory publicParams = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            lpFee: 3_000,
            tickSpacing: 10,
            sqrtPriceBPerAX96: 1 << 96,
            creator: creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        PoolId publicPoolId = protocolPools.createPool(publicParams, "");
        (PoolId permissionedPoolId, PoolKey memory permissionedKey,) = _createDefaultPool(tokenA, tokenB, 3_000, 100);

        IStaticsProtocolPools.ProtocolPoolView memory publicPool = protocolPools.protocolPool(publicPoolId);
        IStaticsProtocolPools.ProtocolPoolView memory permissionedPool = protocolPools.protocolPool(permissionedPoolId);
        assertNotEq(PoolId.unwrap(publicPoolId), PoolId.unwrap(permissionedPoolId));
        assertEq(address(publicPool.key.hooks), address(swapFeeHook));
        assertEq(address(permissionedKey.hooks), address(permissionedHook));
        assertEq(uint256(publicPool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.General));
        assertEq(uint256(permissionedPool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral));
    }

    function testPermissionedRevenueAuthenticatesItsHookAndRejectsBasketShare() public {
        (PoolId poolId, PoolKey memory key,) = _createDefaultPool(
            address(new MockERC20("Revenue A", "rA", 18)), address(new MockERC20("Revenue B", "rB", 18)), 3_000, 100
        );
        address asset = Currency.unwrap(key.currency0);
        IStaticsProtocolRevenue.ProtocolFeeDistribution memory distribution =
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                basketStaker: 0, staticsStaker: 0, creator: 100, treasury: 0
            });

        MockERC20(asset).mint(address(swapFeeHook), 100);
        vm.prank(address(swapFeeHook));
        IERC20(asset).approve(address(diamond), 100);
        vm.prank(address(swapFeeHook));
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolRevenueFacet.OnlySwapFeeHook.selector, address(swapFeeHook), address(permissionedHook)
            )
        );
        revenue.routeProtocolSwapFees(poolId, asset, distribution);

        distribution = IStaticsProtocolRevenue.ProtocolFeeDistribution({
            basketStaker: 100, staticsStaker: 0, creator: 0, treasury: 0
        });
        MockERC20(asset).mint(address(permissionedHook), 100);
        vm.prank(address(permissionedHook));
        IERC20(asset).approve(address(diamond), 100);
        vm.prank(address(permissionedHook));
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolRevenueFacet.GeneralPoolBasketReward.selector, poolId, uint256(100))
        );
        revenue.routeProtocolSwapFees(poolId, asset, distribution);
    }

    function testPhaseOneGeneralTermsRejectBasketShareWhileHookRemainsPhaseTwoReady() public {
        (PoolId poolId,,) = _createDefaultPool(
            address(new MockERC20("Permissioned A", "pA", 18)),
            address(new MockERC20("Permissioned B", "pB", 18)),
            3_000,
            100
        );
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory basketEconomics =
            IStaticsPermissionedSwapFeeHook.PoolEconomics({
                venueFeeBps: 100,
                additionalRewardRestrictedMask: 0,
                allocation: IStaticsPermissionedSwapFeeHook.FeeAllocation({
                    creatorShareBps: 8_000,
                    treasuryShareBps: 1_000,
                    staticsStakerShareBps: 500,
                    basketStakerShareBps: 500
                })
            });

        vm.expectRevert(PermissionedPoolAdminFacet.InvalidEconomics.selector);
        permissionedPools.applyPermissionedPoolTerms(
            poolId, basketEconomics, 0, block.timestamp + 1 days, keccak256("phase-two-basket-terms"), ""
        );

        vm.prank(address(diamond));
        permissionedHook.setPoolEconomics(poolId, basketEconomics);
        assertEq(permissionedHook.poolEconomics(poolId).allocation.basketStakerShareBps, 500);
    }

    function testUntrustedRouterCannotImpersonateApprovedTrader() public {
        (, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Untrusted A", "uA", 18)), address(new MockERC20("Untrusted B", "uB", 18)), 3_000, 100
        );
        _mintFullRangePosition(key, controller, lp, 20 ether);
        _setPermissions(controller, key.toId(), trader, SWAP_ALLOWED);
        address input = Currency.unwrap(key.currency0);
        MockERC20(input).mint(trader, 1 ether);
        _approveV4Router(trader, input);

        vm.prank(trader);
        vm.expectRevert();
        v4Router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        );
    }

    function testRestrictedOutputNormalizesOnlyStakerShareIntoRewardablePair() public {
        address restricted = address(new MockERC20("Restricted", "RST", 18));
        address rewardable = address(new MockERC20("Rewardable", "RWD", 18));
        rewardPolicy.addRewardRestriction(restricted);
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) =
            _createDefaultPool(restricted, rewardable, 3_000, 100);
        _mintFullRangePosition(key, controller, lp, 20 ether);
        _stakeForReward(trader, rewardable);

        uint256 treasuryBefore = globalRewards.treasuryAccrued(restricted);
        uint256 rewardBefore = globalRewards.rewardAsset(rewardable).indexedReserve;
        _swapForOutput(key, controller, trader, restricted, 1 ether);

        uint256 creatorAmount = revenue.creatorRevenue(poolId, restricted);
        uint256 treasuryAmount = globalRewards.treasuryAccrued(restricted) - treasuryBefore;
        uint256 normalizedReward = globalRewards.rewardAsset(rewardable).indexedReserve - rewardBefore;
        assertGt(creatorAmount, 0);
        assertGt(treasuryAmount, 0);
        assertGt(normalizedReward, 0);
        // The treasury receives every remainder from the 80/10/5/5 floor-rounded split.
        // This can move its 1:8 ratio to the creator share by at most 20 wei.
        assertApproxEqAbs(creatorAmount, treasuryAmount * 8, 20);
        assertEq(globalRewards.rewardAsset(restricted).indexedReserve, 0);
        assertEq(revenue.creatorRevenue(poolId, rewardable), 0);
    }

    function testPermissionsPositionOwnershipNativeFeesAndRiskReducingExit() public {
        address tokenA = address(new MockERC20("Access A", "aA", 18));
        address tokenB = address(new MockERC20("Access B", "aB", 18));
        (, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(tokenA, tokenB, 3_000, 100);

        _swapForOutput(key, controller, trader, Currency.unwrap(key.currency1), 1 ether, false);

        uint256 tokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        vm.prank(lp);
        vm.expectRevert(IPermissionedPositionManagerTest.PositionTransferDisabled.selector);
        permissionedPositionManager.transferFrom(lp, makeAddr("position-buyer"), tokenId);
        vm.prank(lp);
        vm.expectRevert(IPermissionedPositionManagerTest.PositionTransferDisabled.selector);
        permissionedPositionManager.safeTransferFrom(lp, makeAddr("safe-position-buyer"), tokenId);
        vm.prank(lp);
        vm.expectRevert(IPermissionedPositionManagerTest.PositionTransferDisabled.selector);
        permissionedPositionManager.safeTransferFrom(lp, makeAddr("data-position-buyer"), tokenId, "");

        _swapForOutput(key, controller, trader, Currency.unwrap(key.currency1), 1 ether);
        _swapForOutput(key, controller, trader, Currency.unwrap(key.currency0), 1 ether);

        uint256 feeBalance0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 feeBalance1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(lp);
        _decreasePosition(tokenId, key, lp, 0);
        assertTrue(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(lp) > feeBalance0Before
                || IERC20(Currency.unwrap(key.currency1)).balanceOf(lp) > feeBalance1Before,
            "native LP fee was not paid to the approved position owner"
        );

        _setPermissions(controller, key.toId(), lp, 0);
        vm.startPrank(lp);
        bytes memory increaseActions = abi.encodePacked(bytes1(uint8(Actions.INCREASE_LIQUIDITY)));
        bytes[] memory increaseParams = new bytes[](1);
        increaseParams[0] = abi.encode(tokenId, uint256(1 ether), uint128(10 ether), uint128(10 ether), bytes(""));
        vm.expectRevert();
        permissionedPositionManager.modifyLiquidities(
            abi.encode(increaseActions, increaseParams), block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 balance0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 balance1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(lp);
        _decreasePosition(tokenId, key, lp, permissionedPositionManager.getPositionLiquidity(tokenId));
        assertEq(permissionedPositionManager.getPositionLiquidity(tokenId), 0);
        assertTrue(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(lp) > balance0Before
                || IERC20(Currency.unwrap(key.currency1)).balanceOf(lp) > balance1Before
        );
    }

    function testRevokedOwnerCannotIncreaseThroughApprovedDelegateOrOperator() public {
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Delegated A", "dA", 18)), address(new MockERC20("Delegated B", "dB", 18)), 3_000, 100
        );
        address delegate = makeAddr("eligible-position-delegate");
        uint256 approvedTokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        uint256 operatorTokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        _setPermissions(controller, poolId, delegate, LIQUIDITY_ALLOWED);

        vm.startPrank(lp);
        permissionedPositionManager.approve(delegate, approvedTokenId);
        permissionedPositionManager.setApprovalForAll(delegate, true);
        vm.stopPrank();
        _setPermissions(controller, poolId, lp, 0);

        bytes memory expected =
            abi.encodeWithSelector(IPermissionedPositionManagerTest.PositionOwnerNotEligible.selector, poolId, lp);
        _increasePosition(approvedTokenId, key, delegate, 1 ether, expected);
        _increasePositionFromDeltas(operatorTokenId, key, delegate, 1 ether, expected);
    }

    function testRevokedOwnerCannotIncreaseThroughPermitDelegateOrOperator() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitted-position-owner");
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Permit A", "pA", 18)), address(new MockERC20("Permit B", "pB", 18)), 3_000, 100
        );
        address delegate = makeAddr("eligible-permit-delegate");
        uint256 permitTokenId = _mintFullRangePosition(key, controller, owner, 20 ether);
        uint256 permitForAllTokenId = _mintFullRangePosition(key, controller, owner, 20 ether);
        _setPermissions(controller, poolId, delegate, LIQUIDITY_ALLOWED);
        _permitPosition(ownerKey, delegate, permitTokenId, 71);
        _permitAllPositions(ownerKey, owner, delegate, 72);
        _setPermissions(controller, poolId, owner, 0);

        bytes memory expected =
            abi.encodeWithSelector(IPermissionedPositionManagerTest.PositionOwnerNotEligible.selector, poolId, owner);
        _increasePosition(permitTokenId, key, delegate, 1 ether, expected);
        _increasePositionFromDeltas(permitForAllTokenId, key, delegate, 1 ether, expected);
    }

    function testEligibleOwnerAndDelegateCanIncreaseWhileRevokedOwnerCanExit() public {
        (PoolId poolId, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Eligible A", "eA", 18)), address(new MockERC20("Eligible B", "eB", 18)), 3_000, 100
        );
        address delegate = makeAddr("eligible-owner-delegate");
        uint256 tokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        _setPermissions(controller, poolId, delegate, LIQUIDITY_ALLOWED);
        vm.prank(lp);
        permissionedPositionManager.approve(delegate, tokenId);

        uint128 initialLiquidity = permissionedPositionManager.getPositionLiquidity(tokenId);
        _increasePosition(tokenId, key, delegate, 1 ether);
        uint128 afterDirectIncrease = permissionedPositionManager.getPositionLiquidity(tokenId);
        assertGt(afterDirectIncrease, initialLiquidity);
        _increasePositionFromDeltas(tokenId, key, delegate, 1 ether);
        assertGt(permissionedPositionManager.getPositionLiquidity(tokenId), afterDirectIncrease);

        _swapForOutput(key, controller, trader, Currency.unwrap(key.currency1), 1 ether);
        _setPermissions(controller, poolId, lp, 0);
        uint256 balance0BeforeCollection = IERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 balance1BeforeCollection = IERC20(Currency.unwrap(key.currency1)).balanceOf(lp);
        _collectPositionFees(tokenId, key, lp);
        assertTrue(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(lp) > balance0BeforeCollection
                || IERC20(Currency.unwrap(key.currency1)).balanceOf(lp) > balance1BeforeCollection
        );
        _swapForOutput(key, controller, trader, Currency.unwrap(key.currency1), 1 ether);
        _collectPositionFeesFromDeltas(tokenId, key, lp);
        _decreasePosition(tokenId, key, lp, 0);
        _decreasePosition(tokenId, key, lp, permissionedPositionManager.getPositionLiquidity(tokenId));
        _burnPosition(tokenId, key, lp);
        vm.expectRevert();
        permissionedPositionManager.ownerOf(tokenId);
    }

    function testExternalExactOutputIsRejected() public {
        (, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Exact A", "eA", 18)), address(new MockERC20("Exact B", "eB", 18)), 3_000, 100
        );
        _mintFullRangePosition(key, controller, lp, 20 ether);
        _setPermissions(controller, key.toId(), trader, SWAP_ALLOWED);

        vm.prank(trader);
        vm.expectRevert();
        quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: 0.1 ether, hookData: ""})
        );
    }

    function testPoolAndAssetHaltsBlockExposureButPreserveOwnerExit() public {
        (, PoolKey memory key, DefaultVenueController controller) = _createDefaultPool(
            address(new MockERC20("Halt A", "hA", 18)), address(new MockERC20("Halt B", "hB", 18)), 3_000, 100
        );
        uint256 tokenId = _mintFullRangePosition(key, controller, lp, 20 ether);
        _setPermissions(controller, key.toId(), trader, SWAP_ALLOWED);
        address input = Currency.unwrap(key.currency0);
        MockERC20(input).mint(trader, 1 ether);
        _approvePermit2(trader, input, address(permissionedRouter), 1 ether);

        vm.prank(creator);
        controller.setAssetStatus(Currency.unwrap(key.currency1), IVenueController.TradingStatus.Halted);
        vm.prank(trader);
        vm.expectRevert();
        permissionedRouter.swapExactInputSingle(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1 ether, amountOutMinimum: 0, hookData: ""
            }),
            block.timestamp + 1 hours
        );

        vm.startPrank(creator);
        controller.setAssetStatus(Currency.unwrap(key.currency1), IVenueController.TradingStatus.Active);
        controller.setPoolStatus(key.toId(), IVenueController.TradingStatus.Halted);
        vm.stopPrank();
        vm.startPrank(lp);
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.INCREASE_LIQUIDITY)));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, uint256(1 ether), uint128(10 ether), uint128(10 ether), bytes(""));
        vm.expectRevert();
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
        vm.stopPrank();

        _decreasePosition(tokenId, key, lp, permissionedPositionManager.getPositionLiquidity(tokenId));
        assertEq(permissionedPositionManager.getPositionLiquidity(tokenId), 0);
    }

    function testCreatorAuthorizedTermsRequireOwnerExecutionAndConsumeNonce() public {
        (PoolId poolId, PoolKey memory key,) = _createDefaultPool(
            address(new MockERC20("Terms A", "tA", 18)), address(new MockERC20("Terms B", "tB", 18)), 500, 100
        );
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory changed = _economics(250, 7_000, 2_000, 1_000);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("issuer-sla-amendment");
        bytes32 digest = permissionedPools.permissionedTermsDigest(poolId, changed, 0, deadline, agreementHash);
        bytes memory authorization = _sign(creatorKey, digest);

        vm.prank(creator);
        vm.expectRevert();
        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, authorization);

        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, authorization);
        IStaticsPermissionedPools.PermissionedPoolView memory configured = permissionedPools.permissionedPool(poolId);
        assertEq(configured.economics.venueFeeBps, 250);
        assertEq(configured.economics.allocation.creatorShareBps, 7_000);
        assertEq(configured.configurationNonce, 1);
        assertEq(configured.key.fee, key.fee);

        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolAdminFacet.InvalidConfigurationNonce.selector, poolId, uint256(1), uint256(0)
            )
        );
        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, authorization);
    }

    function testCreatorAuthorizedControllerReplacementStartsHaltedAndConsumesNonce() public {
        (PoolId poolId, PoolKey memory key, DefaultVenueController oldController) = _createDefaultPool(
            address(new MockERC20("Controller A", "cA", 18)), address(new MockERC20("Controller B", "cB", 18)), 500, 100
        );
        _mintFullRangePosition(key, oldController, lp, 20 ether);
        DefaultVenueController newController = new DefaultVenueController(creator);
        vm.prank(creator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("controller-provider-migration");
        bytes memory authorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, creatorKey
        );

        vm.prank(creator);
        vm.expectRevert();
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, authorization
        );

        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, authorization
        );
        IStaticsPermissionedPools.PermissionedPoolView memory configured = permissionedPools.permissionedPool(poolId);
        assertEq(configured.controller, address(newController));
        assertEq(configured.configurationNonce, 1);
        assertEq(permissionedHook.poolRegistration(poolId).controller, address(newController));

        _setPermissions(oldController, poolId, trader, SWAP_ALLOWED);
        _swapForOutput(key, oldController, trader, Currency.unwrap(key.currency1), 1 ether, false);

        _setPermissions(newController, poolId, trader, SWAP_ALLOWED);
        vm.prank(creator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Active);
        _swapForOutput(key, newController, trader, Currency.unwrap(key.currency1), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolAdminFacet.InvalidConfigurationNonce.selector, poolId, uint256(1), uint256(0)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, authorization
        );
    }

    function testControllerReplacementRejectsUnsafeOrStaleTargets() public {
        (PoolId poolId,, DefaultVenueController oldController) = _createDefaultPool(
            address(new MockERC20("Guard A", "gA", 18)), address(new MockERC20("Guard B", "gB", 18)), 500, 100
        );
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("guarded-controller-migration");
        DefaultVenueController activeController = new DefaultVenueController(creator);
        bytes memory activeAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(activeController), 0, deadline, agreementHash, creatorKey
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsPermissionedSwapFeeHook.ControllerPoolNotHalted.selector, poolId, address(activeController)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(activeController), 0, deadline, agreementHash, activeAuthorization
        );

        BreakableVenueController zeroOperator = new BreakableVenueController(address(0));
        bytes memory zeroOperatorAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(zeroOperator), 0, deadline, agreementHash, creatorKey
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsPermissionedSwapFeeHook.InvalidControllerOperator.selector, address(zeroOperator)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(zeroOperator), 0, deadline, agreementHash, zeroOperatorAuthorization
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolAdminFacet.UnexpectedPoolController.selector,
                poolId,
                address(activeController),
                address(oldController)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(activeController), address(oldController), 0, deadline, agreementHash, ""
        );
    }

    function testControllerReplacementRejectsUnauthorizedInvalidAndDecommissionedChanges() public {
        (PoolId poolId,, DefaultVenueController oldController) = _createDefaultPool(
            address(new MockERC20("Reject A", "rjA", 18)), address(new MockERC20("Reject B", "rjB", 18)), 500, 100
        );
        DefaultVenueController newController = new DefaultVenueController(creator);
        vm.prank(creator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("rejected-controller-migration");

        vm.expectRevert(
            abi.encodeWithSelector(PermissionedPoolAdminFacet.InvalidCreatorAuthorization.selector, creator)
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(PermissionedPoolAdminFacet.DeadlineExpired.selector, block.timestamp - 1)
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, block.timestamp - 1, agreementHash, ""
        );

        bytes memory sameAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(oldController), 0, deadline, agreementHash, creatorKey
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsPermissionedSwapFeeHook.ControllerAlreadySet.selector, poolId, address(oldController)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(oldController), 0, deadline, agreementHash, sameAuthorization
        );

        MockERC20 invalidController = new MockERC20("Not Controller", "NO", 18);
        bytes memory invalidAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(invalidController), 0, deadline, agreementHash, creatorKey
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsPermissionedSwapFeeHook.InvalidController.selector, address(invalidController)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(invalidController), 0, deadline, agreementHash, invalidAuthorization
        );

        vm.expectRevert(
            abi.encodeWithSelector(StaticsPermissionedSwapFeeHook.OnlyStaticsDiamond.selector, address(this))
        );
        permissionedHook.setPoolController(poolId, address(newController));

        permissionedPools.decommissionPermissionedPool(poolId);
        bytes memory decommissionedAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, creatorKey
        );
        vm.expectRevert(abi.encodeWithSelector(PermissionedPoolAdminFacet.PoolAlreadyDecommissioned.selector, poolId));
        permissionedPools.replacePermissionedPoolController(
            poolId,
            address(oldController),
            address(newController),
            0,
            deadline,
            agreementHash,
            decommissionedAuthorization
        );
    }

    function testControllerReplacementDoesNotCallBrokenOldController() public {
        BreakableVenueController oldController = new BreakableVenueController(creator);
        (PoolId poolId,) = _createPoolWithController(
            address(new MockERC20("Broken A", "bA", 18)),
            address(new MockERC20("Broken B", "bB", 18)),
            500,
            _economics(100, 8_000, 1_000, 1_000),
            address(oldController)
        );
        vm.prank(creator);
        oldController.breakController();
        DefaultVenueController newController = new DefaultVenueController(creator);
        vm.prank(creator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("broken-controller-recovery");

        permissionedPools.replacePermissionedPoolController(
            poolId,
            address(oldController),
            address(newController),
            0,
            deadline,
            agreementHash,
            _controllerReplacementAuthorization(
                poolId, address(oldController), address(newController), 0, deadline, agreementHash, creatorKey
            )
        );
        assertEq(permissionedPools.permissionedPool(poolId).controller, address(newController));
    }

    function testTermsAndControllerReplacementShareConfigurationNonce() public {
        (PoolId poolId,, DefaultVenueController oldController) = _createDefaultPool(
            address(new MockERC20("Shared A", "sA", 18)), address(new MockERC20("Shared B", "sB", 18)), 500, 100
        );
        DefaultVenueController newController = new DefaultVenueController(creator);
        vm.prank(creator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("shared-configuration-sequence");
        bytes memory replacementAuthorization = _controllerReplacementAuthorization(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, creatorKey
        );
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory changed = _economics(90, 7_500, 1_500, 1_000);
        bytes memory termsAuthorization =
            _sign(creatorKey, permissionedPools.permissionedTermsDigest(poolId, changed, 0, deadline, agreementHash));
        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, termsAuthorization);

        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolAdminFacet.InvalidConfigurationNonce.selector, poolId, uint256(1), uint256(0)
            )
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, address(oldController), address(newController), 0, deadline, agreementHash, replacementAuthorization
        );
    }

    function testErc1271CreatorCanAuthorizeCreationTermsAndControllerReplacement() public {
        (address walletOwner, uint256 walletOwnerKey) = makeAddrAndKey("permissioned-wallet-owner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        DefaultVenueController controller = new DefaultVenueController(walletOwner);
        IStaticsPermissionedPools.CreatePermissionedPoolParams memory params =
            IStaticsPermissionedPools.CreatePermissionedPoolParams({
                tokenA: address(new MockERC20("Wallet A", "wA", 18)),
                tokenB: address(new MockERC20("Wallet B", "wB", 18)),
                lpFee: 500,
                tickSpacing: 10,
                sqrtPriceBPerAX96: 1 << 96,
                creator: address(wallet),
                controller: address(controller),
                economics: _economics(100, 8_000, 1_000, 1_000),
                authorizationNonce: 9,
                deadline: block.timestamp + 1 days,
                agreementHash: keccak256("wallet-initial-terms")
            });
        IStaticsPermissionedPools.PermissionedPoolQuote memory quote = permissionedPools.quotePermissionedPool(params);
        PoolId poolId =
            permissionedPools.createPermissionedPool(params, _sign(walletOwnerKey, quote.authorizationDigest));
        assertEq(permissionedPools.permissionedPool(poolId).creator, address(wallet));
        _applyWalletTerms(poolId, walletOwnerKey);
        assertEq(permissionedPools.permissionedPool(poolId).economics.allocation.creatorShareBps, 7_500);
        _applyWalletControllerReplacement(poolId, controller, walletOwner, walletOwnerKey);
    }

    function testTermsAuthorizationRejectsWrongChainAndInvalidatedNonce() public {
        (PoolId poolId,,) = _createDefaultPool(
            address(new MockERC20("Domain A", "dA", 18)), address(new MockERC20("Domain B", "dB", 18)), 500, 100
        );
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory changed = _economics(90, 7_500, 1_500, 1_000);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("domain-bound-terms");
        bytes memory authorization =
            _sign(creatorKey, permissionedPools.permissionedTermsDigest(poolId, changed, 0, deadline, agreementHash));

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedPoolAdminFacet.InvalidCreatorAuthorization.selector, creator)
        );
        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, authorization);
        vm.chainId(originalChainId);

        vm.prank(creator);
        permissionedPools.invalidatePermissionedConfigurationNonce(poolId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolAdminFacet.InvalidConfigurationNonce.selector, poolId, uint256(1), uint256(0)
            )
        );
        permissionedPools.applyPermissionedPoolTerms(poolId, changed, 0, deadline, agreementHash, authorization);

        vm.expectRevert(
            abi.encodeWithSelector(PermissionedPoolAdminFacet.DeadlineExpired.selector, block.timestamp - 1)
        );
        permissionedPools.applyPermissionedPoolTerms(
            poolId, changed, 1, block.timestamp - 1, agreementHash, authorization
        );
    }

    function testCreationNonceInvalidationAndExpiryBlockPoolCreation() public {
        IStaticsPermissionedPools.CreatePermissionedPoolParams memory params =
            IStaticsPermissionedPools.CreatePermissionedPoolParams({
                tokenA: address(new MockERC20("Nonce A", "nA", 18)),
                tokenB: address(new MockERC20("Nonce B", "nB", 18)),
                lpFee: 500,
                tickSpacing: 10,
                sqrtPriceBPerAX96: 1 << 96,
                creator: creator,
                controller: address(new DefaultVenueController(creator)),
                economics: _economics(100, 8_000, 1_000, 1_000),
                authorizationNonce: 33,
                deadline: block.timestamp + 1 days,
                agreementHash: keccak256("invalidated-creation")
            });
        bytes memory authorization =
            _sign(creatorKey, permissionedPools.quotePermissionedPool(params).authorizationDigest);
        vm.prank(creator);
        permissionedPools.invalidatePermissionedAuthorizationNonce(params.authorizationNonce);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolCreationFacet.AuthorizationNonceAlreadyUsed.selector, creator, params.authorizationNonce
            )
        );
        permissionedPools.createPermissionedPool(params, authorization);

        params.authorizationNonce = 34;
        params.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(PermissionedPoolCreationFacet.DeadlineExpired.selector, params.deadline));
        permissionedPools.createPermissionedPool(params, "");
    }

    function testHaltedOperatorUnwindCreditsOnlyUndeliverableOwnerAsset() public {
        MockReceiverRestrictedERC20 restricted = new MockReceiverRestrictedERC20("Blocked", "BLK");
        MockERC20 healthy = new MockERC20("Healthy", "HLT", 18);
        (PoolId poolId, PoolKey memory key, DefaultVenueController oldController) =
            _createDefaultPool(address(restricted), address(healthy), 3_000, 100);
        uint256 tokenId = _mintFullRangePosition(key, oldController, lp, 20 ether);
        restricted.setBlockedReceiver(lp);
        address newOperator = makeAddr("replacement-venue-operator");
        DefaultVenueController newController =
            _replaceWithHaltedController(poolId, address(oldController), newOperator, 0, keccak256("unwind migration"));

        uint256 healthyBefore = healthy.balanceOf(lp);
        vm.prank(creator);
        vm.expectRevert();
        positionClaims.forceUnwind(tokenId, 0, 0, "");
        vm.prank(newOperator);
        positionClaims.forceUnwind(tokenId, 0, 0, "");
        vm.expectRevert();
        permissionedPositionManager.ownerOf(tokenId);
        assertGt(healthy.balanceOf(lp), healthyBefore);

        Currency restrictedCurrency = Currency.wrap(address(restricted));
        uint256 credit = positionClaims.creditOf(poolId, lp, restrictedCurrency);
        assertGt(credit, 0);
        restricted.setBlockedReceiver(address(0));
        uint256 ownerClaim = credit / 2;
        uint256 ownerBalanceBefore = restricted.balanceOf(lp);
        vm.prank(lp);
        positionClaims.claim(poolId, restrictedCurrency, lp, ownerClaim);
        assertEq(restricted.balanceOf(lp) - ownerBalanceBefore, ownerClaim);
        address alternate = makeAddr("eligible-proceeds-receiver");
        _setPermissionsAs(newController, poolId, alternate, LIQUIDITY_ALLOWED, newOperator);
        vm.prank(lp);
        positionClaims.claim(poolId, restrictedCurrency, alternate, credit - ownerClaim);
        assertEq(restricted.balanceOf(alternate), credit - ownerClaim);
        assertEq(positionClaims.creditOf(poolId, lp, restrictedCurrency), 0);
    }

    function testOwnerCanClaimBackedCreditWhenControllerFails() public {
        MockReceiverRestrictedERC20 restricted = new MockReceiverRestrictedERC20("Claim Blocked", "cBLK");
        MockERC20 healthy = new MockERC20("Claim Healthy", "cHLT", 18);
        (PoolId poolId, PoolKey memory key, DefaultVenueController originalController) =
            _createDefaultPool(address(restricted), address(healthy), 3_000, 100);
        uint256 tokenId = _mintFullRangePosition(key, originalController, lp, 20 ether);
        restricted.setBlockedReceiver(lp);

        address unwindOperator = makeAddr("credit-unwind-operator");
        DefaultVenueController unwindController = _replaceWithHaltedController(
            poolId, address(originalController), unwindOperator, 0, keccak256("credit unwind controller")
        );
        vm.prank(unwindOperator);
        positionClaims.forceUnwind(tokenId, 0, 0, "");

        Currency restrictedCurrency = Currency.wrap(address(restricted));
        uint256 credit = positionClaims.creditOf(poolId, lp, restrictedCurrency);
        assertGt(credit, 1);
        assertEq(poolManager.balanceOf(address(positionClaims), restrictedCurrency.toId()), credit);

        BreakableVenueController brokenController = new BreakableVenueController(creator);
        vm.prank(creator);
        brokenController.setPoolStatus(IVenueController.TradingStatus.Halted);
        _replaceControllerWithAuthorization(
            poolId, address(unwindController), address(brokenController), 1, keccak256("broken credit controller")
        );
        vm.prank(creator);
        brokenController.breakController();
        restricted.setBlockedReceiver(address(0));

        uint256 ownerClaim = credit / 2;
        uint256 ownerBalanceBefore = restricted.balanceOf(lp);
        vm.prank(lp);
        positionClaims.claim(poolId, restrictedCurrency, lp, ownerClaim);
        assertEq(restricted.balanceOf(lp) - ownerBalanceBefore, ownerClaim);
        assertEq(positionClaims.creditOf(poolId, lp, restrictedCurrency), credit - ownerClaim);
        assertEq(poolManager.balanceOf(address(positionClaims), restrictedCurrency.toId()), credit - ownerClaim);

        vm.prank(lp);
        vm.expectRevert(BreakableVenueController.BrokenController.selector);
        positionClaims.claim(poolId, restrictedCurrency, makeAddr("alternate-credit-receiver"), credit - ownerClaim);
        assertEq(positionClaims.creditOf(poolId, lp, restrictedCurrency), credit - ownerClaim);
        assertEq(poolManager.balanceOf(address(positionClaims), restrictedCurrency.toId()), credit - ownerClaim);
    }

    function testHaltedOperatorUnwindCannotBeVetoedBySubscriber() public {
        MockERC20 tokenA = new MockERC20("Subscriber A", "sA", 18);
        MockERC20 tokenB = new MockERC20("Subscriber B", "sB", 18);
        (PoolId poolId, PoolKey memory key, DefaultVenueController oldController) =
            _createDefaultPool(address(tokenA), address(tokenB), 3_000, 100);
        uint256 tokenId = _mintFullRangePosition(key, oldController, lp, 20 ether);
        RevertingBurnSubscriber hostileSubscriber = new RevertingBurnSubscriber();
        vm.prank(lp);
        permissionedPositionManager.subscribe(tokenId, address(hostileSubscriber), "");

        vm.expectRevert();
        _burnPosition(tokenId, key, lp);
        assertEq(permissionedPositionManager.ownerOf(tokenId), lp);
        assertEq(address(permissionedPositionManager.subscriber(tokenId)), address(hostileSubscriber));

        address newOperator = makeAddr("subscriber-unwind-operator");
        _replaceWithHaltedController(
            poolId, address(oldController), newOperator, 0, keccak256("subscriber unwind migration")
        );
        uint256 balance0Before = IERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 balance1Before = IERC20(Currency.unwrap(key.currency1)).balanceOf(lp);
        vm.prank(newOperator);
        positionClaims.forceUnwind(tokenId, 0, 0, "");

        vm.expectRevert();
        permissionedPositionManager.ownerOf(tokenId);
        assertEq(address(permissionedPositionManager.subscriber(tokenId)), address(0));
        assertTrue(
            IERC20(Currency.unwrap(key.currency0)).balanceOf(lp) > balance0Before
                || IERC20(Currency.unwrap(key.currency1)).balanceOf(lp) > balance1Before
        );
    }

    function testPermissionedPositionManagerRetainsRuntimeHeadroom() public view {
        assertLe(address(permissionedPositionManager).code.length, POSITION_MANAGER_SIZE_LIMIT);
    }

    function _createDefaultPool(address tokenA, address tokenB, uint24 lpFee, uint16 venueFeeBps)
        private
        returns (PoolId poolId, PoolKey memory key, DefaultVenueController controller)
    {
        return _createPool(tokenA, tokenB, lpFee, _economics(venueFeeBps, 8_000, 1_000, 1_000));
    }

    function _createPool(
        address tokenA,
        address tokenB,
        uint24 lpFee,
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory economics
    ) private returns (PoolId poolId, PoolKey memory key, DefaultVenueController controller) {
        controller = new DefaultVenueController(creator);
        (poolId, key) = _createPoolWithController(tokenA, tokenB, lpFee, economics, address(controller));
    }

    function _createPoolWithController(
        address tokenA,
        address tokenB,
        uint24 lpFee,
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory economics,
        address controller
    ) private returns (PoolId poolId, PoolKey memory key) {
        IStaticsPermissionedPools.CreatePermissionedPoolParams memory params =
            IStaticsPermissionedPools.CreatePermissionedPoolParams({
                tokenA: tokenA,
                tokenB: tokenB,
                lpFee: lpFee,
                tickSpacing: 10,
                sqrtPriceBPerAX96: 1 << 96,
                creator: creator,
                controller: controller,
                economics: economics,
                authorizationNonce: 1,
                deadline: block.timestamp + 1 days,
                agreementHash: keccak256("initial-permissioned-venue-terms")
            });
        IStaticsPermissionedPools.PermissionedPoolQuote memory quote = permissionedPools.quotePermissionedPool(params);
        poolId = permissionedPools.createPermissionedPool(params, _sign(creatorKey, quote.authorizationDigest));
        key = quote.key;

        IStaticsProtocolPools.ProtocolPoolView memory registered = protocolPools.protocolPool(poolId);
        assertEq(uint256(registered.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral));
        assertEq(address(registered.key.hooks), address(permissionedHook));
        assertEq(registered.creator, creator);
        assertEq(registered.permanentLiquidity, 0);
    }

    function _controllerReplacementAuthorization(
        PoolId poolId,
        address currentController,
        address newController,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash,
        uint256 signerKey
    ) private returns (bytes memory authorization) {
        bytes32 digest = permissionedPools.permissionedControllerReplacementDigest(
            poolId, currentController, newController, nonce, deadline, agreementHash
        );
        return _sign(signerKey, digest);
    }

    function _replaceWithHaltedController(
        PoolId poolId,
        address oldController,
        address newOperator,
        uint256 nonce,
        bytes32 agreementHash
    ) private returns (DefaultVenueController newController) {
        newController = new DefaultVenueController(newOperator);
        vm.prank(newOperator);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory authorization = _controllerReplacementAuthorization(
            poolId, oldController, address(newController), nonce, deadline, agreementHash, creatorKey
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, oldController, address(newController), nonce, deadline, agreementHash, authorization
        );
    }

    function _replaceControllerWithAuthorization(
        PoolId poolId,
        address oldController,
        address newController,
        uint256 nonce,
        bytes32 agreementHash
    ) private {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory authorization = _controllerReplacementAuthorization(
            poolId, oldController, newController, nonce, deadline, agreementHash, creatorKey
        );
        permissionedPools.replacePermissionedPoolController(
            poolId, oldController, newController, nonce, deadline, agreementHash, authorization
        );
    }

    function _economics(uint16 venueFeeBps, uint16 creatorShareBps, uint16 treasuryShareBps, uint16 stakerShareBps)
        private
        pure
        returns (IStaticsPermissionedSwapFeeHook.PoolEconomics memory economics)
    {
        economics = IStaticsPermissionedSwapFeeHook.PoolEconomics({
            venueFeeBps: venueFeeBps,
            additionalRewardRestrictedMask: 0,
            allocation: IStaticsPermissionedSwapFeeHook.FeeAllocation({
                creatorShareBps: creatorShareBps,
                treasuryShareBps: treasuryShareBps,
                staticsStakerShareBps: stakerShareBps,
                basketStakerShareBps: 0
            })
        });
    }

    function _applyWalletTerms(PoolId poolId, uint256 walletOwnerKey) private {
        IStaticsPermissionedSwapFeeHook.PoolEconomics memory changed = _economics(75, 7_500, 1_500, 1_000);
        uint256 deadline = block.timestamp + 2 days;
        bytes32 agreementHash = keccak256("wallet-amended-terms");
        bytes32 digest = permissionedPools.permissionedTermsDigest(poolId, changed, 0, deadline, agreementHash);
        permissionedPools.applyPermissionedPoolTerms(
            poolId, changed, 0, deadline, agreementHash, _sign(walletOwnerKey, digest)
        );
    }

    function _applyWalletControllerReplacement(
        PoolId poolId,
        DefaultVenueController controller,
        address walletOwner,
        uint256 walletOwnerKey
    ) private {
        DefaultVenueController newController = new DefaultVenueController(walletOwner);
        vm.prank(walletOwner);
        newController.setPoolStatus(poolId, IVenueController.TradingStatus.Halted);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 agreementHash = keccak256("wallet-controller-migration");
        bytes32 digest = permissionedPools.permissionedControllerReplacementDigest(
            poolId, address(controller), address(newController), 1, deadline, agreementHash
        );
        permissionedPools.replacePermissionedPoolController(
            poolId,
            address(controller),
            address(newController),
            1,
            deadline,
            agreementHash,
            _sign(walletOwnerKey, digest)
        );
        assertEq(permissionedPools.permissionedPool(poolId).controller, address(newController));
        assertEq(permissionedPools.permissionedPool(poolId).configurationNonce, 2);
    }

    function _mintFullRangePosition(
        PoolKey memory key,
        DefaultVenueController controller,
        address owner,
        uint256 liquidity
    ) private returns (uint256 tokenId) {
        _setPermissions(controller, key.toId(), owner, LIQUIDITY_ALLOWED);
        uint256 amount0Max = 100 ether;
        uint256 amount1Max = 100 ether;
        MockERC20(Currency.unwrap(key.currency0)).mint(owner, amount0Max);
        MockERC20(Currency.unwrap(key.currency1)).mint(owner, amount1Max);
        _approvePermit2(owner, Currency.unwrap(key.currency0), address(permissionedPositionManager), amount0Max);
        _approvePermit2(owner, Currency.unwrap(key.currency1), address(permissionedPositionManager), amount1Max);
        tokenId = permissionedPositionManager.nextTokenId();

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidity,
            uint128(amount0Max),
            uint128(amount1Max),
            ActionConstants.MSG_SENDER,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.prank(owner);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _decreasePosition(uint256 tokenId, PoolKey memory key, address owner, uint256 liquidity) private {
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.DECREASE_LIQUIDITY)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        vm.prank(owner);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _increasePosition(uint256 tokenId, PoolKey memory key, address executor, uint256 liquidity) private {
        _increasePosition(tokenId, key, executor, liquidity, "");
    }

    function _increasePosition(
        uint256 tokenId,
        PoolKey memory key,
        address executor,
        uint256 liquidity,
        bytes memory expectedRevert
    ) private {
        uint256 amount0Max = 10 ether;
        uint256 amount1Max = 10 ether;
        MockERC20(Currency.unwrap(key.currency0)).mint(executor, amount0Max);
        MockERC20(Currency.unwrap(key.currency1)).mint(executor, amount1Max);
        _approvePermit2(executor, Currency.unwrap(key.currency0), address(permissionedPositionManager), amount0Max);
        _approvePermit2(executor, Currency.unwrap(key.currency1), address(permissionedPositionManager), amount1Max);

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.INCREASE_LIQUIDITY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, uint128(amount0Max), uint128(amount1Max), bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.prank(executor);
        if (expectedRevert.length != 0) vm.expectRevert(expectedRevert);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _increasePositionFromDeltas(uint256 tokenId, PoolKey memory key, address executor, uint256 amount)
        private
    {
        _increasePositionFromDeltas(tokenId, key, executor, amount, "");
    }

    function _increasePositionFromDeltas(
        uint256 tokenId,
        PoolKey memory key,
        address executor,
        uint256 amount,
        bytes memory expectedRevert
    ) private {
        MockERC20(Currency.unwrap(key.currency0)).mint(executor, amount);
        MockERC20(Currency.unwrap(key.currency1)).mint(executor, amount);
        _approvePermit2(executor, Currency.unwrap(key.currency0), address(permissionedPositionManager), amount);
        _approvePermit2(executor, Currency.unwrap(key.currency1), address(permissionedPositionManager), amount);

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SETTLE)),
            bytes1(uint8(Actions.SETTLE)),
            bytes1(uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(key.currency0, amount, true);
        params[1] = abi.encode(key.currency1, amount, true);
        params[2] = abi.encode(tokenId, uint128(amount), uint128(amount), bytes(""));
        params[3] = abi.encode(key.currency0);
        params[4] = abi.encode(key.currency1);
        vm.prank(executor);
        if (expectedRevert.length != 0) vm.expectRevert(expectedRevert);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _burnPosition(uint256 tokenId, PoolKey memory key, address owner) private {
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        vm.prank(owner);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _collectPositionFees(uint256 tokenId, PoolKey memory key, address owner) private {
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.INCREASE_LIQUIDITY)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        vm.prank(owner);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _collectPositionFeesFromDeltas(uint256 tokenId, PoolKey memory key, address owner) private {
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        vm.prank(owner);
        permissionedPositionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _permitPosition(uint256 ownerKey, address delegate, uint256 tokenId, uint256 nonce) private {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permissionedPositionManager.DOMAIN_SEPARATOR(),
                ERC721PermitHash.hashPermit(delegate, tokenId, nonce, deadline)
            )
        );
        vm.prank(delegate);
        permissionedPositionManager.permit(delegate, tokenId, deadline, nonce, _sign(ownerKey, digest));
    }

    function _permitAllPositions(uint256 ownerKey, address owner, address delegate, uint256 nonce) private {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permissionedPositionManager.DOMAIN_SEPARATOR(),
                ERC721PermitHash.hashPermitForAll(delegate, true, nonce, deadline)
            )
        );
        vm.prank(delegate);
        permissionedPositionManager.permitForAll(owner, delegate, true, deadline, nonce, _sign(ownerKey, digest));
    }

    function _swapForOutput(
        PoolKey memory key,
        DefaultVenueController controller,
        address user,
        address output,
        uint128 amountIn
    ) private returns (uint256 amountOut) {
        return _swapForOutput(key, controller, user, output, amountIn, true);
    }

    function _swapForOutput(
        PoolKey memory key,
        DefaultVenueController controller,
        address user,
        address output,
        uint128 amountIn,
        bool approveUser
    ) private returns (uint256 amountOut) {
        bool zeroForOne = output == Currency.unwrap(key.currency1);
        address input = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        if (approveUser) _setPermissions(controller, key.toId(), user, SWAP_ALLOWED);
        MockERC20(input).mint(user, amountIn);
        _approvePermit2(user, input, address(permissionedRouter), amountIn);
        if (!approveUser) vm.expectRevert();
        vm.prank(user);
        amountOut = permissionedRouter.swapExactInputSingle(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, hookData: ""
            }),
            block.timestamp + 1 hours
        );
    }

    function _setPermissions(DefaultVenueController controller, PoolId poolId, address account, uint256 flags) private {
        _setPermissionsAs(controller, poolId, account, flags, creator);
    }

    function _setPermissionsAs(
        DefaultVenueController controller,
        PoolId poolId,
        address account,
        uint256 flags,
        address controllerOperator
    ) private {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        uint256[] memory permissionFlags = new uint256[](1);
        permissionFlags[0] = flags;
        vm.prank(controllerOperator);
        controller.setPermissions(poolId, accounts, permissionFlags);
    }

    function _approvePermit2(address owner, address token, address spender, uint256 amount) private {
        vm.startPrank(owner);
        IERC20(token).approve(address(permit2), amount);
        permit2.approve(token, spender, uint160(amount), uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _stakeForReward(address user, address rewardAsset) private returns (uint256 positionId) {
        uint256 amount = 10 ether;
        stakingAsset.mint(user, amount);
        address[] memory rewards = new address[](1);
        rewards[0] = rewardAsset;
        uint256 fee = IStaticsPositionFees(address(diamond)).positionCreationFee();
        vm.deal(user, fee);
        vm.startPrank(user);
        stakingAsset.approve(address(diamond), amount);
        positionId = IStaticsGlobalRewards(address(diamond)).createAndStake{value: fee}(amount, user, rewards);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
    }

    function _sign(uint256 key, bytes32 digest) private returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
