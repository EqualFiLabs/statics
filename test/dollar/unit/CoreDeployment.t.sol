// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarProductionConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {ChainlinkUsdOracle} from "src/dollar/ChainlinkUsdOracle.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {DiamondLoupeFacet} from "src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract ProductionWETHFixture is ERC20 {
    constructor() ERC20("Production WETH Fixture", "pWETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok);
    }
}

contract DeploymentChainlinkFeed {
    uint8 public immutable decimals;
    int256 internal immutable answer;
    uint256 internal immutable startedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 startedAt_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, block.timestamp, 1);
    }
}

contract CoreDeploymentTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");

    function setUp() public {
        vm.warp(30 days);
    }

    function test_LocalDeploymentBuildsExactCoreAndPeripheryBindings() public {
        DeployStaticsDollar script = new DeployStaticsDollar();
        StaticsDollarLocalConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.riskUri = "ipfs://risk/{id}.json";

        StaticsDollarStackDeployment memory deployment = script.deployLocal(config);
        assertEq(deployment.core, deployment.pool);
        assertEq(StaticsDollar(deployment.staticsDollar).pool(), deployment.core);
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).pool(), deployment.core);
        assertEq(CoreViewFacet(deployment.core).staticsDollar(), deployment.staticsDollar);
        assertEq(CoreViewFacet(deployment.core).staticsDollarRisk(), deployment.staticsDollarRisk);
        assertEq(CoreViewFacet(deployment.core).periphery(), deployment.diamond);
        assertEq(CoreViewFacet(deployment.core).positionNFT(), deployment.positionNFT);
        assertEq(deployment.positionNFT, deployment.diamond);
        assertEq(deployment.gateway, deployment.diamond);
        assertEq(IStaticsDollarGateway(deployment.gateway).pool(), deployment.core);
        assertEq(OwnershipFacet(deployment.core).owner(), owner);
        assertEq(OwnershipFacet(deployment.diamond).owner(), owner);
        assertEq(MockETHUSDOracle(deployment.oracle).priceWad(), 2_500e18);

        _assertManifest(deployment.core, 11, 95);
        _assertManifest(deployment.diamond, 20, 172);
    }

    function test_LocalBroadcastEntrypointUsesDeployerForAddressPredictions() public {
        uint256 privateKey = 0xA11CE;
        address deployer = vm.addr(privateKey);
        vm.setEnv("PRIVATE_KEY", vm.toString(privateKey));

        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().runLocal();

        assertEq(OwnershipFacet(deployment.core).owner(), deployer);
        assertEq(OwnershipFacet(deployment.diamond).owner(), deployer);
        assertEq(StaticsDollar(deployment.staticsDollar).pool(), deployment.core);
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).pool(), deployment.core);
        assertEq(CoreViewFacet(deployment.core).periphery(), deployment.diamond);
        assertEq(CoreViewFacet(deployment.core).positionNFT(), deployment.positionNFT);
    }

    function test_TokenAuthorityHasNoReplacementOrOwnershipSurface() public {
        DeployStaticsDollar script = new DeployStaticsDollar();
        StaticsDollarLocalConfig memory config;
        config.owner = owner;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        StaticsDollarStackDeployment memory deployment = script.deployLocal(config);

        bytes4[7] memory removed = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pendingPool()")),
            bytes4(keccak256("burnOnlyPool(address)")),
            bytes4(keccak256("queuePoolChange(address)")),
            bytes4(keccak256("executePoolChange()")),
            bytes4(keccak256("lockPoolChanges()")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i; i < removed.length; ++i) {
            (bool staticsDollarOk,) = deployment.staticsDollar.call(abi.encodeWithSelector(removed[i], address(this)));
            (bool staticsDollarRiskOk,) =
                deployment.staticsDollarRisk.call(abi.encodeWithSelector(removed[i], address(this)));
            assertFalse(staticsDollarOk);
            assertFalse(staticsDollarRiskOk);
        }
    }

    function test_ProductionRejectsMissingAuthoritiesAndDependencies() public {
        DeployStaticsDollar script = new DeployStaticsDollar();
        StaticsDollarProductionConfig memory config;
        vm.expectRevert(abi.encodeWithSelector(DeployStaticsDollar.MissingProductionInput.selector, bytes32("OWNER")));
        script.deployProduction(config);

        config.owner = owner;
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsDollar.MissingProductionInput.selector, bytes32("PROFILE_GUARDIAN"))
        );
        script.deployProduction(config);
    }

    function test_ProductionRejectsRepositoryMockWeth() public {
        CanonicalWETH9 mockWeth = new CanonicalWETH9();
        StaticsDollarProductionConfig memory config = _productionConfig(address(mockWeth));
        DeployStaticsDollar script = new DeployStaticsDollar();
        vm.expectRevert(abi.encodeWithSelector(DeployStaticsDollar.MockDependency.selector, address(mockWeth)));
        script.deployProduction(config);
    }

    function test_ProductionRequiresExplicitHeartbeatBoundsAndSequencerGrace() public {
        ProductionWETHFixture weth = new ProductionWETHFixture();
        StaticsDollarProductionConfig memory config = _productionConfig(address(weth));
        DeployStaticsDollar script = new DeployStaticsDollar();

        config.oracleMaxStaleness = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsDollar.MissingProductionInput.selector, bytes32("ORACLE_STALENESS"))
        );
        script.deployProduction(config);
        config.oracleMaxStaleness = 1 hours;
        config.oracleMaxPriceWad = config.oracleMinPriceWad;
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsDollar.InvalidProductionInput.selector, bytes32("ORACLE_BOUNDS"))
        );
        script.deployProduction(config);
        config.oracleMaxPriceWad = 100_000e18;
        config.sequencerGracePeriod = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsDollar.MissingProductionInput.selector, bytes32("SEQUENCER_GRACE"))
        );
        script.deployProduction(config);
        config.sequencerGracePeriod = 1 hours;
        config.collateralRatioBps = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsDollar.MissingProductionInput.selector, bytes32("RISK_CONFIG"))
        );
        script.deployProduction(config);
    }

    function test_ProductionDeploymentUsesExplicitChainlinkAndExactBindings() public {
        ProductionWETHFixture weth = new ProductionWETHFixture();
        StaticsDollarProductionConfig memory config = _productionConfig(address(weth));
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployProduction(config);

        ChainlinkUsdOracle oracle = ChainlinkUsdOracle(deployment.oracle);
        assertEq(oracle.feed(), config.ethUsdFeed);
        assertEq(oracle.maxStaleness(), config.oracleMaxStaleness);
        assertEq(oracle.sequencerUptimeFeed(), config.sequencerUptimeFeed);
        assertEq(oracle.sequencerGracePeriod(), config.sequencerGracePeriod);
        assertEq(CoreViewFacet(deployment.core).requiredSequencerUptimeFeed(), config.sequencerUptimeFeed);
        assertEq(CoreViewFacet(deployment.core).minimumSequencerGracePeriod(), config.sequencerGracePeriod);
        assertEq(StaticsDollar(deployment.staticsDollar).pool(), deployment.core);
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).pool(), deployment.core);
        assertEq(CoreViewFacet(deployment.core).periphery(), deployment.diamond);
        assertEq(deployment.positionNFT, deployment.diamond);
        assertEq(deployment.gateway, deployment.diamond);
        assertEq(IStaticsDollarGateway(deployment.gateway).pool(), deployment.core);
    }

    function _productionConfig(address weth) private returns (StaticsDollarProductionConfig memory config) {
        DeploymentChainlinkFeed ethFeed = new DeploymentChainlinkFeed(8, 2_500e8, block.timestamp - 2 hours);
        DeploymentChainlinkFeed sequencerFeed = new DeploymentChainlinkFeed(0, 0, block.timestamp - 2 hours);
        config = StaticsDollarProductionConfig({
            owner: owner,
            profileGuardian: profileGuardian,
            treasury: makeAddr("treasury"),
            creationFeeAmount: 1 ether,
            weth: weth,
            ethUsdFeed: address(ethFeed),
            sequencerUptimeFeed: address(sequencerFeed),
            oracleMaxStaleness: 1 hours,
            oracleMinPriceWad: 100e18,
            oracleMaxPriceWad: 100_000e18,
            sequencerGracePeriod: 1 hours,
            collateralRatioBps: 15_000,
            priceBandBps: 15_000,
            debtCeiling: 1_000_000e18,
            riskUri: "ipfs://risk/{id}.json"
        });
    }

    function _assertManifest(address diamond, uint256 expectedFacets, uint256 expectedSelectors) private view {
        DiamondLoupeFacet loupe = DiamondLoupeFacet(diamond);
        address[] memory facets = loupe.facetAddresses();
        assertEq(facets.length, expectedFacets);
        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            bytes4[] memory selectors = loupe.facetFunctionSelectors(facets[i]);
            assertGt(selectors.length, 0);
            selectorCount += selectors.length;
            for (uint256 j; j < selectors.length; ++j) {
                assertEq(loupe.facetAddress(selectors[j]), facets[i]);
            }
        }
        assertEq(selectorCount, expectedSelectors);
        assertTrue(loupe.supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(loupe.supportsInterface(type(IDiamondLoupe).interfaceId));
    }
}
