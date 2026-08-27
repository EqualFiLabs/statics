// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsGenesis} from "../interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisVault} from "../interfaces/IStaticsGenesisVault.sol";
import {IStaticsTreasuryVesting} from "../interfaces/IStaticsTreasuryVesting.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice Non-upgradeable launch custody for the protocol STATICS allocation and Genesis reserve.
/// @dev The withdrawal recipient is mutable only through recipientAdmin; vesting terms and
///      fixed principal amounts are immutable after bootstrap.
contract StaticsTreasuryVesting is IStaticsTreasuryVesting, ReentrancyGuard {
    using LibExactAssetTransfer for IERC20;

    uint256 public constant STATICS_SUPPLY = 1_000_000_000 ether;
    uint256 public constant PROTOCOL_ALLOCATION = 200_000_000 ether;
    uint256 public constant GENESIS_BACKING_COMMITMENT = 99_900_000 ether;
    uint256 public constant STATICS_VESTING_PRINCIPAL = 100_100_000 ether;
    uint256 public constant GENESIS_VESTING_PRINCIPAL = 555;
    uint256 public constant FIRST_GENESIS_ID = 5_001;
    uint256 public constant LAST_GENESIS_ID = 5_555;
    uint256 public constant VESTING_DURATION = 60 days;
    uint256 public constant MAX_GENESIS_RELEASE_BATCH = 50;

    IERC20 public override statics;
    IStaticsGenesisVault public override genesisVault;
    IStaticsGenesis public override genesis;
    address public immutable override recipientAdmin;
    address public override withdrawalRecipient;
    address public override bootstrapper;
    uint256 public override vestingStart;
    uint256 public override releasedStatics;
    uint256 public override releasedGenesis;

    error InvalidBootstrapper();
    error InvalidRecipientAdmin();
    error InvalidWithdrawalRecipient(address recipient);
    error UnauthorizedBootstrapper(address caller);
    error UnauthorizedRecipientAdmin(address caller);
    error AlreadyBootstrapped();
    error NotBootstrapped();
    error InvalidStaticsToken();
    error InvalidGenesisVault();
    error InvalidGenesisCollection();
    error InvalidSupply(uint256 actual, uint256 expected);
    error InsufficientProtocolAllocation(uint256 actual, uint256 required);
    error InvalidVestingCustody(uint256 actual, uint256 expected);
    error InvalidBatchSize();
    error NothingToRelease();
    error VestingNotComplete();
    error NothingToSweep();

    constructor(address bootstrapper_, address recipientAdmin_, address withdrawalRecipient_) {
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        if (recipientAdmin_ == address(0) || recipientAdmin_ == address(this)) revert InvalidRecipientAdmin();
        if (withdrawalRecipient_ == address(0) || withdrawalRecipient_ == address(this)) {
            revert InvalidWithdrawalRecipient(withdrawalRecipient_);
        }
        bootstrapper = bootstrapper_;
        recipientAdmin = recipientAdmin_;
        withdrawalRecipient = withdrawalRecipient_;
    }

    /// @inheritdoc IStaticsTreasuryVesting
    function finalizeBootstrap(address statics_, address genesisVault_, address genesis_)
        external
        override
        nonReentrant
    {
        if (msg.sender != bootstrapper) revert UnauthorizedBootstrapper(msg.sender);
        if (vestingStart != 0) revert AlreadyBootstrapped();
        if (statics_ == address(0) || statics_.code.length == 0) revert InvalidStaticsToken();
        if (genesisVault_ == address(0) || genesisVault_.code.length == 0) revert InvalidGenesisVault();
        if (genesis_ == address(0) || genesis_.code.length == 0) revert InvalidGenesisCollection();

        IERC20 staticsToken = IERC20(statics_);
        IStaticsGenesisVault vault = IStaticsGenesisVault(genesisVault_);
        IStaticsGenesis collection = IStaticsGenesis(genesis_);
        uint256 supply = staticsToken.totalSupply();
        if (supply != STATICS_SUPPLY) revert InvalidSupply(supply, STATICS_SUPPLY);
        if (
            address(vault.statics()) != statics_ || collection.vault() != genesisVault_
                || collection.treasuryVesting() != address(this) || collection.COLLECTION_SIZE() != LAST_GENESIS_ID
                || collection.mintedSupply() != LAST_GENESIS_ID
                || collection.balanceOf(genesisVault_) != FIRST_GENESIS_ID - 1
                || collection.balanceOf(address(this)) != GENESIS_VESTING_PRINCIPAL
                || collection.ownerOf(FIRST_GENESIS_ID) != address(this)
                || collection.ownerOf(LAST_GENESIS_ID) != address(this)
        ) revert InvalidGenesisCollection();

        uint256 balance = staticsToken.balanceOf(address(this));
        if (balance < PROTOCOL_ALLOCATION) revert InsufficientProtocolAllocation(balance, PROTOCOL_ALLOCATION);

        statics = staticsToken;
        genesisVault = vault;
        genesis = collection;
        vestingStart = block.timestamp;
        delete bootstrapper;

        staticsToken.pushExact(genesisVault_, GENESIS_BACKING_COMMITMENT);
        vault.finalizeGenesisCollection(genesis_);

        uint256 vestingCustody = staticsToken.balanceOf(address(this));
        if (vestingCustody < STATICS_VESTING_PRINCIPAL) {
            revert InvalidVestingCustody(vestingCustody, STATICS_VESTING_PRINCIPAL);
        }
        emit TreasuryVestingBootstrapped(statics_, genesisVault_, genesis_, block.timestamp);
    }

    /// @inheritdoc IStaticsTreasuryVesting
    function releaseStatics() external override nonReentrant returns (uint256 amount) {
        _requireBootstrapped();
        amount = releasableStatics();
        if (amount == 0) revert NothingToRelease();
        releasedStatics += amount;
        address recipient = withdrawalRecipient;
        statics.pushExact(recipient, amount);
        emit StaticsReleased(msg.sender, recipient, amount, releasedStatics);
    }

    /// @inheritdoc IStaticsTreasuryVesting
    function sweepStaticsSurplus() external override nonReentrant returns (uint256 amount) {
        if (msg.sender != recipientAdmin) revert UnauthorizedRecipientAdmin(msg.sender);
        if (releasedStatics != STATICS_VESTING_PRINCIPAL) revert VestingNotComplete();
        amount = statics.balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        address recipient = withdrawalRecipient;
        statics.pushExact(recipient, amount);
        emit StaticsSurplusSwept(recipient, amount);
    }

    /// @inheritdoc IStaticsTreasuryVesting
    function releaseGenesis(uint256 maxCount) external override nonReentrant returns (uint256 count) {
        _requireBootstrapped();
        if (maxCount == 0) revert InvalidBatchSize();
        count = Math.min(Math.min(maxCount, MAX_GENESIS_RELEASE_BATCH), releasableGenesis());
        if (count == 0) revert NothingToRelease();

        uint256 previousReleased = releasedGenesis;
        uint256 firstGenesisId = FIRST_GENESIS_ID + previousReleased;
        uint256 lastGenesisId = firstGenesisId + count - 1;
        releasedGenesis = previousReleased + count;
        address recipient = withdrawalRecipient;
        for (uint256 genesisId = firstGenesisId; genesisId <= lastGenesisId; ++genesisId) {
            genesis.safeTransferFrom(address(this), recipient, genesisId);
        }
        emit GenesisReleased(msg.sender, recipient, firstGenesisId, lastGenesisId, count, releasedGenesis);
    }

    /// @inheritdoc IStaticsTreasuryVesting
    function setWithdrawalRecipient(address newRecipient) external override {
        if (msg.sender != recipientAdmin) revert UnauthorizedRecipientAdmin(msg.sender);
        if (newRecipient == address(0) || newRecipient == address(this)) {
            revert InvalidWithdrawalRecipient(newRecipient);
        }
        address previousRecipient = withdrawalRecipient;
        withdrawalRecipient = newRecipient;
        emit WithdrawalRecipientUpdated(previousRecipient, newRecipient);
    }

    function vestingEnd() external view override returns (uint256) {
        uint256 start = vestingStart;
        return start == 0 ? 0 : start + VESTING_DURATION;
    }

    function vestedStaticsAt(uint256 timestamp) public view override returns (uint256) {
        return _vestedAt(STATICS_VESTING_PRINCIPAL, timestamp);
    }

    function vestedGenesisAt(uint256 timestamp) public view override returns (uint256) {
        return _vestedAt(GENESIS_VESTING_PRINCIPAL, timestamp);
    }

    function releasableStatics() public view override returns (uint256) {
        return vestedStaticsAt(block.timestamp) - releasedStatics;
    }

    function releasableGenesis() public view override returns (uint256) {
        return vestedGenesisAt(block.timestamp) - releasedGenesis;
    }

    function nextGenesisId() external view override returns (uint256) {
        return FIRST_GENESIS_ID + releasedGenesis;
    }

    function vestingComplete() external view override returns (bool) {
        return releasedStatics == STATICS_VESTING_PRINCIPAL && releasedGenesis == GENESIS_VESTING_PRINCIPAL;
    }

    function _vestedAt(uint256 principal, uint256 timestamp) private view returns (uint256) {
        uint256 start = vestingStart;
        if (start == 0 || timestamp <= start) return 0;
        uint256 elapsed = timestamp - start;
        if (elapsed >= VESTING_DURATION) return principal;
        return Math.mulDiv(principal, elapsed, VESTING_DURATION);
    }

    function _requireBootstrapped() private view {
        if (vestingStart == 0) revert NotBootstrapped();
    }
}
