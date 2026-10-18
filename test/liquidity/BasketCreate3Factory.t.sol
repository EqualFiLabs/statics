// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StaticsBasketTokenFactory, PinnedCreateX} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {StaticsBasketToken} from "../../src/tokens/StaticsBasketToken.sol";

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
        tokenSalt = factory.preparedSaltFor(CREATOR, keccak256("creation configuration"), 0);
    }

    function testCreate3IdentityBindsConstructorAuthorityAndRejectsReplay() public {
        (address predicted,) = factory.predict(tokenSalt);
        address token = factory.deployBasketToken(tokenSalt, "Static Basket", "B", 987);
        assertEq(token, predicted);
        assertEq(StaticsBasketToken(token).protocol(), address(this));
        assertEq(StaticsBasketToken(token).basketId(), 987);
        assertEq(address(StaticsBasketToken(token).poolManager()), address(manager));
        assertFalse(factory.saltAvailable(tokenSalt));
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketTokenFactory.SaltUnavailable.selector, tokenSalt));
        factory.deployBasketToken(tokenSalt, "Different", "D", 1);
    }

    function testAutomaticDeploymentsUseDistinctDeterministicSalts() public {
        tokenSalt = factory.automaticSaltFor(0);
        (address predicted,) = factory.predict(tokenSalt);
        assertEq(factory.deployNextBasketToken("Automatic", "A", 8), predicted);
        assertEq(factory.nextAutomaticNonce(), 1);
        bytes32 next = factory.automaticSaltFor(1);
        (address nextPredicted,) = factory.predict(next);
        assertEq(factory.deployNextBasketToken("Next", "N", 9), nextPredicted);
        assertNotEq(predicted, nextPredicted);
        assertEq(factory.nextAutomaticNonce(), 2);
    }

    function testInvalidSaltAndOccupiedProxyCannotDeploy() public {
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketTokenFactory.InvalidSalt.selector, bytes32(uint256(1))));
        factory.deployBasketToken(bytes32(uint256(1)), "B", "B", 1);
        (, address proxy) = factory.predict(tokenSalt);
        vm.etch(proxy, hex"00");
        assertFalse(factory.saltAvailable(tokenSalt));
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketTokenFactory.SaltUnavailable.selector, tokenSalt));
        factory.deployBasketToken(tokenSalt, "B", "B", 1);
    }

    function testPreparedSaltBindsCreatorConfigurationChainAndDiamondCaller() public {
        bytes32 configuration = keccak256("creation configuration");
        assertNotEq(tokenSalt, factory.preparedSaltFor(address(0xBEEF), configuration, 0));
        assertNotEq(tokenSalt, factory.preparedSaltFor(CREATOR, keccak256("changed configuration"), 0));
        (address originalAddress,) = factory.predict(tokenSalt);
        vm.chainId(block.chainid + 1);
        (address otherChainAddress,) = factory.predict(tokenSalt);
        assertNotEq(originalAddress, otherChainAddress);
        vm.startPrank(CREATOR);
        vm.expectRevert(StaticsBasketTokenFactory.OnlyDiamond.selector);
        factory.deployBasketToken(tokenSalt, "B", "B", 1);
        vm.expectRevert(StaticsBasketTokenFactory.OnlyDiamond.selector);
        factory.deployNextBasketToken("B", "B", 1);
        vm.stopPrank();
    }

    function testCallerProtectedCreateXSaltCannotBeSquatted() public {
        (address predicted, address proxy) = factory.predict(tokenSalt);
        vm.prank(CREATOR);
        address outsider = PinnedCreateX(factory.CREATE_X()).deployCreate3(tokenSalt, hex"6001600c60003960016000f300");
        assertNotEq(outsider, predicted);
        assertEq(proxy.code.length, 0);
        assertEq(factory.deployBasketToken(tokenSalt, "B", "B", 10), predicted);
    }

    function testEmbeddedCreationCodeAndFactoryRetainSizeHeadroom() public view {
        assertEq(factory.tokenCreationCodeHash(), keccak256(type(StaticsBasketToken).creationCode));
        assertLt(address(factory).code.length, 24_577);
        assertLt(type(StaticsBasketTokenFactory).creationCode.length + 64, 49_153);
    }

    function testAutomaticDeploymentFailureDoesNotConsumeNonce() public {
        (, address proxy) = factory.predict(factory.automaticSaltFor(0));
        vm.etch(proxy, hex"00");
        vm.expectRevert();
        factory.deployNextBasketToken("B", "B", 1);
        assertEq(factory.nextAutomaticNonce(), 0);
    }

    function testPinnedCreateXRuntimeRequired() public {
        vm.etch(factory.CREATE_X(), hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketTokenFactory.UnsupportedCreateX.selector, factory.CREATE_X().codehash)
        );
        new StaticsBasketTokenFactory(address(this), manager);
    }
}
