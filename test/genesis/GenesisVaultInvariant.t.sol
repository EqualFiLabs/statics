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
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";

contract GenesisNativeFeeActor {
    StaticsGenesisVault public immutable vault;

    constructor(StaticsGenesisVault vault_) {
        vault = vault_;
    }

    receive() external payable {}

    function claim() external {
        if (vault.claimableNativeFees(address(this)) != 0) {
            vault.claimNativeAcquisitionFees(payable(address(this)));
        }
    }
}

contract ForceNativeToGenesisVault {
    constructor(address payable receiver) payable {
        selfdestruct(receiver);
    }
}

contract GenesisVaultHandler is IERC721Receiver {
    uint256 private constant PRICE = 180_018 ether;

    MockDopplerToken public immutable statics;
    StaticsGenesis public immutable genesis;
    StaticsGenesisVault public immutable vault;
    GenesisNativeFeeActor public immutable alternateFeeRecipient;
    uint256[] private acquiredIds;

    constructor(MockDopplerToken statics_, StaticsGenesis genesis_, StaticsGenesisVault vault_) {
        statics = statics_;
        genesis = genesis_;
        vault = vault_;
        alternateFeeRecipient = new GenesisNativeFeeActor(vault_);
        statics.approve(address(vault_), type(uint256).max);
    }

    receive() external payable {}

    function buyGenesis(uint256 seed) external {
        if (statics.balanceOf(address(this)) < PRICE) return;
        uint256 tokenId = (seed % genesis.COLLECTION_SIZE()) + 1;
        if (!vault.isVaultInventory(tokenId)) return;
        vault.buyGenesis{value: vault.nativeAcquisitionFee()}(tokenId, address(this));
        acquiredIds.push(tokenId);
    }

    function redeem(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        genesis.approve(address(vault), tokenId);
        vault.redeemGenesis(tokenId, address(this));
    }

    function transferGenesis(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        genesis.transferFrom(address(this), address(0xBEEF), tokenId);
    }

    function donateGenesis(uint256 seed) external {
        if (acquiredIds.length == 0) return;
        uint256 tokenId = acquiredIds[seed % acquiredIds.length];
        if (genesis.ownerOf(tokenId) != address(this)) return;
        genesis.safeTransferFrom(address(this), address(vault), tokenId);
    }

    function setNativeAcquisitionFee(uint256 rawFee) external {
        vault.setNativeAcquisitionFee(rawFee % (vault.MAX_NATIVE_ACQUISITION_FEE() + 1));
    }

    function rotateNativeFeeRecipient(bool alternate) external {
        vault.setNativeFeeRecipient(alternate ? address(alternateFeeRecipient) : address(this));
    }

    function claimNativeFees() external {
        if (vault.claimableNativeFees(address(this)) != 0) {
            vault.claimNativeAcquisitionFees(payable(address(this)));
        }
        alternateFeeRecipient.claim();
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
}

contract GenesisVaultInvariantTest is StdInvariant, Test {
    MockDopplerToken private statics;
    StaticsGenesis private genesis;
    StaticsGenesisVault private vault;
    GenesisVaultHandler private handler;

    function setUp() public {
        statics = new MockDopplerToken(address(this));
        GenesisActivationRegistry registry = new GenesisActivationRegistry(statics, address(this), address(this));
        vault = new StaticsGenesisVault(statics, address(this), address(this), address(this));
        StaticsAvatarSVG avatar = new StaticsAvatarSVG();
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
        genesis = new StaticsGenesis(
            address(vault),
            address(registry),
            renderer,
            address(this),
            address(this),
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));

        handler = new GenesisVaultHandler(statics, genesis, vault);
        statics.transfer(address(handler), 800_000_000 ether);
        statics.transfer(address(0xCAFE), 200_000_000 ether);
        vm.deal(address(handler), 10_000 ether);
        vault.setNativeFeeRecipient(address(handler));
        vault.transferOwnership(address(handler));
        vm.prank(address(handler));
        vault.acceptOwnership();
        targetContract(address(handler));
    }

    function invariantBackingLedgerCoversCirculatingClaims() public view {
        assertGe(vault.tokenBacking(), vault.requiredBacking());
        assertGe(statics.balanceOf(address(vault)), vault.tokenBacking());
        assertGe(address(vault).balance, vault.totalNativeFeeLiability());
        assertEq(
            vault.totalNativeFeeLiability(),
            vault.claimableNativeFees(address(handler))
                + vault.claimableNativeFees(address(handler.alternateFeeRecipient()))
        );
    }

    function invariantGenesisAccountingIsBoundedAndConserved() public view {
        assertEq(genesis.mintedSupply(), 5_555);
        assertEq(vault.circulatingGenesis() + vault.vaultInventory(), 5_555);
        assertEq(vault.requiredBacking(), vault.circulatingGenesis() * 180_018 ether);
    }

    function invariantStaticsSupplyCanOnlyDecrease() public view {
        assertLe(statics.totalSupply(), 1_000_000_000 ether);
        assertLe(vault.requiredBacking(), 999_999_990 ether);
    }
}
