// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IMorphoBlue, MorphoMarketId, MorphoMarketParams, MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IStaticsMorpho} from "../interfaces/IStaticsMorpho.sol";
import {StaticsMorphoAccount} from "../morpho/StaticsMorphoAccount.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "./LibPositionPortfolio.sol";

library LibMorpho {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.morpho.v1");
    uint256 internal constant MAX_MARKETS_PER_POSITION = 16;
    uint16 internal constant MAX_SYNC_BOUNTY_BPS = 1_000;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000;

    struct MarketConfig {
        MorphoMarketParams params;
        IStaticsMorpho.CollateralKind kind;
        IStaticsMorpho.MarketMode mode;
        uint256 basketId;
        bool registered;
    }

    struct PositionMarket {
        uint256 trackedCollateral;
        bool debtActive;
    }

    struct PositionMarkets {
        bytes32[] ids;
        mapping(bytes32 marketId => uint256 indexPlusOne) indexPlusOne;
        mapping(bytes32 marketId => PositionMarket position) positions;
    }

    struct MorphoStorage {
        address morpho;
        address usdStx;
        uint16 syncBountyBps;
        bool initialized;
        mapping(bytes32 marketId => MarketConfig config) markets;
        mapping(uint256 positionId => bool deployed) accountDeployed;
        mapping(uint256 positionId => PositionMarkets markets) positions;
        mapping(uint256 positionId => mapping(uint256 basketId => uint256 amount)) basketCollateral;
        mapping(uint256 positionId => uint256 amount) staticsCollateral;
        mapping(address keeper => mapping(address asset => uint256 amount)) syncBounties;
        mapping(address asset => uint256 amount) totalSyncBounties;
        address performanceFeeRouter;
        uint16 performanceFeeBps;
        uint16 operatorShareBps;
    }

    error MorphoNotInitialized();
    error MorphoAlreadyInitialized();
    error InvalidMorphoContract(address morpho);
    error InvalidUsdStx(address usdStx);
    error InvalidSyncBounty(uint256 bountyBps);
    error InvalidMarket(bytes32 marketId);
    error MarketAlreadyRegistered(bytes32 marketId);
    error InvalidMarketMode();
    error MarketNotActive(bytes32 marketId);
    error MarketPositionLimit(uint256 positionId);
    error AccountDeploymentFailed(uint256 positionId);
    error InvalidPerformanceFee(uint256 feeBps);
    error InvalidOperatorShare(uint256 shareBps);

    function morphoStorage() internal pure returns (MorphoStorage storage ms) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            ms.slot := slot
        }
    }

    function marketId(MorphoMarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function accountAddress(uint256 positionId) internal view returns (address account) {
        MorphoStorage storage ms = morphoStorage();
        bytes32 salt = bytes32(positionId);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(StaticsMorphoAccount).creationCode, abi.encode(ms.morpho, address(this))));
        account =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function ensureAccount(uint256 positionId) internal returns (address account) {
        MorphoStorage storage ms = morphoStorage();
        account = accountAddress(positionId);
        if (ms.accountDeployed[positionId]) return account;
        address deployed = address(new StaticsMorphoAccount{salt: bytes32(positionId)}(ms.morpho, address(this)));
        if (deployed != account || !IMorphoBlue(ms.morpho).isAuthorized(account, address(this))) {
            revert AccountDeploymentFailed(positionId);
        }
        ms.accountDeployed[positionId] = true;
        emit IStaticsMorpho.MorphoAccountDeployed(positionId, account);
    }

    function requireMarket(bytes32 id) internal view returns (MarketConfig storage config) {
        config = morphoStorage().markets[id];
        if (!config.registered) revert InvalidMarket(id);
    }

    function requireActiveMarket(bytes32 id) internal view returns (MarketConfig storage config) {
        config = requireMarket(id);
        if (config.mode != IStaticsMorpho.MarketMode.Active) revert MarketNotActive(id);
    }

    function trackMarket(uint256 positionId, bytes32 id) internal {
        PositionMarkets storage position = morphoStorage().positions[positionId];
        if (position.indexPlusOne[id] != 0) return;
        if (position.ids.length == MAX_MARKETS_PER_POSITION) revert MarketPositionLimit(positionId);
        position.ids.push(id);
        position.indexPlusOne[id] = position.ids.length;
        LibPositionPortfolio.addMorphoMarket(positionId, uint256(id));
        bytes32 key = LibPosition.morphoLegKey(id);
        if (!LibPosition.positionStorage().activeLeg[positionId][key]) {
            LibPosition.activateLeg(positionId, LibPosition.MORPHO_MODULE, id);
        }
    }

    function syncDebtObligation(uint256 positionId, bytes32 id, uint256 borrowShares) internal {
        PositionMarket storage position = morphoStorage().positions[positionId].positions[id];
        bool active = borrowShares != 0;
        if (active == position.debtActive) return;
        position.debtActive = active;
        if (active) LibPosition.incrementObligation(positionId);
        else LibPosition.decrementObligation(positionId);
    }

    function deactivateIfEmpty(uint256 positionId, bytes32 id, uint256 borrowShares) internal {
        MorphoStorage storage ms = morphoStorage();
        PositionMarkets storage position = ms.positions[positionId];
        if (position.positions[id].trackedCollateral != 0 || borrowShares != 0) return;
        uint256 indexPlusOne = position.indexPlusOne[id];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = position.ids.length - 1;
        if (index != last) {
            bytes32 moved = position.ids[last];
            position.ids[index] = moved;
            position.indexPlusOne[moved] = indexPlusOne;
        }
        position.ids.pop();
        delete position.indexPlusOne[id];
        LibPositionPortfolio.removeMorphoMarket(positionId, uint256(id));
        bytes32 key = LibPosition.morphoLegKey(id);
        if (LibPosition.positionStorage().activeLeg[positionId][key]) LibPosition.deactivateLeg(positionId, key);
    }

    function actualPosition(uint256 positionId, bytes32 id) internal view returns (MorphoPosition memory) {
        MorphoStorage storage ms = morphoStorage();
        if (!ms.accountDeployed[positionId]) return MorphoPosition(0, 0, 0);
        return IMorphoBlue(ms.morpho).position(MorphoMarketId.wrap(id), accountAddress(positionId));
    }

    function syncIfInitialized(uint256 positionId, address keeper) internal {
        if (morphoStorage().initialized) IStaticsMorpho(address(this)).syncMorphoForModule(positionId, keeper);
    }

    function creditSyncBounty(address keeper, address asset, uint256 amount) internal {
        if (keeper == address(0) || amount == 0) return;
        MorphoStorage storage ms = morphoStorage();
        ms.syncBounties[keeper][asset] += amount;
        ms.totalSyncBounties[asset] += amount;
    }
}
