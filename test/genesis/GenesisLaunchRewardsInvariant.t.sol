// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {IGenesisLaunchDistributor} from "../../src/interfaces/IGenesisLaunchDistributor.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";

contract InvariantDopplerFeeSource {
    address public asset;
    address public numeraire;
    address public beneficiary;
    uint256 public staticsPending;
    uint256 public numerairePending;

    function configure(address asset_, address numeraire_, address beneficiary_) external {
        asset = asset_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function queue(uint256 staticsAmount, uint256 numeraireAmount) external {
        staticsPending += staticsAmount;
        numerairePending += numeraireAmount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 assetAmount = staticsPending;
        uint256 pairedAmount = numerairePending;
        staticsPending = 0;
        numerairePending = 0;
        if (assetAmount != 0) MockDopplerToken(asset).transfer(msg.sender, assetAmount);
        if (pairedAmount != 0) MockDopplerToken(numeraire).transfer(msg.sender, pairedAmount);
        fees0 = uint128(assetAmount);
        fees1 = uint128(pairedAmount);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
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

contract GenesisLaunchRewardsHandler is Test {
    uint256 private constant PRICE = 180_000 ether;

    MockDopplerToken public immutable statics;
    MockDopplerToken public immutable weth;
    InvariantDopplerFeeSource public immutable feeSource;
    StaticsFeeReceiver public immutable receiver;
    GenesisActivationRegistry public immutable registry;
    GenesisLaunchDistributor public immutable distributor;
    StaticsGenesis public immutable genesis;
    address[3] public actors;

    constructor(
        MockDopplerToken statics_,
        MockDopplerToken weth_,
        InvariantDopplerFeeSource feeSource_,
        StaticsFeeReceiver receiver_,
        GenesisActivationRegistry registry_,
        GenesisLaunchDistributor distributor_,
        StaticsGenesis genesis_,
        address[3] memory actors_
    ) {
        statics = statics_;
        weth = weth_;
        feeSource = feeSource_;
        receiver = receiver_;
        registry = registry_;
        distributor = distributor_;
        genesis = genesis_;
        actors = actors_;
    }

    function accrue(uint96 staticsSeed, uint96 wethSeed) external {
        uint256 staticsAmount = bound(uint256(staticsSeed), 0, 100_000 ether);
        uint256 wethAmount = bound(uint256(wethSeed), 0, 100 ether);
        if (staticsAmount != 0) statics.transfer(address(feeSource), staticsAmount);
        if (wethAmount != 0) weth.transfer(address(feeSource), wethAmount);
        feeSource.queue(staticsAmount, wethAmount);
        distributor.accrue();
    }

    function harvestOnly(uint96 staticsSeed, uint96 wethSeed) external {
        uint256 staticsAmount = bound(uint256(staticsSeed), 0, 100_000 ether);
        uint256 wethAmount = bound(uint256(wethSeed), 0, 100 ether);
        if (staticsAmount != 0) statics.transfer(address(feeSource), staticsAmount);
        if (wethAmount != 0) weth.transfer(address(feeSource), wethAmount);
        feeSource.queue(staticsAmount, wethAmount);
        receiver.harvest();
    }

    function activate(uint256 tokenSeed, uint8 tierSeed) external {
        uint256 tokenId = bound(tokenSeed, 1, 3);
        uint8 current = registry.tierOf(tokenId);
        if (current == 4) return;
        uint8 target = uint8(bound(uint256(tierSeed), current + 1, 4));
        uint256 cost;
        for (uint8 tier = current + 1; tier <= target; ++tier) {
            cost += registry.tierCost(tier);
        }
        address owner = genesis.ownerOf(tokenId);
        vm.startPrank(owner);
        statics.approve(address(registry), cost);
        registry.activate(tokenId, target);
        vm.stopPrank();
    }

    function transferGenesis(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 tokenId = bound(tokenSeed, 1, 3);
        address previousOwner = genesis.ownerOf(tokenId);
        address nextOwner = actors[bound(actorSeed, 0, 2)];
        if (nextOwner == previousOwner) return;
        vm.prank(previousOwner);
        genesis.transferFrom(previousOwner, nextOwner, tokenId);
    }

    function claimGenesis(uint256 tokenSeed, bool claimStatics) external {
        uint256 tokenId = bound(tokenSeed, 1, 3);
        address owner = genesis.ownerOf(tokenId);
        address asset = claimStatics ? address(statics) : address(weth);
        if (distributor.pendingGenesis(tokenId, asset) == 0) return;
        vm.prank(owner);
        distributor.claimGenesis(tokenId, asset, owner);
    }

    function claimOwner(uint256 actorSeed, bool claimStatics) external {
        address owner = actors[bound(actorSeed, 0, 2)];
        address asset = claimStatics ? address(statics) : address(weth);
        if (distributor.ownerClaimable(owner, asset) == 0) return;
        vm.prank(owner);
        distributor.claimOwnerRewards(asset, owner);
    }

    function donate(uint96 amountSeed, bool toReceiver, bool donateStatics) external {
        uint256 amount = bound(uint256(amountSeed), 0, donateStatics ? 1_000 ether : 1 ether);
        MockDopplerToken token = donateStatics ? statics : weth;
        token.transfer(toReceiver ? address(receiver) : address(distributor), amount);
    }
}

contract GenesisLaunchRewardsInvariantTest is StdInvariant, Test {
    uint256 private constant PRICE = 180_000 ether;

    MockDopplerToken private statics;
    MockDopplerToken private weth;
    StaticsFeeReceiver private receiver;
    GenesisActivationRegistry private registry;
    GenesisLaunchDistributor private distributor;
    StaticsGenesis private genesis;

    function setUp() public {
        address treasury = makeAddr("treasury");
        address[3] memory actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        statics = new MockDopplerToken(address(this));
        weth = new MockDopplerToken(address(this));
        InvariantDopplerFeeSource feeSource = new InvariantDopplerFeeSource();
        receiver = new StaticsFeeReceiver(address(feeSource), address(weth), address(this));
        bytes32 poolId = keccak256("GENESIS_INVARIANT");
        feeSource.configure(address(statics), address(weth), address(receiver));
        receiver.bindMarket(address(statics), poolId);
        registry = new GenesisActivationRegistry(statics, address(this), address(this), treasury);
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(receiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        StaticsGenesisVault vault =
            new StaticsGenesisVault(statics, address(this), address(this), block.timestamp + 3650 days, creditConfig);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(
            address(vault),
            address(this),
            address(registry),
            renderer,
            address(this),
            treasury,
            "ipfs://contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        statics.transfer(address(vault), vault.INITIAL_TOKEN_BACKING());
        vault.finalizeGenesisCollection(address(genesis));
        distributor = new GenesisLaunchDistributor(receiver, genesis, registry, treasury, address(this), 7_500);
        receiver.proposeDistributor(address(distributor));
        distributor.acceptFeeReceiverRole();
        registry.proposeConsumer(address(distributor));
        distributor.acceptActivationConsumer();

        for (uint256 i; i < actors.length; ++i) {
            statics.transfer(actors[i], PRICE + 1_000_000 ether);
            vm.deal(actors[i], 1 ether);
            vm.startPrank(actors[i]);
            statics.approve(address(vault), PRICE);
            vault.buyGenesis(i + 1, actors[i]);
            distributor.registerGenesis(i + 1);
            vm.stopPrank();
        }

        GenesisLaunchRewardsHandler handler =
            new GenesisLaunchRewardsHandler(statics, weth, feeSource, receiver, registry, distributor, genesis, actors);
        statics.transfer(address(handler), 100_000_000 ether);
        weth.transfer(address(handler), 100_000_000 ether);
        targetContract(address(handler));
    }

    function invariantWeightsMatchRegisteredGenesis() public view {
        uint256 expected;
        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) {
            expected += distributor.effectiveWeight(tokenId);
        }
        assertEq(distributor.totalWeight(), expected);
    }

    function invariantReceiverCustodyCoversDistributorLiability() public view {
        assertGe(statics.balanceOf(address(receiver)), receiver.totalDistributorLiability(address(statics)));
        assertGe(weth.balanceOf(address(receiver)), receiver.totalDistributorLiability(address(weth)));
    }

    function invariantDistributorCustodyCoversAllCrystallizedLiability() public view {
        _assertDistributorAsset(address(statics));
        _assertDistributorAsset(address(weth));
    }

    function _assertDistributorAsset(address asset) private view {
        IGenesisLaunchDistributor.RewardBookView memory book = distributor.rewardBook(asset);
        uint256 accounted = distributor.accountedCustody(asset);
        assertGe(IERC20Like(asset).balanceOf(address(distributor)), accounted);
        uint256 deferred = receiver.distributorClaimable(address(distributor), asset);
        uint256 pendingRecovery = asset == address(statics) ? distributor.pendingGenesisRecovery() : 0;
        assertGe(accounted + deferred, book.totalClaimable + book.treasuryClaimable + pendingRecovery);
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
