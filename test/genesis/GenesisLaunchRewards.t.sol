// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {
    IGenesisActivationConsumer,
    IGenesisActivationRegistry
} from "../../src/interfaces/IGenesisActivationRegistry.sol";
import {IStaticsFeeReceiver} from "../../src/interfaces/IStaticsFeeReceiver.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";

contract MockRewardToken is ERC20 {
    bool public transfersRevert;

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setTransfersRevert(bool value) external {
        transfersRevert = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!transfersRevert, "TRANSFERS_DISABLED");
        super._update(from, to, amount);
    }
}

contract MockDopplerFeeSource {
    address public asset;
    address public numeraire;
    mapping(bytes32 poolId => mapping(address beneficiary => uint256 shares)) public getShares;
    uint256 public pending0;
    uint256 public pending1;

    function configure(bytes32 poolId, address asset_, address numeraire_, address receiver) external {
        asset = asset_;
        numeraire = numeraire_;
        getShares[poolId][receiver] = 0.95 ether;
    }

    function queue(address statics, address weth, uint256 staticsAmount, uint256 wethAmount) external {
        if (staticsAmount != 0) IERC20(statics).transferFrom(msg.sender, address(this), staticsAmount);
        if (wethAmount != 0) IERC20(weth).transferFrom(msg.sender, address(this), wethAmount);
        pending0 += staticsAmount;
        pending1 += wethAmount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 staticsAmount = pending0;
        uint256 wethAmount = pending1;
        delete pending0;
        delete pending1;
        if (staticsAmount != 0) IERC20(asset).transfer(msg.sender, staticsAmount);
        if (wethAmount != 0) IERC20(numeraire).transfer(msg.sender, wethAmount);
        fees0 = uint128(staticsAmount);
        fees1 = uint128(wethAmount);
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        (currency0, currency1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract MockNextDistributor {
    function accept(IStaticsFeeReceiver receiver) external {
        receiver.acceptDistributor();
    }

    function claim(IStaticsFeeReceiver receiver, address asset, address destination) external returns (uint256) {
        return receiver.claimDistributorFees(asset, destination);
    }
}

contract MockActivationConsumer is IGenesisActivationConsumer {
    uint256 public callbacks;

    function accept(IGenesisActivationRegistry registry) external {
        registry.acceptConsumer();
    }

    function onGenesisTransition(uint256, address, address, uint16, uint16) external {
        ++callbacks;
    }
}

contract MockActivationStateObserver is IGenesisActivationConsumer {
    IGenesisActivationRegistry public immutable registry;
    uint8 public observedTier;
    uint16 public observedMultiplier;

    constructor(IGenesisActivationRegistry registry_) {
        registry = registry_;
    }

    function accept() external {
        registry.acceptConsumer();
    }

    function onGenesisTransition(uint256 genesisId, address, address, uint16, uint16) external {
        require(msg.sender == address(registry), "REGISTRY_ONLY");
        observedTier = registry.tierOf(genesisId);
        observedMultiplier = registry.multiplierBps(genesisId);
    }
}

contract GenesisLaunchRewardsTest is Test {
    uint256 private constant PRICE = 180_000 ether;
    bytes32 private constant POOL_ID = keccak256("STATICS_WETH");

    address private governance;
    address private treasury;
    address private alice;
    address private bob;
    address private carol;
    MockDopplerToken private statics;
    MockRewardToken private weth;
    MockDopplerFeeSource private feeSource;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private activationRegistry;
    GenesisLaunchDistributor private distributor;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;

    function setUp() public {
        governance = makeAddr("governance");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        statics = new MockDopplerToken(address(this));
        weth = new MockRewardToken();
        feeSource = new MockDopplerFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), address(weth), governance);
        feeSource.configure(POOL_ID, address(statics), address(weth), address(feeReceiver));
        vm.prank(governance);
        feeReceiver.bindMarket(address(statics), POOL_ID);

        activationRegistry = new GenesisActivationRegistry(statics, address(this), governance, treasury);
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(this), governance, block.timestamp + 3650 days, creditConfig);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(
            address(vault),
            address(this),
            address(activationRegistry),
            renderer,
            governance,
            treasury,
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        activationRegistry.bindGenesisCollection(address(genesis));
        statics.transfer(address(vault), vault.INITIAL_TOKEN_BACKING());
        vault.finalizeGenesisCollection(address(genesis));

        distributor =
            new GenesisLaunchDistributor(feeReceiver, genesis, activationRegistry, treasury, governance, 10_000);
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(distributor));
        vm.prank(governance);
        distributor.acceptFeeReceiverRole();
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(distributor));
        vm.prank(governance);
        distributor.acceptActivationConsumer();

        statics.approve(address(feeSource), type(uint256).max);
        weth.mint(address(this), 1_000_000 ether);
        weth.approve(address(feeSource), type(uint256).max);
    }

    function testDirectDonationsDoNotIncreaseHarvestedRevenue() public {
        statics.transfer(address(feeReceiver), 50 ether);
        _queue(100 ether, 25 ether);
        distributor.accrue();
        assertEq(feeReceiver.cumulativeHarvested(address(statics)), 100 ether);
        assertEq(feeReceiver.cumulativeHarvested(address(weth)), 25 ether);
        assertEq(statics.balanceOf(address(feeReceiver)), 50 ether);
        assertEq(distributor.accountedCustody(address(statics)), 100 ether);
    }

    function testMarketBindingRequiresExactNinetyFivePercentBeneficiaryShare() public view {
        assertEq(feeReceiver.poolInitializer(), address(feeSource));
        assertEq(feeSource.getShares(POOL_ID, address(feeReceiver)), 0.95 ether);
    }

    function testActivationConsumerObservesPreviousTierDuringCallback() public {
        _buyAndRegister(alice, 1);
        MockActivationStateObserver observer = new MockActivationStateObserver(activationRegistry);
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(observer));
        observer.accept();

        uint256 activationCost = activationRegistry.tierCost(1);
        statics.transfer(alice, activationCost);
        vm.startPrank(alice);
        statics.approve(address(activationRegistry), activationCost);
        activationRegistry.activate(1, 1);
        vm.stopPrank();

        assertEq(observer.observedTier(), 0);
        assertEq(observer.observedMultiplier(), 10_000);
        assertEq(activationRegistry.tierOf(1), 1);
        assertEq(activationRegistry.multiplierBps(1), 11_000);
    }

    function testTwoGenesisWeightsUseRemainderIndexAcrossActivation() public {
        _buyAndRegister(alice, 1);
        _buyAndRegister(bob, 2);
        _queue(2_000 ether, 0);
        distributor.accrue();

        uint256 activationCost = activationRegistry.tierCost(1);
        statics.transfer(alice, activationCost);
        vm.startPrank(alice);
        statics.approve(address(activationRegistry), activationCost);
        activationRegistry.activate(1, 1);
        vm.stopPrank();

        _queue(2_100 ether, 0);
        distributor.accrue();
        assertEq(distributor.pendingGenesis(1, address(statics)), 2_100 ether);
        assertEq(distributor.pendingGenesis(2, address(statics)), 2_000 ether);
        assertEq(distributor.totalWeight(), 21_000);
    }

    function testTransferCrystallizesOldRewardsAndFutureRewardsFollowNewOwner() public {
        _buyAndRegister(alice, 1);
        _buyAndRegister(bob, 2);
        _queue(2_000 ether, 0);
        distributor.accrue();

        vm.prank(alice);
        genesis.transferFrom(alice, carol, 1);
        assertEq(distributor.ownerClaimable(alice, address(statics)), 1_000 ether);
        assertEq(distributor.effectiveWeight(1), 10_000);

        _queue(2_000 ether, 0);
        distributor.accrue();
        vm.prank(carol);
        assertEq(distributor.claimGenesis(1, address(statics), carol), 1_000 ether);
        vm.prank(alice);
        assertEq(distributor.claimOwnerRewards(address(statics), alice), 1_000 ether);
    }

    function testHarvestThenTransferCheckpointsAttributedFeesToPreviousOwner() public {
        _buyAndRegister(alice, 1);
        _buyAndRegister(bob, 2);
        _queue(2_000 ether, 0);

        feeReceiver.harvest();
        assertEq(feeReceiver.cumulativeDistributorAttributed(address(distributor), address(statics)), 2_000 ether);
        assertEq(feeReceiver.distributorClaimable(address(distributor), address(statics)), 2_000 ether);
        assertEq(statics.balanceOf(address(distributor)), 0);

        vm.prank(alice);
        genesis.transferFrom(alice, carol, 1);
        assertEq(distributor.ownerClaimable(alice, address(statics)), 1_000 ether);
        assertEq(distributor.pendingGenesis(1, address(statics)), 0);
        assertEq(statics.balanceOf(address(distributor)), 0, "transfer moved reward tokens");

        vm.prank(alice);
        assertEq(distributor.claimOwnerRewards(address(statics), alice), 1_000 ether);
        assertEq(distributor.pendingGenesis(1, address(statics)), 0, "new owner inherited attributed fees");
    }

    function testTransferDoesNotCallRevertingRewardToken() public {
        _buyAndRegister(alice, 1);
        _queue(0, 100 ether);
        distributor.accrue();
        weth.setTransfersRevert(true);

        vm.prank(alice);
        genesis.transferFrom(alice, carol, 1);
        assertEq(genesis.ownerOf(1), carol);
        assertEq(distributor.ownerClaimable(alice, address(weth)), 100 ether);
    }

    function testVaultCustodySuspendsAndRepurchaseResumesAtCurrentIndex() public {
        _buyAndRegister(alice, 1);
        _buyAndRegister(bob, 2);
        _queue(2_000 ether, 0);
        distributor.accrue();

        vm.startPrank(alice);
        genesis.approve(address(vault), 1);
        vault.redeemGenesis(1, alice);
        vm.stopPrank();
        assertEq(distributor.effectiveWeight(1), 0);
        assertEq(distributor.ownerClaimable(alice, address(statics)), 1_000 ether);

        _queue(1_000 ether, 0);
        distributor.accrue();
        statics.transfer(carol, PRICE);
        vm.startPrank(carol);
        statics.approve(address(vault), PRICE);
        vault.buyGenesis(1, carol);
        vm.stopPrank();
        assertEq(distributor.effectiveWeight(1), 10_000);
        assertEq(distributor.pendingGenesis(1, address(statics)), 0);
    }

    function testRotationPreservesOldLiabilityAndFinalClaimsFollowNft() public {
        _buyAndRegister(alice, 1);
        _queue(500 ether, 0);
        distributor.accrue();

        MockNextDistributor nextDistributor = new MockNextDistributor();
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(nextDistributor));
        nextDistributor.accept(feeReceiver);
        assertEq(feeReceiver.activeDistributor(), address(nextDistributor));

        vm.prank(governance);
        distributor.finalizeLaunchRewards();
        MockActivationConsumer nextConsumer = new MockActivationConsumer();
        vm.prank(governance);
        activationRegistry.proposeConsumer(address(nextConsumer));
        nextConsumer.accept(activationRegistry);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsFeeReceiver.DistributorAlreadyActivated.selector, address(distributor))
        );
        feeReceiver.proposeDistributor(address(distributor));

        vm.prank(governance);
        activationRegistry.proposeConsumer(address(distributor));
        vm.prank(governance);
        vm.expectRevert(GenesisLaunchDistributor.LaunchRewardsAlreadyFinalized.selector);
        distributor.acceptActivationConsumer();

        vm.prank(alice);
        genesis.transferFrom(alice, carol, 1);
        vm.prank(carol);
        assertEq(distributor.claimGenesis(1, address(statics), carol), 500 ether);
        assertEq(nextConsumer.callbacks(), 1);
    }

    function testDistributorRotationAttributesTransitionHarvestToOldDistributor() public {
        _queue(77 ether, 11 ether);
        MockNextDistributor nextDistributor = new MockNextDistributor();
        vm.prank(governance);
        feeReceiver.proposeDistributor(address(nextDistributor));
        nextDistributor.accept(feeReceiver);

        assertEq(feeReceiver.distributorClaimable(address(distributor), address(statics)), 77 ether);
        assertEq(feeReceiver.distributorClaimable(address(distributor), address(weth)), 11 ether);
        assertEq(feeReceiver.distributorClaimable(address(nextDistributor), address(statics)), 0);
    }

    function testFuzzRepeatedSmallAccrualConservesCustody(uint96 rawAmount, uint8 rawRounds) public {
        _buyAndRegister(alice, 1);
        _buyAndRegister(bob, 2);
        uint256 amount = bound(uint256(rawAmount), 1, 10_000 ether);
        uint256 rounds = bound(uint256(rawRounds), 1, 32);
        for (uint256 i; i < rounds; ++i) {
            _queue(amount, 0);
            distributor.accrue();
        }

        uint256 pending =
            distributor.pendingGenesis(1, address(statics)) + distributor.pendingGenesis(2, address(statics));
        assertLe(pending, amount * rounds);
        assertEq(statics.balanceOf(address(distributor)), amount * rounds);
        assertEq(distributor.accountedCustody(address(statics)), amount * rounds);
    }

    function _buyAndRegister(address owner, uint256 tokenId) private {
        statics.transfer(owner, PRICE);
        vm.startPrank(owner);
        statics.approve(address(vault), PRICE);
        vault.buyGenesis(tokenId, owner);
        distributor.registerGenesis(tokenId);
        vm.stopPrank();
    }

    function _queue(uint256 staticsAmount, uint256 wethAmount) private {
        feeSource.queue(address(statics), address(weth), staticsAmount, wethAmount);
    }
}
