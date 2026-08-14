// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RewardInvariantFeeIngress {
    bytes32 private constant SOURCE_ACCOUNT = keccak256("statics.invariant.reward.source");

    function accrue(address asset, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(SOURCE_ACCOUNT, asset, msg.sender, amount);
        require(received == amount, "incompatible token");
        LibGlobalRewards.accrueNonSwapFee(SOURCE_ACCOUNT, asset, amount);
    }
}

contract GlobalRewardOptInHandler is Test {
    IStaticsGlobalRewards private immutable rewards;
    IStaticsCustody private immutable custody;
    RewardInvariantFeeIngress private immutable ingress;
    MockERC20 private immutable stakingAsset;

    MockERC20[] private rewardTokens;
    uint256[] private positionIds;

    constructor(address diamond, MockERC20 stakingAsset_, MockERC20[] memory rewardTokens_) {
        rewards = IStaticsGlobalRewards(diamond);
        custody = IStaticsCustody(diamond);
        ingress = RewardInvariantFeeIngress(diamond);
        stakingAsset = stakingAsset_;
        for (uint256 i; i < rewardTokens_.length; ++i) {
            rewardTokens.push(rewardTokens_[i]);
            rewardTokens_[i].approve(diamond, type(uint256).max);
        }
        stakingAsset_.approve(diamond, type(uint256).max);
        stakingAsset_.mint(address(this), 1_000_000 ether);

        for (uint256 i; i < 3; ++i) {
            uint256 selectionLength = i == 0 ? 64 : 1;
            address[] memory selected = new address[](selectionLength);
            for (uint256 j; j < selectionLength; ++j) {
                selected[j] = address(rewardTokens_[i == 0 ? j : i]);
            }
            positionIds.push(rewards.createAndStake((i + 1) * 10 ether, address(this), selected));
        }
    }

    function accrue(uint256 rawAsset, uint256 rawAmount) external {
        MockERC20 asset = rewardTokens[rawAsset % rewardTokens.length];
        uint256 amount = bound(rawAmount, 1, 100 ether);
        asset.mint(address(this), amount);
        ingress.accrue(address(asset), amount);
    }

    function optIn(uint256 rawPosition, uint256 rawAsset) external {
        uint256 positionId = positionIds[rawPosition % positionIds.length];
        address asset = address(rewardTokens[rawAsset % rewardTokens.length]);
        if (rewards.isRewardAssetOptedIn(positionId, asset)) return;
        if (rewards.stakePosition(positionId).optedInAssetCount == rewards.maxRewardAssetsPerPosition()) return;
        address[] memory assets = _asset(asset);
        rewards.optInRewardAssets(positionId, assets);
    }

    function optOut(uint256 rawPosition, uint256 rawAsset) external {
        uint256 positionId = positionIds[rawPosition % positionIds.length];
        address asset = address(rewardTokens[rawAsset % rewardTokens.length]);
        if (!rewards.isRewardAssetOptedIn(positionId, asset)) return;
        address[] memory assets = _asset(asset);
        rewards.optOutRewardAssets(positionId, assets);
    }

    function stake(uint256 rawPosition, uint256 rawAmount) external {
        uint256 positionId = positionIds[rawPosition % positionIds.length];
        _checkpointPosition(positionId);
        rewards.stake(positionId, bound(rawAmount, 1, 25 ether));
    }

    function unstake(uint256 rawPosition, uint256 rawAmount) external {
        uint256 positionId = positionIds[rawPosition % positionIds.length];
        uint256 balance = rewards.stakePosition(positionId).stakedBalance;
        if (balance == 0) return;
        _checkpointPosition(positionId);
        rewards.unstake(positionId, bound(rawAmount, 1, balance), address(this));
    }

    function advanceTime(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 1, 30 hours));
    }

    function claim(uint256 rawPosition, uint256 rawAsset) external {
        uint256 positionId = positionIds[rawPosition % positionIds.length];
        address[] memory assets = _asset(address(rewardTokens[rawAsset % rewardTokens.length]));
        if (rewards.pendingRewards(positionId, assets)[0] == 0) return;
        rewards.claimRewards(positionId, assets, address(this), new uint256[](1));
    }

    function eligibleStake(address asset) external view returns (uint256 total) {
        for (uint256 i; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            if (rewards.isRewardAssetOptedIn(positionId, asset)) {
                total += rewards.rewardSelection(positionId, asset).actualEligibleStake;
            }
        }
    }

    function pendingStake(address asset) external view returns (uint256 total) {
        for (uint256 i; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            if (rewards.isRewardAssetOptedIn(positionId, asset)) {
                total += rewards.rewardSelection(positionId, asset).actualPendingStake;
            }
        }
    }

    function totalPending(address asset) external view returns (uint256 total) {
        address[] memory assets = _asset(asset);
        for (uint256 i; i < positionIds.length; ++i) {
            total += rewards.pendingRewards(positionIds[i], assets)[0];
        }
    }

    function selectedCount(uint256 index) external view returns (uint256) {
        return rewards.positionRewardAssets(positionIds[index]).length;
    }

    function selectionIsCoherent(uint256 index) external view returns (bool) {
        uint256 positionId = positionIds[index];
        address[] memory selected = rewards.positionRewardAssets(positionId);
        for (uint256 i; i < selected.length; ++i) {
            if (!rewards.isRewardAssetOptedIn(positionId, selected[i])) return false;
            for (uint256 j = i + 1; j < selected.length; ++j) {
                if (selected[i] == selected[j]) return false;
            }
        }
        return true;
    }

    function rewardToken(uint256 index) external view returns (address) {
        return address(rewardTokens[index]);
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    function feeReservation(address asset) external view returns (uint256) {
        return custody.reservedByAccount(custody.feeCustodyAccount(), asset);
    }

    function _checkpointPosition(uint256 positionId) private {
        address[] memory selected = rewards.positionRewardAssets(positionId);
        address[] memory batch = new address[](8);
        uint256 batchLength;
        for (uint256 i; i < selected.length; ++i) {
            if (!rewards.rewardBookNeedsCheckpoint(selected[i])) continue;
            batch[batchLength++] = selected[i];
            if (batchLength == batch.length) {
                rewards.checkpointRewardAssets(batch);
                batch = new address[](8);
                batchLength = 0;
            }
        }
        if (batchLength == 0) return;
        address[] memory tail = new address[](batchLength);
        for (uint256 i; i < batchLength; ++i) {
            tail[i] = batch[i];
        }
        rewards.checkpointRewardAssets(tail);
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }
}

contract GlobalRewardOptInInvariantTest is StdInvariant, StaticsTestBase {
    GlobalRewardOptInHandler private handler;

    function setUp() public override {
        super.setUp();
        RewardInvariantFeeIngress ingress = new RewardInvariantFeeIngress();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RewardInvariantFeeIngress.accrue.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(ingress), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        MockERC20[] memory rewardTokens = new MockERC20[](65);
        for (uint256 i; i < rewardTokens.length; ++i) {
            rewardTokens[i] = new MockERC20("Invariant Reward", "IR", 18);
        }
        handler = new GlobalRewardOptInHandler(address(diamond), stakingAsset, rewardTokens);
        targetContract(address(handler));
    }

    function invariantEligibleStakeMatchesSelectedPositionBalances() public view {
        for (uint256 i; i < handler.rewardTokenCount(); ++i) {
            address asset = handler.rewardToken(i);
            assertEq(globalRewards.rewardAsset(asset).actualEligibleStake, handler.eligibleStake(asset));
            assertEq(globalRewards.rewardAsset(asset).actualPendingStake, handler.pendingStake(asset));
        }
    }

    function invariantPositionWorkRemainsBoundedByItsSelections() public view {
        for (uint256 i; i < handler.positionCount(); ++i) {
            assertLe(handler.selectedCount(i), globalRewards.maxRewardAssetsPerPosition());
            assertTrue(handler.selectionIsCoherent(i));
        }
    }

    function invariantFeeReservationsCoverTreasuryAndUserClaims() public view {
        for (uint256 i; i < handler.rewardTokenCount(); ++i) {
            address asset = handler.rewardToken(i);
            IStaticsGlobalRewards.RewardAssetView memory book = globalRewards.rewardAsset(asset);
            uint256 pending = handler.totalPending(asset);
            assertLe(book.totalClaimable, pending);
            assertGe(handler.feeReservation(asset), globalRewards.treasuryAccrued(asset) + pending);
            assertGe(IERC20(asset).balanceOf(address(diamond)), custody.globalReservedByToken(asset));
        }
    }
}
