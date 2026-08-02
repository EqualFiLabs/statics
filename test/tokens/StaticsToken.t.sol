// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";

contract StaticsTokenTest is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 private holderKey;
    address private holder;
    address private spender;
    StaticsToken private token;

    function setUp() public {
        (holder, holderKey) = makeAddrAndKey("holder");
        spender = makeAddr("spender");
        token = new StaticsToken(holder, 1_000_000_000 ether);
    }

    function testInitialDistributionUsesStaticsIdentity() public view {
        assertEq(token.name(), "Statics");
        assertEq(token.symbol(), "STATICS");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(holder), token.totalSupply());
        assertEq(token.owner(), holder);
    }

    function testOwnerMintsWithoutConfiguredCap() public {
        address recipient = makeAddr("recipient");
        uint256 firstMint = type(uint128).max;
        uint256 secondMint = type(uint128).max;

        vm.startPrank(holder);
        token.mint(recipient, firstMint);
        token.mint(recipient, secondMint);
        vm.stopPrank();

        assertEq(token.balanceOf(recipient), firstMint + secondMint);
        assertEq(token.totalSupply(), 1_000_000_000 ether + firstMint + secondMint);
    }

    function testNonOwnerCannotMint() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.mint(stranger, 1 ether);
    }

    function testTransferredOwnershipMovesMintAuthority() public {
        address nextOwner = makeAddr("nextOwner");
        vm.prank(holder);
        token.transferOwnership(nextOwner);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        token.mint(holder, 1 ether);

        vm.prank(nextOwner);
        token.mint(nextOwner, 1 ether);
        assertEq(token.balanceOf(nextOwner), 1 ether);
    }

    function testPermitAuthorizesStakingAllowance() public {
        uint256 amount = 25_000 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, amount, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderKey, digest);

        token.permit(holder, spender, amount, deadline, v, r, s);

        assertEq(token.allowance(holder, spender), amount);
        assertEq(token.nonces(holder), 1);
    }
}
