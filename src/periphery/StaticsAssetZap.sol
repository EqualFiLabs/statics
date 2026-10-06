// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {BasketBootstrapCampaign} from "../bootstrap/BasketBootstrapCampaign.sol";
import {BasketBootstrapFactory} from "../bootstrap/BasketBootstrapFactory.sol";

interface IZapWeth is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Typed exact-output v4 conversion with distinct purchase and direct basket-mint settlement.
contract StaticsAssetZap is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Input {
        address token; // zero denotes native ETH, wrapped before entering v4
        uint256 maximum;
        address receiver;
        uint256 deadline;
    }

    struct Route {
        address[] currencies; // forward order; input and destination are explicit
        PoolKey[] pools;
        uint256 maximumInput;
    }

    struct Purchase {
        uint256 auctionIndex;
        uint256 amount;
        uint256 minimumPayment;
    }

    struct Conversion {
        address input;
        uint256 maximum;
        address[] assets;
        uint256[] amounts;
        Route[] routes;
    }

    struct Settlement {
        address input;
        uint256 inputFloor;
        address[] assets;
        uint256[] amounts;
        uint256[] floors;
    }
    address public immutable diamond;
    IPoolManager public immutable poolManager;
    IZapWeth public immutable weth;
    BasketBootstrapFactory public immutable campaignFactory;
    bytes32 private callbackCommitment;
    error InvalidIntegration();
    error InvalidInput();
    error InvalidRoute();
    error InvalidCallback();
    error MaximumInputExceeded();
    error InexactMovement(address token);
    error OutputBoundsExceeded();
    error NativeRefundFailed();

    constructor(address protocol, address wrappedNative, BasketBootstrapFactory campaigns) {
        (address manager,, bool installed) = IStaticsBasketLiquidity(protocol).liquidityIntegration();
        if (
            !installed || manager.code.length == 0 || wrappedNative.code.length == 0
                || address(campaigns).code.length == 0 || campaigns.diamond() != protocol
        ) revert InvalidIntegration();
        diamond = protocol;
        poolManager = IPoolManager(manager);
        weth = IZapWeth(wrappedNative);
        campaignFactory = campaigns;
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert InvalidInput();
    }

    function mintBasket(
        Input calldata input,
        uint256 basketId,
        uint256 shares,
        uint256[] calldata maximumAssetAmounts,
        Route[] calldata routes
    ) external payable nonReentrant returns (uint256 inputSpent) {
        Settlement memory settlement;
        settlement.assets = IStaticsBasket(diamond).basket(basketId).assets;
        settlement.amounts = IStaticsBasket(diamond).quoteMint(basketId, shares);
        if (maximumAssetAmounts.length != settlement.amounts.length) revert InvalidInput();
        for (uint256 i; i < settlement.amounts.length; ++i) {
            if (settlement.amounts[i] > maximumAssetAmounts[i]) revert OutputBoundsExceeded();
        }
        _snapshot(input, settlement);
        _fundInput(input, settlement.input);
        inputSpent = _convert(settlement.input, input.maximum, settlement.assets, settlement.amounts, routes);
        _mintDestination(basketId, shares, input.receiver, settlement);
        _refund(input, settlement.input, inputSpent, settlement.inputFloor);
    }

    function _snapshot(Input calldata input, Settlement memory settlement) private view {
        settlement.input = _inputToken(input);
        settlement.floors = _floors(settlement.assets);
        settlement.inputFloor = IERC20(settlement.input).balanceOf(address(this));
    }

    function _mintDestination(uint256 basketId, uint256 shares, address receiver, Settlement memory settlement)
        private
    {
        uint256[] memory beforeBalances = _approveDestination(settlement.assets, settlement.amounts, diamond);
        uint256[] memory actual = IStaticsBasket(diamond).mint(basketId, shares, receiver, settlement.amounts);
        if (actual.length != settlement.amounts.length) revert OutputBoundsExceeded();
        for (uint256 i; i < actual.length; ++i) {
            if (actual[i] != settlement.amounts[i]) revert OutputBoundsExceeded();
        }
        _clearDestination(settlement.assets, settlement.amounts, beforeBalances, settlement.floors, diamond);
    }

    function purchaseCampaign(
        Input calldata input,
        address campaignAddress,
        Purchase[] calldata purchases,
        uint256 minimumTotalPayment,
        Route[] calldata routes
    ) external payable nonReentrant returns (uint256 inputSpent, uint256 payment) {
        if (!campaignFactory.isCampaign(campaignAddress) || purchases.length == 0 || purchases.length > 16) {
            revert InvalidInput();
        }
        BasketBootstrapCampaign campaign = BasketBootstrapCampaign(campaignAddress);
        Settlement memory settlement;
        settlement.assets = new address[](purchases.length);
        settlement.amounts = new uint256[](purchases.length);
        for (uint256 i; i < purchases.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (purchases[j].auctionIndex == purchases[i].auctionIndex) revert InvalidInput();
            }
            (settlement.assets[i],,,) = campaign.inventory(purchases[i].auctionIndex);
            settlement.amounts[i] = purchases[i].amount;
            if (campaign.quoteFill(purchases[i].auctionIndex, settlement.amounts[i]) < purchases[i].minimumPayment) {
                revert OutputBoundsExceeded();
            }
        }
        _snapshot(input, settlement);
        _fundInput(input, settlement.input);
        inputSpent = _convert(settlement.input, input.maximum, settlement.assets, settlement.amounts, routes);
        payment = _purchaseDestination(input, campaign, purchases, settlement);
        if (payment < minimumTotalPayment) revert OutputBoundsExceeded();
        _refund(input, settlement.input, inputSpent, settlement.inputFloor);
    }

    function _purchaseDestination(
        Input calldata input,
        BasketBootstrapCampaign campaign,
        Purchase[] calldata purchases,
        Settlement memory settlement
    ) private returns (uint256 payment) {
        uint256[] memory beforeBalances = _approveDestination(settlement.assets, settlement.amounts, address(campaign));
        for (uint256 i; i < purchases.length; ++i) {
            Purchase calldata purchase = purchases[i];
            payment += campaign.fill(
                purchase.auctionIndex, purchase.amount, purchase.minimumPayment, input.receiver, input.deadline
            );
        }
        _clearDestination(settlement.assets, settlement.amounts, beforeBalances, settlement.floors, address(campaign));
    }

    function _inputToken(Input calldata input) private view returns (address token) {
        if (
            input.maximum == 0 || input.receiver == address(0) || input.receiver == address(this)
                || block.timestamp > input.deadline
        ) revert InvalidInput();
        token = input.token == address(0) ? address(weth) : input.token;
        if (token.code.length == 0 || IStaticsBasketSettlement(diamond).isRestrictedBasketToken(token)) {
            revert InvalidInput();
        }
    }

    function _fundInput(Input calldata input, address token) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        if (input.token == address(0)) {
            if (msg.value != input.maximum) revert InvalidInput();
            weth.deposit{value: input.maximum}();
        } else {
            if (msg.value != 0) revert InvalidInput();
            uint256 payerBefore = IERC20(token).balanceOf(msg.sender);
            IERC20(token).safeTransferFrom(msg.sender, address(this), input.maximum);
            if (IERC20(token).balanceOf(msg.sender) + input.maximum != payerBefore) revert InexactMovement(token);
        }
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + input.maximum) revert InexactMovement(token);
    }

    function _convert(
        address input,
        uint256 maximum,
        address[] memory assets,
        uint256[] memory amounts,
        Route[] calldata routes
    ) private returns (uint256 spent) {
        if (routes.length != amounts.length) revert InvalidRoute();
        for (uint256 i; i < routes.length; ++i) {
            _validateRoute(input, assets[i], routes[i]);
        }
        bytes memory data = abi.encode(Conversion(input, maximum, assets, amounts, routes));
        callbackCommitment = keccak256(data);
        spent = abi.decode(poolManager.unlock(data), (uint256));
        if (callbackCommitment != bytes32(0) || spent > maximum) revert MaximumInputExceeded();
    }

    function _validateRoute(address input, address output, Route calldata route) private pure {
        uint256 hops = route.pools.length;
        if (
            hops > 8 || route.currencies.length != hops + 1 || route.maximumInput == 0 || route.currencies[0] != input
                || route.currencies[hops] != output
        ) revert InvalidRoute();
        for (uint256 i; i < hops; ++i) {
            address from = route.currencies[i];
            address to = route.currencies[i + 1];
            PoolKey calldata pool = route.pools[i];
            if (
                from == address(0) || to == address(0) || from == to
                    || Currency.unwrap(pool.currency0) != (from < to ? from : to)
                    || Currency.unwrap(pool.currency1) != (from < to ? to : from)
            ) revert InvalidRoute();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || callbackCommitment == bytes32(0)
                || keccak256(data) != callbackCommitment
        ) revert InvalidCallback();
        callbackCommitment = bytes32(0);
        Conversion memory conversion = abi.decode(data, (Conversion));
        uint256 spent;
        for (uint256 i; i < conversion.routes.length; ++i) {
            // Supply-sensitive backing rounding may make one valid mint requirement zero.
            if (conversion.amounts[i] == 0) continue;
            uint256 cost = _swapRoute(conversion.routes[i], conversion.amounts[i]);
            if (cost > conversion.routes[i].maximumInput) revert MaximumInputExceeded();
            spent += cost;
            if (spent > conversion.maximum) revert MaximumInputExceeded();
            if (conversion.routes[i].pools.length != 0) {
                _settle(conversion.input, cost);
                _take(conversion.assets[i], conversion.amounts[i]);
            }
        }
        return abi.encode(spent);
    }

    function _swapRoute(Route memory route, uint256 amountOut) private returns (uint256 amountIn) {
        amountIn = amountOut;
        if (amountOut == 0 || amountOut > uint256(uint128(type(int128).max))) revert InvalidRoute();
        for (uint256 i = route.pools.length; i != 0;) {
            --i;
            bool zeroForOne = Currency.unwrap(route.pools[i].currency0) == route.currencies[i];
            BalanceDelta delta = poolManager.swap(
                route.pools[i],
                SwapParams(
                    zeroForOne, int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
            int128 received = zeroForOne ? delta.amount1() : delta.amount0();
            int128 debit = zeroForOne ? delta.amount0() : delta.amount1();
            if (received <= 0 || debit >= 0 || uint256(uint128(received)) != amountIn) revert InvalidRoute();
            amountIn = uint256(-int256(debit));
        }
    }

    function _settle(address token, uint256 amount) private {
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(address(this));
        poolManager.sync(Currency.wrap(token));
        asset.safeTransfer(address(poolManager), amount);
        if (poolManager.settle() != amount || asset.balanceOf(address(this)) + amount != beforeBalance) {
            revert InexactMovement(token);
        }
    }

    function _take(address token, uint256 amount) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        poolManager.take(Currency.wrap(token), address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + amount) revert InexactMovement(token);
    }

    function _floors(address[] memory assets) private view returns (uint256[] memory floors) {
        floors = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            floors[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    function _approveDestination(address[] memory assets, uint256[] memory amounts, address destination)
        private
        returns (uint256[] memory balances)
    {
        balances = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
            IERC20(assets[i]).forceApprove(destination, amounts[i]);
        }
    }

    function _clearDestination(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory beforeBalances,
        uint256[] memory floors,
        address destination
    ) private {
        for (uint256 i; i < assets.length; ++i) {
            IERC20 asset = IERC20(assets[i]);
            uint256 balance = asset.balanceOf(address(this));
            if (balance + amounts[i] != beforeBalances[i] || balance < floors[i]) revert InexactMovement(assets[i]);
            asset.forceApprove(destination, 0);
        }
    }

    function _refund(Input calldata input, address token, uint256 spent, uint256 floor) private {
        uint256 remaining = input.maximum - spent;
        if (IERC20(token).balanceOf(address(this)) < floor + remaining) revert InexactMovement(token);
        if (remaining == 0) return;
        if (input.token == address(0)) {
            uint256 beforeBalance = address(this).balance;
            weth.withdraw(remaining);
            if (address(this).balance != beforeBalance + remaining) revert InexactMovement(token);
            (bool ok,) = payable(msg.sender).call{value: remaining}("");
            if (!ok) revert NativeRefundFailed();
        } else {
            uint256 payerBefore = IERC20(token).balanceOf(msg.sender);
            uint256 held = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, remaining);
            if (
                IERC20(token).balanceOf(address(this)) + remaining != held
                    || IERC20(token).balanceOf(msg.sender) != payerBefore + remaining
            ) revert InexactMovement(token);
        }
    }
}
