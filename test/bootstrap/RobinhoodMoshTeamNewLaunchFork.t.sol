// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMoshSwarm} from "../../src/interfaces/IMoshSwarm.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {MoshTeamRevenueAdapter} from "../../src/bootstrap/MoshTeamRevenueAdapter.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {MoshForkFeeHook} from "./RobinhoodMoshClaimFork.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IMoshNewLaunchFactory {
    struct Trading {
        uint256 maxBuyFractionBps;
        uint256 maxSellFractionBps;
        uint256 maxBuySizeIn;
        uint256 windowBuyFractionBps;
        uint256 windowSellFractionBps;
        uint256 windowLength;
        uint256 reserveFloorBps;
    }

    struct LaunchStep {
        address planner;
        uint8 phase;
        uint8 vaultMask;
        bytes data;
    }

    struct CreateParams {
        bytes32 launchParamsHash;
        uint256 minBundleReceived;
        uint256 raiseTarget;
        uint256 raiseDuration;
        uint256 launchWindow;
        uint256 agentCount;
        address teamRecipient;
        uint256 teamShareBps;
        Trading trading;
        bool depositWhitelistEnabled;
        address[] whitelist;
        uint256[] whitelistAllowances;
        address whitelistManager;
        LaunchStep[] launchProgram;
    }

    function createLauncher(address beneficiary, bytes32 commit, bytes32 salt) external returns (address);
    function predictSwarm(address launcher) external view returns (address);
    function policyHashOf(CreateParams calldata terms) external view returns (bytes32);
    function policyVersion() external view returns (bytes32);
    function creatorOf(address swarm) external view returns (address);
    function isSwarm(address swarm) external view returns (bool);
    function launcherImplementation() external view returns (address);
}

interface IMoshNewLauncher {
    function create(IMoshNewLaunchFactory.CreateParams calldata terms, bytes calldata launchBytes)
        external
        returns (address);
    function fire(bool finalizeInTx) external;
    function swarm() external view returns (address);
    function isFireAuthority(address who) external view returns (bool);
    function committedLaunchParams() external view returns (bytes memory);
}

interface IMoshNewSwarm is IMoshSwarm {
    function deposit(uint256 amount) external payable;
    function finalize() external;
    function phase() external view returns (uint8);
    function curve() external view returns (address);
    function totalClaims() external view returns (uint256);
    function totalDeposited() external view returns (uint256);
    function totalFeesCredited() external view returns (uint256);
    function vaultCount() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
}

interface IMoshNewPons {
    function previewLaunchEconomics(uint256 config, address pair) external view returns (bytes32);
}

/// @dev Flattened launch payload published by the actual Mosh application at
/// https://mosh.trade/_next/static/chunks/2wtjf91g4vinm.js. This is NOT the
/// nested PONS launchToken TokenParams tuple (nor arbitrary router calldata).
struct MoshNewTokenTerms {
    string name;
    string symbol;
    string logo;
    string description;
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

/// @dev Fork-only real launch: purchase BUN for the genuine creator gate,
/// execute actual factory/launcher/Swarm/PONS contracts, and bind minted team
/// rights. No successful adapter/source authority mocks, storage etch, or
/// adapter impersonation. Only native test-account funding is provisioned.
contract RobinhoodMoshTeamNewLaunchForkTest is CampaignTestBase, IUnlockCallback {
    address private constant FACTORY = 0x9073cb17846398fB8B379Ab06C2B840dEA7f0069;
    address private constant REGISTRY = 0x71BDDCfee17b718c92f0Be80910D2f06542ff379;
    address private constant IMPLEMENTATION = 0x42B0b14C6e6bCAa2e9B29F87aA3DE19290a5c572;
    address private constant LAUNCHER_IMPLEMENTATION = 0xAd1d7de0cC64d2e5884Cb5BfbbBcF5848669Ffa2;
    address private constant PLANNER = 0x2f95F0a9FCf3380C1A621B2813bc717c25E9E3ea;
    address private constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address private constant BUN = 0x07EBB29a38Fbcb41563817e5E19f2ceC619C90D2;
    address private constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPoolManager private constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint256 private constant RAISE = 5 ether;

    WETH private wrapped;
    MoshTeamRevenueAdapter private adapter;
    BasketBootstrapCampaign private destination;
    IMoshNewSwarm private source;
    PoolKey private sourceKey;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "Robinhood RPC not configured");
            return;
        }
        vm.createSelectFork(rpc, 80_155_273);
        super.setUp();
        vm.deal(vm.addr(CREATOR_KEY), 100 ether);
        wrapped = new WETH();
        adapter = new MoshTeamRevenueAdapter(
            vm.addr(CREATOR_KEY),
            address(wrapped),
            address(wrapped).codehash,
            campaignFactory,
            _pins(),
            LibMoshValidation.MarketPins(
                0xA8C83951eE2431106f0aAea6ae79F97A530521aA,
                0x2d345a9fa04e9284e3dc108ed4455c4c73c0747dde5875861aa960f5ed0c483e,
                1000
            ),
            1000
        );
        assertEq(FACTORY.codehash, _pins().factoryRuntimeHash);
        assertEq(REGISTRY.codehash, _pins().registryRuntimeHash);
        assertEq(IMPLEMENTATION.codehash, _pins().implementationRuntimeHash);
        assertEq(PONS.codehash, 0x89a27da6f703e0a7cdd4f233e7cb57604ff75b164530962d3ff7cf8483a67d84);
        assertEq(IMoshNewLaunchFactory(FACTORY).launcherImplementation(), LAUNCHER_IMPLEMENTATION);
        assertEq(LAUNCHER_IMPLEMENTATION.codehash, 0x2eb0095f5e8e0db27a9f2ba828ad96c2221b85b121fa06654b6a89b2a222a66f);
        assertEq(PLANNER.codehash, 0xe87f1db3d85d3ef4005db400641e6215fed8e1ce6fc1e6f294ca60dfe8522b53);
        assertEq(IMoshNewLaunchFactory(FACTORY).policyVersion(), bytes32("pons-balanced-wide-tail-v3"));
    }

    function _pins() private pure returns (LibMoshValidation.SourcePins memory) {
        return LibMoshValidation.SourcePins(
            4663,
            FACTORY,
            0x82edd64be0bedd5f9462e948447c6416adad6c77c71945e1cba585387f553423,
            REGISTRY,
            0x93f0f1391a76bb2aa72c310f33636f9049002ef16584a9b0370e199edb26702e,
            IMPLEMENTATION,
            0x210393a615dd4a801aaa9449b8e65d6b0ba7b98d6ef5ed9f2400833643fd44ac
        );
    }

    function _creation(bytes32 launchHash) private view returns (IMoshNewLaunchFactory.CreateParams memory terms) {
        terms.launchParamsHash = launchHash;
        terms.minBundleReceived = 1;
        terms.raiseTarget = RAISE;
        terms.raiseDuration = 3 days;
        terms.launchWindow = 3 days;
        terms.agentCount = 3;
        terms.teamRecipient = address(adapter);
        terms.teamShareBps = 1000;
        terms.trading = IMoshNewLaunchFactory.Trading(2500, 5, RAISE / 4, 2500, 10, 3600, 0);
        terms.whitelist = new address[](0);
        terms.whitelistAllowances = new uint256[](0);
        terms.launchProgram = new IMoshNewLaunchFactory.LaunchStep[](5);
        uint256[5] memory counts = [uint256(50), 101, 152, 258, 476];
        uint256[5] memory lower = [uint256(5000), 12000, 22000, 34000, 46000];
        uint256[5] memory upper = [uint256(14000), 26000, 38000, 50000, 60000];
        for (uint256 i; i < 5; ++i) {
            terms.launchProgram[i] = IMoshNewLaunchFactory.LaunchStep(
                PLANNER, 2, 0, abi.encode(uint256(0), uint256(1), counts[i], lower[i], upper[i])
            );
        }
    }

    function _launchNewSwarm() private {
        // Buy actual gate tokens through the actual initialized v4 pool. Neither
        // gate exemption nor upstream authority/storage is synthesized.
        _swap(BUN, 1 ether, vm.addr(CREATOR_KEY));
        assertGe(IERC20(BUN).balanceOf(vm.addr(CREATOR_KEY)), 25_000 ether);
        MoshNewTokenTerms memory tokenTerms;
        tokenTerms.name = "Statics new team revenue";
        tokenTerms.symbol = "SNTR";
        tokenTerms.creatorTaxBps = 100;
        tokenTerms.expectedEconomics = IMoshNewPons(PONS).previewLaunchEconomics(0, address(0));
        tokenTerms.salt = keccak256("Statics actual new Mosh team launch");
        bytes memory launchBytes = abi.encode(tokenTerms);
        IMoshNewLaunchFactory.CreateParams memory terms = _creation(keccak256(launchBytes));
        assertTrue(IMoshNewLaunchFactory(FACTORY).policyHashOf(terms) != bytes32(0));
        bytes32 commit = keccak256(abi.encode(terms));
        bytes32 salt = keccak256(abi.encodePacked(hex"6c6e6368", commit));
        vm.prank(vm.addr(CREATOR_KEY));
        IMoshNewLauncher launcher =
            IMoshNewLauncher(IMoshNewLaunchFactory(FACTORY).createLauncher(vm.addr(CREATOR_KEY), commit, salt));
        address predicted = IMoshNewLaunchFactory(FACTORY).predictSwarm(address(launcher));
        vm.prank(vm.addr(CREATOR_KEY));
        source = IMoshNewSwarm(launcher.create(terms, launchBytes));
        assertEq(address(source), predicted);
        assertEq(launcher.swarm(), address(source));
        assertEq(keccak256(launcher.committedLaunchParams()), keccak256(launchBytes));
        assertTrue(IMoshNewLaunchFactory(FACTORY).isSwarm(address(source)));
        // This generation records the actual launcher as factory creator;
        // the initiating EOA retains its launcher fire authority separately.
        assertEq(IMoshNewLaunchFactory(FACTORY).creatorOf(address(source)), address(launcher));
        assertEq(source.teamRecipient(), address(adapter));
        assertEq(source.teamShareBps(), 1000);
        vm.prank(vm.addr(CREATOR_KEY));
        source.deposit{value: RAISE}(RAISE);
        assertEq(source.totalDeposited(), RAISE);
        assertTrue(launcher.isFireAuthority(vm.addr(CREATOR_KEY)));
        // Actual launcher triggers PONS launch, opening purchase, graduation
        // and Swarm agent finalization. Any prerequisite failure is a failure,
        // never a mocked-success shortcut or silently skipped branch.
        vm.prank(vm.addr(CREATOR_KEY));
        launcher.fire(true);
        assertEq(source.phase(), 3, "actual Swarm is Live");
        assertTrue(source.memecoin().code.length != 0);
        assertEq(source.vaultCount(), 3);
        assertGt(source.claim(address(adapter)), 0, "actual launch mints team rights");
        sourceKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(source.memecoin()), 0, 200, IHooks(HOOK));
        vm.warp(block.timestamp + 1 minutes);
    }

    function _bindDestination() private {
        uint256 claimsBefore = source.claim(address(adapter));
        bytes32 principalBefore = _principalHash();
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.projectToken = source.memecoin();
        terms.basket.assets[0] = address(wrapped);
        terms.adapters = new address[](1);
        terms.adapters[0] = address(adapter);
        destination = _campaign(terms, keccak256("actual new Mosh team campaign"));
        vm.startPrank(vm.addr(CREATOR_KEY));
        adapter.bindCampaign(destination, 0);
        adapter.bindSource(source);
        vm.stopPrank();
        assertTrue(adapter.rightsBound());
        assertEq(adapter.teamClaims(), source.claim(address(adapter)));
        assertEq(adapter.sourceTeamRecipient(), address(adapter));
        assertEq(adapter.sourceToken(), source.memecoin());
        assertEq(adapter.teamClaims(), claimsBefore, "binding retains actual minted rights");
        assertEq(_principalHash(), principalBefore, "binding cannot access principal");
    }

    function _swap(address token, uint256 amount, address receiver) private {
        MANAGER.unlock(abi.encode(token, amount, receiver));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER));
        (address token, uint256 amount, address receiver) = abi.decode(data, (address, uint256, address));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 0, 200, IHooks(HOOK));
        BalanceDelta delta = MANAGER.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
        MANAGER.settle{value: uint256(-int256(delta.amount0()))}();
        MANAGER.take(key.currency1, receiver, uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }

    function _principalHash() private view returns (bytes32 commitment) {
        for (uint256 i; i < source.vaultCount(); ++i) {
            address vault = source.vaults(i);
            commitment =
                keccak256(abi.encode(commitment, vault, vault.balance, IERC20(source.memecoin()).balanceOf(vault)));
        }
    }

    function testActualNewLaunchBindsMintedTeamClaimsAndDeliversConvertedSwapRevenue() public {
        _launchNewSwarm();
        _bindDestination();
        // Settle already-realized opening fees first. Subsequent positive
        // credit and receipt must come from the new real pool trade, not from
        // a leftover launch entitlement masquerading as swap coverage.
        adapter.sync();
        adapter.flushTeamRevenue();
        (,, uint256 heldBefore,) = destination.inventory(0);
        uint256 feesBefore = source.totalFeesCredited();
        uint256 measuredBefore = adapter.totalMeasured();
        uint256 claims = adapter.teamClaims();
        uint256 deposited = source.totalDeposited();
        bytes32 principal = _principalHash();
        _swap(source.memecoin(), 0.01 ether, address(this));
        // Existing fee-sweep operator is solely an upstream diagnostic input;
        // the adapter itself gains no operator or principal access.
        vm.prank(MoshForkFeeHook(HOOK).feeSweepOperator());
        MoshForkFeeHook(HOOK).sweepPoolFees(keccak256(abi.encode(sourceKey)), 1, 1);
        source.syncFees();
        assertGt(source.totalFeesCredited(), feesBefore, "new swap credits additional actual source fees");
        uint256 expected = source.claimable(address(adapter));
        assertGt(expected, 0);
        assertEq(adapter.sync(), expected);
        assertEq(adapter.nativeReserved(), expected);
        assertEq(adapter.totalMeasured(), measuredBefore + expected);
        assertEq(adapter.flushTeamRevenue(), expected);
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, heldBefore + expected);
        assertEq(wrapped.balanceOf(address(destination)), heldBefore + expected);
        assertEq(wrapped.allowance(address(adapter), address(destination)), 0);
        assertEq(adapter.nativeReserved(), 0);
        assertEq(source.claim(address(adapter)), claims);
        assertEq(source.teamRecipient(), address(adapter));
        assertEq(source.totalDeposited(), deposited);
        assertEq(_principalHash(), principal, "adapter never accesses agent principal");
    }
}
