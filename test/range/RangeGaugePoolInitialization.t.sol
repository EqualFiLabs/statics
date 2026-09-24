// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract RangeGaugeInitializationProbeFacet {
    function gaugeInitialization(PoolId poolId)
        external
        view
        returns (bool initialized, int24 referenceTick, uint8 slotCount, address statics)
    {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        LibRangeGauge.PoolRewardConfig storage config = rgs.rewardConfig[poolId];
        return (gauge.initialized, gauge.referenceTick, config.slotCount, config.assets[0]);
    }
}

interface IRangeGaugeInitializationProbe {
    function gaugeInitialization(PoolId poolId)
        external
        view
        returns (bool initialized, int24 referenceTick, uint8 slotCount, address statics);
}

contract RangeGaugePoolInitializationTest is CanonicalPoolTestBase {
    using StateLibrary for IPoolManager;

    IRangeGaugeInitializationProbe private probe;

    function setUp() public override {
        super.setUp();
        RangeGaugeInitializationProbeFacet facet = new RangeGaugeInitializationProbeFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RangeGaugeInitializationProbeFacet.gaugeInitialization.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        probe = IRangeGaugeInitializationProbe(address(diamond));
    }

    function testGeneralPoolInitializationSeedsLiveReferenceTickAndStaticsSlot() public {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: address(assetA),
            tokenB: address(assetB),
            lpFee: 3_000,
            tickSpacing: 10,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            initialFeeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: alice,
            nonce: 0,
            deadline: type(uint256).max
        });
        PoolId poolId = IStaticsProtocolPools(address(diamond)).createPool(params, "");

        (, int24 liveTick,,) = poolManager.getSlot0(poolId);
        (bool initialized, int24 referenceTick, uint8 slotCount, address statics) = probe.gaugeInitialization(poolId);
        assertTrue(initialized);
        assertEq(referenceTick, liveTick);
        assertEq(slotCount, 1);
        assertEq(statics, address(stakingAsset));
    }

    function testBasketCanonicalInitializationSeedsEveryGaugeFromLiveTick() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        address[2] memory assets = [address(assetA), address(assetB)];
        for (uint256 i; i < assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, assets[i]);
            (, int24 liveTick,,) = poolManager.getSlot0(pool.poolId);
            (bool initialized, int24 referenceTick, uint8 slotCount, address statics) =
                probe.gaugeInitialization(pool.poolId);
            assertTrue(initialized);
            assertEq(referenceTick, liveTick);
            assertEq(referenceTick, pool.spotTick);
            assertEq(slotCount, 1);
            assertEq(statics, address(stakingAsset));
        }
    }
}
