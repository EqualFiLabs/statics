// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisVaultAccounting} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";

contract MockGenesisProtocol is IStaticsGenesisProtocol {
    address public immutable override genesisCollection;
    mapping(uint256 genesisId => uint8 tier) public override genesisTier;
    uint256 public lastTransferredId;
    address public lastFrom;
    address public lastTo;

    constructor(address collection) {
        genesisCollection = collection;
    }

    function setTier(uint256 genesisId, uint8 tier) external {
        genesisTier[genesisId] = tier;
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

        function onGenesisTransfer(uint256, address, address) external view override {
            require(msg.sender == genesisCollection, "ONLY_GENESIS");
        }
    }

    contract StaticsGenesisVaultTest is Test {
        uint256 private constant PRICE = 180_010 ether;
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
            genesis = new StaticsGenesis(founderTreasury, address(vault), renderer, address(this));

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
            vault.buyGenesis(1_056, buyer);

            assertEq(genesis.ownerOf(1_056), buyer);
            assertEq(vault.circulatingGenesis(), 556);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING + PRICE);
            assertEq(vault.requiredBacking(), FOUNDER_BACKING + PRICE);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING + PRICE);
        }

        function testRedeemReturnsExactBackingAndCreatesVaultInventory() public {
            _fundAndApproveBuyer(PRICE);
            vm.startPrank(buyer);
            uint256 tokenId = 1_056;
            vault.buyGenesis(tokenId, buyer);
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
            vault.buyGenesis(5_555, buyer);
            genesis.approve(address(vault), 5_555);
            vault.redeemGenesis(5_555, buyer);
            statics.approve(address(vault), PRICE);
            vault.buyGenesis(5_555, buyer);
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
            vault.buyGenesis(1, buyer);
        }

        function testDirectGenesisDonationCreatesPersistentBackingSurplus() public {
            uint256 tokenId = 1_056;
            _fundAndApproveBuyer(PRICE);

            vm.startPrank(buyer);
            vault.buyGenesis(tokenId, buyer);
            genesis.safeTransferFrom(buyer, address(vault), tokenId);
            vm.stopPrank();

            assertEq(vault.requiredBacking(), FOUNDER_BACKING);
            assertEq(vault.tokenBacking(), FOUNDER_BACKING + PRICE);
            assertEq(statics.balanceOf(address(vault)), FOUNDER_BACKING + PRICE);

            _fundAndApproveBuyer(PRICE);
            vm.startPrank(buyer);
            vault.buyGenesis(tokenId, buyer);
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
            vault.buyGenesis(tokenId, buyer);

            vm.prank(governance);
            vault.setPurchasesPaused(true);

            vm.prank(buyer);
            vm.expectRevert(StaticsGenesisVault.PurchasesPaused.selector);
            vault.buyGenesis(1_057, buyer);

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
            assertEq(genesis.owner(), address(0));
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

        function testProtocolBindingIsOneTimeAndCollectionValidated() public {
            MockGenesisProtocol protocol = new MockGenesisProtocol(address(genesis));
            genesis.bindProtocol(address(protocol));

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
            genesis.bindProtocol(address(protocol));
        }

        function testCannotFinalizeWithoutExactFounderDistribution() public {
            StaticsGenesisVault emptyVault =
                new StaticsGenesisVault(statics, address(this), governance, founderTreasury);
            StaticsAvatarSVG avatar = new StaticsAvatarSVG();
            StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(avatar);
            StaticsGenesis emptyGenesis = new StaticsGenesis(
                founderTreasury, address(emptyVault), renderer, address(this)
            );

            vm.expectRevert(
                abi.encodeWithSelector(StaticsGenesisVault.CustodyInsolvent.selector, 0, FOUNDER_BACKING)
            );
            emptyVault.finalizeGenesisCollection(address(emptyGenesis));
        }

        function _fundAndApproveBuyer(uint256 amount) private {
            statics.transfer(buyer, amount);
            vm.prank(buyer);
            statics.approve(address(vault), amount);
        }
    }
