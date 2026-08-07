// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ProtocolPoolFacet} from "../../src/facets/ProtocolPoolFacet.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {MockERC20, MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract GovernanceProtocolPoolsTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IStaticsProtocolPools private protocolPools;

    function setUp() public override {
        super.setUp();
        protocolPools = IStaticsProtocolPools(address(diamond));
    }

    function testGovernanceCreatesAndPermanentlySeedsPoolFromSeparatePayer() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        (
            PoolKey memory quotedKey,
            PoolId quotedPoolId,
            uint160 quotedPrice,
            uint128 quotedLiquidity,
            uint256 quotedA,
            uint256 quotedB
        ) = _quote(params);
        uint256 aliceABefore = assetA.balanceOf(alice);
        uint256 aliceBBefore = assetB.balanceOf(alice);

        (PoolId poolId, uint128 liquidity, uint256 amountA, uint256 amountB) =
            protocolPools.createGovernancePool(params);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(quotedPoolId));
        assertEq(liquidity, quotedLiquidity);
        assertEq(amountA, quotedA);
        assertEq(amountB, quotedB);
        assertEq(aliceABefore - assetA.balanceOf(alice), amountA);
        assertEq(aliceBBefore - assetB.balanceOf(alice), amountB);
        assertEq(IERC20(address(assetA)).allowance(address(diamond), address(swapFeeHook)), 0);
        assertEq(IERC20(address(assetB)).allowance(address(diamond), address(swapFeeHook)), 0);
        assertEq(swapFeeHook.lockedLiquidity(poolId), liquidity);
        (uint160 livePrice,,,) = poolManager.getSlot0(poolId);
        assertEq(livePrice, quotedPrice);

        IStaticsProtocolPools.ProtocolPoolView memory view_ = protocolPools.protocolPool(poolId);
        assertEq(uint256(view_.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.Governance));
        assertEq(PoolId.unwrap(view_.poolId), PoolId.unwrap(poolId));
        assertEq(keccak256(abi.encode(view_.key)), keccak256(abi.encode(quotedKey)));
        assertEq(view_.basketId, 0);
        assertEq(view_.basketAsset, address(0));
        assertEq(view_.permanentLiquidity, liquidity);
        assertFalse(view_.decommissioned);
        assertTrue(protocolPools.isProtocolPool(poolId));
    }

    function testNonOwnerCannotCreateGovernancePool() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, bob, address(this)));
        protocolPools.createGovernancePool(params);
    }

    function testLiquidityPauseBlocksCreationWithoutDebitingPayer() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        uint256 beforeA = assetA.balanceOf(alice);
        uint256 beforeB = assetB.balanceOf(alice);
        IStaticsGovernance(address(diamond)).pause(1 << 5);

        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolFacet.ActionPaused.selector, 1 << 5));
        protocolPools.createGovernancePool(params);

        assertEq(assetA.balanceOf(alice), beforeA);
        assertEq(assetB.balanceOf(alice), beforeB);
    }

    function testDuplicatePoolRevertsWithoutDebitingPayer() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        (PoolId poolId,,,) = protocolPools.createGovernancePool(params);
        uint256 aliceABefore = assetA.balanceOf(alice);
        uint256 aliceBBefore = assetB.balanceOf(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibProtocolPools.ProtocolPoolAlreadyRegistered.selector,
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.Governance
            )
        );
        protocolPools.createGovernancePool(params);
        assertEq(assetA.balanceOf(alice), aliceABefore);
        assertEq(assetB.balanceOf(alice), aliceBBefore);
    }

    function testFeeOnTransferSeedRevertsAtomically() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(taxed), address(assetB));
        taxed.mint(alice, params.amountAMax);
        assetB.mint(alice, params.amountBMax);
        vm.startPrank(alice);
        taxed.approve(address(diamond), params.amountAMax);
        assetB.approve(address(diamond), params.amountBMax);
        vm.stopPrank();
        (, PoolId poolId,,,,) = protocolPools.quoteGovernancePool(params);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolFacet.IncompatibleTokenTransfer.selector,
                address(taxed),
                params.amountAMax,
                params.amountAMax * 99 / 100
            )
        );
        protocolPools.createGovernancePool(params);

        assertFalse(protocolPools.isProtocolPool(poolId));
        assertFalse(swapFeeHook.poolRegistration(poolId).registered);
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        assertEq(price, 0);
    }

    function testGovernanceDecommissionRoutesReleasedValueToTreasury() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        (PoolId poolId,,,) = protocolPools.createGovernancePool(params);
        uint256 accruedABefore = globalRewards.treasuryAccrued(address(assetA));
        uint256 accruedBBefore = globalRewards.treasuryAccrued(address(assetB));

        (uint256 amount0, uint256 amount1) = protocolPools.decommissionGovernancePool(poolId);
        IStaticsProtocolPools.ProtocolPoolView memory view_ = protocolPools.protocolPool(poolId);
        assertTrue(view_.decommissioned);
        assertEq(view_.permanentLiquidity, 0);
        assertEq(swapFeeHook.lockedLiquidity(poolId), 0);
        address currency0 = Currency.unwrap(view_.key.currency0);
        address currency1 = Currency.unwrap(view_.key.currency1);
        assertEq(globalRewards.treasuryAccrued(currency0), _before(currency0, accruedABefore, accruedBBefore) + amount0);
        assertEq(globalRewards.treasuryAccrued(currency1), _before(currency1, accruedABefore, accruedBBefore) + amount1);
    }

    function testProtocolPoolFeeConfigurationSupportsGovernancePool() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(params, alice);
        (PoolId poolId,,,) = protocolPools.createGovernancePool(params);
        IStaticsBasketLiquidity.SwapFeeConfiguration memory configuration = IStaticsBasketLiquidity.SwapFeeConfiguration({
            inputFeeBps: 15,
            outputFeeBps: 20,
            polShareBps: 2_000,
            liquidityProviderShareBps: 2_000,
            basketStakerShareBps: 1_000,
            staticsStakerShareBps: 2_000,
            treasuryShareBps: 3_000
        });
        protocolPools.setProtocolPoolFeeConfiguration(poolId, configuration);
        IStaticsBasketLiquidity.PoolFeeConfigurationView memory effective =
            protocolPools.protocolPoolFeeConfiguration(poolId);
        assertEq(effective.inputFeeBps, configuration.inputFeeBps);
        assertEq(effective.outputFeeBps, configuration.outputFeeBps);
        assertTrue(effective.overridden);
        protocolPools.clearProtocolPoolFeeConfiguration(poolId);
        assertFalse(protocolPools.protocolPoolFeeConfiguration(poolId).overridden);
    }

    function testCanonicalPoolResolvesThroughNormalizedView() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        IStaticsProtocolPools.ProtocolPoolView memory view_ = protocolPools.protocolPool(canonical.poolId);
        assertEq(uint256(view_.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
        assertEq(view_.basketId, basketId);
        assertEq(view_.basketAsset, address(assetA));
        assertTrue(protocolPools.isProtocolPool(canonical.poolId));
    }

    function testGovernanceCreationRejectsCanonicalPoolCollision() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(basketToken, address(assetA));

        vm.expectRevert(
            abi.encodeWithSelector(
                LibProtocolPools.ProtocolPoolAlreadyRegistered.selector,
                canonical.poolId,
                IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
            )
        );
        protocolPools.createGovernancePool(params);
    }

    function testQuoteRejectsIdenticalTokensAndExpiredCreationRejectsBeforePull() public {
        IStaticsProtocolPools.CreateGovernancePoolParams memory identical = _params(address(assetA), address(assetA));
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolFacet.IdenticalTokens.selector, address(assetA)));
        protocolPools.quoteGovernancePool(identical);

        IStaticsProtocolPools.CreateGovernancePoolParams memory expired = _params(address(assetA), address(assetB));
        _fundAndApprovePayer(expired, alice);
        uint256 beforeA = assetA.balanceOf(alice);
        uint256 beforeB = assetB.balanceOf(alice);
        expired.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolFacet.DeadlineExpired.selector, expired.deadline));
        protocolPools.createGovernancePool(expired);
        assertEq(assetA.balanceOf(alice), beforeA);
        assertEq(assetB.balanceOf(alice), beforeB);
    }

    function testQuoteNormalizesTokenOrderAndReciprocalPrice() public view {
        IStaticsProtocolPools.CreateGovernancePoolParams memory forward = _params(address(assetA), address(assetB));
        forward.sqrtPriceBPerAX96 = SQRT_PRICE_1_1 * 2;
        IStaticsProtocolPools.CreateGovernancePoolParams memory reverse = _params(address(assetB), address(assetA));
        reverse.sqrtPriceBPerAX96 = SQRT_PRICE_1_1 / 2;

        (PoolKey memory forwardKey, PoolId forwardId, uint160 forwardPrice,, uint256 forwardA, uint256 forwardB) =
            protocolPools.quoteGovernancePool(forward);
        (PoolKey memory reverseKey, PoolId reverseId, uint160 reversePrice,, uint256 reverseA, uint256 reverseB) =
            protocolPools.quoteGovernancePool(reverse);

        assertEq(keccak256(abi.encode(forwardKey)), keccak256(abi.encode(reverseKey)));
        assertEq(PoolId.unwrap(forwardId), PoolId.unwrap(reverseId));
        assertEq(forwardPrice, reversePrice);
        assertEq(forwardA, reverseB);
        assertEq(forwardB, reverseA);
    }

    function testFuzzQuoteRespectsBothMaximums(uint96 maxA, uint96 maxB) public view {
        maxA = uint96(bound(maxA, 1e9, 1e28));
        maxB = uint96(bound(maxB, 1e9, 1e28));
        IStaticsProtocolPools.CreateGovernancePoolParams memory params = _params(address(assetA), address(assetB));
        params.amountAMax = maxA;
        params.amountBMax = maxB;
        (,,,, uint256 amountA, uint256 amountB) = protocolPools.quoteGovernancePool(params);
        assertLe(amountA, maxA);
        assertLe(amountB, maxB);
        assertGt(amountA, 0);
        assertGt(amountB, 0);
    }

    function _params(address tokenA, address tokenB)
        private
        view
        returns (IStaticsProtocolPools.CreateGovernancePoolParams memory params)
    {
        params = IStaticsProtocolPools.CreateGovernancePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            amountAMax: 100 ether,
            amountBMax: 100 ether,
            minLiquidity: 1,
            payer: alice,
            deadline: block.timestamp + 1 days
        });
    }

    function _fundAndApprovePayer(IStaticsProtocolPools.CreateGovernancePoolParams memory params, address payer)
        private
    {
        MockERC20(params.tokenA).mint(payer, params.amountAMax * 2);
        MockERC20(params.tokenB).mint(payer, params.amountBMax * 2);
        vm.startPrank(payer);
        IERC20(params.tokenA).approve(address(diamond), type(uint256).max);
        IERC20(params.tokenB).approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _quote(IStaticsProtocolPools.CreateGovernancePoolParams memory params)
        private
        view
        returns (PoolKey memory, PoolId, uint160, uint128, uint256, uint256)
    {
        return protocolPools.quoteGovernancePool(params);
    }

    function _before(address token, uint256 beforeA, uint256 beforeB) private view returns (uint256) {
        return token == address(assetA) ? beforeA : beforeB;
    }
}
