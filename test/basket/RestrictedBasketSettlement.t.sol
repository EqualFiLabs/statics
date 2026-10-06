// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibRestrictedBasket} from "../../src/libraries/LibRestrictedBasket.sol";
import {StaticsBasketToken} from "../../src/tokens/StaticsBasketToken.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";

contract RestrictedSettlementProtocol {
    bytes32 private constant ACCOUNT = keccak256("statics.test.restricted.custody");

    function deploy(IPoolManager manager) external returns (StaticsRestrictedBasketToken token) {
        token = new StaticsRestrictedBasketToken("Restricted Basket", "RB", address(this), 0, manager);
        LibRestrictedBasket.register(address(token), 0);
    }

    function mint(StaticsBasketToken token, address receiver, uint256 amount) external {
        token.mint(receiver, amount);
    }

    function burn(StaticsBasketToken token, address owner, uint256 amount) external {
        token.burn(owner, amount);
    }

    function authorize(StaticsRestrictedBasketToken token, address from, address to, uint256 amount) external {
        token.authorizeProtocolTransfer(from, to, amount);
    }

    function budgets(StaticsRestrictedBasketToken token, uint256 inbound, uint256 outbound) external {
        token.authorizePoolSettlement(inbound, outbound);
    }

    function claim(StaticsRestrictedBasketToken token, address receiver, uint256 amount) external {
        token.authorizePoolClaim(receiver, amount);
    }

    function configureMorpho(StaticsRestrictedBasketToken token, address morpho) external {
        token.configureMorpho(morpho);
    }

    function morphoIngress(StaticsRestrictedBasketToken token, uint256 amount) external {
        token.authorizeMorphoIngress(amount);
    }

    function approve(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function fund(address token, uint256 amount) external {
        LibCustody.pullAndReserve(ACCOUNT, token, msg.sender, amount);
    }

    function withdraw(address token, address receiver, uint256 amount) external {
        LibCustody.pushReserved(ACCOUNT, token, receiver, amount, amount);
    }

    function reserved(address token) external view returns (uint256) {
        return LibCustody.accountReserved(ACCOUNT, token);
    }

    function isRestricted(address token) external view returns (bool) {
        return LibRestrictedBasket.isRestricted(token);
    }
}

contract RestrictedMorphoBoundary {
    function pull(IERC20 token, address from, uint256 amount) external {
        token.transferFrom(from, address(this), amount);
    }

    function liquidate(IERC20 token, address liquidator, uint256 amount) external {
        token.transfer(liquidator, amount);
    }
}

contract RestrictedBasketSettlementTest is Test, IUnlockCallback {
    RestrictedSettlementProtocol private protocol;
    StaticsRestrictedBasketToken private token;
    IPoolManager private manager;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        protocol = new RestrictedSettlementProtocol();
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        token = protocol.deploy(manager);
        protocol.mint(token, alice, 100 ether);
    }

    function testDirectTransfersAndApprovalsDoNotGrantAuthority() public {
        vm.startPrank(alice);
        token.approve(bob, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsRestrictedBasketToken.TransferNotAuthorized.selector, alice, bob, 1 ether)
        );
        token.transfer(bob, 1 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsRestrictedBasketToken.TransferNotAuthorized.selector, alice, bob, 1 ether)
        );
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, bob), 100 ether);
    }

    function testExactAuthorizationBindsSenderRecipientAmountAndToken() public {
        // Foundry isolates top-level calls as separate transactions. Use one outer call
        // to exercise several attempts against the same transaction-local capability.
        this.checkExactAuthorization();
    }

    function checkExactAuthorization() external {
        protocol.authorize(token, alice, address(protocol), 7 ether);
        vm.startPrank(alice);
        token.approve(address(this), 100 ether);
        vm.expectRevert();
        token.transfer(address(protocol), 6 ether);
        vm.expectRevert();
        token.transfer(bob, 7 ether);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(address(protocol), 7 ether);
        StaticsRestrictedBasketToken other = protocol.deploy(manager);
        protocol.mint(other, alice, 7 ether);
        vm.prank(alice);
        vm.expectRevert();
        other.transfer(address(protocol), 7 ether);
        token.transferFrom(alice, address(protocol), 7 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(protocol), 7 ether);
        assertEq(token.balanceOf(address(protocol)), 7 ether);
    }

    function testOnlyProtocolGrantsAndNoWildcardEndpoints() public {
        this.checkProtocolAuthority();
    }

    function checkProtocolAuthority() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketToken.OnlyProtocol.selector, alice));
        token.authorizeProtocolTransfer(alice, bob, 1 ether);
        vm.expectRevert();
        protocol.authorize(token, alice, bob, 1 ether);
        vm.expectRevert();
        protocol.authorize(token, alice, address(manager), 1 ether);
        protocol.authorize(token, alice, address(protocol), 1 ether);
        vm.expectRevert();
        protocol.authorize(token, alice, address(protocol), 1 ether);
    }

    function testFuzzCustodyRoundTripLeavesNoReusablePermission(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.startPrank(alice);
        token.approve(address(protocol), amount);
        protocol.fund(address(token), amount);
        vm.stopPrank();
        assertEq(protocol.reserved(address(token)), amount);
        protocol.withdraw(address(token), alice, amount);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(protocol.reserved(address(token)), 0);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(protocol), amount);
    }

    function testLegacyTokenRemainsTransferableAndUnregistered() public {
        StaticsBasketToken legacy = new StaticsBasketToken("Legacy", "V1", address(protocol), 1);
        protocol.mint(legacy, alice, 10 ether);
        vm.prank(alice);
        legacy.transfer(bob, 3 ether);
        assertEq(legacy.balanceOf(bob), 3 ether);
        assertFalse(protocol.isRestricted(address(legacy)));
        assertTrue(protocol.isRestricted(address(token)));
    }

    function testMintBurnRequireProtocolWithoutTransferPermissions() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.burn(alice, 1 ether);
        protocol.burn(token, alice, 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
    }

    function testRealPoolManagerClaimsConsumeDirectionalBudgets() public {
        vm.prank(alice);
        token.approve(address(this), 100 ether);
        manager.unlock(abi.encode(uint256(10 ether)));
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        (uint256 inbound, uint256 outbound) = token.settlementBudgets();
        assertEq(inbound, 0);
        assertEq(outbound, 0);
        // A later unlock cannot reuse consumed budgets.
        manager.unlock(abi.encode(uint256(2 ether)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 amount = abi.decode(data, (uint256));
        protocol.budgets(token, amount, 0);
        manager.sync(Currency.wrap(address(token)));
        vm.expectRevert();
        token.transferFrom(alice, address(manager), amount + 1);
        token.transferFrom(alice, address(manager), amount);
        manager.settle();
        // Convert paid credit to a real ERC-6909 claim, then redeem exactly that claim.
        manager.mint(address(this), uint160(address(token)), amount);
        manager.burn(address(this), uint160(address(token)), amount);
        vm.expectRevert();
        manager.take(Currency.wrap(address(token)), alice, amount);
        protocol.claim(token, alice, amount);
        vm.expectRevert();
        manager.take(Currency.wrap(address(token)), bob, amount);
        vm.expectRevert();
        manager.take(Currency.wrap(address(token)), alice, amount - 1);
        manager.take(Currency.wrap(address(token)), alice, amount);
        vm.expectRevert();
        token.transferFrom(alice, address(manager), 1);
        return "";
    }

    function testPoolPermissionsCannotBeGrantedWhileLocked() public {
        vm.expectRevert(StaticsRestrictedBasketToken.PoolManagerLocked.selector);
        protocol.budgets(token, 1, 1);
    }

    function testMorphoIngressExactAndLiquidationIndependentOfDiamond() public {
        this.checkMorphoIngressAndLiquidation();
    }

    function checkMorphoIngressAndLiquidation() external {
        RestrictedMorphoBoundary morpho = new RestrictedMorphoBoundary();
        protocol.configureMorpho(token, address(morpho));
        protocol.mint(token, address(protocol), 10 ether);
        protocol.approve(token, address(morpho), 10 ether);
        vm.expectRevert();
        morpho.pull(token, address(protocol), 10 ether);
        protocol.morphoIngress(token, 10 ether);
        vm.expectRevert();
        morpho.pull(token, address(protocol), 9 ether);
        morpho.pull(token, address(protocol), 10 ether);
        // Removing Diamond code cannot prevent direct liquidator delivery.
        vm.etch(address(protocol), hex"fd");
        morpho.liquidate(token, bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(alice, 1 ether);
    }

    function testDirectMorphoDepositAndAccountBypassBlocked() public {
        RestrictedMorphoBoundary morpho = new RestrictedMorphoBoundary();
        protocol.configureMorpho(token, address(morpho));
        vm.prank(alice);
        token.approve(address(morpho), 100 ether);
        vm.expectRevert();
        morpho.pull(token, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(morpho), 1 ether);
        RestrictedMorphoBoundary otherMorpho = new RestrictedMorphoBoundary();
        vm.expectRevert();
        protocol.configureMorpho(token, address(otherMorpho));
    }

    function testUnusedAuthorizationExpiresAtTransactionBoundary() public {
        // Each call is a separate transaction under the repository's isolated runner.
        protocol.authorize(token, alice, address(protocol), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(protocol), 1 ether);
    }

    function testPermitChangesAllowanceButDoesNotAuthorizeTransfer() public {
        uint256 key = 1234567;
        address signer = vm.addr(key);
        protocol.mint(token, signer, 10 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(this),
                        10 ether,
                        0,
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        token.permit(signer, address(this), 10 ether, deadline, v, r, s);
        vm.expectRevert();
        token.transferFrom(signer, bob, 10 ether);
        assertEq(token.allowance(signer, address(this)), 10 ether);
    }
}
