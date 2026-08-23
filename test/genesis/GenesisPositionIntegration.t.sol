// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {GenesisCreditConfig, IStaticsGenesisVault} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {GenesisNFTFacet} from "../../src/facets/GenesisNFTFacet.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {LibGenesisIntegration} from "../../src/libraries/LibGenesisIntegration.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract GenesisIntegrationFeeSource {
    address public statics;
    address public numeraire;
    address public beneficiary;

    function configure(address statics_, address numeraire_, address beneficiary_) external {
        statics = statics_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function collectFees(bytes32) external pure returns (uint128 fees0, uint128 fees1) {
        return (0, 0);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        (currency0, currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract GenesisIntegrationInitHarness {
    function initializeGenesisIntegration(LibGenesisIntegration.InitArgs calldata args) external {
        LibGenesisIntegration.initialize(args);
    }
}

contract GenesisPositionIntegrationTest is StaticsTestBase {
    uint256 private constant GENESIS_PRICE = 180_000 ether;
    uint256 private constant ORIGINATION_FEE = 0.003 ether;
    uint256 private constant EXTENSION_FEE = 0.003 ether;
    bytes32 private constant POOL_ID = keccak256("GENESIS_POSITION_INTEGRATION");

    MockERC20 private numeraire;
    GenesisIntegrationFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private activationRegistry;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;
    IStaticsGenesisIntegration private integration;
    uint256 private epochEnd;

    function setUp() public override {
        super.setUp();
        numeraire = new MockERC20("Wrapped Native", "WETH", 18);
        feeSource = new GenesisIntegrationFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(numeraire), address(this));
        feeSource.configure(address(stakingAsset), address(numeraire), address(feeReceiver));
        feeReceiver.bindMarket(address(stakingAsset), POOL_ID);

        activationRegistry = new GenesisActivationRegistry(stakingAsset, address(this), address(this), treasury);
        epochEnd = block.timestamp + 7 days;
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: ORIGINATION_FEE,
            extensionFee: EXTENSION_FEE,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(stakingAsset, address(this), address(this), epochEnd, creditConfig);
        genesis = new StaticsGenesis(
            address(vault),
            address(activationRegistry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            address(this),
            treasury,
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        activationRegistry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));
        feeReceiver.bindReserveVault(address(vault));

        _installGenesisIntegration();
        integration = IStaticsGenesisIntegration(address(diamond));
        GenesisIntegrationInitHarness(address(diamond))
            .initializeGenesisIntegration(
                LibGenesisIntegration.InitArgs({
                genesis: address(genesis),
                vault: address(vault),
                activationRegistry: address(activationRegistry),
                feeReceiver: address(feeReceiver),
                statics: address(stakingAsset),
                numeraire: address(numeraire)
            })
            );

        feeReceiver.proposeDistributor(address(diamond));
        integration.acceptGenesisDistributorRole();
        activationRegistry.proposeConsumer(address(diamond));
        integration.acceptGenesisConsumerRole();
        genesis.bindProtocol(address(diamond));
        assertTrue(integration.genesisIntegrationReady());
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function testTierZeroLinkLocksBothNFTsWithoutChangingBaseWeight() external {
        _buyGenesis(alice, 1);
        uint256 positionId = _createPosition(alice);

        vm.prank(alice);
        integration.linkGenesis(positionId, 1);

        assertEq(integration.linkedPosition(1), positionId);
        assertEq(integration.linkedGenesis(positionId), 1);
        assertTrue(genesis.locked(1));
        assertTrue(IERC5192(address(diamond)).locked(positionId));
        assertTrue(
            IStaticsPosition(address(diamond)).isLegActive(positionId, LibPosition.genesisLegKey(address(diamond), 1))
        );
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, alice, positionId);
        vm.prank(alice);
        genesis.transferFrom(alice, alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionLocked.selector, positionId));
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
        genesis.transferFrom(alice, bob, 1);
    }

    function testTierFourLinkUsesEffectiveWeightWithoutChangingPrincipal() external {
        _buyGenesis(alice, 2);
        _activate(alice, 2, 4);
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt;
        vm.warp(eligibleAt);
        globalRewards.checkpointRewardAssets(_asset(address(assetA)));
        integration.linkGenesis(positionId, 2);
        vm.stopPrank();

        IStaticsGlobalRewards.RewardAssetView memory book = globalRewards.rewardAsset(address(assetA));
        vm.prank(alice);
        IStaticsGlobalRewards.StakePositionView memory stake = globalRewards.stakePosition(positionId);
        assertEq(stake.stakedBalance, 100 ether);
        assertEq(stake.rewardMultiplierBps, 12_500);
        assertEq(globalRewards.totalStaked(), 100 ether);
        assertEq(book.eligibleStake, 100 ether);
        assertEq(book.eligibleWeight, 125 ether);
    }

    function testActivationWhileLinkedChangesOnlyFutureRewardWeight() external {
        _buyGenesis(alice, 3);
        _activate(alice, 3, 1);
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 positionId = globalRewards.createAndStake(100 ether, alice, _asset(address(assetA)));
        integration.linkGenesis(positionId, 3);
        uint40 eligibleAt = globalRewards.rewardSelection(positionId, address(assetA)).eligibleAt;
        vm.stopPrank();
        _fundActivation(alice, 90_000 ether);
        vm.prank(alice);
        activationRegistry.activate(3, 4);
        vm.prank(alice);
        IStaticsGlobalRewards.RewardSelectionView memory selection =
            globalRewards.rewardSelection(positionId, address(assetA));

        assertEq(selection.pendingStake, 100 ether);
        assertEq(selection.pendingWeight, 125 ether);
        assertEq(selection.eligibleAt, eligibleAt);
    }

    function testOnlyActualOwnersCanLinkEvenWhenOperatorApprovalsExist() external {
        _buyGenesis(alice, 4);
        uint256 positionId = _createPosition(alice);
        vm.startPrank(alice);
        genesis.approve(bob, 4);
        IERC721(address(diamond)).approve(bob, positionId);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFTFacet.NotAssetOwner.selector, 4, bob, alice));
        integration.linkGenesis(positionId, 4);
    }

    function testUnlinkDuringActiveCreditRemovesBoostButPreservesCredit() external {
        _buyGenesis(alice, 5);
        _activate(alice, 5, 4);
        uint256 positionId = _createPosition(alice);
        vm.prank(alice);
        integration.linkGenesis(positionId, 5);
        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(5, 100_000 ether);

        vm.prank(alice);
        integration.unlinkGenesis(positionId, 5);

        assertTrue(vault.creditActive(5));
        assertEq(genesis.ownerOf(5), alice);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
        assertEq(integration.linkedPosition(5), 0);
        assertEq(integration.linkedGenesis(positionId), 0);
        assertFalse(IERC5192(address(diamond)).locked(positionId));
        assertTrue(genesis.locked(5));
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 10_000);
    }

    function testCreditOpenExtendAndRepayPreserveLinkAndMultiplier() external {
        _buyGenesis(alice, 7);
        _activate(alice, 7, 4);
        uint256 positionId = _createPosition(alice);
        vm.prank(alice);
        integration.linkGenesis(positionId, 7);
        vm.warp(epochEnd);

        vm.startPrank(alice);
        vault.openGenesisCredit{value: ORIGINATION_FEE}(7, 100_000 ether);
        vault.extendGenesisCredit{value: EXTENSION_FEE}(7);
        stakingAsset.approve(address(vault), 100_000 ether);
        vault.repayGenesisCredit(7);
        vm.stopPrank();

        assertFalse(vault.creditActive(7));
        assertEq(integration.linkedPosition(7), positionId);
        assertEq(integration.linkedGenesis(positionId), 7);
        assertTrue(genesis.locked(7));
        assertTrue(IERC5192(address(diamond)).locked(positionId));
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).rewardMultiplierBps, 12_500);
    }

    function testUnlinkRestoresIndependentTransfersWithoutMovingCustody() external {
        _buyGenesis(alice, 6);
        uint256 positionId = _createPosition(alice);
        vm.startPrank(alice);
        integration.linkGenesis(positionId, 6);
        integration.unlinkGenesis(positionId, 6);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        genesis.transferFrom(alice, bob, 6);
        vm.stopPrank();

        assertEq(IERC721(address(diamond)).ownerOf(positionId), bob);
        assertEq(genesis.ownerOf(6), bob);
        assertEq(activationRegistry.multiplierBps(6), 10_000);
    }

    function _installGenesisIntegration() private {
        GenesisNFTFacet genesisFacet = new GenesisNFTFacet();
        GenesisIntegrationInitHarness initHarness = new GenesisIntegrationInitHarness();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(genesisFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: StaticsSelectors.genesisNFT()
        });
        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = GenesisIntegrationInitHarness.initializeGenesisIntegration.selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(initHarness), action: IDiamondCut.FacetCutAction.Add, functionSelectors: initSelectors
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _buyGenesis(address owner, uint256 genesisId) private {
        stakingAsset.mint(owner, GENESIS_PRICE);
        vm.startPrank(owner);
        stakingAsset.approve(address(vault), GENESIS_PRICE);
        vault.buyGenesis(genesisId, owner);
        vm.stopPrank();
    }

    function _createPosition(address owner) private returns (uint256 positionId) {
        vm.prank(owner);
        positionId = IStaticsPosition(address(diamond)).createPosition(owner);
    }

    function _activate(address owner, uint256 genesisId, uint8 tier) private {
        uint256 amount = tier == 1 ? 10_000 ether : 100_000 ether;
        _fundActivation(owner, amount);
        vm.prank(owner);
        activationRegistry.activate(genesisId, tier);
    }

    function _fundActivation(address owner, uint256 amount) private {
        stakingAsset.mint(owner, amount);
        vm.prank(owner);
        stakingAsset.approve(address(activationRegistry), type(uint256).max);
    }

    function _asset(address asset) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = asset;
    }

    function _installLocalLiquidityIntegration() internal pure override returns (bool) {
        return false;
    }
}
