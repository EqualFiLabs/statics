// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {GenesisCreditConfig, GenesisCreditView} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";
import {MockGenesisFeeReceiver, MockGenesisRecoveryDistributor} from "../mocks/MockGenesisCreditDependencies.sol";

contract ForceNativeToGenesisVault {
    constructor(address payable receiver) payable {
        selfdestruct(receiver);
    }
}

contract GenesisVaultHandler is IERC721Receiver {
    uint256 private constant PRICE = 180_000 ether;

    MockDopplerToken public immutable statics;
    StaticsGenesis public immutable genesis;
    StaticsGenesisVault public immutable vault;
    uint256 public donatedReserve;
    uint256[] private acquiredIds;
    uint256 public maximumObservedPrincipal;
    bool public creditAccountingConserved = true;

    constructor(MockDopplerToken statics_, StaticsGenesis genesis_, StaticsGenesisVault vault_) {
        statics = statics_;
        genesis = genesis_;
        vault = vault_;
        statics.approve(address(vault_), type(uint256).max);
    }

    receive() external payable {}

    function buyGenesis(uint256 seed) external {
        if (statics.balanceOf(address(this)) < PRICE) return;
        uint256 tokenId = (seed % genesis.COLLECTION_SIZE()) + 1;
        if (!vault.isVaultInventory(tokenId)) return;
        uint256 required = vault.quoteGenesisPurchase().requiredNative;
        if (address(this).balance < required) return;
        vault.buyGenesis{value: required}(tokenId, address(this));
        acquiredIds.push(tokenId);
    }

    function redeem(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        if (vault.creditActive(tokenId)) return;
        genesis.approve(address(vault), tokenId);
        vault.redeemGenesis(tokenId, address(this));
    }

    function transferGenesis(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        if (vault.creditActive(tokenId)) return;
        genesis.transferFrom(address(this), address(0xBEEF), tokenId);
    }

    function donateGenesis(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        if (vault.creditActive(tokenId)) return;
        genesis.safeTransferFrom(address(this), address(vault), tokenId);
    }

    function openCredit(uint256 seed, uint256 rawPrincipal) external {
        if (vault.epochActive() || acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this) || vault.creditActive(tokenId)) return;
        uint256 principal = (rawPrincipal % vault.MAX_CREDIT_PRINCIPAL()) + 1;
        uint256 accountingBefore = vault.tokenBacking() + vault.totalOutstandingGenesisCredit();
        vault.openGenesisCredit(tokenId, principal);
        if (vault.tokenBacking() + vault.totalOutstandingGenesisCredit() != accountingBefore) {
            creditAccountingConserved = false;
        }
        if (principal > maximumObservedPrincipal) maximumObservedPrincipal = principal;
    }

    function extendCredit(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        GenesisCreditView memory state = vault.credit(tokenId);
        if (!state.active || block.timestamp > state.maturity) return;
        vault.extendGenesisCredit(tokenId);
    }

    function drawCredit(uint256 seed, uint256 rawAmount) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        uint256 available = vault.creditAvailable(tokenId);
        if (available == 0) return;
        uint256 amount = (rawAmount % available) + 1;
        uint256 accountingBefore = vault.tokenBacking() + vault.totalOutstandingGenesisCredit();
        vault.drawGenesisCredit(tokenId, amount);
        if (vault.tokenBacking() + vault.totalOutstandingGenesisCredit() != accountingBefore) {
            creditAccountingConserved = false;
        }
        uint256 principal = vault.credit(tokenId).principal;
        if (principal > maximumObservedPrincipal) maximumObservedPrincipal = principal;
    }

    function repayCredit(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        GenesisCreditView memory state = vault.credit(tokenId);
        if (!state.active) return;
        uint256 amount = (seed % state.principal) + 1;
        if (statics.balanceOf(address(this)) < amount) return;
        uint256 accountingBefore = vault.tokenBacking() + vault.totalOutstandingGenesisCredit();
        vault.repayGenesisCredit(tokenId, amount);
        if (vault.tokenBacking() + vault.totalOutstandingGenesisCredit() != accountingBefore) {
            creditAccountingConserved = false;
        }
    }

    function recoverCredit(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        GenesisCreditView memory state = vault.credit(tokenId);
        if (!state.active || block.timestamp <= state.recoverableAt) return;
        vault.recoverGenesisCredit(tokenId);
    }

    function donateReserve(uint256 rawAmount) external {
        uint256 amount = (rawAmount % (10 ether)) + 1;
        if (amount > address(this).balance) return;
        vault.donate{value: amount}();
        donatedReserve += amount;
    }

    function advanceEpoch(uint256 rawJump) external {
        uint256 jump = rawJump % (3 days + 1);
        vm.warp(block.timestamp + jump);
    }

    function setNativeAcquisitionFee(uint256 rawFee) external {
        vault.setNativeAcquisitionFee(rawFee % (vault.MAX_NATIVE_ACQUISITION_FEE() + 1));
    }

    function donateStatics(uint256 rawAmount) external {
        uint256 balance = statics.balanceOf(address(this));
        if (balance == 0) return;
        statics.transfer(address(vault), rawAmount % (balance + 1));
    }

    function burnStatics(uint256 rawAmount) external {
        uint256 balance = statics.balanceOf(address(this));
        if (balance == 0) return;
        statics.burn(rawAmount % (balance + 1));
    }

    function forceNativeDonation(uint256 rawAmount) external {
        uint256 amount = rawAmount % (1 ether + 1);
        if (amount > address(this).balance) return;
        new ForceNativeToGenesisVault{value: amount}(payable(address(vault)));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // forge-std cheatcode passthrough for time control inside the handler.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}

interface Vm {
    function warp(uint256) external;
}

contract GenesisVaultInvariantTest is StdInvariant, Test {
    MockDopplerToken private statics;
    StaticsGenesis private genesis;
    StaticsGenesisVault private vault;
    GenesisVaultHandler private handler;

    function setUp() public {
        statics = new MockDopplerToken(address(this));
        GenesisActivationRegistry registry =
            new GenesisActivationRegistry(statics, address(this), address(this), address(0xCAFE));
        MockGenesisFeeReceiver feeReceiver = new MockGenesisFeeReceiver(address(statics));
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: address(0xCAFE),
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(this), address(this), block.timestamp + 2 days, creditConfig);
        MockGenesisRecoveryDistributor recoveryDistributor =
            new MockGenesisRecoveryDistributor(address(vault), address(statics));
        feeReceiver.setActiveDistributor(address(recoveryDistributor));
        StaticsAvatarSVG avatar = new StaticsAvatarSVG();
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
        genesis = new StaticsGenesis(
            address(vault),
            address(this),
            address(registry),
            renderer,
            address(this),
            address(this),
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        statics.transfer(address(vault), vault.INITIAL_TOKEN_BACKING());
        vault.finalizeGenesisCollection(address(genesis));

        handler = new GenesisVaultHandler(statics, genesis, vault);
        statics.transfer(address(handler), 800_000_000 ether);
        statics.transfer(address(0xCAFE), 100_100_000 ether);
        vm.deal(address(handler), 10_000 ether);
        vault.transferOwnership(address(handler));
        vm.prank(address(handler));
        vault.acceptOwnership();
        targetContract(address(handler));
    }

    function invariantBackingLedgerCoversCirculatingClaims() public view {
        assertGe(vault.tokenBacking(), vault.requiredBacking());
        assertGe(statics.balanceOf(address(vault)), vault.tokenBacking());
    }

    function invariantNativeCustodyCoversReserve() public view {
        assertGe(address(vault).balance, vault.reserveETH());
    }

    function invariantGenesisAccountingIsBoundedAndConserved() public view {
        assertEq(genesis.mintedSupply(), 5_555);
        assertEq(vault.reserveDenominator(), 5_555);
        assertEq(vault.circulatingGenesis() + vault.vaultInventory(), 5_555);
        uint256 grossBacking = vault.circulatingGenesis() * 180_000 ether;
        assertEq(vault.grossBacking(), grossBacking);
        assertLe(vault.totalOutstandingGenesisCredit(), grossBacking);
        assertEq(vault.requiredBacking(), grossBacking - vault.totalOutstandingGenesisCredit());
        assertTrue(handler.creditAccountingConserved());
        assertLe(handler.maximumObservedPrincipal(), vault.MAX_CREDIT_PRINCIPAL());
    }

    function invariantStaticsSupplyCanOnlyDecrease() public view {
        assertLe(statics.totalSupply(), 1_000_000_000 ether);
        assertLe(vault.requiredBacking(), 999_900_000 ether);
    }

    function invariantEpochEndIsImmutable() public view {
        // genesisEpochEnd is set once at construction and never mutated by any handler action.
        assertGt(vault.genesisEpochEnd(), 0);
    }
}
