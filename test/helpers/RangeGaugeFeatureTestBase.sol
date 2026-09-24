// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CanonicalPoolTestBase} from "./CanonicalPoolTestBase.sol";

contract RangeGaugeFeatureInit {
    function initialize() external {
        LibRangeGauge.initializeGlobalConfig();
        LibRangeGauge.setRewardAssetAllowed(LibRangeGauge.staticsToken(), true);
    }
}

contract RangeGaugeTestStateFacet {
    function setActiveGaugeLiquidity(PoolId poolId, uint256 liquidity) external {
        if (liquidity > type(uint128).max) revert();
        LibRangeGauge.rangeGaugeStorage().gauges[poolId].activeGaugeLiquidity = uint128(liquidity);
    }

    function addGaugeRange(
        PoolId poolId,
        int256 tickLower,
        int256 tickUpper,
        int256 tickSpacing,
        int256 currentTick,
        uint256 liquidity
    ) external {
        LibRangeGauge.addRangeBoundaries(
            poolId,
            _toInt24(tickLower),
            _toInt24(tickUpper),
            _toInt24(tickSpacing),
            _toInt24(currentTick),
            _toUint128(liquidity)
        );
    }

    function seedLpLeg(
        uint256 positionId,
        PoolId poolId,
        address manager,
        uint256 posmTokenId,
        int256 tickLower,
        int256 tickUpper,
        uint256 liquidity
    ) external {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.LpLeg storage leg = rgs.lpLegs[positionId][poolId];
        leg.manager = manager;
        leg.posmTokenId = posmTokenId;
        leg.tickLower = _toInt24(tickLower);
        leg.tickUpper = _toInt24(tickUpper);
        leg.liquidity = _toUint128(liquidity);
        LibRangeGauge.addPositionPool(positionId, poolId);
        LibRangeGauge.bindPosm(posmTokenId, positionId, poolId);
        ++rgs.gauges[poolId].managedLegCount;
        ++rgs.gauges[poolId].unresolvedLegCount;
    }

    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert();
        narrowed = uint128(value);
    }

    function _toInt24(int256 value) private pure returns (int24 narrowed) {
        if (value < type(int24).min || value > type(int24).max) revert();
        narrowed = int24(value);
    }
}

abstract contract RangeGaugeFeatureTestBase is CanonicalPoolTestBase {
    IStaticsRangeGauge internal rangeGauge;
    RangeGaugeTestStateFacet internal rangeGaugeState;
    uint256 private rangePoolNonce;

    function setUp() public virtual override {
        super.setUp();

        RangeGaugeFacet actionFacet = new RangeGaugeFacet();
        RangeGaugeViewFacet viewFacet = new RangeGaugeViewFacet();
        RangeGaugeTestStateFacet stateFacet = new RangeGaugeTestStateFacet();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](3);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(actionFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _actionSelectors()
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _viewSelectors()
        });
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(stateFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _stateSelectors()
        });
        RangeGaugeFeatureInit init = new RangeGaugeFeatureInit();
        IDiamondCut(address(diamond)).diamondCut(cut, address(init), abi.encodeCall(init.initialize, ()));
        rangeGauge = IStaticsRangeGauge(address(diamond));
        rangeGaugeState = RangeGaugeTestStateFacet(address(diamond));
    }

    function _createRangeGaugePool(address creator) internal returns (PoolId poolId) {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: address(assetA),
            tokenB: address(assetB),
            lpFee: 3_000,
            tickSpacing: 10,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            initialFeeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: creator,
            nonce: rangePoolNonce++,
            deadline: type(uint256).max
        });
        poolId = IStaticsProtocolPools(address(diamond)).createPool(params, "");
    }

    function _actionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = RangeGaugeFacet.setGaugeRewardAssetAllowed.selector;
        selectors[1] = RangeGaugeFacet.setGaugeRewardDuration.selector;
        selectors[2] = RangeGaugeFacet.appendPoolRewardAsset.selector;
        selectors[3] = RangeGaugeFacet.fundPoolReward.selector;
    }

    function _viewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = RangeGaugeViewFacet.gaugeRewardDuration.selector;
        selectors[1] = RangeGaugeViewFacet.gaugeRewardAssetAllowed.selector;
        selectors[2] = RangeGaugeViewFacet.poolRewardConfig.selector;
        selectors[3] = RangeGaugeViewFacet.gaugePool.selector;
        selectors[4] = RangeGaugeViewFacet.poolRewardStream.selector;
        selectors[5] = RangeGaugeViewFacet.poolRewardCustodyAccount.selector;
        selectors[6] = RangeGaugeViewFacet.gaugeBoundary.selector;
        selectors[7] = RangeGaugeViewFacet.lpLeg.selector;
        selectors[8] = RangeGaugeViewFacet.positionGaugePools.selector;
        selectors[9] = RangeGaugeViewFacet.posmBinding.selector;
        selectors[10] = RangeGaugeViewFacet.recordedLiquidityManager.selector;
        selectors[11] = RangeGaugeViewFacet.previewLpRewards.selector;
    }

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = RangeGaugeTestStateFacet.setActiveGaugeLiquidity.selector;
        selectors[1] = RangeGaugeTestStateFacet.addGaugeRange.selector;
        selectors[2] = RangeGaugeTestStateFacet.seedLpLeg.selector;
    }
}
