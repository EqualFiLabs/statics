// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {RangeGaugeFacet} from "../../src/facets/RangeGaugeFacet.sol";
import {RangeGaugeLivenessFacet} from "../../src/facets/RangeGaugeLivenessFacet.sol";
import {RangeGaugePositionFacet} from "../../src/facets/RangeGaugePositionFacet.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
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

    function nextGaugeBoundary(PoolId poolId, int256 tick, int256 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        return LibRangeGauge.nextInitializedBoundary(gauge, _toInt24(tick), _toInt24(tickSpacing), lte);
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
    IAllowanceTransfer internal rangePermit2;
    IPositionManager internal rangePositionManager;
    StaticsLiquidityManager internal rangeLiquidityManager;
    uint256 private rangePoolNonce;

    function setUp() public virtual override {
        super.setUp();

        rangePermit2 = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        rangePositionManager = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(rangePermit2), uint256(100_000), address(0), address(0))
            )
        );
        rangeLiquidityManager = new StaticsLiquidityManager(
            address(diamond), address(rangePositionManager), address(poolManager), address(rangePermit2)
        );
        basketLiquidity.installLiquidityManager(address(rangeLiquidityManager));

        RangeGaugeFacet actionFacet = new RangeGaugeFacet();
        RangeGaugeLivenessFacet livenessFacet = new RangeGaugeLivenessFacet();
        RangeGaugePositionFacet positionFacet = new RangeGaugePositionFacet();
        RangeGaugeViewFacet viewFacet = new RangeGaugeViewFacet();
        RangeGaugeTestStateFacet stateFacet = new RangeGaugeTestStateFacet();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(actionFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _actionSelectors()
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(livenessFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _livenessSelectors()
        });
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(positionFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _positionSelectors()
        });
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(viewFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _viewSelectors()
        });
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(stateFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _stateSelectors()
        });
        RangeGaugeFeatureInit init = new RangeGaugeFeatureInit();
        IDiamondCut(address(diamond)).diamondCut(cut, address(init), abi.encodeCall(init.initialize, ()));
        rangeGauge = IStaticsRangeGauge(address(diamond));
        rangeGaugeState = RangeGaugeTestStateFacet(address(diamond));
    }

    function _installDefaultLiquidityManager() internal pure override returns (bool) {
        return false;
    }

    function _createRangeGaugePool(address creator) internal returns (PoolId poolId) {
        return _createRangeGaugePool(creator, address(assetA), address(assetB));
    }

    function _createRangeGaugePool(address creator, address tokenA, address tokenB) internal returns (PoolId poolId) {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
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

    function _positionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = RangeGaugePositionFacet.provideLiquidity.selector;
        selectors[1] = RangeGaugePositionFacet.attachLiquidity.selector;
        selectors[2] = RangeGaugePositionFacet.increaseLiquidity.selector;
        selectors[3] = RangeGaugePositionFacet.decreaseLiquidity.selector;
        selectors[4] = RangeGaugePositionFacet.collectNativeFees.selector;
        selectors[5] = RangeGaugePositionFacet.rebalanceLiquidity.selector;
    }

    function _livenessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = RangeGaugeLivenessFacet.exitLiquidity.selector;
        selectors[1] = RangeGaugeLivenessFacet.claimLpRewards.selector;
        selectors[2] = RangeGaugeLivenessFacet.forfeitLpReward.selector;
        selectors[3] = RangeGaugeLivenessFacet.recoverUnboundPosm.selector;
        selectors[4] = RangeGaugeLivenessFacet.reconcilePoolRewardSurplus.selector;
    }

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = RangeGaugeTestStateFacet.setActiveGaugeLiquidity.selector;
        selectors[1] = RangeGaugeTestStateFacet.addGaugeRange.selector;
        selectors[2] = RangeGaugeTestStateFacet.seedLpLeg.selector;
        selectors[3] = RangeGaugeTestStateFacet.nextGaugeBoundary.selector;
    }
}
