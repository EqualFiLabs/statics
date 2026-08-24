// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ICreatorToken, ICreatorTokenLegacy, ITransferValidator} from "../../src/interfaces/ICreatorToken.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IERC7572} from "../../src/interfaces/IERC7572.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";

contract GenesisMetadataRegistryMock {
    mapping(uint256 tokenId => uint8 tier) public tierOf;

    function setTier(uint256 tokenId, uint8 tier) external {
        tierOf[tokenId] = tier;
    }
}

contract StaticsGenesisRendererHarness is StaticsGenesisRenderer {
    constructor(StaticsAvatarSVG avatarSVG_) StaticsGenesisRenderer(avatarSVG_) {}

    function numericAttribute(string memory traitType, uint256 value, uint256 maxValue)
        external
        pure
        returns (string memory)
    {
        return _numericAttribute(traitType, value, maxValue);
    }
}

contract StaticsGenesisMetadataTest is Test {
    address private constant VAULT = address(0x1001);
    address private constant TREASURY_VESTING = address(0x1002);
    string private constant CONTRACT_URI = "ipfs://statics-genesis-collection";
    string private constant EXTERNAL_URL_BASE = "https://staticsprotocol.com/genesis/";

    GenesisMetadataRegistryMock private registry;
    StaticsGenesisRendererHarness private renderer;
    StaticsGenesis private genesis;

    function setUp() public {
        StaticsAvatarSVG avatar = new StaticsAvatarSVG();
        registry = new GenesisMetadataRegistryMock();
        renderer = new StaticsGenesisRendererHarness(avatar);
        genesis = new StaticsGenesis(
            VAULT,
            TREASURY_VESTING,
            address(registry),
            renderer,
            address(this),
            address(this),
            CONTRACT_URI,
            EXTERNAL_URL_BASE
        );
    }

    function testActivationTierUsesMarketplaceNumericTraitShape() public view {
        assertEq(
            renderer.numericAttribute("Activation Tier", 3, 4),
            '{"display_type":"number","trait_type":"Activation Tier","value":3,"max_value":4}'
        );
    }

    function testActivationTierMetadataChangesAcrossSupportedRange() public {
        string memory tierZeroURI = genesis.tokenURI(1);
        registry.setTier(1, 4);
        string memory tierFourURI = genesis.tokenURI(1);

        assertTrue(_startsWith(tierZeroURI, "data:application/json;base64,"));
        assertTrue(_startsWith(tierFourURI, "data:application/json;base64,"));
        assertNotEq(keccak256(bytes(tierZeroURI)), keccak256(bytes(tierFourURI)));
    }

    function testCollectionMetadataAndMintBoundaries() public view {
        assertEq(genesis.contractURI(), CONTRACT_URI);
        assertEq(genesis.ownerOf(1), VAULT);
        assertEq(genesis.ownerOf(5_000), VAULT);
        assertEq(genesis.ownerOf(5_001), TREASURY_VESTING);
        assertEq(genesis.ownerOf(5_555), TREASURY_VESTING);
        assertEq(genesis.mintedSupply(), 5_555);
    }

    function testMarketplaceInterfacesRemainAdvertised() public view {
        assertTrue(genesis.supportsInterface(type(IERC721).interfaceId));
        assertTrue(genesis.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(genesis.supportsInterface(bytes4(0x49064906)));
        assertTrue(genesis.supportsInterface(type(IERC5192).interfaceId));
        assertTrue(genesis.supportsInterface(type(IERC7572).interfaceId));
        assertTrue(genesis.supportsInterface(type(ICreatorToken).interfaceId));
        assertTrue(genesis.supportsInterface(type(ICreatorTokenLegacy).interfaceId));
    }

    function testDefaultRoyaltyAndTransferValidationDiscovery() public view {
        (address receiver, uint256 royaltyAmount) = genesis.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(this));
        assertEq(royaltyAmount, 0.05 ether);

        (bytes4 selector, bool isViewFunction) = genesis.getTransferValidationFunction();
        assertEq(selector, ITransferValidator.validateTransfer.selector);
        assertTrue(isViewFunction);
    }

    function _startsWith(string memory value, string memory prefix) private pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (valueBytes.length < prefixBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }
}
