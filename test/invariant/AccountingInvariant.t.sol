// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract AccountingHandler is Test, IERC721Receiver {
    IStaticsBasket internal immutable BASKETS;
    IStaticsLending internal immutable LENDING;
    IStaticsBasketRewards internal immutable BASKET_REWARDS;
    IERC20 internal immutable BASKET_TOKEN;
    MockERC20 internal immutable ASSET_A;
    MockERC20 internal immutable ASSET_B;
    uint256 internal immutable BASKET_ID;
    address internal immutable DIAMOND;

    uint256[] internal loanIds;
    uint256 internal basketPositionId;

    constructor(address diamond, uint256 basketId, address basketToken, MockERC20 assetA, MockERC20 assetB) {
        DIAMOND = diamond;
        BASKET_ID = basketId;
        BASKETS = IStaticsBasket(diamond);
        LENDING = IStaticsLending(diamond);
        BASKET_REWARDS = IStaticsBasketRewards(diamond);
        BASKET_TOKEN = IERC20(basketToken);
        ASSET_A = assetA;
        ASSET_B = assetB;
        assetA.approve(diamond, type(uint256).max);
        assetB.approve(diamond, type(uint256).max);
        BASKET_TOKEN.approve(diamond, type(uint256).max);
    }

    function mintShares(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1_000 ether);
        uint256[] memory quote = BASKETS.quoteMint(BASKET_ID, shares);
        if (ASSET_A.balanceOf(address(this)) < quote[0] || ASSET_B.balanceOf(address(this)) < quote[1]) return;
        BASKETS.mint(BASKET_ID, shares, address(this), quote);
    }

    function redeemShares(uint256 rawShares) external {
        uint256 balance = BASKET_TOKEN.balanceOf(address(this));
        if (balance == 0) return;
        uint256 shares = bound(rawShares, 1, balance);
        uint256[] memory quote = BASKETS.quoteRedeem(BASKET_ID, shares);
        BASKETS.redeem(BASKET_ID, shares, address(this), quote);
    }

    function borrowAgainstShares(uint256 rawShares) external {
        if (basketPositionId == 0) return;
        IStaticsBasketRewards.BasketPositionView memory position =
            BASKET_REWARDS.basketPosition(basketPositionId, BASKET_ID);
        uint256 unlocked = position.eligibleShares - position.lockedShares;
        if (unlocked < 1e12) return;
        uint256 shares = bound(rawShares, 1e12, unlocked);
        try LENDING.borrow(basketPositionId, BASKET_ID, shares, address(this)) returns (
            uint256 loanId, uint256[] memory
        ) {
            loanIds.push(loanId);
        } catch {}
    }

    function repayLoan(uint256 rawIndex) external {
        uint256 length = loanIds.length;
        if (length == 0) return;
        uint256 index = rawIndex % length;
        uint256 loanId = loanIds[index];
        try LENDING.repay(loanId) {
            loanIds[index] = loanIds[length - 1];
            loanIds.pop();
        } catch {}
    }

    function extendLoan(uint256 rawIndex, uint256 rawOverpayment) external {
        uint256 length = loanIds.length;
        if (length == 0) return;
        uint256 loanId = loanIds[rawIndex % length];
        IStaticsLending.LoanView memory current = LENDING.loan(loanId);
        if (block.timestamp > current.maturity) return;
        (, uint256[] memory requiredFees) = LENDING.quoteExtension(loanId);
        uint256 feeLength = requiredFees.length;
        uint256[] memory grossAmountsIn = new uint256[](feeLength);
        for (uint256 i; i < feeLength; ++i) {
            grossAmountsIn[i] = requiredFees[i] + (rawOverpayment % (requiredFees[i] + 1));
        }
        try LENDING.extend(loanId, grossAmountsIn) returns (uint256[] memory) {} catch {}
    }

    function mintPositionShares(uint256 rawShares) external {
        uint256 shares = bound(rawShares, 1e12, 1_000 ether);
        uint256[] memory quote = BASKETS.quoteMint(BASKET_ID, shares);
        if (ASSET_A.balanceOf(address(this)) < quote[0] || ASSET_B.balanceOf(address(this)) < quote[1]) return;
        if (basketPositionId == 0) {
            (basketPositionId,) = BASKET_REWARDS.createAndMintBasket(BASKET_ID, shares, address(this), quote);
        } else {
            BASKET_REWARDS.mintBasketToPosition(basketPositionId, BASKET_ID, shares, quote);
        }
    }

    function depositLooseShares(uint256 rawShares) external {
        uint256 balance = BASKET_TOKEN.balanceOf(address(this));
        if (balance == 0) return;
        uint256 shares = bound(rawShares, 1, balance);
        if (basketPositionId == 0) {
            basketPositionId = BASKET_REWARDS.createAndDepositBasket(BASKET_ID, shares, address(this));
        } else {
            BASKET_REWARDS.depositBasket(basketPositionId, BASKET_ID, shares);
        }
    }

    function withdrawPositionShares(uint256 rawShares) external {
        if (basketPositionId == 0) return;
        IStaticsBasketRewards.BasketPositionView memory position =
            BASKET_REWARDS.basketPosition(basketPositionId, BASKET_ID);
        uint256 unlocked = position.eligibleShares - position.lockedShares;
        if (unlocked == 0) return;
        uint256 shares = bound(rawShares, 1, unlocked);
        vm.roll(block.number + 1);
        BASKET_REWARDS.withdrawBasket(basketPositionId, BASKET_ID, shares, address(this));
    }

    function redeemPositionShares(uint256 rawShares) external {
        if (basketPositionId == 0) return;
        IStaticsBasketRewards.BasketPositionView memory position =
            BASKET_REWARDS.basketPosition(basketPositionId, BASKET_ID);
        uint256 unlocked = position.eligibleShares - position.lockedShares;
        if (unlocked == 0) return;
        uint256 shares = bound(rawShares, 1, unlocked);
        uint256[] memory quote = BASKETS.quoteRedeem(BASKET_ID, shares);
        vm.roll(block.number + 1);
        BASKET_REWARDS.redeemBasketFromPosition(basketPositionId, BASKET_ID, shares, address(this), quote);
    }

    function claimPositionRewards() external {
        if (basketPositionId == 0) return;
        (, uint256[] memory pending) = BASKET_REWARDS.pendingBasketRewards(basketPositionId, BASKET_ID);
        if (pending[0] == 0 && pending[1] == 0) return;
        uint256[] memory minimums = new uint256[](2);
        BASKET_REWARDS.claimBasketRewards(basketPositionId, BASKET_ID, address(this), minimums);
    }

    function positionId() external view returns (uint256) {
        return basketPositionId;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AccountingInvariantTest is StdInvariant, StaticsTestBase {
    uint256 internal basketId;
    address internal basketToken;
    AccountingHandler internal handler;

    function setUp() public override(StaticsTestBase) {
        StaticsTestBase.setUp();
        (basketId, basketToken) = _createDefaultBasket(0.1 ether, 0.05 ether);
        handler = new AccountingHandler(address(diamond), basketId, basketToken, assetA, assetB);
        assetA.mint(address(handler), 1e36);
        assetB.mint(address(handler), 1e36);
        targetContract(address(handler));
    }

    function invariantPhysicalBalancesCoverEveryRecordedLedger() public view {
        _assertAssetLedger(assetA);
        _assertAssetLedger(assetB);
    }

    function invariantBaseBackingPlusPrincipalsEqualsStaticSupply() public view {
        uint256 supply = IERC20(basketToken).totalSupply();
        uint256 requiredA = Math.mulDiv(2 ether, supply, 1 ether, Math.Rounding.Ceil);
        uint256 requiredB = Math.mulDiv(5 ether, supply, 1 ether, Math.Rounding.Ceil);
        assertEq(
            baskets.vaultBalance(basketId, address(assetA)) + lending.outstandingPrincipal(basketId, address(assetA)),
            requiredA
        );
        assertEq(
            baskets.vaultBalance(basketId, address(assetB)) + lending.outstandingPrincipal(basketId, address(assetB)),
            requiredB
        );
    }

    function invariantEscrowedBasketSharesNeverExceedSupply() public view {
        assertLe(IERC20(basketToken).balanceOf(address(diamond)), IERC20(basketToken).totalSupply());
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(basketId), basketToken),
            IERC20(basketToken).balanceOf(address(diamond))
        );
    }

    function invariantRewardClaimsRemainCoveredAndIsolated() public view {
        _assertRewardLedger(assetA);
        _assertRewardLedger(assetB);
        uint256 positionId = handler.positionId();
        if (positionId != 0) {
            IStaticsBasketRewards.BasketPositionView memory position =
                basketRewards.basketPosition(positionId, basketId);
            assertLe(position.lockedShares, position.eligibleShares);
            assertEq(
                basketRewards.basketRewardState(basketId, address(assetA)).totalEligibleShares, position.eligibleShares
            );
        }
    }

    function _assertAssetLedger(MockERC20 asset) private view {
        uint256 recorded = baskets.vaultBalance(basketId, address(asset))
            + basketAdmin.protocolRevenue(basketId, address(asset))
            + basketLiquidity.liquidityReserve(basketId, address(asset))
            + basketRewards.basketRewardState(basketId, address(asset)).feeYieldReserve
            + lending.recoverySurplus(basketId, address(asset));
        assertEq(asset.balanceOf(address(diamond)), recorded);
        assertEq(custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(asset)), recorded);
        assertEq(custody.globalReservedByToken(address(asset)), recorded);
    }

    function _assertRewardLedger(MockERC20 asset) private view {
        IStaticsBasketRewards.BasketRewardState memory state = basketRewards.basketRewardState(basketId, address(asset));
        assertLe(state.totalClaimable, state.feeYieldReserve);
    }
}
