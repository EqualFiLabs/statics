// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaticsExternalModules} from "../../../src/interfaces/IStaticsExternalModules.sol";
import {IGenesisActivationRegistry} from "../../../src/interfaces/IGenesisActivationRegistry.sol";

/// @dev Funded reference consumer for interface qualification, not a production product adapter.
contract ExternalRewardConsumer {
    using SafeERC20 for IERC20;
    uint256 public constant RAY = 1e27;
    bytes32 public constant MODULE = keccak256("test.external.reward.account");

    struct Account {
        uint256 receipts;
        uint256 stake;
        uint256 weight;
        uint256 operatorId;
        uint256 multiplier;
        uint256 positionSequence;
        uint256 operatorSequence;
        uint256 cash;
    }

    struct Batch {
        address asset;
        uint256 amount;
        uint256 boundary;
    }
    IStaticsExternalModules public immutable core;
    IERC721 public immutable operators;
    IGenesisActivationRegistry public immutable registry;
    IERC20 public immutable principal;
    address[] public assets;
    mapping(uint256 => Account) public accounts;
    mapping(uint256 => uint256) public operatorAccount;
    mapping(address => uint256) public indexRay;
    mapping(address => uint256) public dustRay;
    mapping(address => uint256) public zeroStakeRevenue;
    mapping(uint256 => mapping(address => uint256)) public earnedRay;
    mapping(uint256 => mapping(address => uint256)) public checkpoint;
    mapping(uint256 => bool) public attached;
    Batch[] public batches;
    uint256 public nextBatch;
    uint256 public cursor;
    uint256 public totalWeight;

    constructor(address core_, address operators_, address registry_, IERC20 principal_, address[] memory assets_) {
        core = IStaticsExternalModules(core_);
        operators = IERC721(operators_);
        registry = IGenesisActivationRegistry(registry_);
        principal = principal_;
        assets = assets_;
        cursor = core.transferHead();
    }
    modifier owner(uint256 id) {
        require(IERC721(address(core)).ownerOf(id) == msg.sender, "owner");
        _synchronize();
        _checkpoint(id);
        _;
    }

    function deposit(uint256 id, uint256 amount, bool stakeNow) external owner(id) {
        principal.safeTransferFrom(msg.sender, address(this), amount);
        _attach(id);
        Account storage a = accounts[id];
        a.receipts += amount;
        if (stakeNow) _stake(id, amount);
    }

    function depositCash(uint256 id, uint256 amount) external owner(id) {
        principal.safeTransferFrom(msg.sender, address(this), amount);
        _attach(id);
        accounts[id].cash += amount;
    }

    function withdrawCash(uint256 id) external owner(id) {
        uint256 amount = accounts[id].cash;
        accounts[id].cash = 0;
        principal.safeTransfer(msg.sender, amount);
    }

    function stake(uint256 id, uint256 amount) external owner(id) {
        _stake(id, amount);
    }

    function _stake(uint256 id, uint256 amount) private {
        Account storage a = accounts[id];
        require(a.stake + amount <= a.receipts, "receipts");
        a.stake += amount;
        _weight(a);
    }

    function unstake(uint256 id, uint256 amount) external owner(id) {
        Account storage a = accounts[id];
        a.stake -= amount;
        _weight(a);
    }

    function withdraw(uint256 id, uint256 amount) external owner(id) {
        Account storage a = accounts[id];
        require(amount <= a.receipts - a.stake, "staked");
        a.receipts -= amount;
        principal.safeTransfer(msg.sender, amount);
    }

    function register(uint256 id, uint256 operatorId) external owner(id) {
        require(core.historyCoverage(address(operators)).ready, "coverage");
        require(operators.ownerOf(operatorId) == msg.sender, "operator owner");
        uint256 occupied = operatorAccount[operatorId];
        require(occupied == 0 || occupied == id, "operator occupied");
        _attach(id);
        _clear(id);
        Account storage a = accounts[id];
        a.operatorId = operatorId;
        a.multiplier = registry.multiplierBps(operatorId);
        a.positionSequence = core.transferState(address(core), id).lastSequence;
        a.operatorSequence = core.transferState(address(operators), operatorId).lastSequence;
        operatorAccount[operatorId] = id;
        _weight(a);
    }

    function removeRegistration(uint256 id) external owner(id) {
        _clear(id);
    }

    function fund(address asset, uint256 amount) external {
        bool supported;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) supported = true;
        }
        require(supported, "asset");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        batches.push(Batch(asset, amount, core.transferHead()));
        process(1);
    }

    /// @notice At most maxWork transfer records / funded allocations; callable by anyone.
    function process(uint256 maxWork) public {
        for (uint256 work; work < maxWork; ++work) {
            bool pending = nextBatch < batches.length;
            uint256 boundary = pending ? batches[nextBatch].boundary : core.transferHead();
            if (cursor < boundary) {
                (IStaticsExternalModules.TransferChange[] memory changes, uint256 next) =
                    core.transferChanges(cursor, 1);
                cursor = next;
                _transfer(changes[0]);
            } else if (pending) {
                Batch memory b = batches[nextBatch++];
                if (totalWeight == 0) {
                    zeroStakeRevenue[b.asset] += b.amount;
                } else {
                    uint256 scaled = b.amount * RAY;
                    indexRay[b.asset] += scaled / totalWeight;
                    dustRay[b.asset] += scaled % totalWeight;
                }
            } else {
                break;
            }
        }
    }

    function claim(uint256 id, address asset) external owner(id) returns (uint256 amount) {
        amount = earnedRay[id][asset] / RAY;
        earnedRay[id][asset] %= RAY;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function cleanup(uint256 id) external owner(id) {
        Account storage a = accounts[id];
        require(a.receipts == 0 && a.cash == 0, "occupied");
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            uint256 fractional = earnedRay[id][asset];
            require(fractional < RAY, "revenue");
            // Explicit owner cleanup relinquishes only sub-token fractions.
            dustRay[asset] += fractional;
            earnedRay[id][asset] = 0;
        }
        _clear(id);
        core.detachExternalAccountLeg(id, MODULE, bytes32(0));
        attached[id] = false;
    }

    function pendingRay(uint256 id, address asset) external view returns (uint256) {
        return earnedRay[id][asset] + accounts[id].weight * (indexRay[asset] - checkpoint[id][asset]);
    }

    function _synchronize() private {
        process(100);
        require(nextBatch == batches.length && cursor == core.transferHead(), "backlog");
    }

    function _checkpoint(uint256 id) private {
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            earnedRay[id][asset] += accounts[id].weight * (indexRay[asset] - checkpoint[id][asset]);
            checkpoint[id][asset] = indexRay[asset];
        }
    }

    function _clear(uint256 id) private {
        Account storage a = accounts[id];
        if (a.operatorId != 0) delete operatorAccount[a.operatorId];
        a.operatorId = 0;
        a.multiplier = 10_000;
        _weight(a);
    }

    function _weight(Account storage a) private {
        totalWeight -= a.weight;
        a.weight = a.stake * (a.multiplier == 0 ? 10_000 : a.multiplier) / 10_000;
        totalWeight += a.weight;
    }

    function _transfer(IStaticsExternalModules.TransferChange memory change) private {
        uint256 id;
        if (change.collection == address(core)) id = change.tokenId;
        else if (change.collection == address(operators)) id = operatorAccount[change.tokenId];
        if (id == 0) return;
        Account storage a = accounts[id];
        if (a.operatorId == 0) return;
        _checkpoint(id);
        _clear(id);
    }

    function _attach(uint256 id) private {
        if (attached[id]) return;
        core.attachExternalAccountLeg(id, MODULE, bytes32(0));
        attached[id] = true;
    }
}

/// @dev A module with no reward/activation interface or callback surface.
contract ExternalLifecycleConsumer {
    IStaticsExternalModules public immutable core;
    bytes32 public constant MODULE = keccak256("test.external.lifecycle");
    mapping(uint256 => uint256) public liability;

    constructor(address core_) {
        core = IStaticsExternalModules(core_);
    }

    function open(uint256 id) external {
        require(IERC721(address(core)).ownerOf(id) == msg.sender, "owner");
        ++liability[id];
        core.attachExternalAccountLeg(id, MODULE, bytes32(0));
    }

    function close(uint256 id) external {
        require(IERC721(address(core)).ownerOf(id) == msg.sender, "owner");
        delete liability[id];
        core.detachExternalAccountLeg(id, MODULE, bytes32(0));
    }
}
