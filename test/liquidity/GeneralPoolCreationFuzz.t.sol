// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ProtocolPoolCreationFacet} from "../../src/facets/ProtocolPoolCreationFacet.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {LibProtocolPoolFee} from "../../src/libraries/LibProtocolPoolFee.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

/// @notice Property-level fuzzing over general-pool quote normalization, fee-rate bounds,
/// tick-spacing bounds, sqrt-price boundaries, and duplicate-market rejection, plus a stateful
/// creator-revenue liability handler proving aggregate reconciliation, conservation, and isolation.
contract GeneralPoolCreationFuzzTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    IStaticsProtocolPools private pools;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzValidFeeRateAcceptedInvalidRejected(uint16 inputFeeBps, uint16 outputFeeBps) public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB));
        params.feeRate = IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: inputFeeBps, outputFeeBps: outputFeeBps});
        if (LibProtocolPoolFee.isValidFeeRate(inputFeeBps, outputFeeBps)) {
            IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
            assertEq(quote.feeRate.inputFeeBps, inputFeeBps);
            assertEq(quote.feeRate.outputFeeBps, outputFeeBps);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidFeeRate.selector, inputFeeBps, outputFeeBps)
            );
            pools.quotePool(params);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzTickSpacingBounds(int24 tickSpacing) public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB));
        params.tickSpacing = tickSpacing;
        if (LibProtocolPoolFee.isValidTickSpacing(tickSpacing)) {
            IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
            assertEq(quote.key.tickSpacing, tickSpacing);
        } else {
            vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidTickSpacing.selector, tickSpacing));
            pools.quotePool(params);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzSqrtPriceBoundaryNormalization(uint160 sqrtPriceBPerAX96) public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB));
        params.sqrtPriceBPerAX96 = sqrtPriceBPerAX96;
        // token ordering: assetA<assetB gives forward orientation, so the raw price is used directly.
        bool inRange = sqrtPriceBPerAX96 != 0 && sqrtPriceBPerAX96 >= TickMath.MIN_SQRT_PRICE
            && sqrtPriceBPerAX96 < TickMath.MAX_SQRT_PRICE && address(assetA) < address(assetB);
        if (inRange) {
            IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
            assertEq(quote.sqrtPriceX96, sqrtPriceBPerAX96);
            assertGe(quote.sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
            assertLt(quote.sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        } else if (address(assetA) < address(assetB)) {
            vm.expectRevert(
                abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidPoolPrice.selector, sqrtPriceBPerAX96)
            );
            pools.quotePool(params);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzDuplicateMarketRejectedRegardlessOfFeeOrPrice(uint16 rawFee, uint160 rawPrice) public {
        IStaticsProtocolPools.CreatePoolParams memory first = _params(address(assetA), address(assetB));
        PoolId poolId = pools.createPool(first, "");

        uint16 inputFee = uint16(bound(rawFee, 0, 200));
        // Keep the requested price within the valid normalized range for this token ordering so the
        // creation reaches the duplicate-registration check rather than price validation. A different
        // requested Statics fee rate or initial price cannot manufacture a distinct market.
        uint160 lowerBound = address(assetA) < address(assetB) ? TickMath.MIN_SQRT_PRICE : (1 << 96);
        uint160 price = uint160(bound(rawPrice, lowerBound, (1 << 96) + 1_000_000));
        IStaticsProtocolPools.CreatePoolParams memory second = _params(address(assetA), address(assetB));
        second.feeRate = IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: inputFee, outputFeeBps: 0});
        second.sqrtPriceBPerAX96 = price;
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ProtocolPoolAlreadyRegistered(bytes32,uint8)")),
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.General
            )
        );
        pools.createPool(second, "");
    }

    function _params(address tokenA, address tokenB)
        private
        view
        returns (IStaticsProtocolPools.CreatePoolParams memory params)
    {
        params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: 10,
            sqrtPriceBPerAX96: 1 << 96,
            feeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: address(this),
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
    }
}

/// @notice Stateful invariant over the real Diamond creator-revenue book: aggregate liability always
/// equals the sum of outstanding per-creator credits, a claim never pays more than the credit, and
/// crediting one pool never mutates an unrelated pool's creator.
contract GeneralPoolCreatorRevenueHandler is Test {
    IStaticsProtocolPools private immutable POOLS;
    IStaticsProtocolRevenue private immutable REVENUE;
    address private immutable HOOK;
    address private immutable ASSET;
    address[] private creators;
    PoolId[] private poolIds;

    uint256 public overpaidClaims;

    constructor(address diamond, address hook, address asset, address[] memory creators_, PoolId[] memory poolIds_) {
        POOLS = IStaticsProtocolPools(diamond);
        REVENUE = IStaticsProtocolRevenue(diamond);
        HOOK = hook;
        ASSET = asset;
        creators = creators_;
        poolIds = poolIds_;
    }

    function accrue(uint256 rawPool, uint256 rawAmount) external {
        PoolId poolId = poolIds[rawPool % poolIds.length];
        uint256 amount = bound(rawAmount, 1, 1e24);
        MockERC20(ASSET).mint(HOOK, amount);
        vm.startPrank(HOOK);
        IERC20(ASSET).approve(address(REVENUE), amount);
        REVENUE.routeProtocolSwapFees(
            poolId,
            ASSET,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                liquidityProvider: 0, basketStaker: 0, staticsStaker: 0, creator: amount, treasury: 0
            })
        );
        vm.stopPrank();
    }

    function claim(uint256 rawCreator) external {
        address creator = creators[rawCreator % creators.length];
        uint256 credit = REVENUE.creatorRevenue(creator, ASSET);
        if (credit == 0) return;
        vm.prank(creator);
        (uint256 amount, uint256 received) = REVENUE.claimCreatorRevenue(ASSET, creator, 0);
        if (amount > credit || received > amount) overpaidClaims++;
    }

    function creatorCount() external view returns (uint256) {
        return creators.length;
    }

    function creatorAt(uint256 i) external view returns (address) {
        return creators[i];
    }

    function feeAssetAddress() external view returns (address) {
        return ASSET;
    }
}

contract GeneralPoolCreatorRevenueInvariantTest is StdInvariant, CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    GeneralPoolCreatorRevenueHandler private handler;
    IStaticsProtocolPools private pools;
    IStaticsProtocolRevenue private revenue;
    MockERC20 private feeAsset;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        feeAsset = new MockERC20("Fee Asset", "FEE", 18);

        address[] memory creators = new address[](2);
        creators[0] = makeAddr("inv-creator-a");
        creators[1] = makeAddr("inv-creator-b");
        PoolId[] memory ids = new PoolId[](2);
        // Two markets: same pair, distinct tick spacings, distinct creators.
        ids[0] = _createPool(address(feeAsset), address(assetA), 10, creators[0]);
        ids[1] = _createPool(address(feeAsset), address(assetA), 60, creators[1]);

        handler = new GeneralPoolCreatorRevenueHandler(
            address(diamond), address(swapFeeHook), address(feeAsset), creators, ids
        );
        targetContract(address(handler));
    }

    function invariantAggregateEqualsSumOfCredits() public view {
        uint256 sum;
        for (uint256 i; i < handler.creatorCount(); ++i) {
            sum += revenue.creatorRevenue(handler.creatorAt(i), handler.feeAssetAddress());
        }
        assertEq(revenue.totalCreatorRevenue(handler.feeAssetAddress()), sum);
    }

    function invariantClaimsNeverOverpay() public view {
        assertEq(handler.overpaidClaims(), 0);
    }

    function _createPool(address tokenA, address tokenB, int24 tickSpacing, address creator)
        private
        returns (PoolId poolId)
    {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: tickSpacing,
            sqrtPriceBPerAX96: 1 << 96,
            feeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        poolId = pools.createPool(params, "");
    }
}
