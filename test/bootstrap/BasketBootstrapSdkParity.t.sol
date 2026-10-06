// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketDelegation} from "../../src/interfaces/IStaticsBasketDelegation.sol";
import {IStaticsBasketLaunchPreview} from "../../src/interfaces/IStaticsBasketLaunchPreview.sol";
import {LibBasketDelegation} from "../../src/libraries/LibBasketDelegation.sol";
import {LibBasketLaunchMath} from "../../src/libraries/LibBasketLaunchMath.sol";
import {StaticsAssetZap} from "../../src/periphery/StaticsAssetZap.sol";
import {NativeCampaignRevenue} from "../../src/bootstrap/NativeCampaignRevenue.sol";

contract BootstrapParityHarness {
    function digest(IStaticsBasketDelegation.Authorization calldata authorization) external view returns (bytes32) {
        return LibBasketDelegation.digest(authorization);
    }

    function preview(
        address token,
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256 nativeFee
    ) external pure returns (LibBasketLaunchMath.Requirements memory) {
        return LibBasketLaunchMath.preview(token, params, pools, nativeFee);
    }
}

contract BasketBootstrapSdkParityTest is Test {
    address private constant PAYER = 0x3333333333333333333333333333333333333333;
    address private constant CREATOR = 0x4444444444444444444444444444444444444444;
    address private constant DIAMOND = 0x2222222222222222222222222222222222222222;

    function testSharedNativeRevenueEncodingFixture() public view {
        string memory json = vm.readFile("test/fixtures/basket-bootstrap.json");
        assertEq(
            abi.encodeCall(NativeCampaignRevenue.deliverNative, ()), vm.parseJsonBytes(json, ".nativeRevenueCalldata")
        );
    }

    function _auth() private pure returns (IStaticsBasketDelegation.Authorization memory) {
        return IStaticsBasketDelegation.Authorization(
            CREATOR,
            PAYER,
            0x220ed04f9e474c0f1cddbf64b003e8654ae35d79687e4be1eeaf944a62675ab1,
            0x59c16dd91a6fb8c8a67b4500b588fcc8d6990ac4fd001e1ead8923dbc4e6a366,
            513,
            2_000_000_000,
            0.01 ether
        );
    }

    function _params() private pure returns (IStaticsBasket.CreateBasketParams memory p) {
        p.name = "Parity";
        p.symbol = "sP";
        p.assets = new address[](2);
        p.assets[0] = PAYER;
        p.assets[1] = CREATOR;
        p.bundleAmounts = new uint256[](2);
        p.bundleAmounts[0] = 1 ether;
        p.bundleAmounts[1] = 2 ether;
        p.mintFeeTiers = new IStaticsBasket.FeeTier[](1);
        p.mintFeeTiers[0] = IStaticsBasket.FeeTier(0, 1);
        p.redemptionFeeTiers = new IStaticsBasket.FeeTier[](0);
        p.flashFeeBps = 5;
        p.originationFeeBps = 100;
        p.extensionFeeBps = 25;
        p.ltvBps = 9500;
        p.recoveryPenaltyBps = 500;
        p.loanDuration = 30 days;
    }

    function _pools() private pure returns (IStaticsBasket.PoolLaunchParams[] memory p) {
        p = new IStaticsBasket.PoolLaunchParams[](2);
        p[0] = IStaticsBasket.PoolLaunchParams(3000, 10, uint160(1 << 96), 1 ether);
        p[1] = IStaticsBasket.PoolLaunchParams(500, 20, uint160(2 << 96), 2 ether);
    }

    function _maximums() private pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = 10 ether;
        m[1] = 20 ether;
    }

    function testSharedAuthorizationAndDelegatedEncodingFixture() public {
        string memory json = vm.readFile("test/fixtures/basket-bootstrap.json");
        vm.chainId(31337);
        BootstrapParityHarness template = new BootstrapParityHarness();
        // Relocate only the digest harness for a fixed domain fixture, not a value-moving lifecycle.
        vm.etch(DIAMOND, address(template).code);
        assertEq(BootstrapParityHarness(DIAMOND).digest(_auth()), vm.parseJsonBytes32(json, ".authorizationDigest"));
        assertEq(
            keccak256(
                abi.encodeCall(
                    IStaticsBasketDelegation.createBasketFor, (_params(), _pools(), _maximums(), _auth(), hex"1234")
                )
            ),
            vm.parseJsonBytes32(json, ".createForHash")
        );
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 4739;
        nonces[1] = 42;
        assertEq(
            keccak256(
                abi.encodeCall(
                    IStaticsBasketDelegation.prepareBasketCreationFor,
                    (_params(), _pools(), _maximums(), 42, nonces, _auth(), hex"1234")
                )
            ),
            vm.parseJsonBytes32(json, ".prepareForHash")
        );
        assertEq(
            keccak256(
                abi.encodeCall(
                    IStaticsBasketLaunchPreview.previewBasketLaunch,
                    (_auth().preparationId, _params(), _pools(), _maximums(), 2_000_000_000)
                )
            ),
            vm.parseJsonBytes32(json, ".previewHash")
        );
    }

    function testSharedExactLaunchAmountsFixture() public {
        string memory json = vm.readFile("test/fixtures/basket-bootstrap.json");
        LibBasketLaunchMath.Requirements memory r = new BootstrapParityHarness()
            .preview(0x602c27827A6ec6f4186f6b6E2F86AD593b5fFA8B, _params(), _pools(), 0.01 ether);
        assertEq(r.basketShares, vm.parseUint(vm.parseJsonString(json, ".requirements.basketShares")));
        assertEq(r.nativeCreationFee, vm.parseUint(vm.parseJsonString(json, ".requirements.nativeCreationFee")));
        for (uint256 i; i < 2; ++i) {
            string memory suffix = string.concat("[", vm.toString(i), "]");
            assertEq(
                r.backing[i], vm.parseUint(vm.parseJsonString(json, string.concat(".requirements.backing", suffix)))
            );
            assertEq(
                r.mintFees[i], vm.parseUint(vm.parseJsonString(json, string.concat(".requirements.mintFees", suffix)))
            );
            assertEq(
                r.pairedAmounts[i],
                vm.parseUint(vm.parseJsonString(json, string.concat(".requirements.pairedAmounts", suffix)))
            );
            assertEq(
                r.totalAmounts[i],
                vm.parseUint(vm.parseJsonString(json, string.concat(".requirements.totalAmounts", suffix)))
            );
        }
    }

    function testSharedZapEncodingFixture() public view {
        string memory json = vm.readFile("test/fixtures/basket-bootstrap.json");
        StaticsAssetZap.Input memory input = StaticsAssetZap.Input(PAYER, 9 ether, CREATOR, 2_000_000_000);
        StaticsAssetZap.Route[] memory routes = new StaticsAssetZap.Route[](1);
        routes[0].currencies = new address[](2);
        routes[0].currencies[0] = PAYER;
        routes[0].currencies[1] = CREATOR;
        routes[0].pools = new PoolKey[](1);
        routes[0].pools[0] = PoolKey(Currency.wrap(PAYER), Currency.wrap(CREATOR), 3000, 60, IHooks(address(0)));
        routes[0].maximumInput = 5 ether;
        uint256[] memory maximums = new uint256[](1);
        maximums[0] = 2 ether;
        assertEq(
            keccak256(abi.encodeCall(StaticsAssetZap.mintBasket, (input, 7, 1 ether, maximums, routes))),
            vm.parseJsonBytes32(json, ".zapMintHash")
        );
        StaticsAssetZap.Purchase[] memory orders = new StaticsAssetZap.Purchase[](1);
        orders[0] = StaticsAssetZap.Purchase(0, 1 ether, 3 ether);
        assertEq(
            keccak256(abi.encodeCall(StaticsAssetZap.purchaseCampaign, (input, DIAMOND, orders, 3 ether, routes))),
            vm.parseJsonBytes32(json, ".zapPurchaseHash")
        );
    }
}
