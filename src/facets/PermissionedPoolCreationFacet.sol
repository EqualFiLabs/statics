// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IVenueController} from "../interfaces/IVenueController.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibPermissionedPools} from "../libraries/LibPermissionedPools.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";

/// @notice Governance-created permissioned pools whose initial terms are exactly authorized by the creator.
contract PermissionedPoolCreationFacet is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME_HASH = keccak256(bytes("Statics Permissioned Pools"));
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));
    bytes32 private constant CREATE_TYPEHASH = keccak256(
        "CreatePermissionedPool(bytes32 poolId,uint160 sqrtPriceX96,address creator,address controller,bytes32 economicsHash,uint256 authorizationNonce,uint256 deadline,bytes32 agreementHash)"
    );

    error PermissionedLiquidityIntegrationNotInstalled();
    error InvalidToken(address token);
    error IdenticalTokens(address token);
    error InvalidCreator(address creator);
    error InvalidController(address controller);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidNativeLpFee(uint24 lpFee);
    error InvalidPoolPrice(uint160 sqrtPriceBPerAX96);
    error InvalidEconomics();
    error DeadlineExpired(uint256 deadline);
    error InvalidCreatorAuthorization(address creator);
    error AuthorizationNonceAlreadyUsed(address creator, uint256 nonce);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolAlreadyRegisteredInHook(PoolId poolId);
    error ActionPaused(uint256 action);

    function quotePermissionedPool(IStaticsPermissionedPools.CreatePermissionedPoolParams calldata params)
        external
        view
        returns (IStaticsPermissionedPools.PermissionedPoolQuote memory quote)
    {
        return _quote(params);
    }

    function createPermissionedPool(
        IStaticsPermissionedPools.CreatePermissionedPoolParams calldata params,
        bytes calldata creatorAuthorization
    ) external nonReentrant returns (PoolId poolId) {
        LibDiamond.enforceIsContractOwner();
        _enforceLiquidityAvailable();
        if (params.deadline < block.timestamp) revert DeadlineExpired(params.deadline);
        IStaticsPermissionedPools.PermissionedPoolQuote memory quote = _quote(params);
        poolId = quote.poolId;
        LibPermissionedPools.enforceUnregistered(poolId);
        LibPermissionedPools.PermissionedPoolStorage storage ps = LibPermissionedPools.permissionedPoolStorage();
        if (ps.authorizationNonceUsed[params.creator][params.authorizationNonce]) {
            revert AuthorizationNonceAlreadyUsed(params.creator, params.authorizationNonce);
        }
        if (!SignatureChecker.isValidSignatureNow(params.creator, quote.authorizationDigest, creatorAuthorization)) {
            revert InvalidCreatorAuthorization(params.creator);
        }
        ps.authorizationNonceUsed[params.creator][params.authorizationNonce] = true;

        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        IStaticsPermissionedSwapFeeHook hook = IStaticsPermissionedSwapFeeHook(ls.permissionedHook);
        if (hook.poolRegistration(poolId).registered) revert PoolAlreadyRegisteredInHook(poolId);
        (uint160 initializedPrice,,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        if (initializedPrice != 0) revert PoolAlreadyInitialized(poolId);

        LibPermissionedPools.PermissionedPool storage stored = ps.pools[poolId];
        stored.key = quote.key;
        stored.creator = params.creator;
        stored.registered = true;
        hook.registerPool(quote.key, params.controller, params.creator, params.economics);
        int24 tick = IPoolManager(ls.poolManager).initialize(quote.key, quote.sqrtPriceX96);
        _emitPoolCreated(params, quote, tick);
    }

    function invalidatePermissionedAuthorizationNonce(uint256 nonce) external {
        LibPermissionedPools.PermissionedPoolStorage storage ps = LibPermissionedPools.permissionedPoolStorage();
        if (ps.authorizationNonceUsed[msg.sender][nonce]) revert AuthorizationNonceAlreadyUsed(msg.sender, nonce);
        ps.authorizationNonceUsed[msg.sender][nonce] = true;
        emit IStaticsPermissionedPools.PermissionedAuthorizationNonceInvalidated(msg.sender, nonce);
    }

    function _emitPoolCreated(
        IStaticsPermissionedPools.CreatePermissionedPoolParams calldata params,
        IStaticsPermissionedPools.PermissionedPoolQuote memory quote,
        int24 tick
    ) private {
        emit IStaticsPermissionedPools.PermissionedPoolCreated(
            quote.poolId,
            params.creator,
            params.controller,
            Currency.unwrap(quote.key.currency0),
            Currency.unwrap(quote.key.currency1),
            params.lpFee,
            params.tickSpacing,
            quote.sqrtPriceX96,
            tick,
            params.agreementHash
        );
    }

    function _quote(IStaticsPermissionedPools.CreatePermissionedPoolParams calldata params)
        private
        view
        returns (IStaticsPermissionedPools.PermissionedPoolQuote memory quote)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = _liquidityStorage();
        _validateToken(params.tokenA);
        _validateToken(params.tokenB);
        if (params.tokenA == params.tokenB) revert IdenticalTokens(params.tokenA);
        if (params.creator == address(0)) revert InvalidCreator(params.creator);
        if (!_validController(params.controller)) revert InvalidController(params.controller);
        if (!LibProtocolPoolFee.isValidTickSpacing(params.tickSpacing)) revert InvalidTickSpacing(params.tickSpacing);
        if (!LibProtocolPoolFee.isValidStaticLpFee(params.lpFee)) revert InvalidNativeLpFee(params.lpFee);
        _validateEconomics(params.economics);
        quote.sqrtPriceX96 = _sortedSqrtPrice(params.tokenA, params.tokenB, params.sqrtPriceBPerAX96);
        quote.key = PoolKey({
            currency0: params.tokenA < params.tokenB ? Currency.wrap(params.tokenA) : Currency.wrap(params.tokenB),
            currency1: params.tokenA < params.tokenB ? Currency.wrap(params.tokenB) : Currency.wrap(params.tokenA),
            fee: params.lpFee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(ls.permissionedHook)
        });
        quote.poolId = quote.key.toId();
        quote.authorizationDigest = _creationDigest(quote.poolId, quote.sqrtPriceX96, params);
    }

    function _creationDigest(
        PoolId poolId,
        uint160 sqrtPriceX96,
        IStaticsPermissionedPools.CreatePermissionedPoolParams calldata params
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_TYPEHASH,
                PoolId.unwrap(poolId),
                sqrtPriceX96,
                params.creator,
                params.controller,
                _economicsHash(params.economics),
                params.authorizationNonce,
                params.deadline,
                params.agreementHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _economicsHash(IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics)
        private
        pure
        returns (bytes32)
    {
        IStaticsPermissionedSwapFeeHook.FeeAllocation calldata a = economics.allocation;
        return keccak256(
            abi.encode(
                economics.venueFeeBps,
                economics.additionalRewardRestrictedMask,
                a.creatorShareBps,
                a.treasuryShareBps,
                a.staticsStakerShareBps,
                a.basketStakerShareBps
            )
        );
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
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

    function _validateEconomics(IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics) private pure {
        IStaticsPermissionedSwapFeeHook.FeeAllocation calldata a = economics.allocation;
        uint256 total = uint256(a.creatorShareBps) + uint256(a.treasuryShareBps) + uint256(a.staticsStakerShareBps)
            + uint256(a.basketStakerShareBps);
        if (
            economics.venueFeeBps > 10_000 || economics.additionalRewardRestrictedMask > 3 || total != 10_000
                || a.basketStakerShareBps != 0
        ) revert InvalidEconomics();
    }

    function _validController(address controller) private view returns (bool valid) {
        if (controller.code.length == 0) return false;
        try IERC165(controller).supportsInterface(type(IVenueController).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
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
        if (!ls.permissionedIntegrationInstalled) revert PermissionedLiquidityIntegrationNotInstalled();
    }
}
