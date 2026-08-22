// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ProtocolPoolCreationFacet} from "../../src/facets/ProtocolPoolCreationFacet.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract GeneralProtocolPoolsTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CREATE_POOL_TYPEHASH = keccak256(
        "CreatePool(bytes32 poolId,uint160 sqrtPriceX96,uint16 inputFeeBps,uint16 outputFeeBps,address creator,uint256 nonce,uint256 deadline)"
    );

    IStaticsProtocolPools private pools;
    uint256 private constant CREATION_FEE = 0.1 ether;

    function setUp() public override {
        super.setUp();
        pools = IStaticsProtocolPools(address(diamond));
    }

    // --- Creation fee gate ---

    function testZeroCreationFeeAllowsOwnerAndRejectsPublic() public {
        assertEq(pools.poolCreationFee(), 0);
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), alice);
        // Owner creates on behalf of a named creator with empty authorization at zero fee.
        PoolId poolId = pools.createPool(params, "");
        assertTrue(pools.isProtocolPool(poolId));
        assertEq(pools.protocolPoolCreator(poolId), alice);

        IStaticsProtocolPools.CreatePoolParams memory other = _params(address(assetA), address(assetC()), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, bob, address(this)));
        pools.createPool(other, "");
    }

    function testNonzeroFeeEnablesPublicCreationWithExactPaymentToTreasury() public {
        pools.setPoolCreationFee(CREATION_FEE);
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), bob);
        uint256 treasuryBefore = treasury.balance;
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        PoolId poolId = pools.createPool{value: CREATION_FEE}(params, "");
        assertTrue(pools.isProtocolPool(poolId));
        assertEq(pools.protocolPoolCreator(poolId), bob);
        assertEq(treasury.balance - treasuryBefore, CREATION_FEE);
    }

    function testUnderpaymentAndOverpaymentRevert() public {
        pools.setPoolCreationFee(CREATION_FEE);
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), bob);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolCreationFacet.IncorrectCreationFee.selector, CREATION_FEE, CREATION_FEE - 1
            )
        );
        pools.createPool{value: CREATION_FEE - 1}(params, "");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolCreationFacet.IncorrectCreationFee.selector, CREATION_FEE, CREATION_FEE + 1
            )
        );
        pools.createPool{value: CREATION_FEE + 1}(params, "");
    }

    // --- PoolKey policy ---

    function testDuplicatePoolKeyReverts() public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), alice);
        PoolId poolId = pools.createPool(params, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                LibProtocolPools.ProtocolPoolAlreadyRegistered.selector,
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.General
            )
        );
        pools.createPool(params, "");
    }

    function testSamePairDifferentTickSpacingSucceeds() public {
        IStaticsProtocolPools.CreatePoolParams memory a = _params(address(assetA), address(assetB), alice);
        a.tickSpacing = 10;
        IStaticsProtocolPools.CreatePoolParams memory b = _params(address(assetA), address(assetB), alice);
        b.tickSpacing = 60;
        PoolId first = pools.createPool(a, "");
        PoolId second = pools.createPool(b, "");
        assertTrue(PoolId.unwrap(first) != PoolId.unwrap(second));
    }

    function testInvalidTickSpacingAndPriceRejected() public {
        IStaticsProtocolPools.CreatePoolParams memory zeroSpacing = _params(address(assetA), address(assetB), alice);
        zeroSpacing.tickSpacing = 0;
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidTickSpacing.selector, int24(0)));
        pools.quotePool(zeroSpacing);

        IStaticsProtocolPools.CreatePoolParams memory identical = _params(address(assetA), address(assetA), alice);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.IdenticalTokens.selector, address(assetA)));
        pools.quotePool(identical);
    }

    function testInvalidFeeRateRejected() public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), alice);
        params.feeRate = IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 150, outputFeeBps: 100});
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidFeeRate.selector, uint16(150), uint16(100))
        );
        pools.quotePool(params);
    }

    function testDeterministicQuoteMatchesCreatedPool() public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), alice);
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        PoolId poolId = pools.createPool(params, "");
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(quote.poolId));
        (uint160 livePrice,,,) = poolManager.getSlot0(poolId);
        assertEq(livePrice, quote.sqrtPriceX96);
        IStaticsProtocolPools.PoolSwapFeeRate memory rate = pools.protocolPoolFeeRate(poolId);
        assertEq(rate.inputFeeBps, params.feeRate.inputFeeBps);
        assertEq(rate.outputFeeBps, params.feeRate.outputFeeBps);
    }

    function testReciprocalPriceNormalization() public view {
        IStaticsProtocolPools.CreatePoolParams memory forward = _params(address(assetA), address(assetB), alice);
        forward.sqrtPriceBPerAX96 = SQRT_PRICE_1_1 * 2;
        IStaticsProtocolPools.CreatePoolParams memory reverse = _params(address(assetB), address(assetA), alice);
        reverse.sqrtPriceBPerAX96 = SQRT_PRICE_1_1 / 2;
        IStaticsProtocolPools.GeneralPoolQuote memory f = pools.quotePool(forward);
        IStaticsProtocolPools.GeneralPoolQuote memory r = pools.quotePool(reverse);
        assertEq(PoolId.unwrap(f.poolId), PoolId.unwrap(r.poolId));
        assertEq(f.sqrtPriceX96, r.sqrtPriceX96);
    }

    // --- Authorization ---

    function testEoaCreatorAuthorizationSucceedsAndConsumesNonce() public {
        pools.setPoolCreationFee(CREATION_FEE);
        (address creator, uint256 pk) = makeAddrAndKey("eoa-creator");
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        bytes memory sig = _sign(pk, quote.authorizationDigest);

        vm.deal(bob, 1 ether);
        vm.prank(bob); // relayer pays and submits
        PoolId poolId = pools.createPool{value: CREATION_FEE}(params, sig);
        assertEq(pools.protocolPoolCreator(poolId), creator);
        assertTrue(pools.isPoolCreationNonceUsed(creator, params.nonce));
    }

    function testErc1271ContractWalletCreatorAuthorizationSucceedsAndConsumesNonce() public {
        pools.setPoolCreationFee(CREATION_FEE);
        // The contract wallet's owner key produces the signature; the wallet address is the creator.
        (address walletOwner, uint256 ownerPk) = makeAddrAndKey("erc1271-owner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        address creator = address(wallet);

        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        bytes memory sig = _sign(ownerPk, quote.authorizationDigest);

        vm.deal(bob, 1 ether);
        vm.prank(bob); // relayer submits on behalf of the contract-wallet creator
        PoolId poolId = pools.createPool{value: CREATION_FEE}(params, sig);
        assertEq(pools.protocolPoolCreator(poolId), creator);
        assertTrue(pools.isPoolCreationNonceUsed(creator, params.nonce));
    }

    function testErc1271WalletRejectingSignatureBlocksAuthorization() public {
        pools.setPoolCreationFee(CREATION_FEE);
        (address walletOwner, uint256 ownerPk) = makeAddrAndKey("erc1271-owner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        wallet.setRejectAll(true); // malicious / misbehaving wallet rejects everything
        address creator = address(wallet);

        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        bytes memory sig = _sign(ownerPk, pools.quotePool(params).authorizationDigest);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidCreatorAuthorization.selector, creator));
        pools.createPool{value: CREATION_FEE}(params, sig);
        assertFalse(pools.isPoolCreationNonceUsed(creator, params.nonce));
    }

    function testConsumedNonceReplayRejected() public {
        pools.setPoolCreationFee(CREATION_FEE);
        (address creator, uint256 pk) = makeAddrAndKey("eoa-creator");
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        bytes memory sig = _sign(pk, pools.quotePool(params).authorizationDigest);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        pools.createPool{value: CREATION_FEE}(params, sig);

        // reuse same nonce for a different pool
        IStaticsProtocolPools.CreatePoolParams memory reuse = _params(address(assetA), address(assetC()), creator);
        reuse.nonce = params.nonce;
        bytes memory reuseSig = _sign(pk, pools.quotePool(reuse).authorizationDigest);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolCreationFacet.PoolCreationNonceAlreadyUsed.selector, creator, reuse.nonce
            )
        );
        pools.createPool{value: CREATION_FEE}(reuse, reuseSig);
    }

    function testCreatorNonceInvalidationBlocksAuthorization() public {
        pools.setPoolCreationFee(CREATION_FEE);
        (address creator, uint256 pk) = makeAddrAndKey("eoa-creator");
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        bytes memory sig = _sign(pk, pools.quotePool(params).authorizationDigest);
        vm.prank(creator);
        pools.invalidatePoolCreationNonce(params.nonce);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolPoolCreationFacet.PoolCreationNonceAlreadyUsed.selector, creator, params.nonce
            )
        );
        pools.createPool{value: CREATION_FEE}(params, sig);
    }

    function testInvalidSignatureRejected() public {
        pools.setPoolCreationFee(CREATION_FEE);
        (address creator,) = makeAddrAndKey("eoa-creator");
        (, uint256 wrongPk) = makeAddrAndKey("wrong-signer");
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), creator);
        bytes memory sig = _sign(wrongPk, pools.quotePool(params).authorizationDigest);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.InvalidCreatorAuthorization.selector, creator));
        pools.createPool{value: CREATION_FEE}(params, sig);
    }

    function testDirectCreatorCreationNeedsNoSignature() public {
        pools.setPoolCreationFee(CREATION_FEE);
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), bob);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        PoolId poolId = pools.createPool{value: CREATION_FEE}(params, "");
        assertEq(pools.protocolPoolCreator(poolId), bob);
        // nonce not consumed for direct creation
        assertFalse(pools.isPoolCreationNonceUsed(bob, params.nonce));
    }

    // --- Admin ---

    function testCanonicalCollisionRejected() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        IStaticsProtocolPools.CreatePoolParams memory params = _params(basketToken, address(assetA), alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibProtocolPools.ProtocolPoolAlreadyRegistered.selector,
                canonical.poolId,
                IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
            )
        );
        pools.createPool(params, "");
    }

    function testGeneralAllocationUpdateRoundtrips() public {
        IStaticsProtocolPools.GeneralFeeAllocation memory allocation = IStaticsProtocolPools.GeneralFeeAllocation({
            polShareBps: 4_000, liquidityProviderShareBps: 2_000, staticsStakerShareBps: 1_500, treasuryShareBps: 2_000
        });
        pools.setGeneralFeeAllocation(allocation);
        IStaticsProtocolPools.GeneralFeeAllocation memory stored = pools.generalFeeAllocation();
        assertEq(stored.polShareBps, 4_000);
        assertEq(stored.liquidityProviderShareBps, 2_000);
    }

    function testLiquidityPauseBlocksCreation() public {
        IStaticsGovernance(address(diamond)).pause(1 << 5);
        IStaticsProtocolPools.CreatePoolParams memory params = _params(address(assetA), address(assetB), alice);
        vm.expectRevert(abi.encodeWithSelector(ProtocolPoolCreationFacet.ActionPaused.selector, 1 << 5));
        pools.createPool(params, "");
    }

    // --- helpers ---

    function assetC() private returns (address) {
        MockERC20 c = new MockERC20("Asset C", "C", 18);
        return address(c);
    }

    function _params(address tokenA, address tokenB, address creator)
        private
        view
        returns (IStaticsProtocolPools.CreatePoolParams memory params)
    {
        params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: 10,
            sqrtPriceBPerAX96: SQRT_PRICE_1_1,
            feeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 pk, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
