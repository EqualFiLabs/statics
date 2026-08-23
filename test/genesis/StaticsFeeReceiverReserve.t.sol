// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {IGenesisRecoveryDistributor} from "../../src/interfaces/IGenesisRecoveryDistributor.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";
import {MockGenesisFeeReceiver} from "../mocks/MockGenesisCreditDependencies.sol";

/// @notice Doppler fee source mock that pays STATICS and WETH on collectFees.
contract ReserveFeeSource {
    address public asset;
    address public numeraire;
    address public beneficiary;
    uint256 public staticsPending;
    uint256 public wethPending;

    function configure(address asset_, address numeraire_, address beneficiary_) external {
        asset = asset_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function queue(uint256 staticsAmount, uint256 wethAmount) external {
        staticsPending += staticsAmount;
        wethPending += wethAmount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 s = staticsPending;
        uint256 w = wethPending;
        staticsPending = 0;
        wethPending = 0;
        if (s != 0) MockDopplerToken(asset).transfer(msg.sender, s);
        if (w != 0) MockWrappedNative(payable(numeraire)).transfer(msg.sender, w);
        return (uint128(s), uint128(w));
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

contract MockDistributor is IGenesisRecoveryDistributor {
    address public immutable override genesisRecoveryVault;
    address public immutable override genesisRecoveryAsset;
    uint256 public override pendingGenesisRecovery;
    bool public override genesisRecoveryReady = true;

    constructor(address vault_, address asset_) {
        genesisRecoveryVault = vault_;
        genesisRecoveryAsset = asset_;
    }

    function accept(StaticsFeeReceiver receiver) external {
        receiver.acceptDistributor();
    }

    function accrueGenesisRecovery(uint256 amount) external override {
        require(msg.sender == genesisRecoveryVault, "ONLY_VAULT");
        emit GenesisRecoveryAccrued(amount, 0, 0);
    }

    function checkpointGenesisRecovery(uint256, address) external pure override {}

    function migratePendingGenesisRecovery(address) external pure override returns (uint256 amount) {
        return 0;
    }

    function acceptPendingGenesisRecovery(uint256 amount) external override {
        pendingGenesisRecovery += amount;
    }
}

contract IncompatibleReserveDistributor {
    function accept(StaticsFeeReceiver receiver) external {
        receiver.acceptDistributor();
    }
}

contract StaticsFeeReceiverReserveTest is Test {
    bytes32 private constant POOL_ID = keccak256("STATICS_WETH_RESERVE");

    address private governance;
    address private treasury;
    MockDopplerToken private statics;
    MockWrappedNative private weth;
    ReserveFeeSource private feeSource;
    StaticsFeeReceiver private receiver;
    StaticsGenesisVault private vault;
    MockDistributor private distributor;

    function setUp() public {
        governance = makeAddr("governance");
        treasury = makeAddr("treasury");
        statics = new MockDopplerToken(address(this));
        weth = new MockWrappedNative();
        vm.deal(address(weth), 2_000_000 ether);
        feeSource = new ReserveFeeSource();
        receiver = new StaticsFeeReceiver(address(feeSource), address(weth), governance);
        feeSource.configure(address(statics), address(weth), address(receiver));
        vm.prank(governance);
        receiver.bindMarket(address(statics), POOL_ID);

        GenesisActivationRegistry registry = new GenesisActivationRegistry(statics, address(this), governance, treasury);
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(receiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(this), governance, block.timestamp + 30 days, creditConfig);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        StaticsGenesis genesis = new StaticsGenesis(
            address(vault),
            address(registry),
            renderer,
            governance,
            treasury,
            "ipfs://contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));

        distributor = new MockDistributor(address(vault), address(statics));
    }

    function _bindAndActivate(uint16 shareBps) private {
        vm.startPrank(governance);
        receiver.bindReserveVault(address(vault));
        receiver.setReserveShareBps(shareBps);
        receiver.proposeDistributor(address(distributor));
        vm.stopPrank();
        distributor.accept(receiver);
    }

    function testReserveVaultBindingRequiresMatchingStaticsAndIsOneTime() public {
        MockDopplerToken otherStatics = new MockDopplerToken(address(this));
        MockGenesisFeeReceiver otherReceiver = new MockGenesisFeeReceiver(address(otherStatics));
        GenesisCreditConfig memory otherCreditConfig = GenesisCreditConfig({
            feeReceiver: address(otherReceiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        StaticsGenesisVault otherVault = new StaticsGenesisVault(
            otherStatics, address(this), governance, block.timestamp + 1 days, otherCreditConfig
        );
        vm.prank(governance);
        vm.expectRevert(StaticsFeeReceiver.InvalidReserveVault.selector);
        receiver.bindReserveVault(address(otherVault));

        vm.prank(governance);
        receiver.bindReserveVault(address(vault));
        assertEq(receiver.reserveVault(), address(vault));

        vm.prank(governance);
        vm.expectRevert(StaticsFeeReceiver.ReserveVaultAlreadyBound.selector);
        receiver.bindReserveVault(address(vault));
    }

    function testNonzeroReserveShareRequiresBoundVault() public {
        vm.prank(governance);
        vm.expectRevert(StaticsFeeReceiver.ReserveVaultNotBound.selector);
        receiver.setReserveShareBps(5_000);
    }

    function testBoundVaultRejectsIncompatibleDistributor() public {
        IncompatibleReserveDistributor incompatible = new IncompatibleReserveDistributor();
        vm.startPrank(governance);
        receiver.bindReserveVault(address(vault));
        receiver.proposeDistributor(address(incompatible));
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                StaticsFeeReceiver.InvalidRecoveryDistributor.selector,
                address(incompatible),
                address(vault),
                address(statics)
            )
        );
        incompatible.accept(receiver);
    }

    function testHarvestSplitsWethAndForwardsReserveAsNativeEth() public {
        _bindAndActivate(5_000);
        weth.mint(address(feeSource), 100 ether);
        statics.transfer(address(feeSource), 40 ether);
        feeSource.queue(40 ether, 100 ether);

        vm.prank(governance);
        (uint256 staticsAmount, uint256 wethAmount) = receiver.harvest();

        // harvest() returns gross harvested amounts; only the distributor WETH remainder is attributed.
        assertEq(staticsAmount, 40 ether);
        assertEq(wethAmount, 100 ether);
        assertEq(receiver.distributorClaimable(address(distributor), address(statics)), 40 ether);
        assertEq(receiver.distributorClaimable(address(distributor), address(weth)), 50 ether);
        // Reserve WETH was unwrapped and donated to the vault as native ETH.
        assertEq(receiver.cumulativeReserveWeth(), 50 ether);
        assertEq(receiver.cumulativeDistributorWeth(), 50 ether);
        assertEq(vault.reserveETH(), 50 ether);
        assertEq(address(vault).balance, 50 ether);
        // gross == reserve + distributor.
        assertEq(receiver.cumulativeReserveWeth() + receiver.cumulativeDistributorWeth(), 100 ether);
    }

    function testZeroReserveShareRoutesAllWethToDistributor() public {
        _bindAndActivate(0);
        weth.mint(address(feeSource), 80 ether);
        feeSource.queue(0, 80 ether);
        vm.prank(governance);
        receiver.harvest();
        assertEq(receiver.distributorClaimable(address(distributor), address(weth)), 80 ether);
        assertEq(receiver.cumulativeReserveWeth(), 0);
        assertEq(receiver.cumulativeDistributorWeth(), 80 ether);
        assertEq(vault.reserveETH(), 0);
    }

    function testSetReserveShareHarvestsAtOldShareFirst() public {
        _bindAndActivate(2_000);
        weth.mint(address(feeSource), 100 ether);
        feeSource.queue(0, 100 ether);

        // Queue is pending; changing the share must harvest at the OLD 2,000 bps first.
        vm.prank(governance);
        receiver.setReserveShareBps(8_000);
        assertEq(receiver.cumulativeReserveWeth(), 20 ether); // old share applied
        assertEq(vault.reserveETH(), 20 ether);
        assertEq(receiver.reserveShareBps(), 8_000);

        // New harvest uses the new 8,000 bps.
        weth.mint(address(feeSource), 100 ether);
        feeSource.queue(0, 100 ether);
        vm.prank(governance);
        receiver.harvest();
        assertEq(receiver.cumulativeReserveWeth(), 20 ether + 80 ether);
    }

    function testFuzzWethSplitConservesGross(uint96 rawGross, uint16 rawShare) public {
        uint256 gross = bound(uint256(rawGross), 1, 1_000_000 ether);
        uint16 share = uint16(bound(uint256(rawShare), 0, 10_000));
        _bindAndActivate(share);
        weth.mint(address(feeSource), gross);
        feeSource.queue(0, gross);
        vm.prank(governance);
        receiver.harvest();
        uint256 expectedReserve = (gross * share) / 10_000;
        assertEq(receiver.cumulativeReserveWeth(), expectedReserve);
        assertEq(receiver.cumulativeDistributorWeth(), gross - expectedReserve);
        assertEq(receiver.cumulativeReserveWeth() + receiver.cumulativeDistributorWeth(), gross);
        assertEq(vault.reserveETH(), expectedReserve);
    }
}
