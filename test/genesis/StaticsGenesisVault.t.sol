// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Test} from "forge-std/Test.sol";
import {ICreatorToken, ICreatorTokenLegacy, ITransferValidator} from "../../src/interfaces/ICreatorToken.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IERC7572} from "../../src/interfaces/IERC7572.sol";
import {GenesisVaultAccounting} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {IStaticsGenesis, IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";

contract MockGenesisProtocol is IStaticsGenesisProtocol {
    address public immutable override genesisCollection;
    mapping(uint256 genesisId => uint8 tier) public override genesisTier;
    mapping(uint256 genesisId => uint256 positionId) public override linkedPosition;
    uint256 public lastTransferredId;
    address public lastFrom;
    address public lastTo;

    constructor(address collection) {
        genesisCollection = collection;
    }

    function setTier(uint256 genesisId, uint8 tier) external {
        genesisTier[genesisId] = tier;
    }

    function link(uint256 genesisId, uint256 positionId) external {
        linkedPosition[genesisId] = positionId;
        IStaticsGenesis(genesisCollection).refreshLockStatus(genesisId);
    }

    function unlink(uint256 genesisId) external {
        delete linkedPosition[genesisId];
        IStaticsGenesis(genesisCollection).refreshLockStatus(genesisId);
    }

    function onGenesisTransfer(uint256 genesisId, address from, address to) external override {
        require(msg.sender == genesisCollection, "ONLY_GENESIS");
        genesisTier[genesisId] = 0;
        lastTransferredId = genesisId;
        lastFrom = from;
        lastTo = to;
    }
}

    contract RevertingTierGenesisProtocol is IStaticsGenesisProtocol {
        address public immutable override genesisCollection;

        constructor(address collection) {
            genesisCollection = collection;
        }

        function genesisTier(uint256) external pure override returns (uint8) {
            revert("TIER_UNAVAILABLE");
        }

        function linkedPosition(uint256) external pure override returns (uint256) {
            return 0;
        }

        function onGenesisTransfer(uint256, address, address) external view override {
            require(msg.sender == genesisCollection, "ONLY_GENESIS");
        }
    }

    contract RevertingLinkGenesisProtocol is IStaticsGenesisProtocol {
        address public immutable override genesisCollection;
        bool public revertLinkRead;

        constructor(address collection) {
            genesisCollection = collection;
        }

        function genesisTier(uint256) external pure override returns (uint8) {
            return 0;
        }

        function setRevertLinkRead(bool shouldRevert) external {
            revertLinkRead = shouldRevert;
        }

        function linkedPosition(uint256) external view override returns (uint256) {
            require(!revertLinkRead, "LINK_UNAVAILABLE");
            return 0;
        }

        function onGenesisTransfer(uint256, address, address) external view override {
            require(msg.sender == genesisCollection, "ONLY_GENESIS");
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

    contract RevertingNativeReceiver {
        receive() external payable {
            revert("NATIVE_REJECTED");
        }

        function claimTo(StaticsGenesisVault vault, address payable receiver) external {
            vault.claimNativeAcquisitionFees(receiver);
        }
    }

    contract StaticsGenesisVaultTest is Test {
        uint256 private constant PRICE = 180_010 ether;
        uint256 private constant NATIVE_FEE = 0.003 ether;
        uint256 private constant FOUNDER_BACKING = 99_905_550 ether;
        uint256 private constant FOUNDER_LIQUID = 90_005_000 ether;
        uint256 private constant LAUNCH_INVENTORY = 810_045_000 ether;

        address private founderTreasury;
        address private governance;
        address private buyer;
        StaticsToken private statics;
        StaticsGenesis private genesis;
        StaticsGenesisVault private vault;

        function setUp() public {
            founderTreasury = makeAddr("founderTreasury");
            governance = makeAddr("governance");
            buyer = makeAddr("buyer");

            statics = new StaticsToken(address(this));
            vault = new StaticsGenesisVault(statics, address(this), governance, founderTreasury);
            StaticsAvatarSVG avatar = new StaticsAvatarSVG();
            StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
            genesis = new StaticsGenesis(
                founderTreasury,
                address(vault),
                renderer,
                address(this),
                "ipfs://statics-genesis/contract.json",
                "https://statics.finance/genesis/"
            );

            statics.transfer(address(vault), FOUNDER_BACKING);
            statics.transfer(founderTreasury, FOUNDER_LIQUID);
            vault.finalizeGenesisCollection(address(genesis));
        }

        function testGenesisDistributionAndSupplyAllocationAreExact() public view {
            assertEq(statics.totalSupply(), 999_955_550 ether);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING);
            assertEq(statics.balanceOf(founderTreasury), FOUNDER_LIQUID);
            assertEq(statics.balanceOf(address(this)), LAUNCH_INVENTORY);

            assertEq(genesis.mintedSupply(), 5_555);
            assertEq(genesis.balanceOf(founderTreasury), 555);
            assertEq(genesis.balanceOf(address(vault)), 5_000);
            assertEq(genesis.ownerOf(1), founderTreasury);
            assertEq(genesis.ownerOf(555), founderTreasury);
            assertEq(genesis.ownerOf(556), address(vault));
            assertEq(genesis.ownerOf(5_555), address(vault));
            assertTrue(genesis.launchFinalized());

            GenesisVaultAccounting memory accounting = vault.vaultAccounting();
            assertEq(accounting.vaultPrice, PRICE);
            assertEq(accounting.maximumSupply, 5_555);
            assertEq(accounting.mintedSupply, 5_555);
            assertEq(accounting.vaultInventory, 5_000);
            assertEq(accounting.circulatingGenesis, 555);
            assertEq(accounting.tokenBacking, FOUNDER_BACKING);
            assertEq(accounting.requiredBacking, FOUNDER_BACKING);
            assertEq(accounting.tokenCustody, FOUNDER_BACKING);
        }

        function testBuyGenesisAddsOneExactBackingUnit() public {
            _fundAndApproveBuyer(PRICE);

            vm.prank(buyer);
            vault.buyGenesis{value: NATIVE_FEE}(1_056, buyer);

            assertEq(genesis.ownerOf(1_056), buyer);
            assertEq(vault.circulatingGenesis(), 556);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING + PRICE);
            assertEq(vault.requiredBacking(), FOUNDER_BACKING + PRICE);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING + PRICE);
        }

        function testGenesisPurchaseRequiresExactConfiguredNativeFee() public {
            (uint256 staticsPrice, uint256 nativeFee) = vault.quoteGenesisPurchase();
            assertEq(staticsPrice, PRICE);
            assertEq(nativeFee, 0.003 ether);
            _fundAndApproveBuyer(PRICE);

            vm.prank(buyer);
            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesisVault.IncorrectNativeFee.selector, 0, nativeFee)
            );
            vault.buyGenesis(1_056, buyer);

            vm.prank(buyer);
            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesisVault.IncorrectNativeFee.selector, nativeFee + 1, nativeFee)
            );
            vault.buyGenesis{value: nativeFee + 1}(1_056, buyer);

            vm.prank(buyer);
            vault.buyGenesis{value: nativeFee}(1_056, buyer);
            assertEq(vault.claimableNativeFees(founderTreasury), nativeFee);
            assertEq(vault.totalNativeFeeLiability(), nativeFee);
            assertEq(address(vault).balance, nativeFee);
        }

        function testNativeFeeCreditsRemainWithRecipientAtPurchaseTime() public {
            uint256 fee = vault.nativeAcquisitionFee();
            address nextRecipient = makeAddr("nextNativeFeeRecipient");
            _fundAndApproveBuyer(2 * PRICE);

            vm.prank(buyer);
            vault.buyGenesis{value: fee}(1_056, buyer);
            vm.prank(governance);
            vault.setNativeFeeRecipient(nextRecipient);
            vm.prank(buyer);
            vault.buyGenesis{value: fee}(1_057, buyer);

            assertEq(vault.claimableNativeFees(founderTreasury), fee);
            assertEq(vault.claimableNativeFees(nextRecipient), fee);
            assertEq(vault.totalNativeFeeLiability(), 2 * fee);

            address payable payout = payable(makeAddr("nativeFeePayout"));
            vm.prank(founderTreasury);
            assertEq(vault.claimNativeAcquisitionFees(payout), fee);
            assertEq(payout.balance, fee);
            assertEq(vault.claimableNativeFees(founderTreasury), 0);
            assertEq(vault.totalNativeFeeLiability(), fee);
        }

        function testRevertingFeeReceiverCannotBlockPurchaseOrLoseClaim() public {
            RevertingNativeReceiver recipient = new RevertingNativeReceiver();
            vm.prank(governance);
            vault.setNativeFeeRecipient(address(recipient));
            uint256 fee = vault.nativeAcquisitionFee();
            _fundAndApproveBuyer(PRICE);

            vm.prank(buyer);
            vault.buyGenesis{value: fee}(1_056, buyer);
            assertEq(genesis.ownerOf(1_056), buyer);
            assertEq(vault.claimableNativeFees(address(recipient)), fee);

            vm.expectRevert(
                abi.encodeWithSelector(
                    StaticsGenesisVault.NativeFeeTransferFailed.selector, address(recipient), fee
                )
            );
            recipient.claimTo(vault, payable(address(recipient)));
            assertEq(vault.claimableNativeFees(address(recipient)), fee);
            assertEq(vault.totalNativeFeeLiability(), fee);

            address payable payout = payable(makeAddr("recoveredPayout"));
            recipient.claimTo(vault, payout);
            assertEq(payout.balance, fee);
            assertEq(vault.totalNativeFeeLiability(), 0);
        }

        function testNativeAcquisitionFeeIsGovernedWithinImmutableCap() public {
            vm.prank(governance);
            vault.setNativeAcquisitionFee(0.01 ether);
            assertEq(vault.nativeAcquisitionFee(), 0.01 ether);

            vm.expectRevert(
                abi.encodeWithSelector(
                    StaticsGenesisVault.NativeFeeExceedsMaximum.selector, 0.01 ether + 1, 0.01 ether
                )
            );
            vm.prank(governance);
            vault.setNativeAcquisitionFee(0.01 ether + 1);

            vm.prank(governance);
            vault.setNativeAcquisitionFee(0);
            assertEq(vault.nativeAcquisitionFee(), 0);
        }

        function testRedeemReturnsExactBackingAndCreatesVaultInventory() public {
            _fundAndApproveBuyer(PRICE);
            vm.startPrank(buyer);
            uint256 tokenId = 1_056;
            vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);
            genesis.approve(address(vault), tokenId);
            vault.redeemGenesis(tokenId, buyer);
            vm.stopPrank();

            assertEq(genesis.ownerOf(tokenId), address(vault));
            assertEq(statics.balanceOf(buyer), PRICE);
            assertEq(vault.circulatingGenesis(), 555);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING);
            assertEq(vault.requiredBacking(), FOUNDER_BACKING);
        }

        function testPurchaseAnyVaultInventoryAndRepurchaseRedeemedToken() public {
            _fundAndApproveBuyer(2 * PRICE);

            vm.startPrank(buyer);
            vault.buyGenesis{value: NATIVE_FEE}(5_555, buyer);
            genesis.approve(address(vault), 5_555);
            vault.redeemGenesis(5_555, buyer);
            statics.approve(address(vault), PRICE);
            vault.buyGenesis{value: NATIVE_FEE}(5_555, buyer);
            vm.stopPrank();

            assertEq(genesis.ownerOf(5_555), buyer);
            assertEq(vault.vaultInventory(), 4_999);
            assertEq(vault.tokenBacking(), vault.requiredBacking());
            assertEq(statics.balanceOf(address(vault)), vault.requiredBacking());
        }

        function testCannotPurchaseGenesisOutsideVaultInventory() public {
            _fundAndApproveBuyer(PRICE);

            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.GenesisNotInVault.selector, 1));
            vault.buyGenesis{value: NATIVE_FEE}(1, buyer);
        }

        function testDirectGenesisDonationCreatesPersistentBackingSurplus() public {
            uint256 tokenId = 1_056;
            _fundAndApproveBuyer(PRICE);

            vm.startPrank(buyer);
            vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);
            genesis.safeTransferFrom(buyer, address(vault), tokenId);
            vm.stopPrank();

            assertEq(vault.requiredBacking(), FOUNDER_BACKING);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING + PRICE);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING + PRICE);

            _fundAndApproveBuyer(PRICE);
            vm.startPrank(buyer);
            vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);
            genesis.approve(address(vault), tokenId);
            vault.redeemGenesis(tokenId, buyer);
            vm.stopPrank();

            assertEq(vault.requiredBacking(), FOUNDER_BACKING);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING + PRICE);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING + PRICE);
        }

        function testPurchasePauseDoesNotBlockRedemption() public {
            _fundAndApproveBuyer(PRICE);
            vm.prank(buyer);
            uint256 tokenId = 1_056;
            vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);

            vm.prank(governance);
            vault.setPurchasesPaused(true);

            vm.prank(buyer);
            vm.expectRevert(StaticsGenesisVault.PurchasesPaused.selector);
            vault.buyGenesis{value: NATIVE_FEE}(1_057, buyer);

            vm.startPrank(buyer);
            genesis.approve(address(vault), tokenId);
            vault.redeemGenesis(tokenId, buyer);
            vm.stopPrank();
            assertEq(genesis.ownerOf(tokenId), address(vault));
        }

        function testTransferInvokesBoundProtocolAndResetsTier() public {
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            protocol.setTier(1, 4);

            address receiver = makeAddr("receiver");
            vm.prank(founderTreasury);
            genesis.transferFrom(founderTreasury, receiver, 1);

            assertEq(genesis.ownerOf(1), receiver);
            assertEq(protocol.genesisTier(1), 0);
            assertEq(protocol.lastTransferredId(), 1);
            assertEq(protocol.lastFrom(), founderTreasury);
            assertEq(protocol.lastTo(), receiver);
            assertEq(genesis.owner(), address(this));
        }

        function testZeroValidatorIsUnrestrictedAndConfiguredValidatorApplies() public {
            assertEq(genesis.getTransferValidator(), address(0));
            assertTrue(genesis.supportsInterface(type(ICreatorToken).interfaceId));
            assertTrue(genesis.supportsInterface(type(ICreatorTokenLegacy).interfaceId));

            MockTransferValidator blockingValidator = new MockTransferValidator(false);
            genesis.setTransferValidator(address(blockingValidator));
            vm.prank(founderTreasury);
            vm.expectRevert("TRANSFER_BLOCKED");
            genesis.transferFrom(founderTreasury, buyer, 1);

            genesis.setTransferValidator(address(0));
            vm.prank(founderTreasury);
            genesis.transferFrom(founderTreasury, buyer, 1);
            assertEq(genesis.ownerOf(1), buyer);
        }

        function testTransferValidatorMustBeZeroOrAContract() public {
            address validatorEOA = makeAddr("validatorEOA");
            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesis.InvalidTransferValidator.selector, validatorEOA)
            );
            genesis.setTransferValidator(validatorEOA);
        }

        function testLinkedGenesisReportsLockedAndMustUnlinkBeforeTransfer() public {
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            assertTrue(genesis.supportsInterface(type(IERC5192).interfaceId));
            assertFalse(genesis.locked(1));

            vm.expectEmit(false, false, false, true, address(genesis));
            emit IERC5192.Locked(1);
            protocol.link(1, 42);
            assertTrue(genesis.locked(1));

            vm.prank(founderTreasury);
            vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
            genesis.transferFrom(founderTreasury, buyer, 1);

            vm.expectEmit(false, false, false, true, address(genesis));
            emit IERC5192.Unlocked(1);
            protocol.unlink(1);
            assertFalse(genesis.locked(1));

            vm.prank(founderTreasury);
            genesis.transferFrom(founderTreasury, buyer, 1);
            assertEq(genesis.ownerOf(1), buyer);
        }

        function testLinkedGenesisMustUnlinkBeforeVaultRedemption() public {
            uint256 tokenId = 1_056;
            _fundAndApproveBuyer(PRICE);
            vm.prank(buyer);
            vault.buyGenesis{value: NATIVE_FEE}(tokenId, buyer);

            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            protocol.link(tokenId, 42);

            vm.startPrank(buyer);
            genesis.approve(address(vault), tokenId);
            vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, tokenId));
            vault.redeemGenesis(tokenId, buyer);
            vm.stopPrank();
            assertEq(genesis.ownerOf(tokenId), buyer);
        }

        function testBoundProtocolLinkReadFailureLocksTransfer() public {
            RevertingLinkGenesisProtocol protocol = new RevertingLinkGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            protocol.setRevertLinkRead(true);
            assertTrue(genesis.locked(1));

            vm.prank(founderTreasury);
            vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
            genesis.transferFrom(founderTreasury, buyer, 1);
        }

        function testGenesisMetadataReflectsBoundProtocolTier() public {
            string memory unactivated = genesis.tokenURI(1);
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            protocol.setTier(1, 4);

            string memory activated = genesis.tokenURI(1);
            assertTrue(bytes(unactivated).length > 100);
            assertTrue(bytes(activated).length > 100);
            assertNotEq(keccak256(bytes(unactivated)), keccak256(bytes(activated)));
        }

        function testGenesisMetadataRemainsAvailableWhenTierReadReverts() public {
            string memory unbound = genesis.tokenURI(1);
            RevertingTierGenesisProtocol protocol = new RevertingTierGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));

            string memory unavailableTier = genesis.tokenURI(1);
            assertTrue(bytes(unavailableTier).length > 100);
            assertEq(keccak256(bytes(unavailableTier)), keccak256(bytes(unbound)));
        }

        function testGenesisPublishesMarketplaceMetadataAndCappedRoyalty() public {
            assertEq(genesis.contractURI(), "ipfs://statics-genesis/contract.json");
            assertTrue(genesis.supportsInterface(type(IERC7572).interfaceId));
            assertTrue(genesis.supportsInterface(type(IERC2981).interfaceId));

            (address receiver, uint256 amount) = genesis.royaltyInfo(1, 1 ether);
            assertEq(receiver, founderTreasury);
            assertEq(amount, 0.05 ether);

            address updatedReceiver = makeAddr("updatedRoyaltyReceiver");
            genesis.setDefaultRoyalty(updatedReceiver, 1_000);
            (receiver, amount) = genesis.royaltyInfo(1, 1 ether);
            assertEq(receiver, updatedReceiver);
            assertEq(amount, 0.1 ether);

            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesis.RoyaltyExceedsMaximum.selector, uint96(1_001), uint96(1_000))
            );
            genesis.setDefaultRoyalty(updatedReceiver, 1_001);
        }

        function testMetadataURLsRemainOwnerConfigurable() public {
            string memory originalTokenURI = genesis.tokenURI(1);
            genesis.setContractURI("ipfs://updated/contract.json");
            genesis.setExternalURLBase("https://app.statics.finance/genesis/");

            assertEq(genesis.contractURI(), "ipfs://updated/contract.json");
            assertEq(genesis.externalURLBase(), "https://app.statics.finance/genesis/");
            assertNotEq(keccak256(bytes(originalTokenURI)), keccak256(bytes(genesis.tokenURI(1))));
        }

        function testProtocolBindingPreservesTwoStepCollectionOwnership() public {
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));
            assertEq(genesis.owner(), address(this));

            address nextOwner = makeAddr("nextOwner");
            genesis.transferOwnership(nextOwner);
            assertEq(genesis.owner(), address(this));
            assertEq(genesis.pendingOwner(), nextOwner);
            vm.prank(nextOwner);
            genesis.acceptOwnership();
            assertEq(genesis.owner(), nextOwner);

            vm.prank(nextOwner);
            vm.expectRevert(StaticsGenesis.OwnershipRenunciationDisabled.selector);
            genesis.renounceOwnership();
        }

        function testProtocolBindingIsOneTimeAndCollectionValidated() public {
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));

            vm.expectRevert(StaticsGenesis.ProtocolAlreadyBound.selector);
            genesis.bindProtocol(address(protocol));
        }

        function testCannotFinalizeWithoutExactFounderDistribution() public {
            StaticsGenesisVault emptyVault =
                new StaticsGenesisVault(statics, address(this), governance, founderTreasury);
            StaticsAvatarSVG avatar = new StaticsAvatarSVG();
            StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
            StaticsGenesis emptyGenesis = new StaticsGenesis(
                founderTreasury,
                address(emptyVault),
                renderer,
                address(this),
                "ipfs://statics-genesis/contract.json",
                "https://statics.finance/genesis/"
            );

            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesisVault.CustodyInsolvent.selector, 0, FOUNDER_BACKING)
            );
            emptyVault.finalizeGenesisCollection(address(emptyGenesis));
        }

        function _fundAndApproveBuyer(uint256 amount) private {
            statics.transfer(buyer, amount);
            vm.deal(buyer, buyer.balance + 1 ether);
            vm.prank(buyer);
            statics.approve(address(vault), amount);
        }
    }
