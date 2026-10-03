// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract ImmutablePermit2AllowanceToken is ERC20 {
    address private immutable permit2;

    error Permit2AllowanceIsFixedAtInfinity();

    constructor(address permit2_) ERC20("Infinite Permit2", "IP2") {
        permit2 = permit2_;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        if (spender == permit2) return type(uint256).max;
        return super.allowance(owner, spender);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (spender == permit2) revert Permit2AllowanceIsFixedAtInfinity();
        return super.approve(spender, value);
    }
}

contract StandardLiquidityToken is ERC20 {
    constructor() ERC20("Standard", "STD") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract StaticsLiquidityManagerPermit2Test is LiquidityManagerTestBase {
    using PoolIdLibrary for PoolKey;

    function testManagedMintSupportsImmutableInfinitePermit2Allowance() public {
        ImmutablePermit2AllowanceToken infinite = new ImmutablePermit2AllowanceToken(address(permit2Contract));
        StandardLiquidityToken standard = new StandardLiquidityToken();
        (address token0, address token1) = address(infinite) < address(standard)
            ? (address(infinite), address(standard))
            : (address(standard), address(infinite));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);
        IStaticsProtocolPools.ProtocolPoolView memory pool;
        pool.poolId = key.toId();
        pool.key = key;
        pool.kind = IStaticsProtocolPools.ProtocolPoolKind.General;
        _setManagerPoolOverride(pool);

        StaticsLiquidityManager managerWithInfiniteAllowance = new StaticsLiquidityManager(
            address(this), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        infinite.mint(address(managerWithInfiniteAllowance), 10 ether);
        standard.mint(address(managerWithInfiniteAllowance), 10 ether);
        IStaticsLiquidityManager.PositionRequest memory request = IStaticsLiquidityManager.PositionRequest({
            poolKey: key,
            tickLower: -600,
            tickUpper: 600,
            liquidity: 5 ether,
            amount0Limit: 10 ether,
            amount1Limit: 10 ether,
            deadline: block.timestamp + 1 hours
        });

        IStaticsLiquidityManager.ManagedPositionMovement memory movement =
            managerWithInfiniteAllowance.mintManagedPosition(request, alice);

        assertEq(
            IERC721(address(positionManagerContract)).ownerOf(movement.tokenId), address(managerWithInfiniteAllowance)
        );
        assertEq(positionManagerContract.getPositionLiquidity(movement.tokenId), 5 ether);
        assertEq(infinite.allowance(address(managerWithInfiniteAllowance), address(permit2Contract)), type(uint256).max);
        assertEq(standard.allowance(address(managerWithInfiniteAllowance), address(permit2Contract)), 0);
        (uint160 infiniteScoped,,) = permit2Contract.allowance(
            address(managerWithInfiniteAllowance), address(infinite), address(positionManagerContract)
        );
        (uint160 standardScoped,,) = permit2Contract.allowance(
            address(managerWithInfiniteAllowance), address(standard), address(positionManagerContract)
        );
        assertEq(infiniteScoped, 0);
        assertEq(standardScoped, 0);
        assertEq(IERC20(token0).balanceOf(address(managerWithInfiniteAllowance)), 0);
        assertEq(IERC20(token1).balanceOf(address(managerWithInfiniteAllowance)), 0);
    }
}
