// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibBasketManagerSettlement} from "../../src/libraries/LibBasketManagerSettlement.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {RangeGaugeViewFacet} from "../../src/facets/RangeGaugeViewFacet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {CanonicalPoolTestBase} from "./CanonicalPoolTestBase.sol";

/// @dev Unit API-edge facade: exposes manager calls without the higher-level gauge/POL state
/// machine. It retains genuine Diamond custody, the production transient settlement window,
/// restricted-token capabilities, and actual v4/Permit2 execution. Production lifecycle suites
/// independently exercise the real public gauge/POL entrypoints.
contract LiquidityManagerFixtureFacet is ReentrancyGuard {
    function fixtureManagerCall(
        address manager,
        PoolKey calldata key,
        address receiver,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external nonReentrant returns (bytes memory result) {
        LibDiamond.enforceIsContractOwner();
        LibBasketManagerSettlement.begin(key, manager, receiver);
        // Negative API edges intentionally omit inventory. Never borrow reserved basket backing
        // merely to reach those validations, or partially fund one side of a failing request.
        if (
            LibCustody.unreservedBalance(Currency.unwrap(key.currency0)) >= amount0
                && LibCustody.unreservedBalance(Currency.unwrap(key.currency1)) >= amount1
        ) {
            if (amount0 != 0) {
                LibCustody.pushUnreserved(Currency.unwrap(key.currency0), manager, amount0, amount0);
            }
            if (amount1 != 0) LibCustody.pushUnreserved(Currency.unwrap(key.currency1), manager, amount1, amount1);
        }
        bool success;
        (success, result) = manager.call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        LibBasketManagerSettlement.end();
    }
}

abstract contract LiquidityManagerTestBase is CanonicalPoolTestBase {
    IAllowanceTransfer internal permit2Contract;
    IPositionManager internal positionManagerContract;
    StaticsLiquidityManager internal liquidityManager;
    uint256 internal basketId;
    address internal basketToken;
    PoolKey internal canonicalKey;
    uint256 internal firstUserPositionId;
    mapping(bytes32 poolId => IStaticsProtocolPools.ProtocolPoolView pool) private managerPoolOverrides;
    mapping(bytes32 poolId => bool configured) private managerPoolOverrideConfigured;
    mapping(uint256 tokenId => bytes32 binding) private managerPosmBindings;

    function setUp() public virtual override {
        super.setUp();
        permit2Contract = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        positionManagerContract = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2Contract), uint256(100_000), address(0), address(0))
            )
        );
        liquidityManager = new StaticsLiquidityManager(
            address(diamond), address(positionManagerContract), address(poolManager), address(permit2Contract)
        );
        basketLiquidity.installLiquidityManager(address(liquidityManager));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LiquidityManagerFixtureFacet.fixtureManagerCall.selector;
        cut[0] = IDiamondCut.FacetCut(
            address(new LiquidityManagerFixtureFacet()), IDiamondCut.FacetCutAction.Add, selectors
        );
        bytes4[] memory views = new bytes4[](1);
        views[0] = RangeGaugeViewFacet.posmBinding.selector;
        cut[1] = IDiamondCut.FacetCut(address(new RangeGaugeViewFacet()), IDiamondCut.FacetCutAction.Add, views);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        (basketId, basketToken) = _createDefaultBasket(0, 0);
        canonicalKey = _canonicalKey();
        // Canonical POL uses this real PositionManager too; rejected calls must preserve its cursor.
        firstUserPositionId = positionManagerContract.nextTokenId();

        uint256[] memory quote = baskets.quoteMint(basketId, 200 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, 200 ether, alice, quote);
        assetA.mint(alice, 200 ether);
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(assetA));
    }

    function _request(uint256 liquidity, uint256 amount0Limit, uint256 amount1Limit)
        internal
        view
        returns (IStaticsLiquidityManager.PositionRequest memory request)
    {
        request = IStaticsLiquidityManager.PositionRequest({
            poolKey: canonicalKey,
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidity: liquidity,
            amount0Limit: amount0Limit,
            amount1Limit: amount1Limit,
            deadline: block.timestamp + 1 hours
        });
    }

    function _installDefaultLiquidityManager() internal pure override returns (bool) {
        return false;
    }

    function _setManagerPoolOverride(IStaticsProtocolPools.ProtocolPoolView memory pool) internal {
        bytes32 rawPoolId = PoolId.unwrap(pool.poolId);
        managerPoolOverrides[rawPoolId] = pool;
        managerPoolOverrideConfigured[rawPoolId] = true;
        // Deliberately synthetic registry edges; no token or manager implementation is mocked.
        vm.mockCall(
            address(diamond), abi.encodeCall(IStaticsProtocolPools.protocolPool, (pool.poolId)), abi.encode(pool)
        );
    }

    function _setManagerPosmBinding(uint256 tokenId, bytes32 binding) internal {
        managerPosmBindings[tokenId] = binding;
        vm.mockCall(address(diamond), abi.encodeWithSignature("posmBinding(uint256)", tokenId), abi.encode(binding));
    }

    // Preserve the ordinary-token Permit2 allowance fixture, whose separate manager deliberately
    // binds to this test contract. Restricted-value flows above always bind to the real Diamond.
    function protocolPool(PoolId poolId) external view returns (IStaticsProtocolPools.ProtocolPoolView memory pool) {
        bytes32 rawPoolId = PoolId.unwrap(poolId);
        if (managerPoolOverrideConfigured[rawPoolId]) return managerPoolOverrides[rawPoolId];
        return IStaticsProtocolPools(address(diamond)).protocolPool(poolId);
    }

    function posmBinding(uint256 tokenId) external view returns (bytes32) {
        return managerPosmBindings[tokenId];
    }

    function _mintManagerInventory(uint256 basketAmount, uint256 assetAmount) internal {
        uint256[] memory quote = baskets.quoteMint(basketId, basketAmount);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, basketAmount, address(diamond), quote);
        assetA.mint(address(diamond), assetAmount);
    }

    function _managerCall(address receiver, uint256 amount0, uint256 amount1, bytes memory data)
        internal
        returns (bytes memory)
    {
        (bool success, bytes memory result) = address(diamond)
            .call(
                abi.encodeCall(
                    LiquidityManagerFixtureFacet.fixtureManagerCall,
                    (address(liquidityManager), canonicalKey, receiver, amount0, amount1, data)
                )
            );
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        // Foundry consumes a matched vm.expectRevert on this external facade call and returns
        // empty bytes. No genuine successful facade/manager call has an empty ABI response.
        if (result.length == 0) return result;
        return abi.decode(result, (bytes));
    }

    function _mintUserPosition(
        IStaticsLiquidityManager.PositionRequest memory request,
        address recipient,
        address refund
    ) internal returns (IStaticsLiquidityManager.PositionMovement memory movement, uint256 refund0, uint256 refund1) {
        bytes memory result = _managerCall(
            refund,
            request.amount0Limit,
            request.amount1Limit,
            abi.encodeCall(IStaticsLiquidityManager.mintUserPosition, (request, recipient, refund))
        );
        if (result.length == 0) return (movement, 0, 0);
        return abi.decode(result, (IStaticsLiquidityManager.PositionMovement, uint256, uint256));
    }

    function _mintManagedPosition(IStaticsLiquidityManager.PositionRequest memory request, address receiver)
        internal
        returns (IStaticsLiquidityManager.ManagedPositionMovement memory movement)
    {
        bytes memory result = _managerCall(
            receiver,
            request.amount0Limit,
            request.amount1Limit,
            abi.encodeCall(IStaticsLiquidityManager.mintManagedPosition, (request, receiver))
        );
        if (result.length == 0) return movement;
        return abi.decode(result, (IStaticsLiquidityManager.ManagedPositionMovement));
    }

    function _managedCall(IStaticsLiquidityManager.ManagedLiquidityRequest memory request, bytes4 selector)
        internal
        returns (IStaticsLiquidityManager.ManagedPositionMovement memory movement)
    {
        bytes memory result = _managerCall(
            request.receiver, request.amount0Limit, request.amount1Limit, abi.encodeWithSelector(selector, request)
        );
        if (result.length == 0) return movement;
        return abi.decode(result, (IStaticsLiquidityManager.ManagedPositionMovement));
    }

    function _attachManagedPosition(address owner, PoolId poolId, uint256 tokenId)
        internal
        returns (IStaticsLiquidityManager.ManagedPositionState memory state)
    {
        bytes memory result = _managerCall(
            owner, 0, 0, abi.encodeCall(IStaticsLiquidityManager.attachManagedPosition, (owner, poolId, tokenId))
        );
        if (result.length == 0) return state;
        return abi.decode(result, (IStaticsLiquidityManager.ManagedPositionState));
    }

    function _recoverUnboundPosition(uint256 tokenId, address receiver) internal {
        _managerCall(
            receiver, 0, 0, abi.encodeCall(IStaticsLiquidityManager.recoverUnboundPosition, (tokenId, receiver))
        );
    }

    function _canonicalKey() private view returns (PoolKey memory key) {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }
}
