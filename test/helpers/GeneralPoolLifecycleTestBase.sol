// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "./CanonicalPoolTestBase.sol";

/// @notice Shared real-flow harness for the permissionless general-pool lifecycle. Installs a real
/// v4 PositionManager, Permit2, and the production `StaticsLiquidityManager` so general pools can be
/// created at zero liquidity, funded with full-range liquidity, staked, activated, swapped, and
/// decommissioned against the actual PoolManager rather than a mock.
abstract contract GeneralPoolLifecycleTestBase is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IAllowanceTransfer internal permit2Contract;
    IPositionManager internal positionManagerContract;
    StaticsLiquidityManager internal liquidityManager;
    IStaticsProtocolPools internal pools;
    IStaticsPosition internal positions;

    uint160 internal constant SQRT_PRICE_1_1_LOCAL = 1 << 96;

    function setUp() public virtual override {
        super.setUp();
        permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        positionManagerContract = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        liquidityManager = new StaticsLiquidityManager(
            address(diamond), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installLiquidityManager(address(liquidityManager));
        pools = IStaticsProtocolPools(address(diamond));
        positions = IStaticsPosition(address(diamond));
    }

    function _installDefaultLiquidityManager() internal pure override returns (bool) {
        return false;
    }

    // --- General-pool creation ---

    function _createGeneralPool(address tokenA, address tokenB, int24 tickSpacing, address creator)
        internal
        returns (PoolId poolId, PoolKey memory key)
    {
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: tickSpacing,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1_LOCAL,
            feeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        key = quote.key;
        poolId = pools.createPool(params, "");
    }

    // --- Full-range liquidity minted directly to a user through the PositionManager ---

    function _mintFullRangeGeneralPosition(PoolKey memory key, address user, uint256 liquidity)
        internal
        returns (uint256 tokenId)
    {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 amount0Max = 100 ether;
        uint256 amount1Max = 100 ether;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        MockERC20(token0).mint(user, amount0Max);
        MockERC20(token1).mint(user, amount1Max);
        tokenId = positionManagerContract.nextTokenId();
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
            user,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.startPrank(user);
        IERC20(token0).approve(address(permit2Contract), amount0Max);
        IERC20(token1).approve(address(permit2Contract), amount1Max);
        permit2Contract.approve(token0, address(positionManagerContract), uint160(amount0Max), deadline);
        permit2Contract.approve(token1, address(positionManagerContract), uint160(amount1Max), deadline);
        positionManagerContract.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), user);
    }

    /// @notice Mints a deliberately concentrated (non full-range) position for negative staking tests.
    function _mintConcentratedGeneralPosition(PoolKey memory key, address user, uint256 liquidity)
        internal
        returns (uint256 tokenId)
    {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 amount0Max = 100 ether;
        uint256 amount1Max = 100 ether;
        uint48 deadline = uint48(block.timestamp + 1 hours);
        MockERC20(token0).mint(user, amount0Max);
        MockERC20(token1).mint(user, amount1Max);
        tokenId = positionManagerContract.nextTokenId();
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(key.tickSpacing) + key.tickSpacing,
            TickMath.maxUsableTick(key.tickSpacing) - key.tickSpacing,
            liquidity,
            uint128(amount0Max),
            uint128(amount1Max),
            user,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        vm.startPrank(user);
        IERC20(token0).approve(address(permit2Contract), amount0Max);
        IERC20(token1).approve(address(permit2Contract), amount1Max);
        permit2Contract.approve(token0, address(positionManagerContract), uint160(amount0Max), deadline);
        permit2Contract.approve(token1, address(positionManagerContract), uint160(amount1Max), deadline);
        positionManagerContract.modifyLiquidities(abi.encode(actions, params), deadline);
        vm.stopPrank();
    }

    // --- Swapping ---

    function _swapGeneralPool(PoolKey memory key, address user, bool zeroForOne, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        MockERC20(inputToken).mint(user, amountIn);
        _approveV4Router(user, inputToken);
        vm.prank(user);
        delta = v4Router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _createUserPosition(address owner) internal returns (uint256 positionId) {
        uint256 fee = IStaticsPositionFees(address(diamond)).positionCreationFee();
        vm.deal(owner, owner.balance + fee);
        vm.prank(owner);
        positionId = positions.createPosition{value: fee}(owner);
    }

    function _newToken(string memory name) internal returns (address) {
        return address(new MockERC20(name, name, 18));
    }
}
