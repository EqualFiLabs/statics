// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {ConfigureStaticsMorpho, StaticsMorphoConfig} from "../../script/ConfigureStaticsMorpho.s.sol";
import {MorphoMarketId, MorphoMarketParams} from "../../src/interfaces/IMorphoBlue.sol";
import {IStaticsDollarCoreTypes} from "../../src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {TestnetMorphoOracle} from "../../src/testnet/TestnetMorphoOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorphoBlue} from "../mocks/MockMorphoBlue.sol";

contract TestIrm {}

contract TestPeggedGateway {
    MockERC20 public immutable collateral;
    MockERC20 public immutable usdStx;

    constructor(MockERC20 collateral_, MockERC20 usdStx_) {
        collateral = collateral_;
        usdStx = usdStx_;
    }

    function previewPeggedMint(uint256 profileId, uint256 amount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview)
    {
        preview = IStaticsDollarCoreTypes.PeggedMintPreview({
            profileId: profileId,
            collateralToken: address(collateral),
            staticsDollarMinted: amount,
            principalCollateral: amount,
            feeAmount: 0,
            totalCollateralIn: amount,
            priceWad: 1 ether
        });
    }

    function mintPegged(uint256, uint256 amount, uint256 maximumCollateralIn, address receiver)
        external
        returns (uint256 collateralIn)
    {
        collateral.transferFrom(msg.sender, address(this), maximumCollateralIn);
        usdStx.mint(receiver, amount);
        return maximumCollateralIn;
    }
}

contract ConfigureStaticsMorphoTest is Test {
    ConfigureStaticsMorpho private ceremony;
    MockMorphoBlue private morpho;
    StaticsMorphoConfig private config;

    function setUp() public {
        vm.warp(1_800_000_000);
        ceremony = new ConfigureStaticsMorpho();
        morpho = new MockMorphoBlue();
        MockERC20 usdStx = new MockERC20("USDstx", "USDstx", 18);
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 basket = new MockERC20("Basket", "BASKET", 18);
        TestnetMorphoOracle staticsOracle = new TestnetMorphoOracle(address(this), 1e36);
        TestnetMorphoOracle basketOracle = new TestnetMorphoOracle(address(this), 2e36);
        config = StaticsMorphoConfig({
            morpho: address(morpho),
            usdStx: address(usdStx),
            statics: address(statics),
            staticsOracle: address(staticsOracle),
            basketToken: address(basket),
            basketOracle: address(basketOracle),
            irm: address(new TestIrm()),
            lltv: 0.77 ether,
            syncBountyBps: 500,
            basketId: 7
        });
    }

    function testCreateMarketsIsSafeToResume() public {
        (bytes32 staticsId, bytes32 basketId) = ceremony.createMarkets(config);
        (bytes32 resumedStaticsId, bytes32 resumedBasketId) = ceremony.createMarkets(config);

        assertEq(resumedStaticsId, staticsId);
        assertEq(resumedBasketId, basketId);
        assertGt(morpho.market(MorphoMarketId.wrap(staticsId)).lastUpdate, 0);
        assertGt(morpho.market(MorphoMarketId.wrap(basketId)).lastUpdate, 0);
        _assertParams(morpho.idToMarketParams(MorphoMarketId.wrap(staticsId)), ceremony.staticsMarketParams(config));
        _assertParams(morpho.idToMarketParams(MorphoMarketId.wrap(basketId)), ceremony.basketMarketParams(config));
    }

    function testBatchInitializesAndRegistersBothMarkets() public {
        address diamond = makeAddr("diamond");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, config);

        assertEq(targets.length, 3);
        assertEq(values.length, 3);
        assertEq(payloads.length, 3);
        for (uint256 i; i < targets.length; ++i) {
            assertEq(targets[i], diamond);
            assertEq(values[i], 0);
        }
        assertEq(_selector(payloads[0]), IStaticsMorpho.initializeMorphoIntegration.selector);
        assertEq(_selector(payloads[1]), IStaticsMorpho.registerMorphoMarket.selector);
        assertEq(_selector(payloads[2]), IStaticsMorpho.registerMorphoMarket.selector);
    }

    function testSeedLiquidityMintsThroughPeggedGatewayAndSuppliesBothMarkets() public {
        ceremony.createMarkets(config);
        MockERC20 collateral = new MockERC20("Collateral", "COL", 18);
        TestPeggedGateway gateway = new TestPeggedGateway(collateral, MockERC20(config.usdStx));
        uint256 assetsPerMarket = 100 ether;
        collateral.mint(address(ceremony), assetsPerMarket * 2);

        uint256 collateralIn = ceremony.seedLiquidity(address(gateway), config, 2, assetsPerMarket, address(ceremony));

        assertEq(collateralIn, assetsPerMarket * 2);
        bytes32 staticsId = ceremony.marketId(ceremony.staticsMarketParams(config));
        bytes32 basketId = ceremony.marketId(ceremony.basketMarketParams(config));
        assertEq(morpho.position(MorphoMarketId.wrap(staticsId), address(ceremony)).supplyShares, assetsPerMarket);
        assertEq(morpho.position(MorphoMarketId.wrap(basketId), address(ceremony)).supplyShares, assetsPerMarket);
    }

    function _assertParams(MorphoMarketParams memory actual, MorphoMarketParams memory expected) private pure {
        assertEq(actual.loanToken, expected.loanToken);
        assertEq(actual.collateralToken, expected.collateralToken);
        assertEq(actual.oracle, expected.oracle);
        assertEq(actual.irm, expected.irm);
        assertEq(actual.lltv, expected.lltv);
    }

    function _selector(bytes memory payload) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(payload, 0x20))
        }
    }
}
