// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {FeeRouterFacet} from "src/dollar/periphery/facets/FeeRouterFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {IStaticsBasket} from "src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketLiquidity} from "src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLending} from "src/interfaces/IStaticsLending.sol";
import {IStaticsPosition} from "src/interfaces/IStaticsPosition.sol";
import {LibPosition} from "src/position/LibPosition.sol";
import {StaticsSwapFeeHook} from "src/liquidity/StaticsSwapFeeHook.sol";
import {MockERC20, MockReentrantERC20, MockSenderExtraFeeERC20} from "test/mocks/MockERC20.sol";
import {MockLaunchLiquidityManager} from "test/mocks/MockLaunchLiquidityManager.sol";

struct UnifiedHandlerConfig {
    address diamond;
    address core;
    address weth;
    address staticsDollar;
    address staticsDollarRisk;
    address oracle;
    address peggedOracle;
    address senderExtraToken;
    address reentrantToken;
    uint256 peggedProfileId;
    uint256 firstBasketId;
    uint256 secondBasketId;
    address firstBasketToken;
    address secondBasketToken;
}

contract UnifiedProtocolHandler is Test, IERC721Receiver, IERC1155Receiver {
    uint256 internal constant SERIES_ID = 1;
    uint256 internal constant PRICE_WAD = 2_500e18;
    uint256 internal constant SHARE_SCALE = 1e18;
    uint256 internal constant RECOVERY_GRACE_PERIOD = 1 hours;

    address internal immutable DIAMOND;
    IStaticsDollarCore internal immutable CORE;
    IStaticsDollarGateway internal immutable GATEWAY;
    CanonicalWETH9 internal immutable WETH;
    StaticsDollar internal immutable STATICS_DOLLAR;
    StaticsDollarRiskShares internal immutable STATICS_DOLLAR_RISK;
    MockETHUSDOracle internal immutable ORACLE;
    MockETHUSDOracle internal immutable PEGGED_ORACLE;
    MockSenderExtraFeeERC20 internal immutable SENDER_EXTRA;
    MockReentrantERC20 internal immutable REENTRANT;
    IStaticsBasket internal immutable BASKETS;
    IStaticsBasketCollateral internal immutable BASKET_COLLATERAL;
    IStaticsLending internal immutable LENDING;
    IStaticsCustody internal immutable CUSTODY;
    IStaticsPosition internal immutable POSITIONS;
    IERC721 internal immutable POSITION_NFT;
    StakingFacet internal immutable STAKING;
    FeeRouterFacet internal immutable FEE_ROUTER;
    IStaticsGlobalRewards internal immutable GLOBAL_REWARDS;

    uint256 internal immutable FIRST_BASKET_ID;
    uint256 internal immutable SECOND_BASKET_ID;
    uint256 internal immutable PEGGED_PROFILE_ID;
    address internal immutable FIRST_BASKET_TOKEN;
    address internal immutable SECOND_BASKET_TOKEN;
    bytes32 internal immutable FIRST_BASKET_ACCOUNT;
    bytes32 internal immutable SECOND_BASKET_ACCOUNT;
    bytes32 internal immutable DOLLAR_ACCOUNT;

    uint256 internal sharedPositionId;
    uint256[] internal activeLoanIds;

    bool public crossModuleReservationChanged;
    bool public siblingBasketReservationChanged;
    bool public directGatewayFeeParityBroken;
    bool public peggedGatewayFeeParityBroken;
    bool public livePositionClosed;

    constructor(UnifiedHandlerConfig memory config) payable {
        DIAMOND = config.diamond;
        CORE = IStaticsDollarCore(config.core);
        GATEWAY = IStaticsDollarGateway(config.diamond);
        WETH = CanonicalWETH9(payable(config.weth));
        STATICS_DOLLAR = StaticsDollar(config.staticsDollar);
        STATICS_DOLLAR_RISK = StaticsDollarRiskShares(config.staticsDollarRisk);
        ORACLE = MockETHUSDOracle(config.oracle);
        PEGGED_ORACLE = MockETHUSDOracle(config.peggedOracle);
        SENDER_EXTRA = MockSenderExtraFeeERC20(config.senderExtraToken);
        REENTRANT = MockReentrantERC20(config.reentrantToken);
        BASKETS = IStaticsBasket(config.diamond);
        BASKET_COLLATERAL = IStaticsBasketCollateral(config.diamond);
        LENDING = IStaticsLending(config.diamond);
        CUSTODY = IStaticsCustody(config.diamond);
        POSITIONS = IStaticsPosition(config.diamond);
        POSITION_NFT = IERC721(config.diamond);
        STAKING = StakingFacet(config.diamond);
        FEE_ROUTER = FeeRouterFacet(config.diamond);
        GLOBAL_REWARDS = IStaticsGlobalRewards(config.diamond);
        FIRST_BASKET_ID = config.firstBasketId;
        SECOND_BASKET_ID = config.secondBasketId;
        PEGGED_PROFILE_ID = config.peggedProfileId;
        FIRST_BASKET_TOKEN = config.firstBasketToken;
        SECOND_BASKET_TOKEN = config.secondBasketToken;
        FIRST_BASKET_ACCOUNT = CUSTODY.basketCustodyAccount(config.firstBasketId);
        SECOND_BASKET_ACCOUNT = CUSTODY.basketCustodyAccount(config.secondBasketId);
        DOLLAR_ACCOUNT = CUSTODY.dollarCustodyAccount();

        WETH.deposit{value: msg.value}();
        IERC20(config.weth).approve(config.diamond, type(uint256).max);
        IERC20(config.senderExtraToken).approve(config.diamond, type(uint256).max);
        IERC20(config.reentrantToken).approve(config.diamond, type(uint256).max);
        IERC20(config.firstBasketToken).approve(config.diamond, type(uint256).max);
        IERC20(config.secondBasketToken).approve(config.diamond, type(uint256).max);
        STATICS_DOLLAR.approve(config.diamond, type(uint256).max);
        STATICS_DOLLAR.approve(config.core, type(uint256).max);
        STATICS_DOLLAR_RISK.setApprovalForAll(config.diamond, true);

        uint256[] memory minimums = new uint256[](3);
        REENTRANT.setCallback(
            config.diamond,
            config.diamond,
            abi.encodeCall(IStaticsBasket.redeem, (config.firstBasketId, uint256(1), config.reentrantToken, minimums))
        );
    }

    function depositAndStakeDollar(uint256 rawAmount) external {
        bytes32 basketReservationsBefore = _basketReservationsHash();
        uint256 amount = bound(rawAmount, 0.001 ether, 2 ether);
        vm.deal(address(this), address(this).balance + amount);
        ORACLE.setPriceWad(PRICE_WAD);
        ORACLE.setUpdatedAt(block.timestamp);

        try GATEWAY.depositETH{value: amount}(address(this), address(this), 0, 0) returns (
            uint256, uint256, uint256 sharesMinted
        ) {
            uint256 stakeAmount = sharesMinted / 2;
            if (stakeAmount != 0) {
                if (sharedPositionId == 0) {
                    try STAKING.createAndStakeRiskShares(SERIES_ID, stakeAmount, address(this)) returns (
                        uint256 newPositionId
                    ) {
                        sharedPositionId = newPositionId;
                    } catch {}
                } else {
                    try STAKING.stakeRiskShares(sharedPositionId, SERIES_ID, stakeAmount) {} catch {}
                }
            }
        } catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function claimDollarProceeds() external {
        if (sharedPositionId == 0) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        StakingFacet.RiskLiquidityView memory state = STAKING.riskLiquidity(sharedPositionId, SERIES_ID);
        if (state.claimableCollateral != 0 || state.claimableStaticsDollar != 0 || state.claimableStatics != 0) {
            try STAKING.claimRiskProceeds(sharedPositionId, SERIES_ID, address(this)) {} catch {}
        }
        _observeDollarIsolation(basketReservationsBefore);
    }

    function routeDollarInsurance() external {
        bytes32 basketReservationsBefore = _basketReservationsHash();
        try FEE_ROUTER.routePendingInsurance(1) {} catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function mintPeggedDollar(uint256 rawAmount) external {
        bytes32 basketReservationsBefore = _basketReservationsHash();
        PEGGED_ORACLE.setPriceWad(1e18);
        PEGGED_ORACLE.setUpdatedAt(block.timestamp);
        uint256 amount = bound(rawAmount, 1e12, 100 ether);
        try GATEWAY.previewPeggedMint(PEGGED_PROFILE_ID, amount) returns (
            IStaticsDollarCoreTypes.PeggedMintPreview memory preview
        ) {
            if (SENDER_EXTRA.balanceOf(address(this)) >= preview.totalCollateralIn) {
                try GATEWAY.mintPegged(PEGGED_PROFILE_ID, amount, preview.totalCollateralIn, address(this)) {} catch {}
            }
        } catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function redeemPeggedDollar(uint256 rawAmount) external {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = CORE.collateralProfile(PEGGED_PROFILE_ID);
        uint256 available = STATICS_DOLLAR.balanceOf(address(this));
        if (profile.seniorOutstanding < available) available = profile.seniorOutstanding;
        if (available == 0) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        ORACLE.setPriceWad(PRICE_WAD);
        ORACLE.setUpdatedAt(block.timestamp);
        PEGGED_ORACLE.setPriceWad(1e18);
        PEGGED_ORACLE.setUpdatedAt(block.timestamp);
        (IStaticsDollarCoreTypes.ExitStatus status,,,) = GATEWAY.peggedRedemptionStatus();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            _observeDollarIsolation(basketReservationsBefore);
            return;
        }
        uint256 amount = bound(rawAmount, 1, available);
        try GATEWAY.redeemPegged(PEGGED_PROFILE_ID, amount, 0, address(this)) returns (
            IStaticsDollarCoreTypes.ExitStatus, uint256
        ) {}
            catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function compareDirectAndGatewayPeggedRedemption(uint256 rawAmount) external {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = CORE.collateralProfile(PEGGED_PROFILE_ID);
        uint256 available = STATICS_DOLLAR.balanceOf(address(this)) / 2;
        if (profile.seniorOutstanding / 2 < available) available = profile.seniorOutstanding / 2;
        if (available < 1e12) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        ORACLE.setPriceWad(PRICE_WAD);
        ORACLE.setUpdatedAt(block.timestamp);
        PEGGED_ORACLE.setPriceWad(1e18);
        PEGGED_ORACLE.setUpdatedAt(block.timestamp);
        (IStaticsDollarCoreTypes.ExitStatus status,,,) = GATEWAY.peggedRedemptionStatus();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            _observeDollarIsolation(basketReservationsBefore);
            return;
        }
        uint256 amount = bound(rawAmount, 1e12, available);
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory gatewayPreview =
            GATEWAY.previewPeggedRedemption(PEGGED_PROFILE_ID, amount);

        try GATEWAY.redeemPegged(PEGGED_PROFILE_ID, amount, gatewayPreview.collateralOut, address(this)) returns (
            IStaticsDollarCoreTypes.ExitStatus gatewayStatus, uint256 gatewayOut
        ) {
            if (
                gatewayStatus != IStaticsDollarCoreTypes.ExitStatus.Available
                    || gatewayOut != gatewayPreview.collateralOut
            ) {
                peggedGatewayFeeParityBroken = true;
            } else {
                IStaticsDollarCoreTypes.PeggedRedemptionPreview memory directPreview =
                    CORE.previewPeggedRedemption(PEGGED_PROFILE_ID, amount);
                try CORE.redeemPegged(PEGGED_PROFILE_ID, amount, directPreview.collateralOut, address(this)) returns (
                    IStaticsDollarCoreTypes.ExitStatus directStatus, uint256 directOut
                ) {
                    if (
                        directStatus != IStaticsDollarCoreTypes.ExitStatus.Available
                            || directOut != directPreview.collateralOut
                            || directPreview.feeAmount != gatewayPreview.feeAmount
                    ) {
                        peggedGatewayFeeParityBroken = true;
                    }
                } catch {
                    peggedGatewayFeeParityBroken = true;
                }
            }
        } catch {
            peggedGatewayFeeParityBroken = true;
        }
        _observeDollarIsolation(basketReservationsBefore);
    }

    function distributePeggedTreasuryFees(uint256) external {
        uint256 available = GLOBAL_REWARDS.treasuryAccrued(address(SENDER_EXTRA));
        if (available == 0) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        try GLOBAL_REWARDS.distributeTreasuryFees(address(SENDER_EXTRA)) returns (uint256) {} catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function recombineThroughGateway(uint256 rawAmount) external {
        uint256 available = _loosePairBalance();
        if (available < 1e12) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        ORACLE.setPriceWad(PRICE_WAD);
        ORACLE.setUpdatedAt(block.timestamp);
        uint256 amount = bound(rawAmount, 1e12, available);
        try GATEWAY.recombineToWETH(SERIES_ID, amount, amount, address(this), 0) returns (
            IStaticsDollarCoreTypes.ExitStatus, uint256
        ) {}
            catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function compareDirectAndGatewayRecombination(uint256 rawAmount) external {
        uint256 available = _loosePairBalance() / 2;
        if (available < 1e12) return;
        bytes32 basketReservationsBefore = _basketReservationsHash();
        ORACLE.setPriceWad(PRICE_WAD);
        ORACLE.setUpdatedAt(block.timestamp);
        uint256 amount = bound(rawAmount, 1e12, available);
        IStaticsDollarCoreTypes.RedemptionPreview memory gatewayPreview = CORE.previewRecombine(SERIES_ID, amount);

        try GATEWAY.recombineToWETH(SERIES_ID, amount, amount, address(this), 0) returns (
            IStaticsDollarCoreTypes.ExitStatus gatewayStatus, uint256 gatewayOut
        ) {
            if (gatewayStatus == IStaticsDollarCoreTypes.ExitStatus.Available) {
                if (gatewayOut != gatewayPreview.collateralOut) directGatewayFeeParityBroken = true;
                IStaticsDollarCoreTypes.RedemptionPreview memory directPreview =
                    CORE.previewRecombine(SERIES_ID, amount);
                try CORE.recombine(SERIES_ID, amount, amount, 0, address(this)) returns (
                    IStaticsDollarCoreTypes.ExitStatus directStatus, uint256 directOut
                ) {
                    if (
                        directStatus != IStaticsDollarCoreTypes.ExitStatus.Available
                            || directOut != directPreview.collateralOut
                    ) {
                        directGatewayFeeParityBroken = true;
                    }
                } catch {
                    directGatewayFeeParityBroken = true;
                }
            }
        } catch {}
        _observeDollarIsolation(basketReservationsBefore);
    }

    function mintBasketToSharedPosition(uint256 rawBasket, uint256 rawShares) external {
        (uint256 basketId,, bytes32 otherAccount) = _basket(rawBasket);
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        _ensureSharedPosition();
        if (sharedPositionId != 0) {
            uint256 shares = bound(rawShares, 0.02 ether, 10 ether);
            uint256[] memory maximums = BASKETS.quoteMint(basketId, shares);
            try BASKET_COLLATERAL.mintBasketCollateral(sharedPositionId, basketId, shares, maximums) {} catch {}
        }
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function redeemBasketFromSharedPosition(uint256 rawBasket, uint256 rawShares) external {
        if (sharedPositionId == 0) return;
        (uint256 basketId,, bytes32 otherAccount) = _basket(rawBasket);
        IStaticsBasketCollateral.BasketCollateralPosition memory current =
            BASKET_COLLATERAL.basketCollateralPosition(sharedPositionId, basketId);
        uint256 unlocked = current.depositedShares - current.lockedShares;
        if (unlocked == 0) return;
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        uint256 shares = bound(rawShares, 1, unlocked);
        uint256[] memory minimums = new uint256[](3);
        vm.roll(block.number + 1);
        try BASKET_COLLATERAL.redeemBasketCollateral(sharedPositionId, basketId, shares, address(this), minimums) {}
            catch {}
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function borrowAndLoop(uint256 rawBasket, uint256 rawShares) external {
        if (sharedPositionId == 0) return;
        (uint256 basketId, uint256 wethBundle, bytes32 otherAccount) = _basket(rawBasket);
        IStaticsBasketCollateral.BasketCollateralPosition memory current =
            BASKET_COLLATERAL.basketCollateralPosition(sharedPositionId, basketId);
        uint256 unlocked = current.depositedShares - current.lockedShares;
        if (unlocked < 1e12) return;
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        uint256 shares = bound(rawShares, 1e12, unlocked);

        try LENDING.borrow(sharedPositionId, basketId, shares, address(this)) returns (
            uint256 loanId, uint256[] memory principals
        ) {
            activeLoanIds.push(loanId);
            uint256 nextLayerShares = Math.mulDiv(principals[0], SHARE_SCALE, wethBundle);
            if (nextLayerShares != 0) {
                uint256[] memory maximums = BASKETS.quoteMint(basketId, nextLayerShares);
                try BASKET_COLLATERAL.mintBasketCollateral(sharedPositionId, basketId, nextLayerShares, maximums) {}
                    catch {}
            }
        } catch {}
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function repayLoan(uint256 rawIndex) external {
        uint256 length = activeLoanIds.length;
        if (length == 0) return;
        uint256 index = rawIndex % length;
        uint256 loanId = activeLoanIds[index];
        IStaticsLending.LoanView memory current = LENDING.loan(loanId);
        (,, bytes32 otherAccount) = _basket(current.basketId == FIRST_BASKET_ID ? 0 : 1);
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        try LENDING.repay(loanId) {
            _removeLoan(index);
        } catch {}
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function extendLoan(uint256 rawIndex, uint256 rawOverpayment) external {
        uint256 length = activeLoanIds.length;
        if (length == 0) return;
        uint256 loanId = activeLoanIds[rawIndex % length];
        IStaticsLending.LoanView memory current = LENDING.loan(loanId);
        if (block.timestamp > current.maturity) return;
        (,, bytes32 otherAccount) = _basket(current.basketId == FIRST_BASKET_ID ? 0 : 1);
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        (, uint256[] memory requiredFees) = LENDING.quoteExtension(loanId);
        uint256 feeLength = requiredFees.length;
        uint256[] memory grossAmountsIn = new uint256[](feeLength);
        for (uint256 i; i < feeLength; ++i) {
            grossAmountsIn[i] = requiredFees[i] + (rawOverpayment % (requiredFees[i] + 1));
        }
        try LENDING.extend(loanId, grossAmountsIn) returns (uint256[] memory) {} catch {}
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function recoverLoan(uint256 rawIndex) external {
        uint256 length = activeLoanIds.length;
        if (length == 0) return;
        uint256 index = rawIndex % length;
        uint256 loanId = activeLoanIds[index];
        IStaticsLending.LoanView memory current = LENDING.loan(loanId);
        (,, bytes32 otherAccount) = _basket(current.basketId == FIRST_BASKET_ID ? 0 : 1);
        bytes32 dollarReservationsBefore = _dollarReservationsHash();
        bytes32 siblingBefore = _accountReservationsHash(otherAccount);
        vm.warp(uint256(current.maturity) + RECOVERY_GRACE_PERIOD + 1);
        try LENDING.recover(loanId) {
            _removeLoan(index);
        } catch {}
        _observeBasketIsolation(dollarReservationsBefore, siblingBefore, otherAccount);
    }

    function transferPositionRoundTrip(uint256 rawActor) external {
        if (sharedPositionId == 0) return;
        bytes32 allReservationsBefore = _allReservationsHash();
        address actor = address(uint160(bound(rawActor, 100, type(uint160).max)));
        if (actor == address(this) || actor == DIAMOND || actor.code.length != 0) return;
        try POSITION_NFT.transferFrom(address(this), actor, sharedPositionId) {
            vm.prank(actor);
            POSITION_NFT.transferFrom(actor, address(this), sharedPositionId);
        } catch {}
        if (_allReservationsHash() != allReservationsBefore) crossModuleReservationChanged = true;
    }

    function attemptCloseLivePosition() external {
        if (sharedPositionId == 0 || POSITIONS.activeLegCount(sharedPositionId) == 0) return;
        try POSITIONS.closePosition(sharedPositionId) {
            livePositionClosed = true;
        } catch {}
    }

    function setSenderExtraTax(uint256 enabled) external {
        SENDER_EXTRA.setTaxedSender(enabled % 2 == 0 ? address(0) : DIAMOND);
    }

    function positionId() external view returns (uint256) {
        return sharedPositionId;
    }

    function loanCount() external view returns (uint256) {
        return activeLoanIds.length;
    }

    function loanIdAt(uint256 index) external view returns (uint256) {
        return activeLoanIds[index];
    }

    function _ensureSharedPosition() private {
        if (sharedPositionId != 0) return;
        try POSITIONS.createPosition(address(this)) returns (uint256 positionId_) {
            sharedPositionId = positionId_;
        } catch {}
    }

    function _removeLoan(uint256 index) private {
        uint256 last = activeLoanIds.length - 1;
        activeLoanIds[index] = activeLoanIds[last];
        activeLoanIds.pop();
    }

    function _loosePairBalance() private view returns (uint256 available) {
        available = STATICS_DOLLAR.balanceOf(address(this));
        uint256 riskBalance = STATICS_DOLLAR_RISK.balanceOf(address(this), SERIES_ID);
        if (riskBalance < available) available = riskBalance;
    }

    function _basket(uint256 rawBasket)
        private
        view
        returns (uint256 basketId, uint256 wethBundle, bytes32 otherAccount)
    {
        if (rawBasket % 2 == 0) {
            return (FIRST_BASKET_ID, 0.001 ether, SECOND_BASKET_ACCOUNT);
        }
        return (SECOND_BASKET_ID, 0.002 ether, FIRST_BASKET_ACCOUNT);
    }

    function _observeDollarIsolation(bytes32 basketReservationsBefore) private {
        if (_basketReservationsHash() != basketReservationsBefore) crossModuleReservationChanged = true;
    }

    function _observeBasketIsolation(bytes32 dollarReservationsBefore, bytes32 siblingBefore, bytes32 siblingAccount)
        private
    {
        if (_dollarReservationsHash() != dollarReservationsBefore) crossModuleReservationChanged = true;
        if (_accountReservationsHash(siblingAccount) != siblingBefore) siblingBasketReservationChanged = true;
    }

    function _basketReservationsHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(_accountReservationsHash(FIRST_BASKET_ACCOUNT), _accountReservationsHash(SECOND_BASKET_ACCOUNT))
        );
    }

    function _dollarReservationsHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                CUSTODY.reservedByAccount(DOLLAR_ACCOUNT, address(WETH)),
                CUSTODY.reservedByAccount(DOLLAR_ACCOUNT, address(STATICS_DOLLAR)),
                CUSTODY.reservedByAccount(DOLLAR_ACCOUNT, address(SENDER_EXTRA))
            )
        );
    }

    function _accountReservationsHash(bytes32 account) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                CUSTODY.reservedByAccount(account, address(WETH)),
                CUSTODY.reservedByAccount(account, address(SENDER_EXTRA)),
                CUSTODY.reservedByAccount(account, address(REENTRANT)),
                CUSTODY.reservedByAccount(account, FIRST_BASKET_TOKEN),
                CUSTODY.reservedByAccount(account, SECOND_BASKET_TOKEN)
            )
        );
    }

    function _allReservationsHash() private view returns (bytes32) {
        return keccak256(abi.encode(_dollarReservationsHash(), _basketReservationsHash()));
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC721Receiver).interfaceId;
    }
}

contract UnifiedProtocolInvariantTest is StdInvariant, Test {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant FIRST_WETH_BUNDLE = 0.001 ether;
    uint256 internal constant SECOND_WETH_BUNDLE = 0.002 ether;
    uint256 internal constant MAX_LTV_BPS = 9_500;
    uint256 internal constant BPS = 10_000;

    StaticsDollarStackDeployment internal deployment;
    IStaticsBasket internal baskets;
    IStaticsBasketAdmin internal basketAdmin;
    IStaticsBasketCollateral internal basketCollateral;
    IStaticsBasketLiquidity internal basketLiquidity;
    IStaticsLending internal lending;
    IStaticsCustody internal custody;
    IStaticsPosition internal positions;
    FeeRouterFacet internal feeRouter;
    IStaticsGlobalRewards internal globalRewards;
    StakingFacet internal staking;
    CanonicalWETH9 internal weth;
    StaticsDollar internal staticsDollar;
    MockSenderExtraFeeERC20 internal senderExtra;
    MockReentrantERC20 internal reentrant;
    MockETHUSDOracle internal peggedOracle;
    UnifiedProtocolHandler internal handler;

    uint256 internal firstBasketId;
    uint256 internal secondBasketId;
    address internal firstBasketToken;
    address internal secondBasketToken;
    uint256 internal peggedProfileId;

    function setUp() public {
        vm.warp(1_700_000_000);
        StaticsDollarLocalConfig memory config;
        config.owner = address(this);
        config.profileGuardian = address(this);
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        deployment = new DeployStaticsDollar().deployLocal(config);

        baskets = IStaticsBasket(deployment.diamond);
        basketAdmin = IStaticsBasketAdmin(deployment.diamond);
        basketCollateral = IStaticsBasketCollateral(deployment.diamond);
        basketLiquidity = IStaticsBasketLiquidity(deployment.diamond);
        lending = IStaticsLending(deployment.diamond);
        custody = IStaticsCustody(deployment.diamond);
        positions = IStaticsPosition(deployment.diamond);
        feeRouter = FeeRouterFacet(deployment.diamond);
        globalRewards = IStaticsGlobalRewards(deployment.diamond);
        staking = StakingFacet(deployment.diamond);
        weth = CanonicalWETH9(payable(deployment.weth));
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        senderExtra = new MockSenderExtraFeeERC20();
        reentrant = new MockReentrantERC20();
        peggedOracle = new MockETHUSDOracle(1e18, type(uint256).max);
        _installBasketLaunchLiquidity();

        vm.deal(address(this), 1_000_000 ether);
        (firstBasketId, firstBasketToken) =
            _createSharedBasket("Static Shared One", "sSHARE1", FIRST_WETH_BUNDLE, 2 ether, 3 ether);
        (secondBasketId, secondBasketToken) =
            _createSharedBasket("Static Shared Two", "sSHARE2", SECOND_WETH_BUNDLE, 5 ether, 7 ether);
        peggedProfileId = CoreGovernanceFacet(deployment.core)
            .createPeggedCollateralProfile(
                address(senderExtra), address(peggedOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18
            );
        CoreGovernanceFacet(deployment.core).setProfileMode(peggedProfileId, IStaticsDollarCoreTypes.ProfileMode.Active);

        UnifiedHandlerConfig memory handlerConfig = UnifiedHandlerConfig({
            diamond: deployment.diamond,
            core: deployment.core,
            weth: deployment.weth,
            staticsDollar: deployment.staticsDollar,
            staticsDollarRisk: deployment.staticsDollarRisk,
            oracle: deployment.oracle,
            peggedOracle: address(peggedOracle),
            senderExtraToken: address(senderExtra),
            reentrantToken: address(reentrant),
            peggedProfileId: peggedProfileId,
            firstBasketId: firstBasketId,
            secondBasketId: secondBasketId,
            firstBasketToken: firstBasketToken,
            secondBasketToken: secondBasketToken
        });
        handler = new UnifiedProtocolHandler{value: 100_000 ether}(handlerConfig);
        senderExtra.mint(address(handler), 1e36);
        reentrant.mint(address(handler), 1e36);
        basketAdmin.setTreasury(address(handler));
        _seedCombinedValueFlows();
        targetContract(address(handler));
    }

    function invariantPhysicalBalancesCoverGlobalAndModuleReservations() public view {
        bytes32 dollarAccount = custody.dollarCustodyAccount();
        bytes32 firstAccount = custody.basketCustodyAccount(firstBasketId);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        bytes32 stakingAccount = custody.stakingCustodyAccount();

        _assertCovered(address(weth));
        _assertCovered(address(senderExtra));
        _assertCovered(address(reentrant));
        _assertCovered(address(staticsDollar));
        _assertCovered(firstBasketToken);
        _assertCovered(secondBasketToken);

        assertEq(
            custody.globalReservedByToken(address(weth)),
            custody.reservedByAccount(dollarAccount, address(weth))
                + custody.reservedByAccount(firstAccount, address(weth))
                + custody.reservedByAccount(secondAccount, address(weth))
                + custody.reservedByAccount(feeAccount, address(weth))
                + custody.reservedByAccount(stakingAccount, address(weth))
        );
        assertEq(
            custody.globalReservedByToken(address(senderExtra)),
            custody.reservedByAccount(dollarAccount, address(senderExtra))
                + custody.reservedByAccount(firstAccount, address(senderExtra))
                + custody.reservedByAccount(secondAccount, address(senderExtra))
                + custody.reservedByAccount(feeAccount, address(senderExtra))
                + custody.reservedByAccount(stakingAccount, address(senderExtra))
        );
        assertEq(
            custody.globalReservedByToken(address(reentrant)),
            custody.reservedByAccount(firstAccount, address(reentrant))
                + custody.reservedByAccount(secondAccount, address(reentrant))
                + custody.reservedByAccount(feeAccount, address(reentrant))
                + custody.reservedByAccount(stakingAccount, address(reentrant))
        );
        assertEq(
            custody.globalReservedByToken(address(staticsDollar)),
            custody.reservedByAccount(dollarAccount, address(staticsDollar))
                + custody.reservedByAccount(feeAccount, address(staticsDollar))
                + custody.reservedByAccount(stakingAccount, address(staticsDollar))
        );
        assertEq(
            custody.globalReservedByToken(firstBasketToken),
            custody.reservedByAccount(firstAccount, firstBasketToken)
                + custody.reservedByAccount(feeAccount, firstBasketToken)
                + custody.reservedByAccount(stakingAccount, firstBasketToken)
        );
        assertEq(
            custody.globalReservedByToken(secondBasketToken),
            custody.reservedByAccount(secondAccount, secondBasketToken)
                + custody.reservedByAccount(feeAccount, secondBasketToken)
                + custody.reservedByAccount(stakingAccount, secondBasketToken)
        );
    }

    function invariantEveryModuleReservationEqualsItsInternalBooks() public view {
        _assertBasketBooks(firstBasketId, firstBasketToken);
        _assertBasketBooks(secondBasketId, secondBasketToken);

        bytes32 dollarAccount = custody.dollarCustodyAccount();
        uint256 wethLiabilities = staking.reservedBalance(address(weth)) + feeRouter.pendingInsurance(1);
        assertEq(custody.reservedByAccount(dollarAccount, address(weth)), wethLiabilities);
        assertEq(
            custody.reservedByAccount(dollarAccount, address(staticsDollar)),
            staking.reservedBalance(address(staticsDollar))
        );
        assertEq(
            custody.reservedByAccount(custody.feeCustodyAccount(), address(senderExtra)),
            globalRewards.treasuryAccrued(address(senderExtra))
        );
        assertEq(custody.reservedByAccount(custody.stakingCustodyAccount(), address(weth)), globalRewards.totalStaked());
        assertEq(staticsDollar.totalSupply(), IStaticsDollarCore(deployment.core).seniorLiabilities());
    }

    function invariantCrossModuleAndSiblingActionsRemainIsolated() public view {
        assertFalse(handler.crossModuleReservationChanged());
        assertFalse(handler.siblingBasketReservationChanged());
        assertFalse(handler.directGatewayFeeParityBroken());
        assertFalse(handler.peggedGatewayFeeParityBroken());
        assertFalse(handler.livePositionClosed());
        assertFalse(reentrant.reentrySucceeded());
    }

    function invariantLiveValuesKeepTheirPositionLegsAttached() public view {
        uint256 positionId = handler.positionId();
        if (positionId == 0) return;
        IERC721(deployment.diamond).ownerOf(positionId);

        uint256 expectedActiveLegs;
        StakingFacet.RiskLiquidityView memory dollarLeg = staking.riskLiquidity(positionId, 1);
        bool dollarHasValue = dollarLeg.effectiveShares != 0 || dollarLeg.claimableCollateral != 0
            || dollarLeg.claimableStaticsDollar != 0 || dollarLeg.claimableStatics != 0;
        if (dollarHasValue) {
            assertTrue(positions.isPositionLegActive(positionId, LibPosition.dollarLegKey(1)));
        }
        if (positions.isPositionLegActive(positionId, LibPosition.dollarLegKey(1))) ++expectedActiveLegs;

        if (_assertBasketPositionLeg(positionId, firstBasketId)) ++expectedActiveLegs;
        if (_assertBasketPositionLeg(positionId, secondBasketId)) ++expectedActiveLegs;
        assertEq(positions.activeLegCount(positionId), expectedActiveLegs);

        uint256 firstLocked;
        uint256 secondLocked;
        uint256 length = handler.loanCount();
        for (uint256 i; i < length; ++i) {
            IStaticsLending.LoanView memory current = lending.loan(handler.loanIdAt(i));
            assertEq(current.positionId, positionId);
            assertTrue(positions.isPositionLegActive(positionId, LibPosition.basketLegKey(current.basketId)));
            if (current.basketId == firstBasketId) firstLocked += current.collateralShares;
            else secondLocked += current.collateralShares;
        }
        assertEq(basketCollateral.basketCollateralPosition(positionId, firstBasketId).lockedShares, firstLocked);
        assertEq(basketCollateral.basketCollateralPosition(positionId, secondBasketId).lockedShares, secondLocked);
    }

    function invariantRecursiveBorrowingRemainsBoundedAtNinetyFivePercent() public view {
        uint256 positionId = handler.positionId();
        if (positionId == 0) return;
        _assertDebtBound(positionId, firstBasketId, FIRST_WETH_BUNDLE);
        _assertDebtBound(positionId, secondBasketId, SECOND_WETH_BUNDLE);
    }

    function _assertCovered(address token) private view {
        assertGe(IERC20(token).balanceOf(deployment.diamond), custody.globalReservedByToken(token));
    }

    function _seedCombinedValueFlows() private {
        handler.mintPeggedDollar(100 ether);
        assertEq(IStaticsDollarCore(deployment.core).collateralProfile(peggedProfileId).seniorOutstanding, 100 ether);

        handler.compareDirectAndGatewayPeggedRedemption(1 ether);
        assertEq(IStaticsDollarCore(deployment.core).collateralProfile(peggedProfileId).seniorOutstanding, 98 ether);

        uint256 revenueBefore = globalRewards.treasuryAccrued(address(senderExtra));
        assertGt(revenueBefore, 1);
        uint256 treasuryBalanceBefore = senderExtra.balanceOf(address(handler));
        handler.distributePeggedTreasuryFees(revenueBefore);
        assertEq(globalRewards.treasuryAccrued(address(senderExtra)), 0);
        assertEq(senderExtra.balanceOf(address(handler)), treasuryBalanceBefore + revenueBefore);

        handler.mintBasketToSharedPosition(0, 1 ether);
        handler.borrowAndLoop(0, 0.5 ether);
        assertGt(handler.loanCount(), 0);
        uint256 loanId = handler.loanIdAt(0);
        uint40 maturityBefore = lending.loan(loanId).maturity;
        handler.extendLoan(0, 0);
        assertEq(lending.loan(loanId).maturity, uint256(maturityBefore) + 30 days);
    }

    function _assertBasketBooks(uint256 basketId, address basketToken) private view {
        IStaticsBasket.BasketView memory configured = baskets.basket(basketId);
        bytes32 account = custody.basketCustodyAccount(basketId);
        for (uint256 i; i < configured.assets.length; ++i) {
            address asset = configured.assets[i];
            uint256 recorded = baskets.vaultBalance(basketId, asset);
            assertEq(custody.reservedByAccount(account, asset), recorded);
        }
        assertEq(custody.reservedByAccount(account, basketToken), IERC20(basketToken).balanceOf(deployment.diamond));
    }

    function _assertBasketPositionLeg(uint256 positionId, uint256 basketId) private view returns (bool active) {
        active = positions.isPositionLegActive(positionId, LibPosition.basketLegKey(basketId));
        IStaticsBasketCollateral.BasketCollateralPosition memory current =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        bool hasValue = current.depositedShares != 0 || current.lockedShares != 0;
        if (hasValue) assertTrue(active);
    }

    function _assertDebtBound(uint256 positionId, uint256 basketId, uint256 wethBundle) private view {
        IStaticsBasketCollateral.BasketCollateralPosition memory current =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        uint256 wethPrincipal = lending.outstandingPrincipal(basketId, address(weth));
        uint256 debtShares;
        uint256 loanCount;
        uint256 length = handler.loanCount();
        for (uint256 i; i < length; ++i) {
            IStaticsLending.LoanView memory opened = lending.loan(handler.loanIdAt(i));
            if (opened.basketId != basketId) continue;
            debtShares += opened.debtShares;
            ++loanCount;
        }
        assertLe(wethPrincipal, Math.mulDiv(wethBundle, debtShares, 1e18));
        uint256 roundingAllowance = loanCount == 0 ? 0 : loanCount - 1;
        assertLe(
            debtShares, Math.mulDiv(current.lockedShares, MAX_LTV_BPS, BPS, Math.Rounding.Ceil) + roundingAllowance
        );
        assertLe(
            debtShares, Math.mulDiv(current.depositedShares, MAX_LTV_BPS, BPS, Math.Rounding.Ceil) + roundingAllowance
        );
    }

    function _createSharedBasket(
        string memory name,
        string memory symbol,
        uint256 wethBundle,
        uint256 senderExtraBundle,
        uint256 reentrantBundle
    ) private returns (uint256 basketId, address basketToken) {
        address[] memory assets = new address[](3);
        assets[0] = address(weth);
        assets[1] = address(senderExtra);
        assets[2] = address(reentrant);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = wethBundle;
        amounts[1] = senderExtraBundle;
        amounts[2] = reentrantBundle;
        IStaticsBasket.FeeTier[] memory mintFees = new IStaticsBasket.FeeTier[](1);
        mintFees[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: 0.01 ether});
        IStaticsBasket.FeeTier[] memory redemptionFees = new IStaticsBasket.FeeTier[](1);
        redemptionFees[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: 0.005 ether});
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: name,
            symbol: symbol,
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: mintFees,
            redemptionFeeTiers: redemptionFees,
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: uint16(MAX_LTV_BPS),
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](3);
        uint256[] memory maximums = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            pools[i] =
                IStaticsBasket.PoolLaunchParams({sqrtPriceAssetPerBasketX96: 1 << 96, pairedAssetAmount: 1 ether});
            maximums[i] = 1_000_000 ether;
        }
        weth.deposit{value: 1_000 ether}();
        senderExtra.mint(address(this), 1_000_000 ether);
        reentrant.mint(address(this), 1_000_000 ether);
        IERC20(address(weth)).approve(deployment.diamond, type(uint256).max);
        IERC20(address(senderExtra)).approve(deployment.diamond, type(uint256).max);
        IERC20(address(reentrant)).approve(deployment.diamond, type(uint256).max);
        return baskets.createBasket{value: basketAdmin.creationFee()}(params, pools, maximums, type(uint256).max);
    }

    function _installBasketLaunchLiquidity() private {
        IPoolManager poolManager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        bytes memory constructorArgs = abi.encode(poolManager, deployment.diamond, uint16(25), uint16(25));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        StaticsSwapFeeHook hook = new StaticsSwapFeeHook{salt: salt}(poolManager, deployment.diamond, 25, 25);
        assertEq(address(hook), expected);
        MockLaunchLiquidityManager manager = new MockLaunchLiquidityManager(deployment.diamond, address(poolManager));
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(hook));
        basketLiquidity.installLiquidityManager(address(manager));
    }

    receive() external payable {}
}
