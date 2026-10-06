// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BasketFactoryTestTools} from "../helpers/BasketFactoryTestTools.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketFactory, PinnedCreateX} from "../../src/liquidity/StaticsBasketFactory.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";

contract Create3FeePolicy {
    address public immutable staticsDiamond;

    constructor(address diamond) {
        staticsDiamond = diamond;
    }
}

contract BasketCreate3FactoryTest is BasketFactoryTestTools {
    using PoolIdLibrary for PoolKey;
    StaticsBasketFactory private factory;
    IPoolManager private manager;
    bytes32 private tokenSalt;
    bytes32[] private hookSalts;
    uint256[] private hookNonces;
    address private constant CREATOR = address(0xCAFE);

    function setUp() public {
        // Executable, pinned upstream runtime, not a CREATE3 approximation or mock.
        string memory fixture = vm.readFile("test/fixtures/createx-v1.json");
        vm.etch(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, vm.parseJsonBytes(fixture, ".runtime"));
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        factory = new StaticsBasketFactory(
            address(this), manager, IStaticsSwapFeeHook(address(new Create3FeePolicy(address(this))))
        );
        assertEq(factory.CREATE_X().codehash, factory.CREATE_X_CODE_HASH());
        tokenSalt = factory.preparedSaltFor(_intent(), 0);
        (uint256 nonce, bytes32 salt) = _minePreparedTestHook(factory, _intent(), 1);
        hookSalts.push(salt);
        hookNonces.push(nonce);
    }

    function testCreate3IdentityIgnoresBasketIdAndBindsActualConstructorAuthority() public {
        (address predicted,) = factory.predict(tokenSalt);
        bytes32 id = factory.reserve(_intent(), 0, hookNonces);
        uint256 beforeGas = gasleft();
        address token = factory.deployBasketToken(id, "Static Basket", "B", 987);
        emit log_named_uint("CREATE3 restricted token deployment gas", beforeGas - gasleft());
        assertEq(token, predicted);
        assertEq(StaticsRestrictedBasketToken(token).protocol(), address(this));
        assertEq(StaticsRestrictedBasketToken(token).basketId(), 987);
        assertEq(address(StaticsRestrictedBasketToken(token).poolManager()), address(manager));
        assertEq(StaticsRestrictedBasketToken(token).name(), "Static Basket");
        assertEq(uint256(factory.saltState(tokenSalt)), uint256(StaticsBasketFactory.SaltState.Consumed));
        vm.expectRevert(StaticsBasketFactory.InvalidDeploymentOrder.selector);
        factory.deployBasketToken(id, "Different", "D", 1);
        vm.prank(CREATOR);
        vm.expectRevert();
        StaticsRestrictedBasketToken(token).mint(CREATOR, 1);
    }

    function testCreate3HookUsesPreminedPermissionBitsAndImmutableConstructorBinding() public {
        bytes32 id = factory.reserve(_intent(), 0, hookNonces);
        address token = factory.deployBasketToken(id, "Basket", "B", 0);
        StaticsBasketHook.Binding memory binding = _binding(token);
        (address predicted,) = factory.predict(hookSalts[0]);
        uint256 beforeGas = gasleft();
        address deployed = factory.deployBasketHook(id, binding);
        emit log_named_uint("CREATE3 basket hook deployment gas", beforeGas - gasleft());
        StaticsBasketHook hook = StaticsBasketHook(deployed);
        assertEq(deployed, predicted);
        assertEq(uint160(deployed) & ((1 << 14) - 1), factory.HOOK_PERMISSION_MASK());
        assertEq(hook.staticsDiamond(), address(this));
        assertEq(hook.boundCreator(), CREATOR);
        assertEq(hook.version(), 1);
        PoolKey memory key =
            PoolKey(binding.currency0, binding.currency1, binding.lpFee, binding.tickSpacing, IHooks(deployed));
        assertEq(PoolId.unwrap(hook.boundPoolId()), PoolId.unwrap(key.toId()));
        assertEq(uint256(hook.poolRegistration(key.toId()).kind), uint256(IStaticsSwapFeeHook.PoolKind.BasketCanonical));
        assertLt(deployed.code.length, 24_577);
        vm.expectRevert(StaticsBasketFactory.InvalidDeploymentOrder.selector);
        factory.deployBasketHook(id, binding);
    }

    function testQueuedCreationConsumesAtomicallyAndFailsClearlyWhenDepleted() public {
        tokenSalt = factory.saltFor(0);
        hookSalts[0] = _mine(1);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = tokenSalt;
        vm.prank(CREATOR);
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(hookSalts, true);
        (uint256 tokenCount, uint256 hookCount) = factory.queueAvailability();
        assertEq(tokenCount, 1);
        assertEq(hookCount, 1);
        assertEq(factory.queuedSalt(false, 0), tokenSalt);
        assertEq(factory.queuedSalt(true, 0), hookSalts[0]);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, true));
        factory.queuedSalt(true, 1);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, true));
        factory.reserveQueued(_intent(), 2);
        (tokenCount, hookCount) = factory.queueAvailability();
        assertEq(tokenCount, 1); // Entire failed reservation rolls back.
        assertEq(hookCount, 1);
        bytes32 id = factory.reserveQueued(_intent(), 1);
        assertEq(id, factory.preparationId(_intent(), tokenSalt, hookSalts));
        (tokenCount, hookCount) = factory.queueAvailability();
        assertEq(tokenCount + hookCount, 0);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, false));
        factory.queuedSalt(false, 0);
        address token = factory.deployBasketToken(id, "Queued", "Q", 8);
        factory.deployBasketHook(id, _binding(token));
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, false));
        factory.reserveQueued(_intent(), 1);
    }

    function testSaltValidationDeduplicationAndOccupiedProxy() public {
        bytes32 preparedTokenSalt = tokenSalt;
        tokenSalt = factory.saltFor(0);
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = tokenSalt;
        salts[1] = tokenSalt;
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltUnavailable.selector, tokenSalt));
        factory.enqueueSalts(salts, false);
        assertTrue(factory.saltAvailable(tokenSalt));
        salts = new bytes32[](1);
        salts[0] = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.InvalidSalt.selector, salts[0]));
        factory.enqueueSalts(salts, false);
        (address predicted, address proxy) = factory.predict(tokenSalt);
        assertTrue(uint160(predicted) & ((1 << 14) - 1) != factory.HOOK_PERMISSION_MASK());
        salts[0] = tokenSalt;
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.InvalidHookAddress.selector, predicted));
        factory.enqueueSalts(salts, true);
        vm.etch(proxy, hex"00"); // Occupied helper rejects reuse even with no child code.
        assertFalse(factory.saltAvailable(tokenSalt));
        (address preparedAddress, address preparedProxy) = factory.predict(preparedTokenSalt);
        vm.etch(preparedProxy, hex"00");
        assertEq(preparedAddress.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltUnavailable.selector, preparedTokenSalt));
        factory.reserve(_intent(), 0, hookNonces);
    }

    function testReservationBindsFullIntentAndChainAndRequiresDiamond() public {
        StaticsBasketFactory.Intent memory intent = _intent();
        bytes32 original = factory.preparationId(intent, tokenSalt, hookSalts);
        intent.creator = address(0xBEEF);
        assertNotEq(original, factory.preparationId(intent, tokenSalt, hookSalts));
        intent = _intent();
        intent.payer = address(0xBEEF);
        assertNotEq(original, factory.preparationId(intent, tokenSalt, hookSalts));
        intent = _intent();
        intent.configurationHash = bytes32(uint256(2));
        assertNotEq(original, factory.preparationId(intent, tokenSalt, hookSalts));
        intent = _intent();
        intent.deadline++;
        assertNotEq(original, factory.preparationId(intent, tokenSalt, hookSalts));
        (address originalAddress,) = factory.predict(tokenSalt);
        vm.chainId(block.chainid + 1);
        (address otherChainAddress,) = factory.predict(tokenSalt);
        assertNotEq(originalAddress, otherChainAddress);
        assertNotEq(original, factory.preparationId(_intent(), tokenSalt, hookSalts));
        vm.prank(CREATOR);
        vm.expectRevert(StaticsBasketFactory.OnlyDiamond.selector);
        factory.reserve(_intent(), 0, hookNonces);
    }

    function testCallerProtectedCreateXSaltCannotBeSquattedByAnotherCaller() public {
        (address predicted, address proxy) = factory.predict(tokenSalt);
        // An outsider can use identical raw salt but CreateX guards it differently.
        vm.prank(CREATOR);
        address outsider = PinnedCreateX(factory.CREATE_X()).deployCreate3(tokenSalt, hex"6001600c60003960016000f300");
        assertNotEq(outsider, predicted);
        assertEq(proxy.code.length, 0);
        bytes32 id = factory.reserve(_intent(), 0, hookNonces);
        assertEq(factory.deployBasketToken(id, "B", "B", 10), predicted);
    }

    function testDeploymentOrderExpiryAndHookIntentMismatch() public {
        bytes32 id = factory.reserve(_intent(), 0, hookNonces);
        vm.expectRevert(StaticsBasketFactory.InvalidDeploymentOrder.selector);
        factory.deployBasketHook(id, _binding(address(3)));
        address token = factory.deployBasketToken(id, "B", "B", 10);
        StaticsBasketHook.Binding memory binding = _binding(token);
        binding.creator = address(0xBEEF);
        vm.expectRevert(StaticsBasketFactory.InvalidPreparation.selector);
        factory.deployBasketHook(id, binding);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(StaticsBasketFactory.PreparationExpired.selector);
        factory.deployBasketHook(id, _binding(token));
    }

    function testFactoryAndApprovedCodeStoresRetainDeploymentHeadroom() public view {
        assertLt(address(factory).code.length, 24_577);
        assertLt(factory.tokenCodeStore().code.length, 24_577);
        assertLt(factory.hookCodeStore().code.length, 24_577);
        assertLt(type(StaticsBasketFactory).creationCode.length + 96, 49_153);
    }

    function testPinnedCreateXRuntimeRequired() public {
        vm.etch(factory.CREATE_X(), hex"00");
        IStaticsSwapFeeHook policy = IStaticsSwapFeeHook(address(new Create3FeePolicy(address(this))));
        vm.expectRevert(
            abi.encodeWithSelector(StaticsBasketFactory.UnsupportedCreateX.selector, factory.CREATE_X().codehash)
        );
        new StaticsBasketFactory(address(this), manager, policy);
    }

    function testReservedIdentityCannotChangeChainsAtDeployment() public {
        bytes32 id = factory.reserve(_intent(), 0, hookNonces);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(StaticsBasketFactory.InvalidPreparation.selector);
        factory.deployBasketToken(id, "B", "B", 1);
    }

    function _intent() private view returns (StaticsBasketFactory.Intent memory) {
        return StaticsBasketFactory.Intent(
            address(this), CREATOR, keccak256("complete creation configuration"), block.timestamp + 1 days, 1
        );
    }

    function _binding(address token) private pure returns (StaticsBasketHook.Binding memory) {
        address asset = address(0x1111111111111111111111111111111111111111);
        return StaticsBasketHook.Binding(
            Currency.wrap(token < asset ? token : asset),
            Currency.wrap(token < asset ? asset : token),
            3000,
            60,
            CREATOR,
            1
        );
    }

    /// @dev Test-only mining. Production accepts validated, already mined salts; no search loop is deployed.
    function _mine(uint88 start) private view returns (bytes32 salt) {
        uint256 prefix = uint256(factory.saltFor(0));
        for (uint256 i = start; i < uint256(start) + 1_000_000; ++i) {
            salt = bytes32(prefix | i);
            bytes32 effective = keccak256(abi.encode(address(factory), block.chainid, salt));
            address proxy = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(hex"ff", factory.CREATE_X(), effective, factory.CREATE3_PROXY_HASH())
                        )
                    )
                )
            );
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
            if (uint160(predicted) & ((1 << 14) - 1) == factory.HOOK_PERMISSION_MASK()) return salt;
        }
        revert("test salt search exhausted");
    }
}
