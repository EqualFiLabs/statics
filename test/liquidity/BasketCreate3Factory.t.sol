// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StaticsBasketTokenFactory, PinnedCreateX} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";

contract BasketCreate3FactoryTest is Test {
    StaticsBasketTokenFactory private factory;
    IPoolManager private manager;
    bytes32 private tokenSalt;
    address private constant CREATOR = address(0xCAFE);

    function setUp() public {
        vm.etch(
            0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed,
            vm.parseJsonBytes(vm.readFile("test/fixtures/createx-v1.json"), ".runtime")
        );
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        factory = new StaticsBasketTokenFactory(address(this), manager);
        assertEq(factory.CREATE_X().codehash, factory.CREATE_X_CODE_HASH());
        tokenSalt = factory.preparedSaltFor(_intent(), 0);
    }

    function testCreate3IdentityBindsConstructorAuthority() public {
        (address predicted,) = factory.predict(tokenSalt);
        bytes32 id = factory.reserve(_intent(), 0);
        address token = factory.deployBasketToken(id, "Static Basket", "B", 987);
        assertEq(token, predicted);
        assertEq(StaticsRestrictedBasketToken(token).protocol(), address(this));
        assertEq(StaticsRestrictedBasketToken(token).basketId(), 987);
        assertEq(address(StaticsRestrictedBasketToken(token).poolManager()), address(manager));
        assertEq(uint256(factory.saltState(tokenSalt)), uint256(StaticsBasketTokenFactory.SaltState.Consumed));
        vm.expectRevert(StaticsBasketTokenFactory.InvalidDeploymentOrder.selector);
        factory.deployBasketToken(id, "Different", "D", 1);
    }

    function testAutomaticReservationsUseDistinctDeterministicSalts() public {
        tokenSalt = factory.automaticSaltFor(0);
        bytes32 id = factory.reserveNext(_intent());
        assertEq(id, factory.preparationId(_intent(), tokenSalt));
        assertEq(factory.nextAutomaticNonce(), 1);
        bytes32 next = factory.automaticSaltFor(1);
        bytes32 nextId = factory.reserveNext(_intent());
        assertEq(nextId, factory.preparationId(_intent(), next));
        assertNotEq(tokenSalt, next);
        (address predicted,) = factory.predict(tokenSalt);
        assertEq(factory.deployBasketToken(id, "Automatic", "A", 8), predicted);
    }

    function testSaltValidationDeduplicationAndOccupiedProxy() public {
        bytes32 raw = factory.preparedSaltFor(_intent(), 7);
        factory.reserve(_intent(), 7);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketTokenFactory.SaltUnavailable.selector, raw));
        factory.reserve(_intent(), 7);

        vm.expectRevert(abi.encodeWithSelector(StaticsBasketTokenFactory.InvalidSalt.selector, bytes32(uint256(1))));
        factory.effectiveSalt(bytes32(uint256(1)));

        bytes32 unreserved = factory.preparedSaltFor(_intent(), 8);
        (, address proxy) = factory.predict(unreserved);
        vm.etch(proxy, hex"00");
        assertFalse(factory.saltAvailable(unreserved));
    }

    function testReservationBindsFullIntentChainAndDiamondCaller() public {
        StaticsBasketTokenFactory.Intent memory intent = _intent();
        bytes32 original = factory.preparationId(intent, tokenSalt);
        intent.creator = address(0xBEEF);
        assertNotEq(original, factory.preparationId(intent, tokenSalt));
        intent = _intent();
        intent.configurationHash = bytes32(uint256(2));
        assertNotEq(original, factory.preparationId(intent, tokenSalt));
        (address originalAddress,) = factory.predict(tokenSalt);
        vm.chainId(block.chainid + 1);
        (address otherChainAddress,) = factory.predict(tokenSalt);
        assertNotEq(originalAddress, otherChainAddress);
        vm.prank(CREATOR);
        vm.expectRevert(StaticsBasketTokenFactory.OnlyDiamond.selector);
        factory.reserve(_intent(), 0);
    }

    function testCallerProtectedCreateXSaltCannotBeSquatted() public {
        (address predicted, address proxy) = factory.predict(tokenSalt);
        vm.prank(CREATOR);
        address outsider = PinnedCreateX(factory.CREATE_X()).deployCreate3(tokenSalt, hex"6001600c60003960016000f300");
        assertNotEq(outsider, predicted);
        assertEq(proxy.code.length, 0);
        bytes32 id = factory.reserve(_intent(), 0);
        assertEq(factory.deployBasketToken(id, "B", "B", 10), predicted);
    }

    function testExpiryCodeStoreAndCreationHeadroom() public {
        bytes32 id = factory.reserve(_intent(), 0);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(StaticsBasketTokenFactory.PreparationExpired.selector);
        factory.deployBasketToken(id, "B", "B", 1);
        assertLt(address(factory).code.length, 24_577);
        assertLt(factory.tokenCodeStore().code.length, 24_577);
        assertLt(type(StaticsBasketTokenFactory).creationCode.length + 64, 49_153);
    }

    function testPinnedCreateXRuntimeRequired() public {
        vm.etch(factory.CREATE_X(), hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketTokenFactory.UnsupportedCreateX.selector, factory.CREATE_X().codehash)
        );
        new StaticsBasketTokenFactory(address(this), manager);
    }

    function _intent() private view returns (StaticsBasketTokenFactory.Intent memory) {
        return StaticsBasketTokenFactory.Intent(
            address(this), CREATOR, keccak256("complete creation configuration"), block.timestamp + 1 days, 1
        );
    }
}
