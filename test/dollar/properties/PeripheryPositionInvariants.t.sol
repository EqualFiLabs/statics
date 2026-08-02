// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskSeriesRewards} from "src/dollar/interfaces/IStaticsDollarRiskSeriesRewards.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {IStaticsPosition} from "src/interfaces/IStaticsPosition.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {FeeRouterFacet} from "src/dollar/periphery/facets/FeeRouterFacet.sol";
import {OptInFacet} from "src/dollar/periphery/facets/OptInFacet.sol";
import {PairingVaultFacet} from "src/dollar/periphery/facets/PairingVaultFacet.sol";
import {RewardsFacet} from "src/dollar/periphery/facets/RewardsFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {LibPeriphery} from "src/dollar/periphery/libraries/LibPeriphery.sol";

contract PeripheryPositionHandler is Test, IERC1155Receiver {
    uint256 internal constant SERIES_ID = 1;

    CanonicalWETH9 internal immutable weth;
    IStaticsDollarCore internal immutable pool;
    StaticsDollarRiskShares internal immutable staticsDollarRisk;
    StaticsDollar internal immutable staticsDollar;
    IERC721 internal immutable positionNFT;
    StakingFacet internal immutable staking;
    OptInFacet internal immutable optIn;
    PairingVaultFacet internal immutable vault;
    RewardsFacet internal immutable rewards;
    address internal immutable diamond;

    uint256[] internal positions;
    mapping(uint256 positionId => bool open) internal positionOpen;

    constructor(StaticsDollarStackDeployment memory deployment) {
        weth = CanonicalWETH9(payable(deployment.weth));
        pool = IStaticsDollarCore(deployment.pool);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        positionNFT = IERC721(deployment.positionNFT);
        staking = StakingFacet(deployment.diamond);
        optIn = OptInFacet(deployment.diamond);
        vault = PairingVaultFacet(deployment.diamond);
        rewards = RewardsFacet(deployment.diamond);
        diamond = deployment.diamond;
        staticsDollarRisk.setApprovalForAll(deployment.diamond, true);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        weth.approve(deployment.diamond, type(uint256).max);
    }

    function depositAndStake(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e12, 1 ether);
        try pool.previewDeposit(1, amount) returns (IStaticsDollarCoreTypes.DepositPreview memory) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.approve(address(pool), amount);
            IStaticsDollarCoreTypes.DepositPreview memory preview = pool.previewDeposit(1, amount);
            (, uint256 minted, uint256 shares) = pool.depositCollateral(
                1, amount, preview.staticsDollarMinted, preview.sharesMinted, address(this), address(this)
            );
            if (minted == 0 || shares == 0) return;
            uint256 positionId = staking.createAndStake(SERIES_ID, shares, address(this));
            positions.push(positionId);
            positionOpen[positionId] = true;
        } catch {}
    }

    function activate(uint256 rawIndex) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        LibPeriphery.PositionLeg memory leg = staking.leg(positionId, SERIES_ID);
        if (leg.pendingPrincipal == 0) return;
        vm.warp(block.timestamp + 24 hours);
        staking.activateLeg(positionId, SERIES_ID);
    }

    function optInPrincipal(uint256 rawIndex, uint256 rawAmount) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        LibPeriphery.PositionLeg memory leg = staking.leg(positionId, SERIES_ID);
        uint256 available = leg.pendingPrincipal + leg.eligiblePrincipal;
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        try optIn.optIn(positionId, SERIES_ID, amount) {}
        catch (bytes memory reason) {
            bytes4 selector;
            if (reason.length >= 4) {
                assembly ("memory-safe") {
                    selector := mload(add(reason, 0x20))
                }
            }
            if (selector != OptInFacet.OptInAmountTooSmall.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    function optOutPrincipal(uint256 rawIndex, uint256 rawAmount) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        uint256 available = optIn.optInBalanceOf(positionId, SERIES_ID);
        if (available == 0) return;
        optIn.optOut(positionId, SERIES_ID, bound(rawAmount, 1, available), address(this));
    }

    function redeemOptIn(uint256 rawAmount) external {
        uint256 available = optIn.optInTotal(SERIES_ID);
        uint256 balance = staticsDollar.balanceOf(address(this));
        if (available == 0 || balance == 0) return;
        uint256 maximum = available < balance ? available : balance;
        uint256 amount = bound(rawAmount, 1, maximum);
        try vault.redeem(SERIES_ID, amount, 1, 0, type(uint256).max, address(this)) {} catch {}
    }

    function donateOptInCollateral(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1, 1 ether);
        vm.deal(address(this), address(this).balance + amount);
        weth.deposit{value: amount}();
        rewards.donateCollateralRewards(SERIES_ID, 0, amount);
    }

    function donateOptInStaticsDollar(uint256 rawAmount) external {
        uint256 balance = staticsDollar.balanceOf(address(this));
        if (balance == 0) return;
        rewards.donateStaticsDollarRewards(SERIES_ID, 0, bound(rawAmount, 1, balance));
    }

    function withdrawPrincipal(uint256 rawIndex, uint256 rawAmount) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        LibPeriphery.PositionLeg memory leg = staking.leg(positionId, SERIES_ID);
        uint256 available = leg.pendingPrincipal + leg.eligiblePrincipal;
        if (available == 0) return;
        staking.withdrawLeg(positionId, SERIES_ID, bound(rawAmount, 1, available), address(this));
    }

    function transferRoundTrip(uint256 rawIndex, uint256 actorSeed) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        address actor = address(uint160(bound(actorSeed, 1, type(uint160).max)));
        if (actor == address(this) || actor.code.length != 0) return;
        positionNFT.transferFrom(address(this), actor, positionId);
        vm.prank(actor);
        positionNFT.transferFrom(actor, address(this), positionId);
    }

    function closeEmpty(uint256 rawIndex) external {
        uint256 positionId = _openPosition(rawIndex);
        if (positionId == 0) return;
        LibPeriphery.PositionLeg memory leg = staking.leg(positionId, SERIES_ID);
        if (
            leg.pendingPrincipal != 0 || leg.eligiblePrincipal != 0 || leg.optInStored != 0
                || leg.accruedCollateral != 0 || leg.accruedStaticsDollar != 0
        ) return;
        staking.closeLeg(positionId, SERIES_ID);
        IStaticsPosition(diamond).closePosition(positionId);
        positionOpen[positionId] = false;
    }

    function aggregatePrincipal() external view returns (uint256 total) {
        for (uint256 i; i < positions.length; ++i) {
            uint256 positionId = positions[i];
            if (!positionOpen[positionId]) continue;
            LibPeriphery.PositionLeg memory leg = staking.leg(positionId, SERIES_ID);
            total += leg.pendingPrincipal + leg.eligiblePrincipal + optIn.optInBalanceOf(positionId, SERIES_ID);
        }
    }

    function _openPosition(uint256 rawIndex) internal view returns (uint256 positionId) {
        if (positions.length == 0) return 0;
        positionId = positions[rawIndex % positions.length];
        if (!positionOpen[positionId]) return 0;
    }

    receive() external payable {}

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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract PeripheryPositionInvariants is StdInvariant, Test {
    StaticsDollarRiskShares internal staticsDollarRisk;
    PeripheryPositionHandler internal handler;
    address internal diamond;
    address internal weth;
    address internal staticsDollar;
    IStaticsCustody internal custody;
    RewardsFacet internal rewards;
    FeeRouterFacet internal feeRouter;

    function setUp() public {
        StaticsDollarLocalConfig memory config;
        config.owner = address(this);
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployLocal(config);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        diamond = deployment.diamond;
        weth = deployment.weth;
        staticsDollar = deployment.staticsDollar;
        custody = IStaticsCustody(deployment.diamond);
        rewards = RewardsFacet(deployment.diamond);
        feeRouter = FeeRouterFacet(deployment.diamond);
        handler = new PeripheryPositionHandler(deployment);
        targetContract(address(handler));
    }

    function invariant_PositionPrincipalNeverExceedsDiamondCustody() public view {
        assertGe(staticsDollarRisk.balanceOf(diamond, 1), handler.aggregatePrincipal());
    }

    function invariant_SharedReservationsEqualDollarBooks() public view {
        bytes32 account = custody.dollarCustodyAccount();
        uint256 wethLiabilities = rewards.reservedBalance(weth) + feeRouter.pendingInsurance(1);
        uint256 staticsDollarLiabilities = rewards.reservedBalance(staticsDollar);
        assertEq(custody.reservedByAccount(account, weth), wethLiabilities);
        assertEq(custody.globalReservedByToken(weth), wethLiabilities);
        assertEq(custody.reservedByAccount(account, staticsDollar), staticsDollarLiabilities);
        assertEq(custody.globalReservedByToken(staticsDollar), staticsDollarLiabilities);
    }

    function invariant_OptInReservesRemainCoveredByRewardCustody() public view {
        IStaticsDollarRiskSeriesRewards.SeriesRewardState memory state = rewards.seriesRewardState(1);
        uint256 collateralLiabilities = rewards.reservedBalance(weth);
        uint256 staticsDollarLiabilities = rewards.reservedBalance(staticsDollar);
        assertLe(state.collateralOptInReserve, collateralLiabilities);
        assertLe(state.staticsDollarOptInReserve, staticsDollarLiabilities);
        assertLe(collateralLiabilities, IERC20(weth).balanceOf(diamond));
        assertLe(staticsDollarLiabilities, IERC20(staticsDollar).balanceOf(diamond));
    }
}
