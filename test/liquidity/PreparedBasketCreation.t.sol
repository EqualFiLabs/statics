// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {BasketPreparationFacet} from "../../src/facets/BasketPreparationFacet.sol";
import {BasketSettlementFacet} from "../../src/facets/BasketSettlementFacet.sol";
import {StaticsBasketFactory} from "../../src/liquidity/StaticsBasketFactory.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract PreparedBasketCreationTest is CanonicalPoolTestBase {
    BasketPreparationFacet private preparation;
    StaticsBasketFactory private factory;
    bytes32 private tokenSalt;
    bytes32[] private hookSalts;

    function setUp() public override {
        super.setUp();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BasketPreparationFacet.installBasketFactory.selector;
        selectors[1] = BasketPreparationFacet.basketFactory.selector;
        selectors[2] = BasketPreparationFacet.basketCreationConfigurationHash.selector;
        selectors[3] = BasketPreparationFacet.prepareBasketCreation.selector;
        cut[0] = IDiamondCut.FacetCut(address(new BasketPreparationFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        selectors = new bytes4[](3);
        selectors[0] = BasketSettlementFacet.validateBasketPool.selector;
        selectors[1] = BasketSettlementFacet.authorizeBasketPoolSettlement.selector;
        selectors[2] = BasketSettlementFacet.authorizeBasketPoolClaim.selector;
        cut[1] = IDiamondCut.FacetCut(address(new BasketSettlementFacet()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        preparation = BasketPreparationFacet(address(diamond));
        vm.etch(
            0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed,
            vm.parseJsonBytes(vm.readFile("test/fixtures/createx-v1.json"), ".runtime")
        );
        factory = StaticsBasketFactory(
            deployCode(
                "out/StaticsBasketFactory.sol/StaticsBasketFactory.json",
                abi.encode(address(diamond), poolManager, swapFeeHook)
            )
        );
        preparation.installBasketFactory(address(factory));
        tokenSalt = factory.saltFor(0);
        hookSalts.push(_mine(1));
        hookSalts.push(_mine(uint88(uint256(hookSalts[0])) + 1));
    }

    function testPreparedCreationUsesReservedIdentitiesAndCreatesActualProtocolPol() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        (bytes32 id, address predicted) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, tokenSalt, hookSalts);
        vm.prank(alice);
        (uint256 basketId, address token) =
            baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertEq(token, predicted);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
        assertEq(baskets.basket(basketId).creator, alice);
        for (uint256 i; i < params.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                basketLiquidity.canonicalPool(basketId, params.assets[i]);
            (address predictedHook,) = factory.predict(hookSalts[i]);
            assertEq(pool.hook, predictedHook);
            assertEq(StaticsBasketHook(pool.hook).boundCreator(), alice);
            IStaticsProtocolPools.ProtocolPoolView memory market =
                IStaticsProtocolPools(address(diamond)).protocolPool(pool.poolId);
            assertEq(uint256(market.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
            assertEq(market.creator, alice);
            assertTrue(market.polActivated);
        }
        assertEq(IERC20(token).balanceOf(alice), 0); // Launch inventory belongs to POL, not the payer.
        assertGt(IERC20(token).totalSupply(), 0);
    }

    function testLegacySelectorConsumesQueueAndDoesNotDeployTransferableTokens() public {
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = tokenSalt;
        factory.enqueueSalts(tokens, false);
        factory.enqueueSalts(hookSalts, true);
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        assertEq(StaticsRestrictedBasketToken(token).basketId(), basketId);
        (address predicted,) = factory.predict(tokenSalt);
        assertEq(token, predicted);
        (uint256 availableTokens, uint256 availableHooks) = factory.queueAvailability();
        assertEq(availableTokens + availableHooks, 0);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StaticsBasketFactory.SaltQueueDepleted.selector, false));
        baskets.createBasket{value: 1 ether}(params, pools, maximums, type(uint256).max);
    }

    function testChangedPreparedEconomicsFailAndPreserveReservedIdentity() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        (bytes32 id,) =
            preparation.prepareBasketCreation(params, pools, maximums, type(uint256).max, tokenSalt, hookSalts);
        params.name = "Changed";
        vm.prank(alice);
        vm.expectRevert();
        baskets.createBasketPrepared{value: 1 ether}(params, pools, maximums, type(uint256).max, id);
        assertFalse(factory.preparation(id).tokenDeployed);
        assertEq(baskets.basketCount(), 0);
        params.name = "Static A-B";
        basketAdmin.setCreationFee(2 ether);
        vm.prank(alice);
        vm.expectRevert();
        baskets.createBasketPrepared{value: 2 ether}(params, pools, maximums, type(uint256).max, id);
        assertFalse(factory.preparation(id).tokenDeployed);
    }

    /// @dev Test-only equivalent of offchain mining over the effective guarded CreateX salt.
    function _mine(uint88 start) private view returns (bytes32 salt) {
        uint256 prefix = uint256(factory.saltFor(0));
        address createX = factory.CREATE_X();
        bytes32 proxyHash = factory.CREATE3_PROXY_HASH();
        for (uint256 i = start; i < uint256(start) + 1_000_000; ++i) {
            salt = bytes32(prefix | i);
            bytes32 effective = keccak256(abi.encode(address(factory), block.chainid, salt));
            address proxy =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", createX, effective, proxyHash)))));
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
            if (uint160(predicted) & ((1 << 14) - 1) == 0x1fec) return salt;
        }
        revert("test salt search exhausted");
    }
}
