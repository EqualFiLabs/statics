// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsFeeReceiver} from "../interfaces/IStaticsFeeReceiver.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

interface IDopplerFeeSource {
    function collectFees(bytes32 poolId) external returns (uint128 fees0, uint128 fees1);
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256 shares);
    function getPoolKey(bytes32 poolId)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

/// @notice Permanent donation-resistant ingress for Statics' 95% share of standard Doppler Multicurve fees.
contract StaticsFeeReceiver is IStaticsFeeReceiver, Ownable2Step, ReentrancyGuard {
    using LibExactAssetTransfer for IERC20;

    IDopplerFeeSource public immutable feeSource;
    address public immutable override poolInitializer;
    address public immutable override numeraire;
    address public override statics;
    bytes32 public override poolId;
    address public override activeDistributor;
    address public override pendingDistributor;

    mapping(address asset => uint256 amount) public override cumulativeHarvested;
    mapping(address distributor => mapping(address asset => uint256 amount))
        public
        override cumulativeDistributorAttributed;
    mapping(address distributor => mapping(address asset => uint256 amount)) public override distributorClaimable;
    mapping(address asset => uint256 amount) public override totalDistributorLiability;

    error InvalidPoolInitializer();
    error InvalidNumeraire();
    error InvalidMarket();
    error MarketAlreadyBound();
    error MarketNotBound();
    error InvalidDistributor(address distributor);
    error UnauthorizedPendingDistributor(address caller);
    error DistributorNotActive();
    error InvalidReceiver(address receiver);
    error BalanceDecreased(address asset, uint256 beforeBalance, uint256 afterBalance);
    error NoDistributorFees(address distributor, address asset);
    error InsufficientSurplus(address asset, uint256 available, uint256 requested);
    error OwnershipRenunciationDisabled();

    constructor(address poolInitializer_, address numeraire_, address governance) Ownable(governance) {
        if (poolInitializer_ == address(0) || poolInitializer_.code.length == 0) {
            revert InvalidPoolInitializer();
        }
        if (numeraire_ == address(0) || numeraire_.code.length == 0) revert InvalidNumeraire();
        feeSource = IDopplerFeeSource(poolInitializer_);
        poolInitializer = poolInitializer_;
        numeraire = numeraire_;
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function bindMarket(address statics_, bytes32 poolId_) external override onlyOwner {
        if (statics != address(0)) revert MarketAlreadyBound();
        if (statics_ == address(0) || statics_.code.length == 0 || statics_ == numeraire) revert InvalidMarket();
        (address currency0, address currency1,,, address hooks) = feeSource.getPoolKey(poolId_);
        bool pairMatches =
            (currency0 == statics_ && currency1 == numeraire) || (currency0 == numeraire && currency1 == statics_);
        if (!pairMatches || hooks != poolInitializer || feeSource.getShares(poolId_, address(this)) != 0.95 ether) {
            revert InvalidMarket();
        }
        statics = statics_;
        poolId = poolId_;
        emit MarketBound(statics_, numeraire, poolId_);
    }

    function harvest() external override nonReentrant returns (uint256 staticsAmount, uint256 numeraireAmount) {
        address distributor = activeDistributor;
        if (distributor == address(0)) revert DistributorNotActive();
        return _harvest(distributor);
    }

    function proposeDistributor(address distributor) external override onlyOwner {
        if (distributor == address(0) || distributor.code.length == 0 || distributor == activeDistributor) {
            revert InvalidDistributor(distributor);
        }
        pendingDistributor = distributor;
        emit DistributorProposed(activeDistributor, distributor);
    }

    function acceptDistributor() external override nonReentrant {
        address pending = pendingDistributor;
        if (msg.sender != pending) revert UnauthorizedPendingDistributor(msg.sender);
        if (statics == address(0)) revert MarketNotBound();
        address previous = activeDistributor;
        if (previous == address(0)) {
            activeDistributor = pending;
            delete pendingDistributor;
            emit DistributorAccepted(address(0), pending);
            _harvest(pending);
            return;
        }
        _harvest(previous);
        activeDistributor = pending;
        delete pendingDistributor;
        emit DistributorAccepted(previous, pending);
    }

    function claimDistributorFees(address asset, address receiver)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver(receiver);
        amount = distributorClaimable[msg.sender][asset];
        if (amount == 0) revert NoDistributorFees(msg.sender, asset);
        delete distributorClaimable[msg.sender][asset];
        totalDistributorLiability[asset] -= amount;
        IERC20(asset).pushExact(receiver, amount);
        emit DistributorFeesClaimed(msg.sender, asset, receiver, amount);
    }

    function recoverSurplus(address asset, address receiver, uint256 amount) external override onlyOwner nonReentrant {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver(receiver);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 liability = totalDistributorLiability[asset];
        uint256 available = balance > liability ? balance - liability : 0;
        if (amount > available) revert InsufficientSurplus(asset, available, amount);
        IERC20(asset).pushExact(receiver, amount);
        emit SurplusRecovered(asset, receiver, amount);
    }

    function _harvest(address distributor) private returns (uint256 staticsAmount, uint256 numeraireAmount) {
        address asset = statics;
        if (asset == address(0)) revert MarketNotBound();
        IERC20 staticsToken = IERC20(asset);
        IERC20 numeraireToken = IERC20(numeraire);
        uint256 staticsBefore = staticsToken.balanceOf(address(this));
        uint256 numeraireBefore = numeraireToken.balanceOf(address(this));
        feeSource.collectFees(poolId);
        uint256 staticsAfter = staticsToken.balanceOf(address(this));
        uint256 numeraireAfter = numeraireToken.balanceOf(address(this));
        if (staticsAfter < staticsBefore) revert BalanceDecreased(asset, staticsBefore, staticsAfter);
        if (numeraireAfter < numeraireBefore) revert BalanceDecreased(numeraire, numeraireBefore, numeraireAfter);
        staticsAmount = staticsAfter - staticsBefore;
        numeraireAmount = numeraireAfter - numeraireBefore;
        _attribute(distributor, asset, staticsAmount);
        _attribute(distributor, numeraire, numeraireAmount);
    }

    function _attribute(address distributor, address asset, uint256 amount) private {
        if (amount == 0) return;
        cumulativeHarvested[asset] += amount;
        cumulativeDistributorAttributed[distributor][asset] += amount;
        distributorClaimable[distributor][asset] += amount;
        totalDistributorLiability[asset] += amount;
        emit FeesHarvested(distributor, asset, amount, cumulativeHarvested[asset]);
    }
}
