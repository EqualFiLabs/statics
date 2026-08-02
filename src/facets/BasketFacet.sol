// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketLaunchModule} from "../interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketMint} from "../libraries/LibBasketMint.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLending} from "../libraries/LibLending.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketFacet is IStaticsBasket, ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidBasketDefinition();
    error FeeExceedsCap(uint16 feeBps);
    error LtvExceedsMaximum(uint16 ltvBps);
    error InvalidRecoveryParameters(uint16 ltvBps, uint16 recoveryPenaltyBps);
    error InvalidReceiver();
    error InvalidShares();
    error InvalidAmountsLength();
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error PermissionlessBasketCreationDisabled();
    error IncorrectCreationFee(uint256 expected, uint256 actual);
    error CreationFeeTransferFailed(address treasury, uint256 amount);
    error LiquidityIntegrationNotInstalled();
    error LiquidityManagerNotInstalled();
    error InvalidPoolLaunchParameters();
    error LaunchDeadlineExpired(uint256 deadline, uint256 timestamp);

    function createBasket(
        CreateBasketParams calldata params,
        PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 launchDeadline
    ) external payable nonReentrant returns (uint256 basketId, address token) {
        if (block.timestamp > launchDeadline) {
            revert LaunchDeadlineExpired(launchDeadline, block.timestamp);
        }
        _validateDefinition(params);
        _enforceNotPaused(LibGovernance.PAUSE_LIQUIDITY);
        uint256 assetCount = params.assets.length;
        if (pools.length != assetCount || maxAmountsIn.length != assetCount) {
            revert InvalidPoolLaunchParameters();
        }
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
        if (!ls.managerInstalled) revert LiquidityManagerNotInstalled();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        _collectCreationFee(bs);

        basketId = bs.basketCount;
        bs.basketCount = basketId + 1;
        token = address(new StaticsBasketToken(params.name, params.symbol, address(this), basketId));

        LibBasket.Basket storage created = bs.baskets[basketId];
        created.token = token;
        created.creator = msg.sender;
        created.assets = params.assets;
        created.bundleAmounts = params.bundleAmounts;
        _copyFeeTiers(created.mintFeeTiers, params.mintFeeTiers);
        _copyFeeTiers(created.redemptionFeeTiers, params.redemptionFeeTiers);
        created.flashFeeBps = params.flashFeeBps;
        created.originationFeeBps = params.originationFeeBps;
        created.extensionFeeBps = params.extensionFeeBps;
        created.ltvBps = params.ltvBps;
        created.recoveryPenaltyBps = params.recoveryPenaltyBps;
        created.loanDuration = params.loanDuration;
        bs.basketIds[token] = basketId + 1;

        emit BasketCreated(basketId, token, msg.sender, params.name, params.symbol);
        emit BasketConfigured(
            basketId,
            params.assets,
            params.bundleAmounts,
            params.flashFeeBps,
            params.originationFeeBps,
            params.extensionFeeBps,
            params.ltvBps,
            params.recoveryPenaltyBps,
            params.loanDuration
        );
        _emitFeeTiers(basketId, true, params.mintFeeTiers);
        _emitFeeTiers(basketId, false, params.redemptionFeeTiers);

        uint256 basketShares =
            IStaticsBasketLaunchModule(address(this)).launchBasketPools(basketId, msg.sender, pools, maxAmountsIn);
        emit BasketLaunched(basketId, token, msg.sender, basketShares, assetCount);
    }

    function mint(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        returns (uint256[] memory amountsIn)
    {
        return _mint(basketId, shares, receiver, maxAmountsIn);
    }

    function createAndMintBasketCollateral(
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata maxAmountsIn
    ) external payable nonReentrant returns (uint256 positionId, uint256[] memory amountsIn) {
        if (receiver == address(0)) revert InvalidReceiver();
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.basketLegKey(basketId)
        );
        amountsIn = _mint(basketId, shares, address(this), maxAmountsIn);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibCustody.reserve(LibCustody.basketAccount(basketId), configured.token, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function mintBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        returns (uint256[] memory amountsIn)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        amountsIn = _mint(basketId, shares, address(this), maxAmountsIn);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibCustody.reserve(LibCustody.basketAccount(basketId), configured.token, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function _mint(uint256 basketId, uint256 shares, address receiver, uint256[] calldata maxAmountsIn)
        private
        returns (uint256[] memory amountsIn)
    {
        uint256[] memory maximums = maxAmountsIn;
        return LibBasketMint.mintFromPayer(basketId, shares, msg.sender, receiver, maximums);
    }

    function redeem(uint256 basketId, uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        if (configured.status != BasketStatus.ExitOnly) _enforceNotPaused(LibGovernance.PAUSE_REDEEM);
        if (minAmountsOut.length != configured.assets.length) revert InvalidAmountsLength();
        uint256 supply = IERC20(configured.token).totalSupply();
        if (shares > IERC20(configured.token).balanceOf(msg.sender)) revert InvalidShares();
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, supply);

        StaticsBasketToken(configured.token).burn(msg.sender, shares);
        _redeemUnderlying(bs, configured, basketId, shares, supply, receiver, minAmountsOut, amountsOut);
        emit BasketRedeemed(basketId, msg.sender, receiver, shares);
    }

    function redeemBasketCollateral(
        uint256 positionId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external nonReentrant returns (uint256[] memory amountsOut) {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        if (configured.status != BasketStatus.ExitOnly) _enforceNotPaused(LibGovernance.PAUSE_REDEEM);
        if (minAmountsOut.length != configured.assets.length) revert InvalidAmountsLength();
        uint256 supply = IERC20(configured.token).totalSupply();
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, supply);

        LibBasketRewards.decreasePosition(positionId, basketId, configured, shares);
        LibCustody.release(LibCustody.basketAccount(basketId), configured.token, shares);
        StaticsBasketToken(configured.token).burn(address(this), shares);
        _redeemUnderlying(bs, configured, basketId, shares, supply, receiver, minAmountsOut, amountsOut);
        LibBasketRewards.deactivateIfEmpty(positionId, basketId);
        emit BasketRedeemed(basketId, address(this), receiver, shares);
        emit IStaticsBasketCollateral.BasketCollateralRedeemed(positionId, basketId, receiver, shares);
    }

    function _redeemUnderlying(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256 shares,
        uint256 supply,
        address receiver,
        uint256[] calldata minAmountsOut,
        uint256[] memory amountsOut
    ) private {
        uint256 length = configured.assets.length;
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 baseOut = LibBasket.backingReduction(configured.bundleAmounts[i], supply, shares);
            uint256 payout = amountsOut[i];
            uint256 available = bs.vaultBalances[basketId][asset];
            if (baseOut > available) revert InsufficientVaultBalance(asset, baseOut, available);
            bs.vaultBalances[basketId][asset] = available - baseOut;
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, baseOut - payout);
            uint256 received;
            if (payout != 0) {
                (, received) = LibCustody.pushReserved(custodyAccount, asset, receiver, payout, payout);
            }
            if (received < minAmountsOut[i]) revert MinimumOutputNotMet(asset, received, minAmountsOut[i]);
        }
    }

    function quoteMint(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsIn) {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        amountsIn = LibBasketMint.quote(configured, shares, IERC20(configured.token).totalSupply());
    }

    function quoteRedeem(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsOut) {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, IERC20(configured.token).totalSupply());
    }

    function basket(uint256 basketId) external view returns (BasketView memory result) {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        result = BasketView({
            token: configured.token,
            creator: configured.creator,
            status: configured.status,
            assets: configured.assets,
            bundleAmounts: configured.bundleAmounts,
            mintFeeTiers: configured.mintFeeTiers,
            redemptionFeeTiers: configured.redemptionFeeTiers,
            flashFeeBps: configured.flashFeeBps,
            originationFeeBps: configured.originationFeeBps,
            extensionFeeBps: configured.extensionFeeBps,
            ltvBps: configured.ltvBps,
            recoveryPenaltyBps: configured.recoveryPenaltyBps,
            loanDuration: configured.loanDuration
        });
    }

    function basketStatus(uint256 basketId) external view returns (BasketStatus) {
        return _getBasket(LibBasket.basketStorage(), basketId).status;
    }

    function basketCount() external view returns (uint256) {
        return LibBasket.basketStorage().basketCount;
    }

    function basketIdOf(address token) external view returns (uint256 basketId, bool exists) {
        uint256 plusOne = LibBasket.basketStorage().basketIds[token];
        return plusOne == 0 ? (0, false) : (plusOne - 1, true);
    }

    function vaultBalance(uint256 basketId, address asset) external view returns (uint256) {
        return LibBasket.basketStorage().vaultBalances[basketId][asset];
    }

    function feeSharesFor(uint256 basketId, bool mintAction, uint256 actionShares)
        external
        view
        returns (uint256 feeShares)
    {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return
            LibBasket.selectFeeShares(
                mintAction ? configured.mintFeeTiers : configured.redemptionFeeTiers, actionShares
            );
    }

    function _validateDefinition(CreateBasketParams calldata params) private pure {
        uint256 length = params.assets.length;
        if (length == 0 || length > LibBasket.MAX_ASSETS || length != params.bundleAmounts.length) {
            revert InvalidBasketDefinition();
        }
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0 || params.loanDuration == 0) {
            revert InvalidBasketDefinition();
        }
        _validateFee(params.flashFeeBps);
        _validateFee(params.originationFeeBps);
        _validateFee(params.extensionFeeBps);
        _validateFee(params.recoveryPenaltyBps);
        if (params.ltvBps > LibLending.MAX_LTV_BPS) revert LtvExceedsMaximum(params.ltvBps);
        uint256 maximumRecoverySharesBps = uint256(params.ltvBps)
            + Math.mulDiv(params.ltvBps, params.recoveryPenaltyBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (maximumRecoverySharesBps > LibBasket.BPS) {
            revert InvalidRecoveryParameters(params.ltvBps, params.recoveryPenaltyBps);
        }

        for (uint256 i; i < length; ++i) {
            address asset = params.assets[i];
            if (asset == address(0) || params.bundleAmounts[i] == 0) revert InvalidBasketDefinition();
            for (uint256 j = i + 1; j < length; ++j) {
                if (asset == params.assets[j]) revert InvalidBasketDefinition();
            }
        }
    }

    function _validateFee(uint16 feeBps) private pure {
        if (feeBps > LibBasket.MAX_FEE_BPS) revert FeeExceedsCap(feeBps);
    }

    function _collectCreationFee(LibBasket.BasketStorage storage bs) private {
        uint256 amount = bs.creationFeeAmount;
        if (amount == 0) {
            if (msg.sender != LibDiamond.contractOwner()) revert PermissionlessBasketCreationDisabled();
            if (msg.value != 0) revert IncorrectCreationFee(0, msg.value);
            return;
        }
        if (msg.value != amount) revert IncorrectCreationFee(amount, msg.value);
        address treasury_ = bs.treasury;
        (bool success,) = payable(treasury_).call{value: amount}("");
        if (!success) revert CreationFeeTransferFailed(treasury_, amount);
        emit IStaticsBasketAdmin.CreationFeePaid(msg.sender, treasury_, amount);
    }

    function _quoteRedeem(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256 shares,
        uint256 supply
    ) private view returns (uint256[] memory amountsOut) {
        if (shares == 0 || shares > supply) revert InvalidShares();
        uint256 length = configured.assets.length;
        uint256 feeShares = LibBasket.selectFeeShares(configured.redemptionFeeTiers, shares);
        amountsOut = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 bundleAmount = configured.bundleAmounts[i];
            uint256 baseOut = LibBasket.backingReduction(bundleAmount, supply, shares);
            uint256 available = bs.vaultBalances[basketId][asset];
            if (baseOut > available) revert InsufficientVaultBalance(asset, baseOut, available);
            uint256 fee = LibBasket.convertFeeShares(bundleAmount, feeShares);
            amountsOut[i] = fee < baseOut ? baseOut - fee : 0;
        }
    }

    function _copyFeeTiers(FeeTier[] storage destination, FeeTier[] calldata source) private {
        uint256 length = source.length;
        for (uint256 i; i < length; ++i) {
            destination.push(source[i]);
        }
    }

    function _emitFeeTiers(uint256 basketId, bool mintAction, FeeTier[] calldata tiers) private {
        uint256 length = tiers.length;
        uint256[] memory thresholds = new uint256[](length);
        uint256[] memory fees = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            thresholds[i] = tiers[i].minActionShares;
            fees[i] = tiers[i].feeShares;
        }
        emit BasketFeeTiersConfigured(basketId, mintAction, thresholds, fees);
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceNotPaused(uint256 action) private view {
        if (LibGovernance.governanceStorage().pausedActions & action != 0) revert ActionPaused(action);
    }
}
