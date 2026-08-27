// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsGenesis} from "./IStaticsGenesis.sol";
import {IStaticsGenesisVault} from "./IStaticsGenesisVault.sol";

/// @notice Non-upgradeable bootstrap custody and linear vesting interface for treasury Genesis NFTs.
interface IStaticsTreasuryVesting {
    event TreasuryVestingBootstrapped(
        address indexed statics, address indexed genesisVault, address indexed genesis, uint256 vestingStart
    );
    event WithdrawalRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event StaticsSurplusSwept(address indexed recipient, uint256 amount);
    event GenesisReleased(
        address indexed caller,
        address indexed recipient,
        uint256 indexed firstGenesisId,
        uint256 lastGenesisId,
        uint256 count,
        uint256 totalReleased
    );

    /// @notice Funds the Genesis vault, binds the launch assets, and starts Genesis NFT vesting once.
    /// @param statics STATICS token address.
    /// @param genesisVault Genesis vault holding the initial collection inventory.
    /// @param genesis Genesis collection holding the treasury NFTs.
    function finalizeBootstrap(address statics, address genesisVault, address genesis) external;
    /// @notice Sweeps accidentally retained or donated STATICS after bootstrap.
    function sweepStaticsSurplus() external returns (uint256 amount);
    /// @notice Permissionlessly releases up to 50 currently vested Genesis NFTs.
    /// @param maxCount Maximum number of NFTs to release in this call.
    function releaseGenesis(uint256 maxCount) external returns (uint256 count);
    /// @notice Changes the recipient of future Genesis releases and STATICS surplus recovery.
    /// @param newRecipient New ERC-20/ERC-721-compatible recipient.
    function setWithdrawalRecipient(address newRecipient) external;

    function statics() external view returns (IERC20);
    function genesisVault() external view returns (IStaticsGenesisVault);
    function genesis() external view returns (IStaticsGenesis);
    function recipientAdmin() external view returns (address);
    function withdrawalRecipient() external view returns (address);
    function bootstrapper() external view returns (address);
    function vestingStart() external view returns (uint256);
    function vestingEnd() external view returns (uint256);
    function releasedGenesis() external view returns (uint256);
    function vestedGenesisAt(uint256 timestamp) external view returns (uint256);
    function releasableGenesis() external view returns (uint256);
    function nextGenesisId() external view returns (uint256);
    function vestingComplete() external view returns (bool);
}
