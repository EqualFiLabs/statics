// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

/// @notice Permissionless general-pool creation with deterministic quoting, sorted PoolKey policy,
/// reciprocal normalized pricing, independent native creation fee gating, EIP-712 creator
/// authorization (EOA and ERC-1271 via `SignatureChecker`), and unordered creator nonces.
contract ProtocolPoolCreationFacet is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant PROTOCOL_LP_FEE = 0;
    uint256 private constant Q96 = 1 << 96;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME_HASH = keccak256(bytes("Statics Protocol Pools"));
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));
    bytes32 private constant CREATE_POOL_TYPEHASH = keccak256(
        "CreatePool(bytes32 poolId,uint160 sqrtPriceX96,uint16 inputFeeBps,uint16 outputFeeBps,address creator,uint256 nonce,uint256 deadline)"
    );

    error LiquidityIntegrationNotInstalled();
    error InvalidToken(address token);
    error IdenticalTokens(address token);
    error DeadlineExpired(uint256 deadline);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidPoolPrice(uint160 sqrtPriceBPerAX96);
    error InvalidFeeRate(uint16 inputFeeBps, uint16 outputFeeBps);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolAlreadyRegisteredInHook(PoolId poolId);
    error ActionPaused(uint256 action);
    error IncorrectCreationFee(uint256 expected, uint256 provided);
    error CreationFeeTransferFailed(address treasury, uint256 amount);
    error InvalidCreatorAuthorization(address creator);
    error PoolCreationNonceAlreadyUsed(address creator, uint256 nonce);

    function quotePool(IStaticsProtocolPools.CreatePoolParams calldata params)
        external
        view
        returns (IStaticsProtocolPools.GeneralPoolQuote memory quote)
    {
        return _quote(params);
    }

    function createPool(IStaticsProtocolPools.CreatePoolParams calldata params, bytes calldata creatorAuthorization)
        external
        payable
        nonReentrant
        returns (PoolId poolId)
    {
        _enforceLiquidityAvailable();
        if (params.deadline < block.timestamp) revert DeadlineExpired(params.deadline);
        IStaticsProtocolPools.GeneralPoolQuote memory quote = _quote(params);
        poolId = quote.poolId;
        LibProtocolPools.enforceUnregistered(poolId);

        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(ls.hook);
        if (hook.poolRegistration(poolId).registered) revert PoolAlreadyRegisteredInHook(poolId);
        (uint160 initializedPrice,,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        if (initializedPrice != 0) revert PoolAlreadyInitialized(poolId);

        _authorizeCreator(params, quote.authorizationDigest, creatorAuthorization);
        _collectCreationFee(quote.creationFee);
        _registerAndInitialize(ls, hook, params, quote);
    }

    function _registerAndInitialize(
        LibBasketLiquidity.LiquidityStorage storage ls,
        IStaticsSwapFeeHook hook,
        IStaticsProtocolPools.CreatePoolParams calldata params,
        IStaticsProtocolPools.GeneralPoolQuote memory quote
    ) private {
        PoolId poolId = quote.poolId;
        LibProtocolPools.GeneralPool storage stored = LibProtocolPools.protocolPoolStorage().generalPools[poolId];
        stored.key = quote.key;
        stored.creator = params.creator;
        stored.registered = true;

        hook.registerPool(quote.key, IStaticsSwapFeeHook.PoolKind.General, params.creator);
        hook.setPoolFeeRate(poolId, params.feeRate.inputFeeBps, params.feeRate.outputFeeBps);
        int24 tick = IPoolManager(ls.poolManager).initialize(quote.key, quote.sqrtPriceX96);

        emit IStaticsProtocolPools.ProtocolPoolCreated(
            poolId,
            params.creator,
            Currency.unwrap(quote.key.currency0),
            Currency.unwrap(quote.key.currency1),
            params.tickSpacing,
            params.feeRate.inputFeeBps,
            params.feeRate.outputFeeBps,
            quote.sqrtPriceX96,
            tick
        );
    }

    function invalidatePoolCreationNonce(uint256 nonce) external {
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        if (ps.poolCreationNonceUsed[msg.sender][nonce]) revert PoolCreationNonceAlreadyUsed(msg.sender, nonce);
        ps.poolCreationNonceUsed[msg.sender][nonce] = true;
        emit IStaticsProtocolPools.PoolCreationNonceInvalidated(msg.sender, nonce);
    }

    function _quote(IStaticsProtocolPools.CreatePoolParams calldata params)
        private
        view
        returns (IStaticsProtocolPools.GeneralPoolQuote memory quote)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        _validateToken(params.tokenA);
        _validateToken(params.tokenB);
        if (params.tokenA == params.tokenB) revert IdenticalTokens(params.tokenA);
        if (!LibProtocolPoolFee.isValidTickSpacing(params.tickSpacing)) revert InvalidTickSpacing(params.tickSpacing);
        if (!LibProtocolPoolFee.isValidFeeRate(params.feeRate.inputFeeBps, params.feeRate.outputFeeBps)) {
            revert InvalidFeeRate(params.feeRate.inputFeeBps, params.feeRate.outputFeeBps);
        }
        quote.sqrtPriceX96 = _sortedSqrtPrice(params.tokenA, params.tokenB, params.sqrtPriceBPerAX96);
        quote.key = PoolKey({
            currency0: params.tokenA < params.tokenB ? Currency.wrap(params.tokenA) : Currency.wrap(params.tokenB),
            currency1: params.tokenA < params.tokenB ? Currency.wrap(params.tokenB) : Currency.wrap(params.tokenA),
            fee: PROTOCOL_LP_FEE,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(ls.hook)
        });
        quote.poolId = quote.key.toId();
        quote.feeRate = params.feeRate;
        quote.creationFee = LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
        quote.authorizationDigest = _authorizationDigest(quote.poolId, quote.sqrtPriceX96, params);
    }

    function _sortedSqrtPrice(address tokenA, address tokenB, uint160 sqrtPriceBPerAX96)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (sqrtPriceBPerAX96 == 0) revert InvalidPoolPrice(sqrtPriceBPerAX96);
        uint256 sorted =
            tokenA < tokenB ? uint256(sqrtPriceBPerAX96) : Math.mulDiv(Q96, Q96, uint256(sqrtPriceBPerAX96));
        if (sorted > type(uint160).max) revert InvalidPoolPrice(sqrtPriceBPerAX96);
        sqrtPriceX96 = uint160(sorted);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidPoolPrice(sqrtPriceBPerAX96);
        }
    }

    function _authorizationDigest(
        PoolId poolId,
        uint160 sqrtPriceX96,
        IStaticsProtocolPools.CreatePoolParams calldata params
    ) private view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_POOL_TYPEHASH,
                PoolId.unwrap(poolId),
                sqrtPriceX96,
                params.feeRate.inputFeeBps,
                params.feeRate.outputFeeBps,
                params.creator,
                params.nonce,
                params.deadline
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @dev Resolves the direct, governed, or signed creator-authorization path. Nonce consumption
    /// occurs before external interactions so any later revert restores the nonce atomically.
    function _authorizeCreator(
        IStaticsProtocolPools.CreatePoolParams calldata params,
        bytes32 digest,
        bytes calldata creatorAuthorization
    ) private {
        if (params.creator == msg.sender) return;

        uint256 creationFee = LibProtocolPools.protocolPoolStorage().poolCreationFeeAmount;
        if (creationFee == 0) {
            LibDiamond.enforceIsContractOwner();
            return;
        }

        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        if (ps.poolCreationNonceUsed[params.creator][params.nonce]) {
            revert PoolCreationNonceAlreadyUsed(params.creator, params.nonce);
        }
        if (!SignatureChecker.isValidSignatureNow(params.creator, digest, creatorAuthorization)) {
            revert InvalidCreatorAuthorization(params.creator);
        }
        ps.poolCreationNonceUsed[params.creator][params.nonce] = true;
    }

    function _collectCreationFee(uint256 creationFee) private {
        if (creationFee == 0) {
            if (msg.value != 0) revert IncorrectCreationFee(0, msg.value);
            return;
        }
        if (msg.value != creationFee) revert IncorrectCreationFee(creationFee, msg.value);
        address treasury = LibBasket.basketStorage().treasury;
        (bool ok,) = payable(treasury).call{value: creationFee}("");
        if (!ok) revert CreationFeeTransferFailed(treasury, creationFee);
    }

    function _validateToken(address token) private view {
        if (token == address(0) || token.code.length == 0) revert InvalidToken(token);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }
}
