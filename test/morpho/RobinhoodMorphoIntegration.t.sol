// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMorphoBlue, MorphoMarketId, MorphoMarketParams, MorphoPosition} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IMorphoMarketSetup is IMorphoBlue {
    function createMarket(MorphoMarketParams memory marketParams) external;
    function supply(
        MorphoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
}

contract StaticsMorphoTestOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

contract RobinhoodMorphoIntegrationTest is StaticsTestBase {
    string private constant MANIFEST = "deployments/robinhood-testnet-46630-morpho.json";
    uint256 private constant INITIAL_PRICE = 1e36;

    bool private forkEnabled;
    IStaticsMorpho private morphoApi;
    IMorphoMarketSetup private realMorpho;
    MockERC20 private usdStx;
    StaticsMorphoTestOracle private oracle;
    MorphoMarketParams private marketParams;
    bytes32 private marketId;
    uint256 private basketId;
    address private basketToken;

    function setUp() public override {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) rpcUrl = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        string memory manifest = vm.readFile(MANIFEST);
        vm.createSelectFork(rpcUrl, vm.parseJsonUint(manifest, ".network.deploymentEndBlock"));
        forkEnabled = true;
        super.setUp();

        morphoApi = IStaticsMorpho(address(diamond));
        realMorpho = IMorphoMarketSetup(vm.parseJsonAddress(manifest, ".morpho"));
        usdStx = new MockERC20("Test USDstx", "USDstx", 18);
        oracle = new StaticsMorphoTestOracle(INITIAL_PRICE);
        (basketId, basketToken) = _createDefaultBasket(0, 0);
        marketParams = MorphoMarketParams({
            loanToken: address(usdStx),
            collateralToken: basketToken,
            oracle: address(oracle),
            irm: vm.parseJsonAddress(manifest, ".adaptiveCurveIrm"),
            lltv: 0.77 ether
        });
        marketId = keccak256(abi.encode(marketParams));
        realMorpho.createMarket(marketParams);
        morphoApi.initializeMorphoIntegration(address(realMorpho), address(usdStx), 500);
        morphoApi.registerMorphoMarket(
            marketParams, IStaticsMorpho.CollateralKind.Basket, basketId, IStaticsMorpho.MarketMode.Active
        );
        _supplyLoanLiquidity(1_000 ether);
    }

    function testRealMorphoAccruesInterestAndRepaysExactShares() public {
        if (!forkEnabled) return;
        uint256 positionId = _openBorrowerPosition(10 ether, 5 ether);
        MorphoPosition memory beforeInterest = realMorpho.position(MorphoMarketId.wrap(marketId), _account(positionId));
        assertGt(beforeInterest.borrowShares, 0);

        vm.warp(block.timestamp + 30 days);
        usdStx.mint(alice, 5 ether);
        vm.startPrank(alice);
        usdStx.approve(address(diamond), 10 ether);
        (uint256 assetsRepaid, uint256 sharesRepaid) =
            morphoApi.repayMorphoUsd(positionId, marketId, 0, beforeInterest.borrowShares, 10 ether);
        vm.stopPrank();

        assertGt(assetsRepaid, 5 ether);
        assertEq(sharesRepaid, beforeInterest.borrowShares);
        assertEq(realMorpho.position(MorphoMarketId.wrap(marketId), _account(positionId)).borrowShares, 0);
        vm.prank(alice);
        morphoApi.recallMorphoCollateral(positionId, marketId, 10 ether);
    }

    function testRealMorphoBadDebtLiquidationSynchronizesTotalLoss() public {
        if (!forkEnabled) return;
        uint256 positionId = _openBorrowerPosition(10 ether, 5 ether);
        oracle.setPrice(0.1e36);
        address liquidator = makeAddr("realMorphoLiquidator");
        usdStx.mint(liquidator, 2 ether);
        vm.startPrank(liquidator);
        usdStx.approve(address(realMorpho), type(uint256).max);
        realMorpho.liquidate(marketParams, _account(positionId), 10 ether, 0, "");
        vm.stopPrank();

        MorphoPosition memory liquidated = realMorpho.position(MorphoMarketId.wrap(marketId), _account(positionId));
        assertEq(liquidated.collateral, 0);
        assertEq(liquidated.borrowShares, 0);
        vm.prank(bob);
        assertEq(morphoApi.syncMorpho(positionId, marketId), 10 ether);
        assertEq(morphoApi.morphoPositionMarket(positionId, marketId).trackedCollateral, 0);
    }

    function _openBorrowerPosition(uint256 collateral, uint256 borrowAssets) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, collateral);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, collateral, alice, quote);
        vm.startPrank(alice);
        morphoApi.deployMorphoCollateral(positionId, marketId, collateral);
        morphoApi.borrowMorphoUsd(positionId, marketId, borrowAssets, type(uint256).max, alice);
        vm.stopPrank();
    }

    function _supplyLoanLiquidity(uint256 assets) private {
        address lender = makeAddr("realMorphoLender");
        usdStx.mint(lender, assets);
        vm.startPrank(lender);
        usdStx.approve(address(realMorpho), assets);
        realMorpho.supply(marketParams, assets, 0, lender, "");
        vm.stopPrank();
    }

    function _account(uint256 positionId) private view returns (address account) {
        (account,) = morphoApi.morphoAccount(positionId);
    }
}
