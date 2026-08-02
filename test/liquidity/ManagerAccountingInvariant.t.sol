// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LiquidityManagerTestBase} from "../helpers/LiquidityManagerTestBase.sol";

contract ManagerAccountingHandler {
    StaticsLiquidityManager public immutable manager;
    IPositionManager public immutable positionManager;
    uint256 public immutable basketId;
    address public immutable asset;
    PoolKey private key;

    constructor(
        IPositionManager positionManager_,
        address poolManager,
        IAllowanceTransfer permit2,
        uint256 basketId_,
        address asset_,
        PoolKey memory key_
    ) {
        positionManager = positionManager_;
        basketId = basketId_;
        asset = asset_;
        key = key_;
        manager = new StaticsLiquidityManager(address(this), address(positionManager_), poolManager, address(permit2));
        manager.registerCanonicalPool(basketId_, asset_, key_);
    }

    function credit(uint256 raw0, uint256 raw1) external {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 amount0 = _bound(raw0, IERC20(token0).balanceOf(address(this)));
        uint256 amount1 = _bound(raw1, IERC20(token1).balanceOf(address(this)));
        if (amount0 != 0) {
            IERC20(token0).transfer(address(manager), amount0);
            manager.creditProtocolInventory(basketId, token0, amount0);
        }
        if (amount1 != 0) {
            IERC20(token1).transfer(address(manager), amount1);
            manager.creditProtocolInventory(basketId, token1, amount1);
        }
    }

    function mintProtocol(uint256 rawLiquidity) external {
        if (manager.protocolPositionId(basketId, asset) != 0) return;
        (uint256 available0, uint256 available1) = _inventory();
        uint256 maximum = available0 < available1 ? available0 : available1;
        if (maximum < 1_000) return;
        uint256 liquidity = 1 + rawLiquidity % (maximum / 2);
        try manager.mintProtocolPosition(_request(liquidity, available0, available1)) {} catch {}
    }

    function increaseProtocol(uint256 rawLiquidity) external {
        if (manager.protocolPositionId(basketId, asset) == 0) return;
        (uint256 available0, uint256 available1) = _inventory();
        uint256 maximum = available0 < available1 ? available0 : available1;
        if (maximum < 1_000) return;
        uint256 liquidity = 1 + rawLiquidity % (maximum / 2);
        try manager.increaseProtocolPosition(_request(liquidity, available0, available1)) {} catch {}
    }

    function collect() external {
        if (manager.protocolPositionId(basketId, asset) == 0) return;
        try manager.collectProtocolPosition(basketId, asset, block.timestamp + 1) {} catch {}
    }

    function remove(uint256 rawLiquidity) external {
        uint256 tokenId = manager.protocolPositionId(basketId, asset);
        if (tokenId == 0) return;
        uint256 available = positionManager.getPositionLiquidity(tokenId);
        if (available == 0) return;
        uint256 liquidity = 1 + rawLiquidity % available;
        try manager.removeProtocolLiquidity(basketId, asset, liquidity, 0, 0, block.timestamp + 1) {} catch {}
    }

    function returnInventory(uint256 rawAmount, bool firstCurrency) external {
        address token = Currency.unwrap(firstCurrency ? key.currency0 : key.currency1);
        uint256 available = manager.protocolInventory(basketId, token);
        uint256 amount = _bound(rawAmount, available);
        try manager.returnProtocolInventory(basketId, token, amount) {} catch {}
    }

    function mintUser(uint256 rawLiquidity) external {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 available0 = IERC20(token0).balanceOf(address(this));
        uint256 available1 = IERC20(token1).balanceOf(address(this));
        uint256 provided = available0 < available1 ? available0 : available1;
        if (provided < 1_000) return;
        provided /= 2;
        try this.executeUserMint(rawLiquidity, provided) {} catch {}
    }

    function executeUserMint(uint256 rawLiquidity, uint256 provided) external {
        if (msg.sender != address(this)) return;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        IERC20(token0).transfer(address(manager), provided);
        IERC20(token1).transfer(address(manager), provided);
        uint256 liquidity = 1 + rawLiquidity % provided;
        manager.mintUserPosition(_request(liquidity, provided, provided), address(0xBEEF), address(this));
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function _request(uint256 liquidity, uint256 amount0, uint256 amount1)
        private
        view
        returns (IStaticsLiquidityManager.PositionRequest memory request)
    {
        request = IStaticsLiquidityManager.PositionRequest({
            basketId: basketId,
            asset: asset,
            poolKey: key,
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidity: liquidity,
            amount0Limit: amount0,
            amount1Limit: amount1,
            deadline: block.timestamp + 1
        });
    }

    function _inventory() private view returns (uint256 amount0, uint256 amount1) {
        amount0 = manager.protocolInventory(basketId, Currency.unwrap(key.currency0));
        amount1 = manager.protocolInventory(basketId, Currency.unwrap(key.currency1));
    }

    function _bound(uint256 raw, uint256 maximum) private pure returns (uint256) {
        return maximum == 0 ? 0 : raw % (maximum + 1);
    }
}

contract ManagerAccountingInvariantTest is LiquidityManagerTestBase {
    ManagerAccountingHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new ManagerAccountingHandler(
            positionManagerContract, address(poolManager), permit2Contract, basketId, address(assetA), canonicalKey
        );
        vm.startPrank(alice);
        IERC20(basketToken).transfer(address(handler), 150 ether);
        assetA.transfer(address(handler), 150 ether);
        vm.stopPrank();
        targetContract(address(handler));
    }

    function invariantManagerInventoryIsLocationSolventAndIsolated() public view {
        StaticsLiquidityManager managed = handler.manager();
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        assertEq(managed.totalProtocolInventory(token0), managed.protocolInventory(basketId, token0));
        assertEq(managed.totalProtocolInventory(token1), managed.protocolInventory(basketId, token1));
        assertGe(IERC20(token0).balanceOf(address(managed)), managed.totalProtocolInventory(token0));
        assertGe(IERC20(token1).balanceOf(address(managed)), managed.totalProtocolInventory(token1));
    }

    function invariantManagerLeavesNoV4Allowances() public view {
        StaticsLiquidityManager managed = handler.manager();
        address token0 = Currency.unwrap(canonicalKey.currency0);
        address token1 = Currency.unwrap(canonicalKey.currency1);
        assertEq(IERC20(token0).allowance(address(managed), address(permit2Contract)), 0);
        assertEq(IERC20(token1).allowance(address(managed), address(permit2Contract)), 0);
        (uint160 amount0,,) = permit2Contract.allowance(address(managed), token0, address(positionManagerContract));
        (uint160 amount1,,) = permit2Contract.allowance(address(managed), token1, address(positionManagerContract));
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function invariantProtocolPositionRemainsManagerOwned() public view {
        StaticsLiquidityManager managed = handler.manager();
        uint256 tokenId = managed.protocolPositionId(basketId, address(assetA));
        if (tokenId != 0) {
            assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(managed));
        }
    }
}
