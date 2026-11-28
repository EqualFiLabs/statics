// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBasketStaging} from "../../src/interfaces/IStaticsBasketStaging.sol";
import {IStaticsBasketPreparation} from "../../src/interfaces/IStaticsBasketPreparation.sol";
import {IStaticsBasketLaunchModule} from "../../src/interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {BasketCreationFacet} from "../../src/facets/BasketCreationFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketDeployment} from "../../src/libraries/LibBasketDeployment.sol";
import {LibBasketMarkets} from "../../src/libraries/LibBasketMarkets.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {StaticsBasketToken} from "../../src/tokens/StaticsBasketToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract StagedBasketLaunchTest is CanonicalPoolTestBase {
    struct Launch {
        IStaticsBasket.CreateBasketParams params;
        IStaticsBasket.PoolLaunchParams[] pools;
        uint256[] maximums;
        uint256 deadline;
        uint256 id;
        address token;
    }
    IStaticsBasketStaging private staged;

    function setUp() public override {
        super.setUp();
        staged = IStaticsBasketStaging(address(diamond));
    }

    function testSixteenAssetsLaunchInTwoTransactionsWithAggregateBacking() public {
        Launch memory launch = _fixture(16);
        uint256 beforeGas = gasleft();
        _start(launch, 6, bytes32(0));
        emit log_named_uint("staged-token-and-first-six-gas", beforeGas - gasleft());
        assertEq(uint256(baskets.basketStatus(launch.id)), uint256(IStaticsBasket.BasketStatus.Pending));
        _assertProgress(launch, 6);
        beforeGas = gasleft();
        _continue(launch, 10);
        emit log_named_uint("staged-last-ten-gas", beforeGas - gasleft());
        assertEq(uint256(baskets.basketStatus(launch.id)), uint256(IStaticsBasket.BasketStatus.Active));
        _assertProgress(launch, 16);
        uint256 supply = IERC20(launch.token).totalSupply();
        assertGt(supply, 0);
        assertEq(IERC20(launch.token).balanceOf(address(diamond)), 0);
        for (uint256 i; i < 16; ++i) {
            assertEq(
                baskets.vaultBalance(launch.id, launch.params.assets[i]),
                LibBasket.backingAtSupply(launch.params.bundleAmounts[i], supply)
            );
            assertEq(
                custody.reservedByAccount(custody.basketCustodyAccount(launch.id), launch.params.assets[i]),
                baskets.vaultBalance(launch.id, launch.params.assets[i])
            );
        }
        vm.prank(alice);
        vm.expectRevert(BasketCreationFacet.InvalidBasketLaunchState.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
    }

    function testPreparedTokenSupportsStagedLaunch() public {
        Launch memory launch = _fixture(2);
        IStaticsBasketPreparation prep = IStaticsBasketPreparation(address(diamond));
        vm.prank(alice);
        (bytes32 id,, address token) =
            prep.prepareBasketToken(launch.params, launch.pools, launch.maximums, launch.deadline, 887);
        _start(launch, 1, id);
        assertEq(launch.token, token);
        _continue(launch, 1);
        assertEq(uint256(baskets.basketStatus(launch.id)), uint256(IStaticsBasket.BasketStatus.Active));
    }

    function testInvalidBatchSizesPreserveCreationAndLaunchProgress() public {
        Launch memory launch = _fixture(2);
        uint256 treasuryBefore = treasury.balance;
        uint256 basketsBefore = baskets.basketCount();
        vm.expectRevert(BasketCreationFacet.InvalidPoolLaunchParameters.selector);
        _start(launch, 0, bytes32(0));
        vm.expectRevert(BasketCreationFacet.InvalidPoolLaunchParameters.selector);
        _start(launch, 3, bytes32(0));
        assertEq(treasury.balance, treasuryBefore);
        assertEq(baskets.basketCount(), basketsBefore);

        _start(launch, 1, bytes32(0));
        treasuryBefore = treasury.balance;
        vm.prank(alice);
        vm.expectRevert(BasketCreationFacet.InvalidPoolLaunchParameters.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 0);
        vm.prank(alice);
        vm.expectRevert(BasketCreationFacet.InvalidPoolLaunchParameters.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 2);
        assertEq(treasury.balance, treasuryBefore);
        _assertProgress(launch, 1);
        _continue(launch, 1);
        _assertProgress(launch, 2);
        assertEq(uint256(baskets.basketStatus(launch.id)), uint256(IStaticsBasket.BasketStatus.Active));
    }

    function testPendingBasketRejectsPublicMintSwapLiquidityAndNewMarkets() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        IStaticsFlashLoan(address(diamond)).quoteFlashLoanAsset(launch.token, 1);
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        IStaticsFlashLoan(address(diamond)).maxFlashLoan(launch.token);
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        IStaticsFlashLoan(address(diamond)).flashLoanAsset(launch.token, 1, address(this), "");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        baskets.mint(launch.id, 1 ether, alice, launch.maximums);
        PoolKey memory key =
        IStaticsProtocolPools(address(diamond))
        .protocolPool(basketLiquidity.canonicalPool(launch.id, launch.params.assets[0]).poolId)
        .key;
        vm.expectRevert();
        v4Router.swap(key, SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1));
        vm.expectRevert();
        v4Router.modifyLiquidity(key, ModifyLiquidityParams(-100, 100, int256(100), bytes32(0)));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        IStaticsBasketMarkets(address(diamond))
            .createBasketMarket(
                IStaticsBasketMarkets.MarketParams(
                    launch.token, launch.params.assets[0], 500, 10, uint160(1 << 96), 0, launch.deadline, false
                )
            );
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibBasket.BasketNotActive.selector, launch.id, IStaticsBasket.BasketStatus.Pending)
        );
        baskets.redeem(launch.id, 1, alice, new uint256[](2));
    }

    function testPendingPoolLiquidityRequiresTheConfiguredManagerAsPositionManagerLocker() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        (address manager,) = basketLiquidity.liquidityManager();
        address positionManager = IStaticsLiquidityManager(manager).positionManager();
        vm.mockCall(positionManager, abi.encodeWithSelector(IMsgSender.msgSender.selector), abi.encode(alice));
        vm.prank(alice);
        try staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1) {
            fail("hostile PositionManager locker accepted");
        } catch (bytes memory reason) {
            bytes4 wrapper;
            bytes4 cause;
            assembly ("memory-safe") {
                wrapper := mload(add(reason, 32))
                cause := mload(add(reason, 196))
            }
            assertEq(wrapper, CustomRevert.WrappedError.selector);
            assertEq(cause, LibBasketMarkets.BasketMarketNotActive.selector);
        }
        vm.clearMockedCalls();
        _continue(launch, 1);
        assertEq(uint256(baskets.basketStatus(launch.id)), uint256(IStaticsBasket.BasketStatus.Active));
    }

    function testResumeRejectsUnauthorizedCallerChangedLimitsConfigurationAndDeadline() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        vm.prank(bob);
        vm.expectRevert(BasketCreationFacet.OnlyBasketLaunchCreator.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        launch.maximums[0]++;
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        launch.maximums[0]--;
        launch.pools[1].pairedAssetAmount++;
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        launch.pools[1].pairedAssetAmount--;
        vm.prank(alice);
        vm.expectRevert(LibBasketDeployment.PreparationIntentMismatch.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline + 1, 1);
        _continue(launch, 1);
    }

    function testLaterBatchFailurePreservesProgressAndCanBeRetried() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        vm.prank(alice);
        IERC20(launch.params.assets[1]).approve(address(diamond), 0);
        vm.prank(alice);
        vm.expectRevert();
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        _assertProgress(launch, 1);
        vm.prank(alice);
        IERC20(launch.params.assets[1]).approve(address(diamond), type(uint256).max);
        _continue(launch, 1);
        _assertProgress(launch, 2);
    }

    function testCompleteLaunchMaximumAppliesAcrossBatches() public {
        Launch memory launch = _fixture(2);
        // Enough to fund the first batch, insufficient for the total second-asset POL plus backing.
        launch.maximums[1] = 1 ether;
        _start(launch, 1, bytes32(0));
        vm.prank(alice);
        vm.expectRevert();
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        _assertProgress(launch, 1);
    }

    function testUnrelatedAdminChangeDoesNotBlockContinuationButExpiryDoes() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        basketAdmin.setTreasury(bob);
        _continue(launch, 1);
        _assertProgress(launch, 2);

        Launch memory expiringLaunch = _fixture(2);
        _start(expiringLaunch, 1, bytes32(0));
        vm.warp(expiringLaunch.deadline + 1);
        vm.prank(alice);
        vm.expectPartialRevert(BasketCreationFacet.LaunchDeadlineExpired.selector);
        staged.continueBasketLaunch(
            expiringLaunch.id, expiringLaunch.pools, expiringLaunch.maximums, expiringLaunch.deadline, 1
        );
        vm.prank(alice);
        staged.cancelBasketLaunch(expiringLaunch.id);
        assertEq(uint256(baskets.basketStatus(expiringLaunch.id)), uint256(IStaticsBasket.BasketStatus.ExitOnly));
    }

    function testCancelUnwindsSeededPolThroughExistingTreasuryRails() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        vm.prank(bob);
        vm.expectRevert(BasketCreationFacet.OnlyBasketLaunchCreator.selector);
        staged.cancelBasketLaunch(launch.id);
        vm.prank(alice);
        staged.cancelBasketLaunch(launch.id);
        IStaticsProtocolPools protocol = IStaticsProtocolPools(address(diamond));
        PoolId id = basketLiquidity.canonicalPool(launch.id, launch.params.assets[0]).poolId;
        uint256[] memory positions = protocol.protocolPolPositionIds(id);
        protocol.closeProtocolPolPosition(positions[0], 0, 0, type(uint256).max);
        basketLiquidity.unwindBasketLiquidity(launch.id, launch.params.assets[0]);
        // Uniswap full-range burn rounds down; its one-wei token dust stays fully backed.
        uint256 dust = IERC20(launch.token).totalSupply();
        assertLe(dust, 1);
        assertTrue(basketLiquidity.basketLiquidityUnwound(launch.id, launch.params.assets[0]));
        assertEq(protocol.protocolPool(id).activePolPositions, 0);
        for (uint256 i; i < 2; ++i) {
            assertEq(
                baskets.vaultBalance(launch.id, launch.params.assets[i]),
                LibBasket.backingAtSupply(launch.params.bundleAmounts[i], dust)
            );
            assertGt(globalRewards.treasuryAccrued(launch.params.assets[i]), 0);
        }
        vm.prank(alice);
        vm.expectRevert(BasketCreationFacet.InvalidBasketLaunchState.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
    }

    function testZeroFeeRuleAndSelfOnlyModuleCannotBeBypassed() public {
        Launch memory launch = _fixture(2);
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0);
        vm.prank(alice);
        vm.expectRevert(LibProtocolPools.PermissionlessPoolCreationDisabled.selector);
        staged.createBasketStaged{value: 1 ether}(
            launch.params, launch.pools, launch.maximums, launch.deadline, bytes32(0), 1
        );
        vm.expectRevert(abi.encodeWithSelector(BasketLiquidityFacet.OnlyDiamondSelf.selector, address(this)));
        IStaticsBasketLaunchModule(address(diamond))
            .launchBasketPoolBatch(IStaticsBasketLaunchModule.PoolBatch(0, alice, 0, 1), launch.pools, launch.maximums);
    }

    function testClosedCreationGateBlocksContinuationWithoutChangingProgress() public {
        Launch memory launch = _fixture(2);
        _start(launch, 1, bytes32(0));
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(0);
        vm.prank(alice);
        vm.expectRevert(LibProtocolPools.PermissionlessPoolCreationDisabled.selector);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, 1);
        _assertProgress(launch, 1);

        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(1);
        _continue(launch, 1);
        _assertProgress(launch, 2);
    }

    function _start(Launch memory launch, uint256 count, bytes32 preparation) private {
        vm.prank(alice);
        (launch.id, launch.token) = staged.createBasketStaged{value: 1 ether}(
            launch.params, launch.pools, launch.maximums, launch.deadline, preparation, count
        );
    }

    function _continue(Launch memory launch, uint256 count) private {
        vm.prank(alice);
        staged.continueBasketLaunch(launch.id, launch.pools, launch.maximums, launch.deadline, count);
    }

    function _assertProgress(Launch memory launch, uint256 expected) private view {
        (uint256 count, uint256 shares, uint256[] memory debits) = staged.basketLaunchProgress(launch.id);
        assertEq(count, expected);
        assertEq(shares, IERC20(launch.token).totalSupply());
        for (uint256 i; i < launch.params.assets.length; ++i) {
            assertEq(debits[i], 1_000_000 ether - IERC20(launch.params.assets[i]).balanceOf(alice));
            assertLe(debits[i], launch.maximums[i]);
            if (i < expected) {
                PoolId id = basketLiquidity.canonicalPool(launch.id, launch.params.assets[i]).poolId;
                assertEq(IStaticsProtocolPools(address(diamond)).protocolPool(id).activePolPositions, 1);
            }
        }
    }

    function _fixture(uint256 count) private returns (Launch memory launch) {
        launch.params = _defaultParams(0, 0);
        launch.params.assets = new address[](count);
        launch.params.bundleAmounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            launch.params.assets[i] = address(new MockERC20("Constituent", "C", 18));
            launch.params.bundleAmounts[i] = (i + 1) * 0.01 ether;
        }
        (launch.pools, launch.maximums) = _fundDefaultLaunch(launch.params.assets, alice);
        launch.deadline = block.timestamp + 1 days;
    }
}
