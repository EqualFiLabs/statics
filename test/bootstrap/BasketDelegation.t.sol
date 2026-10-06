// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketDelegation} from "../../src/interfaces/IStaticsBasketDelegation.sol";
import {LibBasketDelegation} from "../../src/libraries/LibBasketDelegation.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {BasketCreationFacet} from "../../src/facets/BasketCreationFacet.sol";
import {PreparedBasketTestBase} from "../liquidity/PreparedBasketCreation.t.sol";

contract CreationContractSigner {
    address private immutable signer;

    constructor(address owner) {
        signer = owner;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract BasketDelegationTest is PreparedBasketTestBase {
    uint256 private constant CREATOR_KEY = 0xC0FFEE;
    IStaticsBasketDelegation private delegated;

    struct Launch {
        IStaticsBasket.CreateBasketParams params;
        IStaticsBasket.PoolLaunchParams[] pools;
        uint256[] maximums;
        uint256[] hookNonces;
        IStaticsBasketDelegation.Authorization authorization;
        bytes signature;
        address token;
        uint256 nativeFee;
    }

    function setUp() public override {
        super.setUp();
        delegated = IStaticsBasketDelegation(address(diamond));
    }

    function _launch(address creator) private returns (Launch memory launch) {
        launch.params = _defaultParams(0, 0);
        launch.nativeFee = basketAdmin.creationFee();
        (launch.pools, launch.maximums) = _fundDefaultLaunch(launch.params.assets, alice);
        uint256 deadline = block.timestamp + 7 days;
        bytes32 configuration =
            preparation.basketCreationConfigurationHash(launch.params, launch.pools, launch.maximums, deadline);
        StaticsBasketFactory.Intent memory intent =
            StaticsBasketFactory.Intent(alice, creator, configuration, deadline, 1);
        bytes32 salt = factory.preparedSaltFor(intent, 0);
        bytes32[] memory salts = new bytes32[](launch.pools.length);
        launch.hookNonces = new uint256[](salts.length);
        uint256 start;
        for (uint256 i; i < salts.length; ++i) {
            (launch.hookNonces[i], salts[i]) = _minePreparedTestHook(factory, intent, start);
            start = launch.hookNonces[i] + 1;
        }
        launch.authorization = IStaticsBasketDelegation.Authorization(
            creator, alice, factory.preparationId(intent, salt, salts), configuration, 513, deadline, 1 ether
        );
        (launch.token,) = factory.predict(salt);
        launch.signature = _sign(launch.authorization);
    }

    function _sign(IStaticsBasketDelegation.Authorization memory authorization) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CREATOR_KEY, delegated.creationAuthorizationDigest(authorization));
        return abi.encodePacked(r, s, v);
    }

    function _prepare(Launch memory launch) private {
        vm.prank(alice);
        delegated.prepareBasketCreationFor(
            launch.params, launch.pools, launch.maximums, 0, launch.hookNonces, launch.authorization, launch.signature
        );
    }

    function _execute(Launch memory launch) private returns (uint256 basketId, address token) {
        vm.prank(alice);
        return delegated.createBasketFor{value: launch.nativeFee}(
            launch.params, launch.pools, launch.maximums, launch.authorization, launch.signature
        );
    }

    function testDelegatedEoaLaunchPreservesCreatorAndConsumesUnorderedNonceOnce() public {
        Launch memory launch = _launch(vm.addr(CREATOR_KEY));
        _prepare(launch);
        (uint256 basketId, address token) = _execute(launch);
        assertEq(token, launch.token);
        assertEq(baskets.basket(basketId).creator, launch.authorization.creator);
        assertEq(IERC20(token).balanceOf(alice), 0);
        assertGt(IERC20(token).balanceOf(address(poolManager)), 0);
        assertTrue(delegated.creationNonceUsed(launch.authorization.creator, 513));
        vm.expectRevert(LibBasketDelegation.CreationNonceAlreadyUsed.selector);
        _execute(launch);
    }

    function testContractCreatorAuthorizationUsesErc1271() public {
        Launch memory launch = _launch(address(new CreationContractSigner(vm.addr(CREATOR_KEY))));
        _prepare(launch);
        (uint256 basketId,) = _execute(launch);
        assertEq(baskets.basket(basketId).creator, launch.authorization.creator);
    }

    function testWrongPayerConfigurationSignatureAndExpiredAuthorizationReject() public {
        Launch memory launch = _launch(vm.addr(CREATOR_KEY));
        vm.prank(bob);
        vm.expectRevert(LibBasketDelegation.InvalidCreationAuthorization.selector);
        delegated.prepareBasketCreationFor(
            launch.params, launch.pools, launch.maximums, 0, launch.hookNonces, launch.authorization, launch.signature
        );
        _prepare(launch);
        launch.params.bundleAmounts[0]++;
        vm.expectRevert(LibBasketDelegation.InvalidCreationAuthorization.selector);
        _execute(launch);
        launch.params.bundleAmounts[0]--;
        launch.signature[0] ^= bytes1(uint8(1));
        vm.expectRevert(LibBasketDelegation.InvalidCreationAuthorization.selector);
        _execute(launch);
        launch.signature = _sign(launch.authorization);
        vm.warp(launch.authorization.deadline);
        vm.expectRevert(LibBasketDelegation.InvalidCreationAuthorization.selector);
        _execute(launch);
        assertFalse(delegated.creationNonceUsed(launch.authorization.creator, 513));
    }

    function testNonceCancellationAndFailedLaunchRollback() public {
        Launch memory launch = _launch(vm.addr(CREATOR_KEY));
        _prepare(launch);
        vm.prank(alice);
        IERC20(launch.params.assets[0]).approve(address(diamond), 0);
        vm.expectRevert();
        _execute(launch);
        assertFalse(delegated.creationNonceUsed(launch.authorization.creator, 513));
        vm.prank(launch.authorization.creator);
        delegated.invalidateCreationNonces(2, 2);
        assertTrue(delegated.creationNonceUsed(launch.authorization.creator, 513));
        vm.expectRevert(LibBasketDelegation.CreationNonceAlreadyUsed.selector);
        _execute(launch);
    }

    function testNativeFeeBoundAndClosedCreationPolicyCannotBeBypassed() public {
        Launch memory launch = _launch(vm.addr(CREATOR_KEY));
        launch.authorization.maxNativeFee = 0;
        launch.signature = _sign(launch.authorization);
        vm.expectRevert(LibBasketDelegation.InvalidCreationAuthorization.selector);
        _prepare(launch);
        basketAdmin.setCreationFee(0);
        launch = _launch(vm.addr(CREATOR_KEY));
        _prepare(launch);
        vm.expectRevert(BasketCreationFacet.PermissionlessBasketCreationDisabled.selector);
        _execute(launch);
        assertFalse(delegated.creationNonceUsed(launch.authorization.creator, 513));
    }
}
