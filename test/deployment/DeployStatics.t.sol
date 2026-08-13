// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsGenesisStaking} from "../../src/interfaces/IStaticsGenesisStaking.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../../src/interfaces/IPositionOwnerIndex.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsDollarGateway} from "../../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {IStaticsDollarRiskLiquidity} from "../../src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarRiskIncentives} from "../../src/dollar/interfaces/IStaticsDollarRiskIncentives.sol";
import {StaticsDollar} from "../../src/dollar/StaticsDollar.sol";
import {StaticsDollarRiskShares} from "../../src/dollar/StaticsDollarRiskShares.sol";
import {CoreViewFacet} from "../../src/dollar/core/facets/CoreViewFacet.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {ConfigureStaticsLiquidity, StaticsLiquidityConfig} from "../../script/ConfigureStaticsLiquidity.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";

contract DeployStaticsTest is Test {
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;

    function testCanonicalLauncherCreatesOnlyDeployableContracts() public {
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: makeAddr("multisig"),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            partnerRecipient: address(0),
            creationFeeAmount: 0,
            positionCreationFeeAmount: 0
        });
        uint64 firstCreationNonce = vm.getNonce(address(deployer));

        deployer.deploy(config);

        uint64 nextCreationNonce = vm.getNonce(address(deployer));
        assertGt(nextCreationNonce, firstCreationNonce);
        for (uint64 nonce = firstCreationNonce; nonce < nextCreationNonce; ++nonce) {
            address created = vm.computeCreateAddress(address(deployer), nonce);
            assertGt(created.code.length, 0, "launcher creation has no runtime code");
            assertLe(created.code.length, EIP170_RUNTIME_LIMIT, "launcher created oversized runtime");
        }
    }

    function testLocalLaunchPreservesClosedBasketCreationConfiguration() public {
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: makeAddr("multisig"),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            partnerRecipient: address(0),
            creationFeeAmount: 0,
            positionCreationFeeAmount: 0.001 ether
        });

        (StaticsDollarStackDeployment memory deployment,) = deployer.deploy(config);

        assertEq(IStaticsBasketAdmin(deployment.diamond).creationFee(), 0);
        assertEq(IStaticsPositionFees(deployment.diamond).positionCreationFee(), 0.001 ether);
    }

    function testLaunchInstallsFullProtocolBehindTimelockedDiamond() public {
        address guardian = makeAddr("guardian");
        address treasury = makeAddr("treasury");
        ConfigureStaticsLiquidity ceremony = new ConfigureStaticsLiquidity();
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: address(ceremony),
            guardian: guardian,
            treasury: treasury,
            partnerRecipient: makeAddr("stonkbrokers"),
            creationFeeAmount: 0.01 ether,
            positionCreationFeeAmount: 0
        });
        DeployStatics.V4Config memory v4 = _v4Config();

        (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock) =
            deployer.deployWithLiquidity(config, v4);
        address diamond = deployment.diamond;

        StaticsLiquidityConfig memory liquidityConfig = StaticsLiquidityConfig({
            poolManager: deployment.poolManager,
            positionManager: deployment.positionManager,
            permit2: deployment.permit2,
            hook: deployment.swapFeeHook,
            manager: deployment.liquidityManager,
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: deployment.poolManager.codehash,
            positionManagerCodeHash: deployment.positionManager.codehash,
            permit2CodeHash: deployment.permit2.codehash
        });
        bytes32 salt = keccak256("install Statics liquidity");
        bytes32 operationId = ceremony.schedule(diamond, liquidityConfig, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(diamond, liquidityConfig, salt);

        assertEq(IERC173(diamond).owner(), address(timelock));
        assertEq(OwnershipFacet(deployment.core).owner(), address(timelock));
        assertEq(timelock.getMinDelay(), 2 minutes);
        _assertManifest(deployment.core, 11, 95);
        _assertManifest(diamond, 25, 231);
        assertEq(IStaticsGovernance(diamond).guardian(), guardian);
        assertEq(IStaticsBasketAdmin(diamond).treasury(), treasury);
        assertEq(IStaticsBasketAdmin(diamond).creationFee(), 0.01 ether);
        assertEq(IStaticsPositionFees(diamond).positionCreationFee(), 0);
        assertEq(deployment.gateway, diamond);
        assertEq(deployment.positionNFT, diamond);
        assertEq(address(StaticsGenesisRenderer(deployment.genesisRenderer).avatarSVG()), deployment.avatarSVG);
        assertEq(StaticsGenesis(deployment.genesisNFT).protocol(), diamond);
        assertEq(StaticsGenesis(deployment.genesisNFT).ownerOf(1), treasury);
        assertEq(StaticsToken(deployment.staticsToken).balanceOf(treasury), 1_000_000_000 ether);
        assertGt(deployment.genesisRenderer.code.length, 0);
        assertGt(deployment.avatarSVG.code.length, 0);
        assertEq(StaticsDollar(deployment.staticsDollar).symbol(), "USDstx");
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).symbol(), "ethLEV");
        assertEq(IStaticsDollarGateway(diamond).pool(), deployment.core);
        assertEq(CoreViewFacet(deployment.core).periphery(), diamond);
        assertEq(CoreViewFacet(deployment.core).positionNFT(), diamond);
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsCustody).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBasketCollateral).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBasketRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBasketLiquidity).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBorrowLiquidity).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsLiquidityRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGlobalRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPositionFees).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGenesisStaking).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsProtocolRevenue).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IModularPositionNFT).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IPositionOwnerIndex).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPositionPortfolio).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskLiquidity).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskIncentives).interfaceId));
        (address poolManager, address hook, bool integrationInstalled) =
            IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address manager, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        assertTrue(integrationInstalled);
        assertTrue(managerInstalled);
        assertEq(poolManager, deployment.poolManager);
        assertEq(hook, deployment.swapFeeHook);
        assertEq(manager, deployment.liquidityManager);
        assertEq(StaticsSwapFeeHook(payable(hook)).staticsDiamond(), diamond);
        assertEq(address(StaticsSwapFeeHook(payable(hook)).poolManager()), deployment.poolManager);
        IStaticsSwapFeeHook.FeeConfiguration memory feeConfig = StaticsSwapFeeHook(payable(hook)).feeConfiguration();
        assertEq(feeConfig.inputFeeBps, 25);
        assertEq(feeConfig.outputFeeBps, 25);
        assertEq(feeConfig.lockedLiquidityShareBps, 1_000);
        assertEq(feeConfig.liquidityProviderShareBps, 2_000);
        assertEq(feeConfig.basketStakerShareBps, 2_000);
        assertEq(feeConfig.staticsStakerShareBps, 1_500);
        assertEq(feeConfig.stonkBrokersShareBps, 1_000);
        assertEq(feeConfig.indexCreatorShareBps, 500);
        assertEq(feeConfig.treasuryShareBps, 2_000);
        assertEq(IStaticsProtocolRevenue(diamond).partnerRecipient(), config.partnerRecipient);
        assertEq(
            uint160(hook) & Hooks.ALL_HOOK_MASK,
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG
        );
        assertEq(StaticsLiquidityManager(manager).staticsDiamond(), diamond);
        assertEq(StaticsLiquidityManager(manager).poolManager(), deployment.poolManager);
        assertEq(StaticsLiquidityManager(manager).positionManager(), deployment.positionManager);
        assertEq(StaticsLiquidityManager(manager).permit2(), deployment.permit2);
    }

    function _v4Config() private returns (DeployStatics.V4Config memory config) {
        IPoolManager poolManager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        IAllowanceTransfer permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        IPositionManager positionManager = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        config = DeployStatics.V4Config({
            poolManager: address(poolManager),
            positionManager: address(positionManager),
            permit2: address(permit2Contract),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2Contract).codehash
        });
    }

    function testLaunchRejectsMissingGuardian() public {
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory config = DeployStatics.Config({
            multisig: makeAddr("multisig"),
            guardian: address(0),
            treasury: makeAddr("treasury"),
            partnerRecipient: address(0),
            creationFeeAmount: 1 ether,
            positionCreationFeeAmount: 0
        });
        vm.expectRevert(DeployStatics.InvalidConfig.selector);
        deployer.deploy(config);
    }

    function testProductionHookMiningUsesFoundryCreate2Deployer() public {
        DeployStatics deployer = new DeployStatics();
        assertEq(deployer.FOUNDRY_CREATE2_DEPLOYER(), 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }

    function _assertManifest(address diamond, uint256 expectedFacets, uint256 expectedSelectors) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        assertEq(facets.length, expectedFacets);
        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            bytes4[] memory selectors = loupe.facetFunctionSelectors(facets[i]);
            assertTrue(facets[i].code.length > 0);
            for (uint256 j; j < selectors.length; ++j) {
                assertEq(loupe.facetAddress(selectors[j]), facets[i]);
            }
            selectorCount += selectors.length;
        }
        assertEq(selectorCount, expectedSelectors);
    }
}
