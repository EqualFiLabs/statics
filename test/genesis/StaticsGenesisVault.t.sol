// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Test} from "forge-std/Test.sol";
import {ICreatorToken, ICreatorTokenLegacy, ITransferValidator} from "../../src/interfaces/ICreatorToken.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IERC7572} from "../../src/interfaces/IERC7572.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {IStaticsGenesis, IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {GenesisVaultAccounting} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../mocks/MockDopplerToken.sol";

contract MockGenesisProtocol is IStaticsGenesisProtocol {
    address public immutable override genesisCollection;
    mapping(uint256 genesisId => uint256 positionId) public override linkedPosition;

    constructor(address collection) {
        genesisCollection = collection;
    }

    function link(uint256 genesisId, uint256 positionId) external {
        linkedPosition[genesisId] = positionId;
        IStaticsGenesis(genesisCollection).refreshLockStatus(genesisId);
    }

    function unlink(uint256 genesisId) external {
        delete linkedPosition[genesisId];
        IStaticsGenesis(genesisCollection).refreshLockStatus(genesisId);
    }
}

    contract RevertingLinkGenesisProtocol is IStaticsGenesisProtocol {
        address public immutable override genesisCollection;
        bool public revertLinkRead;

        constructor(address collection) {
            genesisCollection = collection;
        }

        function setRevertLinkRead(bool shouldRevert) external {
            revertLinkRead = shouldRevert;
        }

        function linkedPosition(uint256) external view override returns (uint256) {
            require(!revertLinkRead, "LINK_UNAVAILABLE");
            return 0;
        }
    }

        contract MockTransferValidator is ITransferValidator {
            bool public immutable allowed;

            constructor(bool allowed_) {
                allowed = allowed_;
            }

            function validateTransfer(address, address, address, uint256) external view override {
                require(allowed, "TRANSFER_BLOCKED");
            }
        }

        contract PrevalidatingTransferValidator is ITransferValidator {
            function validateTransfer(address caller, address, address, uint256) external view override {
                require(caller != address(this), "REVALIDATED_TRANSFER");
            }

            function transferAsValidator(StaticsGenesis genesis, address from, address to, uint256 tokenId) external {
                genesis.transferFrom(from, to, tokenId);
            }
        }

        contract RevertingNativeReceiver {
            receive() external payable {
                revert("NATIVE_REJECTED");
            }

            function claimTo(StaticsGenesisVault vault, address payable receiver) external {
                vault.claimNativeAcquisitionFees(receiver);
            }
        }

        contract StaticsGenesisVaultTest is Test {
            uint256 private constant PRICE = 180_018 ether;
            uint256 private constant NATIVE_FEE = 0.003 ether;
            uint256 private constant TREASURY_ALLOCATION = 200_000_000 ether;
            uint256 private constant DOPPLER_INVENTORY = 800_000_000 ether;

            address private treasury;
            address private governance;
            address private buyer;
            MockDopplerToken private statics;
            GenesisActivationRegistry private activationRegistry;
            StaticsGenesis private genesis;
            StaticsGenesisVault private vault;

            function setUp() public {
                treasury = makeAddr("treasury");
                governance = makeAddr("governance");
                buyer = makeAddr("buyer");

                statics = new MockDopplerToken(address(this));
                activationRegistry = new GenesisActivationRegistry(statics, address(this), governance);
                vault = new StaticsGenesisVault(statics, address(this), governance, treasury);
                StaticsAvatarSVG avatar = new StaticsAvatarSVG();
                StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
                genesis = new StaticsGenesis(
                    address(vault),
                    address(activationRegistry),
                    renderer,
                    governance,
                    treasury,
                    "ipfs://statics-genesis/contract.json",
                    "https://statics.finance/genesis/"
                );
                activationRegistry.bindGenesisCollection(address(genesis));
                vault.finalizeGenesisCollection(address(genesis));
                statics.transfer(treasury, TREASURY_ALLOCATION);
            }

            function testFullCollectionStartsAsUnbackedVaultInventory() public view {
                assertEq(statics.totalSupply(), 1_000_000_000 ether);
                assertEq(statics.balanceOf(treasury), TREASURY_ALLOCATION);
                assertEq(statics.balanceOf(address(this)), DOPPLER_INVENTORY);
                assertEq(statics.balanceOf(address(vault)), 0);
                assertEq(genesis.mintedSupply(), 5_555);
                assertEq(genesis.balanceOf(address(vault)), 5_555);
                assertEq(genesis.ownerOf(1), address(vault));
                assertEq(genesis.ownerOf(5_555), address(vault));
                assertEq(vault.circulatingGenesis(), 0);
                assertEq(vault.requiredBacking(), 0);
                assertEq(vault.tokenBacking(), 0);
                assertEq(5_555 * PRICE, 999_999_990 ether);
                assertEq(statics.totalSupply() - 5_555 * PRICE, 10 ether);
            }

            function testBuyAndRedeemMoveOneExactBackingUnit() public {
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(1, buyer);

                assertEq(genesis.ownerOf(1), buyer);
                assertEq(vault.circulatingGenesis(), 1);
                assertEq(vault.tokenBacking(), PRICE);
                assertEq(vault.requiredBacking(), PRICE);
                assertEq(statics.balanceOf(address(vault)), PRICE);

                vm.startPrank(buyer);
                genesis.approve(address(vault), 1);
                vault.redeemGenesis(1, buyer);
                vm.stopPrank();

                assertEq(genesis.ownerOf(1), address(vault));
                assertEq(statics.balanceOf(buyer), PRICE);
                assertEq(vault.tokenBacking(), 0);
                assertEq(vault.requiredBacking(), 0);
            }

            function testFuzzBuyRedeemPreservesBacking(uint256 rawTokenId) public {
                uint256 tokenId = bound(rawTokenId, 1, 5_555);
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);
                assertEq(vault.tokenBacking(), PRICE);
                assertEq(vault.requiredBacking(), PRICE);

                vm.startPrank(buyer);
                genesis.approve(address(vault), tokenId);
                vault.redeemGenesis(tokenId, buyer);
                vm.stopPrank();
                assertEq(vault.tokenBacking(), 0);
                assertEq(vault.requiredBacking(), 0);
                assertEq(statics.balanceOf(address(vault)), 0);
            }

            function testDirectGenesisDonationCreatesBackingSurplus() public {
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(1, buyer);
                vm.prank(buyer);
                genesis.safeTransferFrom(buyer, address(vault), 1);
                assertEq(vault.requiredBacking(), 0);
                assertEq(vault.tokenBacking(), PRICE);
                assertEq(statics.balanceOf(address(vault)), PRICE);

                address nextBuyer = makeAddr("nextBuyer");
                statics.transfer(nextBuyer, PRICE);
                vm.deal(nextBuyer, 1 ether);
                vm.startPrank(nextBuyer);
                statics.approve(address(vault), PRICE);
                vault.buyGenesis{value: NATIVE_FEE}(1, nextBuyer);
                genesis.approve(address(vault), 1);
                vault.redeemGenesis(1, nextBuyer);
                vm.stopPrank();
                assertEq(vault.requiredBacking(), 0);
                assertEq(vault.tokenBacking(), PRICE);
                assertEq(statics.balanceOf(address(vault)), PRICE);
            }

            function testActivationCanCrossMultipleTiersAndBurnsCumulativeCost() public {
                _buyFor(buyer, 1);
                uint256 burnCost = 10_000 ether + 20_000 ether + 30_000 ether;
                statics.transfer(buyer, burnCost);
                uint256 supplyBefore = statics.totalSupply();
                vm.startPrank(buyer);
                statics.approve(address(activationRegistry), burnCost);
                assertEq(activationRegistry.activate(1, 3), burnCost);
                vm.stopPrank();

                assertEq(activationRegistry.tierOf(1), 3);
                assertEq(activationRegistry.multiplierBps(1), 12_000);
                assertEq(statics.totalSupply(), supplyBefore - burnCost);
                assertEq(statics.balanceOf(address(vault)), PRICE);
                assertEq(vault.requiredBacking(), PRICE);
            }

            function testOwnerChangingTransferResetsActivationButSelfTransferDoesNot() public {
                _buyFor(buyer, 1);
                _activateBuyer(1, 2);
                vm.prank(buyer);
                genesis.transferFrom(buyer, buyer, 1);
                assertEq(activationRegistry.tierOf(1), 2);

                address nextOwner = makeAddr("nextOwner");
                vm.prank(buyer);
                genesis.transferFrom(buyer, nextOwner, 1);
                assertEq(genesis.ownerOf(1), nextOwner);
                assertEq(activationRegistry.tierOf(1), 0);
                assertEq(activationRegistry.multiplierBps(1), 10_000);
            }

            function testTierCostsAreBoundedAndOnlyAffectFutureActivation() public {
                _buyFor(buyer, 1);
                _activateBuyer(1, 1);
                vm.prank(governance);
                activationRegistry.setTierCost(2, 5_000 ether);
                assertEq(activationRegistry.tierOf(1), 1);
                assertEq(activationRegistry.tierCost(2), 5_000 ether);

                vm.prank(governance);
                vm.expectRevert();
                activationRegistry.setTierCost(2, 999 ether);
            }

            function testNativeFeeIsPullBasedAndRecipientRotationPreservesLiability() public {
                _fundAndApproveBuyer(2 * PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(1, buyer);
                address nextRecipient = makeAddr("nextRecipient");
                vm.prank(governance);
                vault.setNativeFeeRecipient(nextRecipient);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(2, buyer);

                assertEq(vault.claimableNativeFees(treasury), NATIVE_FEE);
                assertEq(vault.claimableNativeFees(nextRecipient), NATIVE_FEE);
                assertEq(vault.totalNativeFeeLiability(), 2 * NATIVE_FEE);
            }

            function testRevertingNativeRecipientCannotBlockPurchase() public {
                RevertingNativeReceiver recipient = new RevertingNativeReceiver();
                vm.prank(governance);
                vault.setNativeFeeRecipient(address(recipient));
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: NATIVE_FEE}(1, buyer);
                assertEq(genesis.ownerOf(1), buyer);
                assertEq(vault.claimableNativeFees(address(recipient)), NATIVE_FEE);

                vm.expectRevert();
                recipient.claimTo(vault, payable(address(recipient)));
                address payable safeReceiver = payable(makeAddr("safeReceiver"));
                recipient.claimTo(vault, safeReceiver);
                assertEq(safeReceiver.balance, NATIVE_FEE);
            }

            function testMarketplaceInterfacesAndRoyaltyAreDiscoverable() public view {
                assertTrue(genesis.supportsInterface(type(IERC2981).interfaceId));
                assertTrue(genesis.supportsInterface(type(IERC7572).interfaceId));
                assertTrue(genesis.supportsInterface(type(IERC5192).interfaceId));
                assertTrue(genesis.supportsInterface(type(ICreatorToken).interfaceId));
                assertTrue(genesis.supportsInterface(type(ICreatorTokenLegacy).interfaceId));
                assertTrue(genesis.supportsInterface(0x49064906));
                (address receiver, uint256 royalty) = genesis.royaltyInfo(1, 100 ether);
                assertEq(receiver, treasury);
                assertEq(royalty, 5 ether);
                assertEq(genesis.getTransferValidator(), address(0));
                assertFalse(genesis.locked(1));
            }

            function testTransferValidatorCanBeEnabledWithoutBypassingAuthorization() public {
                _buyFor(buyer, 1);
                PrevalidatingTransferValidator validator = new PrevalidatingTransferValidator();
                vm.prank(governance);
                genesis.setTransferValidator(address(validator));
                address nextOwner = makeAddr("nextOwner");

                vm.expectRevert();
                validator.transferAsValidator(genesis, buyer, nextOwner, 1);
                vm.prank(buyer);
                genesis.setApprovalForAll(address(validator), true);
                validator.transferAsValidator(genesis, buyer, nextOwner, 1);
                assertEq(genesis.ownerOf(1), nextOwner);
            }

            function testLinkedGenesisIsLockedUntilUnlinked() public {
                _buyFor(buyer, 1);
                MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
                vm.prank(governance);
                genesis.bindProtocol(address(protocol));
                protocol.link(1, 77);
                assertTrue(genesis.locked(1));
                vm.prank(buyer);
                vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
                genesis.transferFrom(buyer, makeAddr("nextOwner"), 1);
                protocol.unlink(1);
                vm.prank(buyer);
                genesis.transferFrom(buyer, makeAddr("nextOwner"), 1);
            }

            function testLinkReadFailureLocksFailClosed() public {
                _buyFor(buyer, 1);
                RevertingLinkGenesisProtocol protocol = new RevertingLinkGenesisProtocol(address(genesis));
                vm.prank(governance);
                genesis.bindProtocol(address(protocol));
                protocol.setRevertLinkRead(true);
                assertTrue(genesis.locked(1));
            }

            function testMetadataReadsPermanentActivationRegistry() public {
                _buyFor(buyer, 1);
                _activateBuyer(1, 1);
                string memory decoded = _decodeDataURI(genesis.tokenURI(1));
                assertTrue(
                    _contains(
                        decoded, '"description":"A fixed-supply Statics Genesis NFT redeemable for 180,018 STATICS."'
                    )
                );
                assertTrue(_contains(decoded, '"trait_type":"Activation Tier","value":1'));
                assertTrue(_contains(decoded, '"external_url":"https://statics.finance/genesis/1"'));
            }

            function testVaultAccountingReportsCurrentState() public {
                _buyFor(buyer, 1);
                GenesisVaultAccounting memory accounting = vault.vaultAccounting();
                assertEq(accounting.maximumSupply, 5_555);
                assertEq(accounting.mintedSupply, 5_555);
                assertEq(accounting.vaultInventory, 5_554);
                assertEq(accounting.circulatingGenesis, 1);
                assertEq(accounting.tokenBacking, PRICE);
                assertEq(accounting.requiredBacking, PRICE);
                assertEq(accounting.tokenCustody, PRICE);
            }

            function _buyFor(address owner, uint256 tokenId) private {
                statics.transfer(owner, PRICE);
                vm.deal(owner, 1 ether);
                vm.startPrank(owner);
                statics.approve(address(vault), PRICE);
                vault.buyGenesis{value: NATIVE_FEE}(tokenId, owner);
                vm.stopPrank();
            }

            function _activateBuyer(uint256 tokenId, uint8 tier) private {
                uint256 cost;
                for (uint8 current = 1; current <= tier; ++current) {
                    cost += activationRegistry.tierCost(current);
                }
                statics.transfer(buyer, cost);
                vm.startPrank(buyer);
                statics.approve(address(activationRegistry), cost);
                activationRegistry.activate(tokenId, tier);
                vm.stopPrank();
            }

            function _fundAndApproveBuyer(uint256 amount) private {
                statics.transfer(buyer, amount);
                vm.deal(buyer, 100 ether);
                vm.prank(buyer);
                statics.approve(address(vault), amount);
            }

            function _decodeDataURI(string memory uri) private pure returns (string memory) {
                bytes memory raw = bytes(uri);
                bytes memory prefix = bytes("data:application/json;base64,");
                bytes memory encoded = new bytes(raw.length - prefix.length);
                for (uint256 i; i < encoded.length; ++i) {
                    encoded[i] = raw[i + prefix.length];
                }
                return string(_decodeBase64(string(encoded)));
            }

            function _decodeBase64(string memory data) private pure returns (bytes memory result) {
                bytes memory input = bytes(data);
                if (input.length == 0) return bytes("");
                string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                bytes memory tableBytes = bytes(table);
                uint256 decodedLength = (input.length / 4) * 3;
                if (input[input.length - 1] == bytes1("=")) --decodedLength;
                if (input[input.length - 2] == bytes1("=")) --decodedLength;
                result = new bytes(decodedLength);
                uint256 outputIndex;
                for (uint256 i; i < input.length; i += 4) {
                    uint256 accumulator = (_base64Index(tableBytes, input[i]) << 18)
                        | (_base64Index(tableBytes, input[i + 1]) << 12) | (_base64Index(tableBytes, input[i + 2]) << 6)
                        | _base64Index(tableBytes, input[i + 3]);
                    if (outputIndex < decodedLength) result[outputIndex++] = bytes1(uint8(accumulator >> 16));
                    if (outputIndex < decodedLength) result[outputIndex++] = bytes1(uint8(accumulator >> 8));
                    if (outputIndex < decodedLength) result[outputIndex++] = bytes1(uint8(accumulator));
                }
            }

            function _base64Index(bytes memory table, bytes1 value) private pure returns (uint256) {
                if (value == bytes1("=")) return 0;
                for (uint256 i; i < table.length; ++i) {
                    if (table[i] == value) return i;
                }
                revert("INVALID_BASE64");
            }

            function _contains(string memory haystack, string memory needle) private pure returns (bool) {
                bytes memory haystackBytes = bytes(haystack);
                bytes memory needleBytes = bytes(needle);
                if (needleBytes.length > haystackBytes.length) return false;
                for (uint256 i; i <= haystackBytes.length - needleBytes.length; ++i) {
                    bool match_ = true;
                    for (uint256 j; j < needleBytes.length; ++j) {
                        if (haystackBytes[i + j] != needleBytes[j]) {
                            match_ = false;
                            break;
                        }
                    }
                    if (match_) return true;
                }
                return false;
            }
        }
