// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract LiquidityRewardsHandler is Test {
    IStaticsLiquidityRewards internal immutable rewards;
    IPositionManager internal immutable positionManager;
    IERC721 internal immutable positionNft;
    IERC20 internal immutable currency0;
    IERC20 internal immutable currency1;
    uint256 internal immutable positionId;
    uint256 internal immutable tokenId;

    constructor(
        address diamond,
        IPositionManager positionManager_,
        uint256 positionId_,
        uint256 tokenId_,
        address currency0_,
        address currency1_
    ) {
        rewards = IStaticsLiquidityRewards(diamond);
        positionManager = positionManager_;
        positionNft = IERC721(diamond);
        positionId = positionId_;
        tokenId = tokenId_;
        currency0 = IERC20(currency0_);
        currency1 = IERC20(currency1_);
        IERC721(address(positionManager_)).setApprovalForAll(diamond, true);
        currency0.approve(diamond, type(uint256).max);
        currency1.approve(diamond, type(uint256).max);
    }

    function stake() external {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) return;
        try rewards.stakeLiquidityPosition(positionId, tokenId) {} catch {}
    }

    function activate() external {
        IStaticsLiquidityRewards.StakedLiquidityView memory position = rewards.stakedLiquidityPosition(tokenId);
        if (!position.staked || position.pendingLiquidity == 0) return;
        vm.roll(block.number + 1);
        try rewards.activateLiquidityPosition(tokenId) {} catch {}
    }

    function increase(uint256 rawLiquidity) external {
        IStaticsLiquidityRewards.StakedLiquidityView memory position = rewards.stakedLiquidityPosition(tokenId);
        if (!position.staked) return;
        uint256 liquidity = bound(rawLiquidity, 1, 0.01 ether);
        IStaticsLiquidityRewards.IncreaseRequest memory request = IStaticsLiquidityRewards.IncreaseRequest({
            liquidityDelta: liquidity,
            amount0Max: 0.02 ether,
            amount1Max: 0.02 ether,
            deadline: block.timestamp + 1 hours
        });
        try rewards.increaseStakedLiquidity(positionId, tokenId, request, address(this)) {} catch {}
    }

    function claim() external {
        try rewards.claimLiquidityRewards(positionId, tokenId, address(this), 0, 0) {} catch {}
    }

    function unstake() external {
        IStaticsLiquidityRewards.StakedLiquidityView memory position = rewards.stakedLiquidityPosition(tokenId);
        if (!position.staked) return;
        try rewards.unstakeLiquidityPosition(positionId, tokenId, address(this)) {} catch {}
    }
}

contract LiquidityRewardsInvariantTest is StdInvariant, BorrowLiquidityTestBase {
    IStaticsLiquidityRewards private rewards;
    LiquidityRewardsHandler private handler;
    uint256 private tokenId;
    PoolId private poolId;

    function setUp() public override {
        super.setUp();
        rewards = IStaticsLiquidityRewards(address(diamond));
        _createReadyBasket(1);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        vm.prank(alice);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, alice);
        tokenId = tokenIds[0];
        IStaticsLiquidityRewards.StakedLiquidityView memory empty = rewards.stakedLiquidityPosition(tokenId);
        empty;
        address currency0 = basketLiquidity.canonicalPool(basketId, basketAssets[0]).currency0;
        address currency1 = basketLiquidity.canonicalPool(basketId, basketAssets[0]).currency1;
        poolId = basketLiquidity.canonicalPool(basketId, basketAssets[0]).poolId;

        _fundHandlerCurrencies(currency0, currency1);
        handler = new LiquidityRewardsHandler(
            address(diamond), positionManagerContract, basketPositionId, tokenId, currency0, currency1
        );
        vm.startPrank(alice);
        IERC721(address(positionManagerContract)).transferFrom(alice, address(handler), tokenId);
        IERC721(address(diamond)).transferFrom(alice, address(handler), basketPositionId);
        vm.stopPrank();
        IERC20(currency0).transfer(address(handler), 100 ether);
        IERC20(currency1).transfer(address(handler), 100 ether);
        targetContract(address(handler));
    }

    function invariantRecordedLiquidityMatchesPositionManagerAndPoolTotal() public view {
        IStaticsLiquidityRewards.StakedLiquidityView memory position = rewards.stakedLiquidityPosition(tokenId);
        if (position.staked) {
            assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(diamond));
            assertEq(
                positionManagerContract.getPositionLiquidity(tokenId),
                position.eligibleLiquidity + position.pendingLiquidity
            );
            assertEq(rewards.poolLiquidityRewards(poolId).totalEligibleLiquidity, position.eligibleLiquidity);
        } else {
            assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenId), address(handler));
            assertEq(rewards.poolLiquidityRewards(poolId).totalEligibleLiquidity, 0);
        }
    }

    function invariantFeeReservationsRemainPhysicallyCovered() public view {
        IStaticsLiquidityRewards.StakedLiquidityView memory position = rewards.stakedLiquidityPosition(tokenId);
        if (position.currency0 != address(0)) {
            assertLe(
                IStaticsCustody(address(diamond)).globalReservedByToken(position.currency0),
                IERC20(position.currency0).balanceOf(address(diamond))
            );
            assertLe(
                IStaticsCustody(address(diamond)).globalReservedByToken(position.currency1),
                IERC20(position.currency1).balanceOf(address(diamond))
            );
        }
    }

    function _fundHandlerCurrencies(address currency0, address currency1) private {
        address constituent = basketAssets[0];
        MockERC20(constituent).mint(address(this), 300 ether);
        IERC20(constituent).approve(address(diamond), type(uint256).max);
        uint256[] memory quote = baskets.quoteMint(basketId, 150 ether);
        baskets.mint(basketId, 150 ether, address(this), quote);
        if (currency0 == constituent || currency1 == constituent) {
            MockERC20(constituent).mint(address(this), 150 ether);
        }
    }
}
