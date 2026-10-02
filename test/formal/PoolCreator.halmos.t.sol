// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {LibPermissionedPools} from "../../src/libraries/LibPermissionedPools.sol";
import {LibProtocolRevenue} from "../../src/libraries/LibProtocolRevenue.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Narrow registered-state harness for authority and claim conservation. The ordinary
/// Diamond tests independently exercise real PoolManager creation, swaps, settlement and funding.
contract PoolCreatorHarness is ProtocolRevenueFacet {
    using PoolIdLibrary for PoolKey;
    address public constant CREATOR = address(0xA11CE);
    address public constant NEXT = address(0xB0B);
    address public constant RECIPIENT = address(0xCAFE);
    PoolId public generalId;
    PoolId public permissionedId;
    MockERC20 public token;

    constructor() {
        token = new MockERC20("Reward", "RWD", 18);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0x22)), Currency.wrap(address(token)), 500, 10, IHooks(address(0x44)));
        generalId = key.toId();
        LibProtocolPools.protocolPoolStorage().generalPools[generalId] =
            LibProtocolPools.GeneralPool(key, CREATOR, true);
        key.fee = 3000;
        permissionedId = key.toId();
        LibPermissionedPools.permissionedPoolStorage().pools[permissionedId] =
            LibPermissionedPools.PermissionedPool(key, CREATOR, 0, true, false);
    }

    function seedCredit(uint256 amount) external {
        token.mint(address(this), amount);
        LibCustody.reserve(LibCustody.feeAccount(), address(token), amount);
        LibProtocolRevenue.credit(generalId, address(token), amount);
    }

    function configurationNonce() external view returns (uint256) {
        return LibPermissionedPools.resolve(permissionedId).configurationNonce;
    }

    function reserved() external view returns (uint256) {
        return LibCustody.globalReserved(address(token));
    }
}

contract PoolCreatorHalmosTest is SymTest, Test {
    PoolCreatorHarness private pool;

    function setUp() public {
        pool = new PoolCreatorHarness();
    }

    function testRepresentativeProposalAuthority() public {
        check_onlyCreatorCanPropose(address(0x1234));
    }

    function testRepresentativeAcceptanceAuthority() public {
        check_onlyPendingCreatorCanAccept(address(0x1234));
    }

    function testRepresentativeRecipientAuthority() public {
        check_onlyCreatorCanChangeRecipient(address(0x1234));
    }

    function testRepresentativeFixedRecipientConservation() public {
        check_fixedRecipientClaimConservesCredit(address(0x1234), address(0xCAFE), 500);
    }

    function testRepresentativeTransferRoundTrip() public {
        check_permissionedRoundTripInvalidatesNonceAndRecipient();
    }

    function check_onlyCreatorCanPropose(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool));
        vm.startPrank(caller);
        (bool success,) = address(pool).call(abi.encodeCall(pool.proposePoolCreator, (pool.generalId(), pool.NEXT())));
        vm.stopPrank();
        assertEq(success, caller == pool.CREATOR());
        (address creator, address pending,) = pool.poolCreatorConfiguration(pool.generalId());
        assertEq(creator, pool.CREATOR());
        assertEq(pending, success ? pool.NEXT() : address(0));
    }

    function check_onlyPendingCreatorCanAccept(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool));
        vm.startPrank(pool.CREATOR());
        pool.proposePoolCreator(pool.generalId(), pool.NEXT());
        vm.stopPrank();
        vm.startPrank(caller);
        (bool success,) = address(pool).call(abi.encodeCall(pool.acceptPoolCreator, (pool.generalId())));
        vm.stopPrank();
        assertEq(success, caller == pool.NEXT());
        (address creator, address pending, address recipient) = pool.poolCreatorConfiguration(pool.generalId());
        assertEq(creator, success ? pool.NEXT() : pool.CREATOR());
        assertEq(pending, success ? address(0) : pool.NEXT());
        assertEq(recipient, creator);
    }

    function check_onlyCreatorCanChangeRecipient(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool));
        vm.startPrank(caller);
        (bool success,) =
            address(pool).call(abi.encodeCall(pool.setCreatorRevenueRecipient, (pool.generalId(), pool.RECIPIENT())));
        vm.stopPrank();
        assertEq(success, caller == pool.CREATOR());
        (,, address recipient) = pool.poolCreatorConfiguration(pool.generalId());
        assertEq(recipient, success ? pool.RECIPIENT() : pool.CREATOR());
    }

    function check_fixedRecipientClaimConservesCredit(address caller, address receiver, uint128 amount) public {
        vm.assume(caller != address(0) && caller != address(pool));
        vm.assume(receiver != address(pool));
        vm.assume(amount != 0);
        pool.seedCredit(amount);
        vm.startPrank(pool.CREATOR());
        pool.setCreatorRevenueRecipient(pool.generalId(), pool.RECIPIENT());
        vm.stopPrank();
        vm.startPrank(caller);
        (bool success,) = address(pool)
            .call(abi.encodeCall(pool.claimCreatorRevenue, (pool.generalId(), address(pool.token()), receiver, 0)));
        vm.stopPrank();
        assertEq(success, receiver == pool.RECIPIENT());
        uint256 remaining = success ? 0 : amount;
        assertEq(pool.creatorRevenue(pool.generalId(), address(pool.token())), remaining);
        assertEq(pool.totalCreatorRevenue(address(pool.token())), remaining);
        assertEq(pool.reserved(), remaining);
        assertEq(pool.token().balanceOf(address(pool)), remaining);
        assertEq(pool.token().balanceOf(pool.RECIPIENT()), success ? amount : 0);
    }

    function check_permissionedRoundTripInvalidatesNonceAndRecipient() public {
        PoolId id = pool.permissionedId();
        vm.startPrank(pool.CREATOR());
        pool.setCreatorRevenueRecipient(id, pool.RECIPIENT());
        pool.proposePoolCreator(id, pool.NEXT());
        vm.stopPrank();
        vm.startPrank(pool.NEXT());
        pool.acceptPoolCreator(id);
        pool.proposePoolCreator(id, pool.CREATOR());
        vm.stopPrank();
        vm.prank(pool.CREATOR());
        pool.acceptPoolCreator(id);
        (address creator, address pending, address recipient) = pool.poolCreatorConfiguration(id);
        assertEq(creator, pool.CREATOR());
        assertEq(pending, address(0));
        assertEq(recipient, creator);
        assertEq(pool.configurationNonce(), 2);
    }
}
