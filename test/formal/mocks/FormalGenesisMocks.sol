// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
import {StaticsTreasuryVesting} from "../../../src/genesis/StaticsTreasuryVesting.sol";
import {IStaticsGenesisProtocol} from "../../../src/interfaces/IStaticsGenesis.sol";
import {GenesisCreditConfig} from "../../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsAvatarSVG} from "../../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";

contract FormalToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract FormalWrappedNative is FormalToken {
    constructor() FormalToken("Formal Wrapped Native", "FWETH") {}

    receive() external payable {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "native transfer failed");
    }
}

contract FormalFeeSource {
    IERC20 public statics;
    IERC20 public numeraire;
    address public beneficiary;
    uint256 public pendingStatics;
    uint256 public pendingNumeraire;

    function configure(IERC20 statics_, IERC20 numeraire_, address beneficiary_) external {
        statics = statics_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function queue(uint256 staticsAmount, uint256 numeraireAmount) external {
        require(staticsAmount <= type(uint128).max && numeraireAmount <= type(uint128).max, "amount too large");
        pendingStatics += staticsAmount;
        pendingNumeraire += numeraireAmount;
    }

    function collectFees(bytes32) external returns (uint128 fees0, uint128 fees1) {
        uint256 staticsAmount = pendingStatics;
        uint256 numeraireAmount = pendingNumeraire;
        pendingStatics = 0;
        pendingNumeraire = 0;
        if (staticsAmount != 0) require(statics.transfer(msg.sender, staticsAmount), "statics transfer failed");
        if (numeraireAmount != 0) {
            require(numeraire.transfer(msg.sender, numeraireAmount), "numeraire transfer failed");
        }
        fees0 = uint128(staticsAmount);
        fees1 = uint128(numeraireAmount);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        address staticsAddress = address(statics);
        address numeraireAddress = address(numeraire);
        (currency0, currency1) =
            staticsAddress < numeraireAddress ? (staticsAddress, numeraireAddress) : (numeraireAddress, staticsAddress);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract FormalReserveVault {
    address public immutable statics;
    uint256 public reserve;

    constructor(address statics_) {
        statics = statics_;
    }

    function donate() external payable {
        reserve += msg.value;
    }
}

contract FormalCreditFeeReceiver {
    address public immutable statics;

    constructor(address statics_) {
        statics = statics_;
    }
}

contract FormalBootstrapVault {
    IERC20 public immutable statics;
    bool public finalized;

    constructor(IERC20 statics_) {
        statics = statics_;
    }

    function finalizeGenesisCollection(address) external {
        finalized = true;
    }
}

contract FormalBootstrapGenesis {
    uint256 public constant COLLECTION_SIZE = 5_555;
    uint256 public constant mintedSupply = COLLECTION_SIZE;
    address public immutable vault;
    address public immutable treasuryVesting;
    address public releaseRecipient;
    uint256 public released;

    constructor(address vault_, address treasuryVesting_) {
        vault = vault_;
        treasuryVesting = treasuryVesting_;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == vault) return 5_000;
        if (owner == treasuryVesting) return 555 - released;
        if (owner == releaseRecipient) return released;
        return 0;
    }

    function ownerOf(uint256 genesisId) external view returns (address) {
        require(genesisId >= 1 && genesisId <= COLLECTION_SIZE, "invalid Genesis");
        if (genesisId < 5_001) return vault;
        return genesisId < 5_001 + released ? releaseRecipient : treasuryVesting;
    }

    function safeTransferFrom(address from, address to, uint256 genesisId) external {
        require(msg.sender == treasuryVesting, "only vesting");
        require(from == treasuryVesting && to != address(0), "invalid transfer");
        require(genesisId == 5_001 + released, "nonsequential release");
        if (released == 0) releaseRecipient = to;
        else require(to == releaseRecipient, "recipient changed during batch");
        ++released;
    }
}

contract FormalDistributorSink {
    address public immutable genesisRecoveryVault;
    address public immutable genesisRecoveryAsset;

    constructor(address genesisRecoveryVault_, address genesisRecoveryAsset_) {
        genesisRecoveryVault = genesisRecoveryVault_;
        genesisRecoveryAsset = genesisRecoveryAsset_;
    }

    function genesisRecoveryReady() external pure returns (bool) {
        return true;
    }

    function migratePendingGenesisRecovery(address) external pure returns (uint256 amount) {
        return 0;
    }

    function accept(StaticsFeeReceiver receiver) external {
        receiver.acceptDistributor();
    }

    function claim(StaticsFeeReceiver receiver, address asset, address recipient) external returns (uint256) {
        return receiver.claimDistributorFees(asset, recipient);
    }
}

contract FormalGenesisProtocol {
    address public immutable genesisCollection;

    constructor(address genesisCollection_) {
        genesisCollection = genesisCollection_;
    }

    function linkedPosition(uint256) external pure returns (uint256) {
        return 0;
    }

    function genesisRecoveryCallback() external pure returns (bytes4 acknowledgement) {
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }

    function onGenesisRecovery(uint256, address) external pure returns (bytes4 acknowledgement) {
        return IStaticsGenesisProtocol.onGenesisRecovery.selector;
    }
}

abstract contract FormalGenesisEnvironment is Test {
    FormalToken internal statics;
    GenesisActivationRegistry internal registry;
    StaticsGenesisVault internal vault;
    StaticsGenesis internal genesis;
    StaticsTreasuryVesting internal vesting;
    address internal treasury;

    function _deployGenesis(uint256 epochEnd) internal {
        treasury = makeAddr("formalTreasury");
        statics = new FormalToken("Formal STATICS", "FSTATICS");
        vesting = new StaticsTreasuryVesting(address(this), address(this), treasury);
        statics.mint(address(vesting), 200_000_000 ether);
        statics.mint(makeAddr("formalDopplerInventory"), 800_000_000 ether);
        registry = new GenesisActivationRegistry(statics, address(this), address(this), treasury);
        FormalCreditFeeReceiver feeReceiver = new FormalCreditFeeReceiver(address(statics));
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(vesting), address(this), epochEnd, creditConfig);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(
            address(vault),
            address(vesting),
            address(registry),
            renderer,
            address(this),
            treasury,
            "ipfs://formal-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vesting.finalizeBootstrap(address(statics), address(vault), address(genesis));
        statics.mint(address(this), 2_000_000 ether);
        statics.approve(address(vault), type(uint256).max);
    }

    function _acquire(uint256 genesisId, address owner) internal {
        uint256 requiredNative = vault.quoteGenesisPurchase().requiredNative;
        vm.deal(address(this), address(this).balance + requiredNative);
        vault.buyGenesis{value: requiredNative}(genesisId, owner);
    }
}
