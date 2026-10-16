// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";
import {BasketFactoryTestTools} from "../helpers/BasketFactoryTestTools.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketPreparation} from "../../src/interfaces/IStaticsBasketPreparation.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";

contract BasketSdkParityTest is BasketFactoryTestTools {
    function _assertPreparedFixture(string memory json, StaticsBasketTokenFactory factory) private view {
        StaticsBasketTokenFactory.Intent memory ownedIntent = StaticsBasketTokenFactory.Intent(
            vm.parseJsonAddress(json, ".payer"),
            vm.parseJsonAddress(json, ".creator"),
            vm.parseJsonBytes32(json, ".configurationHash"),
            2_000_000_000,
            1
        );
        bytes32 owned = factory.preparedSaltFor(ownedIntent, 42);
        assertEq(owned, vm.parseJsonBytes32(json, ".preparedTokenSalt"));
        (address ownedToken,) = factory.predict(owned);
        assertEq(ownedToken, vm.parseJsonAddress(json, ".preparedTokenAddress"));
    }

    function testSharedSdkConfigurationAndCreationCalldataFixture() public {
        string memory json = vm.readFile("test/fixtures/basket-create3.json");
        IStaticsBasket.CreateBasketParams memory params;
        params.name = "Parity";
        params.symbol = "sP";
        params.assets = new address[](2);
        params.assets[0] = vm.parseJsonAddress(json, ".payer");
        params.assets[1] = vm.parseJsonAddress(json, ".creator");
        params.bundleAmounts = new uint256[](2);
        params.bundleAmounts[0] = 1 ether;
        params.bundleAmounts[1] = 2 ether;
        params.mintFeeTiers = new IStaticsBasket.FeeTier[](1);
        params.mintFeeTiers[0] = IStaticsBasket.FeeTier(0, 1);
        params.redemptionFeeTiers = new IStaticsBasket.FeeTier[](0);
        params.flashFeeBps = 5;
        params.originationFeeBps = 100;
        params.extensionFeeBps = 25;
        params.ltvBps = 9500;
        params.recoveryPenaltyBps = 500;
        params.loanDuration = 30 days;
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](2);
        pools[0] = IStaticsBasket.PoolLaunchParams(3000, 10, uint160(1 << 96), 1 ether);
        pools[1] = IStaticsBasket.PoolLaunchParams(500, 20, uint160(2 << 96), 2 ether);
        uint256[] memory maxima = new uint256[](2);
        maxima[0] = 10 ether;
        maxima[1] = 20 ether;
        uint256 deadline = 2_000_000_000;
        assertEq(
            keccak256(abi.encode(params, pools, maxima, deadline, vm.parseJsonBytes32(json, ".environmentHash"))),
            vm.parseJsonBytes32(json, ".creationConfigurationHash")
        );
        bytes32 id = vm.parseJsonBytes32(json, ".preparationId");
        assertEq(
            keccak256(
                abi.encodeCall(IStaticsBasketPreparation.prepareBasketToken, (params, pools, maxima, deadline, 42))
            ),
            vm.parseJsonBytes32(json, ".prepareCalldataHash")
        );
        assertEq(
            keccak256(abi.encodeCall(IStaticsBasket.createBasketPrepared, (params, pools, maxima, deadline, id))),
            vm.parseJsonBytes32(json, ".createCalldataHash")
        );
        IStaticsBasketMarkets.MarketParams memory market = IStaticsBasketMarkets.MarketParams(
            params.assets[0], params.assets[1], 3000, 10, uint160(1 << 96), 1, deadline
        );
        assertEq(
            keccak256(abi.encodeCall(IStaticsBasketMarkets.createBasketMarket, (market))),
            vm.parseJsonBytes32(json, ".marketCalldataHash")
        );
    }

    function testSharedSdkCreate3AddressAndIntentFixture() public {
        string memory json = vm.readFile("test/fixtures/basket-create3.json");
        vm.chainId(31337);
        address diamond = vm.parseJsonAddress(json, ".diamond");
        address expectedFactory = vm.parseJsonAddress(json, ".factory");
        // The SDK hash fixture uses a fixed Diamond address; only code presence is needed here.
        // Real Diamond authorization and deployment are covered by the CREATE3 lifecycle tests.
        vm.etch(diamond, hex"00");
        IPoolManager manager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        StaticsBasketTokenFactory template = _deployTestBasketFactory(diamond, manager, IStaticsSwapFeeHook(address(0)));
        // Only relocate compiled code for a fixed address fixture; real CREATE3 deployment is tested separately.
        vm.etch(expectedFactory, address(template).code);
        StaticsBasketTokenFactory factory = StaticsBasketTokenFactory(expectedFactory);
        bytes32 salt = factory.automaticSaltFor(0);
        assertEq(salt, vm.parseJsonBytes32(json, ".tokenSalt"));
        _assertPreparedFixture(json, factory);
        assertEq(factory.effectiveSalt(salt), vm.parseJsonBytes32(json, ".effectiveSalt"));
        (address token, address proxy) = factory.predict(salt);
        assertEq(token, vm.parseJsonAddress(json, ".tokenAddress"));
        assertEq(proxy, vm.parseJsonAddress(json, ".tokenProxy"));
        StaticsBasketTokenFactory.Intent memory intent = StaticsBasketTokenFactory.Intent(
            vm.parseJsonAddress(json, ".payer"),
            vm.parseJsonAddress(json, ".creator"),
            vm.parseJsonBytes32(json, ".configurationHash"),
            2_000_000_000,
            1
        );
        assertEq(factory.preparationId(intent, salt), vm.parseJsonBytes32(json, ".automaticPreparationId"));
    }
}
