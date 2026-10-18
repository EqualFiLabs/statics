// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {StaticsBasketConversionZap} from "../../src/liquidity/StaticsBasketConversionZap.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";

/// A real temporary physical-backing shortage, without editing custody storage.
contract FlashConversionProbe {
    address immutable core;
    StaticsBasketConversionZap immutable zap;
    uint256 immutable basketId;
    PoolId immutable poolId;

    constructor(address c, StaticsBasketConversionZap z, PoolId pool, uint256 id, address bt) {
        core = c;
        poolId = pool;
        zap = z;
        basketId = id;
        IERC20(bt).approve(address(z), type(uint256).max);
    }

    function execute(uint256 flashShares, BasketConversionRequest calldata r) external {
        IStaticsFlashLoan(core).flashLoan(basketId, flashShares, address(this), abi.encode(r));
    }

    function onStaticsFlashLoan(
        address,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == core);
        zap.sell(poolId, 1 ether, address(this), abi.decode(data, (BasketConversionRequest)));
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).approve(core, amounts[i] + fees[i]);
        }
        return keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");
    }
}
