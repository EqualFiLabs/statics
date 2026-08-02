// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarRiskShares} from "src/dollar/interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "src/dollar/interfaces/IStaticsDollar.sol";

contract StaticsDollarTokensTest is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;

    address internal pool = makeAddr("pool");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");

    function setUp() public {
        staticsDollar = new StaticsDollar(pool);
        staticsDollarRisk = new StaticsDollarRiskShares(pool, "ipfs://risk/{id}.json");
    }

    function test_TokenMetadataAndImmutableAuthorityMatchSpec() public view {
        assertEq(staticsDollar.name(), "Statics Dollar");
        assertEq(staticsDollar.symbol(), "etUSD");
        assertEq(staticsDollar.decimals(), 18);
        assertEq(staticsDollar.pool(), pool);
        assertEq(staticsDollarRisk.name(), "Statics Dollar Risk Shares");
        assertEq(staticsDollarRisk.symbol(), "ETRISK");
        assertEq(staticsDollarRisk.pool(), pool);
        assertEq(staticsDollarRisk.uri(1), "ipfs://risk/{id}.json");
    }

    function test_RevertWhen_PoolIsZero() public {
        vm.expectRevert(IStaticsDollar.ZeroAddress.selector);
        new StaticsDollar(address(0));

        vm.expectRevert(IStaticsDollarRiskShares.ZeroAddress.selector);
        new StaticsDollarRiskShares(address(0), "");
    }

    function test_PoolReplacementAndTokenOwnershipSelectorsDoNotExist() public {
        bytes4[8] memory removed = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pendingPool()")),
            bytes4(keccak256("burnOnlyPool(address)")),
            bytes4(keccak256("queuePoolChange(address)")),
            bytes4(keccak256("executePoolChange()")),
            bytes4(keccak256("cancelPoolChange()")),
            bytes4(keccak256("lockPoolChanges()")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i; i < removed.length; ++i) {
            (bool staticsDollarOk,) = address(staticsDollar).call(abi.encodeWithSelector(removed[i], address(this)));
            (bool staticsDollarRiskOk,) =
                address(staticsDollarRisk).call(abi.encodeWithSelector(removed[i], address(this)));
            assertFalse(staticsDollarOk);
            assertFalse(staticsDollarRiskOk);
        }
    }

    function test_RevertWhen_UnauthorizedMintOrBurn() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollar.NotMinter.selector, alice));
        staticsDollar.mint(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollar.NotBurner.selector, alice));
        staticsDollar.burn(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollarRiskShares.NotPool.selector, alice));
        staticsDollarRisk.mint(alice, 1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollarRiskShares.NotPool.selector, alice));
        staticsDollarRisk.burn(alice, 1, 1 ether);
        vm.stopPrank();
    }

    function test_PoolMintBurnAndBatchAuthoritySucceed() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 100 ether;
        amounts[1] = 50 ether;

        vm.startPrank(pool);
        staticsDollar.mint(alice, 100 ether);
        staticsDollar.burn(alice, 40 ether);
        staticsDollarRisk.batchMint(alice, ids, amounts);
        amounts[0] = 40 ether;
        amounts[1] = 10 ether;
        staticsDollarRisk.batchBurn(alice, ids, amounts);
        vm.stopPrank();

        assertEq(staticsDollar.balanceOf(alice), 60 ether);
        assertEq(staticsDollar.totalSupply(), 60 ether);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), 60 ether);
        assertEq(staticsDollarRisk.balanceOf(alice, 2), 40 ether);
    }

    function test_PermitAllowsRelayedTransferFrom() public {
        uint256 ownerKey = 0xa11ce;
        address owner = vm.addr(ownerKey);
        uint256 permitted = 2 ether;
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(pool);
        staticsDollar.mint(owner, 5 ether);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, permitted, deadline);

        vm.prank(operator);
        IStaticsDollar(address(staticsDollar)).permit(owner, bob, permitted, deadline, v, r, s);
        vm.prank(bob);
        staticsDollar.transferFrom(owner, alice, 1.25 ether);

        assertEq(staticsDollar.nonces(owner), 1);
        assertEq(staticsDollar.allowance(owner, bob), 0.75 ether);
        assertEq(staticsDollar.balanceOf(owner), 3.75 ether);
        assertEq(staticsDollar.balanceOf(alice), 1.25 ether);
    }

    function test_RevertWhen_PermitSignatureIsReplayed() public {
        uint256 ownerKey = 0xa11ce;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, 1 ether, deadline);

        staticsDollar.permit(owner, bob, 1 ether, deadline, v, r, s);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        staticsDollar.permit(owner, bob, 1 ether, deadline, v, r, s);

        assertEq(staticsDollar.nonces(owner), 1);
        assertEq(staticsDollar.allowance(owner, bob), 1 ether);
    }

    function test_RevertWhen_PermitIsExpired() public {
        uint256 ownerKey = 0xa11ce;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, 1 ether, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        staticsDollar.permit(owner, bob, 1 ether, deadline, v, r, s);

        assertEq(staticsDollar.nonces(owner), 0);
        assertEq(staticsDollar.allowance(owner, bob), 0);
    }

    function test_RevertWhen_PermitUsesAnotherTokenDomain() public {
        uint256 ownerKey = 0xa11ce;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        StaticsDollar otherDollar = new StaticsDollar(pool);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, bob, 1 ether, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", otherDollar.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        staticsDollar.permit(owner, bob, 1 ether, deadline, v, r, s);

        assertEq(staticsDollar.nonces(owner), 0);
        assertEq(staticsDollar.allowance(owner, bob), 0);
    }

    function test_TransfersRemainUnrestricted() public {
        vm.startPrank(pool);
        staticsDollar.mint(alice, 100 ether);
        staticsDollarRisk.mint(alice, 1, 100 ether);
        vm.stopPrank();

        vm.prank(alice);
        staticsDollar.transfer(bob, 30 ether);
        vm.prank(alice);
        staticsDollarRisk.safeTransferFrom(alice, bob, 1, 30 ether, "");
        vm.prank(alice);
        staticsDollarRisk.setApprovalForAll(operator, true);
        vm.prank(operator);
        staticsDollarRisk.safeTransferFrom(alice, bob, 1, 20 ether, "");

        assertEq(staticsDollar.balanceOf(alice), 70 ether);
        assertEq(staticsDollar.balanceOf(bob), 30 ether);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), 50 ether);
        assertEq(staticsDollarRisk.balanceOf(bob, 1), 50 ether);
    }

    function test_RevertWhen_StaticsDollarTransferExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        staticsDollar.transfer(bob, 1);
    }

    function _signPermit(uint256 ownerKey, address owner, address spender, uint256 value, uint256 deadline)
        private
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, staticsDollar.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", staticsDollar.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(ownerKey, digest);
    }
}
