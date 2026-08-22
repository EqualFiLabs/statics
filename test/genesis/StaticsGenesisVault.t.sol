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
import {
    GenesisPurchaseQuote,
    GenesisRedemptionQuote,
    GenesisVaultAccounting
} from "../../src/interfaces/IStaticsGenesisVault.sol";
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

        contract StaticsGenesisVaultTest is Test {
            uint256 private constant PRICE = 180_000 ether;
            uint256 private constant TREASURY_ALLOCATION = 200_000_000 ether;
            uint256 private constant DOPPLER_INVENTORY = 800_000_000 ether;
            uint256 private constant EPOCH_DURATION = 7 days;

            address private treasury;
            address private governance;
            address private buyer;
            uint256 private epochEnd;
            MockDopplerToken private statics;
            GenesisActivationRegistry private activationRegistry;
            StaticsGenesis private genesis;
            StaticsGenesisVault private vault;

            function setUp() public {
                treasury = makeAddr("treasury");
                governance = makeAddr("governance");
                buyer = makeAddr("buyer");
                epochEnd = block.timestamp + EPOCH_DURATION;

                statics = new MockDopplerToken(address(this));
                activationRegistry = new GenesisActivationRegistry(statics, address(this), governance, treasury);
                vault = new StaticsGenesisVault(statics, address(this), governance, epochEnd);
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
                assertEq(vault.circulatingGenesis(), 0);
                assertEq(vault.requiredBacking(), 0);
                assertEq(vault.tokenBacking(), 0);
                assertEq(vault.reserveETH(), 0);
                assertEq(vault.reserveDenominator(), 5_555);
                assertEq(5_555 * PRICE, 999_900_000 ether);
                assertEq(statics.totalSupply() - 5_555 * PRICE, 100_000 ether);
            }

            function testGenesisEpochAcquisitionCostsExactlyBackingWithNoNative() public {
                assertTrue(vault.epochActive());
                GenesisPurchaseQuote memory quote = vault.quoteGenesisPurchase();
                assertEq(quote.staticsPrice, PRICE);
                assertEq(quote.reserveBuyIn, 0);
                assertEq(quote.nativeFee, 0);
                assertEq(quote.requiredNative, 0);
                assertTrue(quote.epochActive);

                // Reserve accumulates during the epoch but must not change acquisition pricing.
                _donate(10 ether);
                assertEq(vault.reserveETH(), 10 ether);
                assertEq(vault.quoteGenesisPurchase().reserveBuyIn, 0);

                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis(1, buyer);
                assertEq(genesis.ownerOf(1), buyer);
                assertEq(vault.tokenBacking(), PRICE);
                assertEq(vault.reserveETH(), 10 ether); // unchanged by epoch acquisition
                assertEq(buyer.balance, 100 ether); // no native consumed
            }

            function testGenesisEpochRedemptionReturnsOnlyStatics() public {
                _donate(5_555 ether);
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis(1, buyer);

                uint256 reserveBefore = vault.reserveETH();
                uint256 ethBefore = buyer.balance;
                GenesisRedemptionQuote memory quote = vault.quoteGenesisRedemption();
                assertEq(quote.staticsPayout, PRICE);
                assertEq(quote.reservePayout, 0);

                vm.startPrank(buyer);
                genesis.approve(address(vault), 1);
                vault.redeemGenesis(1, buyer);
                vm.stopPrank();

                assertEq(statics.balanceOf(buyer), PRICE);
                assertEq(buyer.balance, ethBefore); // no ETH released during epoch
                assertEq(vault.reserveETH(), reserveBefore); // reserve unchanged during epoch
            }

            function testPostEpochAcquisitionChargesCeilBuyInAndFeeIntoReserve() public {
                _donate(5_554 ether);
                vm.warp(epochEnd);
                assertFalse(vault.epochActive());

                uint256 reserve = vault.reserveETH();
                uint256 expectedBuyIn = _ceilDiv(reserve, 5_554);
                uint256 fee = vault.nativeAcquisitionFee();
                GenesisPurchaseQuote memory quote = vault.quoteGenesisPurchase();
                assertEq(quote.reserveBuyIn, expectedBuyIn);
                assertEq(quote.nativeFee, fee);
                assertEq(quote.requiredNative, expectedBuyIn + fee);

                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis{value: expectedBuyIn + fee}(1, buyer);

                // Both buy-in and fee permanently accrete to the reserve.
                assertEq(vault.reserveETH(), reserve + expectedBuyIn + fee);
                assertEq(address(vault).balance, vault.reserveETH());
            }

            function testPostEpochPurchaseRefundsExcessNative() public {
                _donate(5_554 ether);
                vm.warp(epochEnd);
                uint256 required = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
                _fundAndApproveBuyer(PRICE);
                uint256 ethBefore = buyer.balance;
                vm.prank(buyer);
                vault.buyGenesis{value: required + 3 ether}(1, buyer);
                assertEq(buyer.balance, ethBefore - required); // 3 ether refunded
            }

            function testPostEpochPurchaseRevertsWhenNativeBelowRequired() public {
                _donate(5_554 ether);
                vm.warp(epochEnd);
                uint256 required = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vm.expectRevert(
                    abi.encodeWithSelector(StaticsGenesisVault.InsufficientNative.selector, required - 1, required)
                );
                vault.buyGenesis{value: required - 1}(1, buyer);
            }

            function testPostEpochRedemptionPaysFloorReserveShare() public {
                _donate(5_555 ether);
                _fundAndApproveBuyer(PRICE);
                vm.prank(buyer);
                vault.buyGenesis(1, buyer);
                vm.warp(epochEnd);

                uint256 reserve = vault.reserveETH();
                uint256 expectedPayout = reserve / 5_555;
                assertEq(expectedPayout, 1 ether);
                uint256 ethBefore = buyer.balance;

                vm.startPrank(buyer);
                genesis.approve(address(vault), 1);
                vault.redeemGenesis(1, buyer);
                vm.stopPrank();

                assertEq(statics.balanceOf(buyer), PRICE);
                assertEq(buyer.balance - ethBefore, expectedPayout);
                assertEq(vault.reserveETH(), reserve - expectedPayout);
                assertEq(address(vault).balance, vault.reserveETH());
            }

            function testRedemptionThenReacquisitionRestoresReserveShareIgnoringFee() public {
                _donate(5_555 ether);
                _fundAndApproveBuyer(2 * PRICE);
                vm.prank(buyer);
                vault.buyGenesis(1, buyer);
                vm.warp(epochEnd);

                uint256 reserveStart = vault.reserveETH();
                vm.startPrank(buyer);
                genesis.approve(address(vault), 1);
                vault.redeemGenesis(1, buyer);
                vm.stopPrank();
                uint256 afterRedeem = vault.reserveETH();
                assertEq(afterRedeem, reserveStart - reserveStart / 5_555);

                uint256 buyIn = vault.reserveBuyIn();
                uint256 fee = vault.nativeAcquisitionFee();
                vm.deal(buyer, buyIn + fee);
                vm.prank(buyer);
                vault.buyGenesis{value: buyIn + fee}(1, buyer);
                // Reserve is fully restored (dust stays with reserve) plus the acquisition fee.
                assertGe(vault.reserveETH(), reserveStart);
                assertEq(vault.reserveETH(), afterRedeem + buyIn + fee);
            }

            function testDonateIncrementsReserveExactlyAndForcedEthDoesNot() public {
                _donate(2 ether);
                assertEq(vault.reserveETH(), 2 ether);
                assertEq(address(vault).balance, 2 ether);

                // Forced ETH via selfdestruct does not change reserveETH.
                ForceNative force = new ForceNative{value: 1 ether}(payable(address(vault)));
                force.destroy();
                assertEq(address(vault).balance, 3 ether);
                assertEq(vault.reserveETH(), 2 ether);
            }

            function testDonateRejectsZeroValue() public {
                vm.expectRevert(StaticsGenesisVault.ZeroDonation.selector);
                vault.donate{value: 0}();
            }

            function testGenesisEpochEndIsImmutableAndNoAdminWithdrawal() public {
                assertEq(vault.genesisEpochEnd(), epochEnd);
                // There is no function to withdraw reserveETH; enumerate the governance surface.
                _donate(100 ether);
                vm.startPrank(governance);
                vault.setPurchasesPaused(true);
                vault.setNativeAcquisitionFee(0.005 ether);
                vm.stopPrank();
                assertEq(vault.reserveETH(), 100 ether); // untouched by any governance call
            }

            function testActivationPaysTreasuryAndNeverBurns() public {
                _buyFor(buyer, 1);
                uint256 payCost = 10_000 ether + 20_000 ether + 30_000 ether;
                statics.transfer(buyer, payCost);
                uint256 supplyBefore = statics.totalSupply();
                uint256 treasuryBefore = statics.balanceOf(treasury);
                vm.startPrank(buyer);
                statics.approve(address(activationRegistry), payCost);
                assertEq(activationRegistry.activate(1, 3), payCost);
                vm.stopPrank();

                assertEq(activationRegistry.tierOf(1), 3);
                assertEq(activationRegistry.multiplierBps(1), 12_000);
                assertEq(statics.totalSupply(), supplyBefore); // no burn
                assertEq(statics.balanceOf(treasury) - treasuryBefore, payCost); // 100% to treasury
                assertEq(statics.balanceOf(address(vault)), PRICE); // backing untouched
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

            function testVaultAccountingReportsReserveState() public {
                _buyFor(buyer, 1);
                _donate(11_110 ether);
                GenesisVaultAccounting memory accounting = vault.vaultAccounting();
                assertEq(accounting.maximumSupply, 5_555);
                assertEq(accounting.circulatingGenesis, 1);
                assertEq(accounting.tokenBacking, PRICE);
                assertEq(accounting.requiredBacking, PRICE);
                assertEq(accounting.tokenCustody, PRICE);
                assertEq(accounting.reserveETH, 11_110 ether);
                assertEq(accounting.nativeCustody, 11_110 ether);
                assertEq(accounting.genesisEpochEnd, epochEnd);
                assertTrue(accounting.epochActive);
                assertEq(accounting.reserveBackingPerGenesis, 11_110 ether / 5_555);
                assertEq(vault.reserveBuyIn(), 0); // reserve pricing remains dormant during the epoch

                vm.warp(epochEnd);
                accounting = vault.vaultAccounting();
                assertFalse(accounting.epochActive);
                assertEq(accounting.reserveBackingPerGenesis, 11_110 ether / 5_555);
            }

            function testEpochBoundaryPricingTransition() public {
                _donate(5_554 ether);
                vm.warp(epochEnd - 1);
                assertTrue(vault.epochActive());
                assertEq(vault.reserveBuyIn(), 0);

                vm.warp(epochEnd);
                assertFalse(vault.epochActive());
                assertEq(vault.reserveBuyIn(), _ceilDiv(vault.reserveETH(), 5_554));

                vm.warp(epochEnd + 1);
                assertFalse(vault.epochActive());
            }

            function testMarketplaceInterfacesAndRoyaltyAreDiscoverable() public view {
                assertTrue(genesis.supportsInterface(type(IERC2981).interfaceId));
                assertTrue(genesis.supportsInterface(type(IERC7572).interfaceId));
                assertTrue(genesis.supportsInterface(type(IERC5192).interfaceId));
                assertTrue(genesis.supportsInterface(type(ICreatorToken).interfaceId));
                assertTrue(genesis.supportsInterface(type(ICreatorTokenLegacy).interfaceId));
                (address receiver, uint256 royalty) = genesis.royaltyInfo(1, 100 ether);
                assertEq(receiver, treasury);
                assertEq(royalty, 5 ether);
            }

            function testMetadataReadsPermanentActivationRegistry() public {
                _buyFor(buyer, 1);
                _activateBuyer(1, 1);
                string memory decoded = _decodeDataURI(genesis.tokenURI(1));
                assertTrue(_contains(decoded, '"trait_type":"Activation Tier","value":1'));
                assertTrue(_contains(decoded, "180,000 STATICS"));
                assertTrue(_contains(decoded, '"external_url":"https://statics.finance/genesis/1"'));
            }

            function testFuzzPostEpochBuyInIsCeilOfReserveOverDenominator(uint256 rawReserve) public {
                uint256 reserve = bound(rawReserve, 1, 1_000_000 ether);
                _donate(reserve);
                vm.warp(epochEnd);
                assertEq(vault.reserveBuyIn(), _ceilDiv(reserve, 5_554));
                assertEq(vault.reserveRedemptionPayout(), reserve / 5_555);
            }

            function _buyFor(address owner, uint256 tokenId) private {
                statics.transfer(owner, PRICE);
                vm.deal(owner, 1 ether);
                vm.startPrank(owner);
                statics.approve(address(vault), PRICE);
                vault.buyGenesis(tokenId, owner);
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

            function _donate(uint256 amount) private {
                vm.deal(address(this), address(this).balance + amount);
                vault.donate{value: amount}();
            }

            function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
                return a == 0 ? 0 : (a - 1) / b + 1;
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

        contract ForceNative {
            address payable private immutable target;

            constructor(address payable target_) payable {
                target = target_;
            }

            function destroy() external {
                selfdestruct(target);
            }
        }
