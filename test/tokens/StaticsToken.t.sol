// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

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
        token = new StaticsToken(holder);
    }

    function testInitialDistributionUsesStaticsIdentity() public view {
        assertEq(token.name(), "Statics");
        assertEq(token.symbol(), "STATICS");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(holder), token.totalSupply());
        assertEq(token.FIXED_SUPPLY(), 1_000_000_000 ether);
    }

    function testBurnAndBurnFromOnlyReduceSupply() public {
        vm.prank(holder);
        token.burn(100 ether);

        vm.prank(holder);
        token.approve(spender, 50 ether);
        vm.prank(spender);
        token.burnFrom(holder, 50 ether);

        assertEq(token.totalSupply(), 1_000_000_000 ether - 150 ether);
        assertEq(token.balanceOf(holder), token.totalSupply());
    }

    function testRevertWhenTreasuryIsZero() public {
        vm.expectRevert(StaticsToken.InvalidTreasury.selector);
        new StaticsToken(address(0));
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
