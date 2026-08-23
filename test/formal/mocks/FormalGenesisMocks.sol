// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
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

contract FormalDistributorSink {
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
}

contract FormalForceNative {
    constructor(address payable receiver) payable {
        selfdestruct(receiver);
    }
}

abstract contract FormalGenesisEnvironment is Test {
    FormalToken internal statics;
    GenesisActivationRegistry internal registry;
    StaticsGenesisVault internal vault;
    StaticsGenesis internal genesis;
    address internal treasury;

    function _deployGenesis(uint256 epochEnd) internal {
        treasury = makeAddr("formalTreasury");
        statics = new FormalToken("Formal STATICS", "FSTATICS");
        statics.mint(address(this), 1_000_000_000 ether);
        registry = new GenesisActivationRegistry(statics, address(this), address(this), treasury);
        vault = new StaticsGenesisVault(statics, address(this), address(this), epochEnd);
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        genesis = new StaticsGenesis(
            address(vault),
            address(registry),
            renderer,
            address(this),
            treasury,
            "ipfs://formal-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));
        statics.approve(address(vault), type(uint256).max);
    }

    function _acquire(uint256 genesisId, address owner) internal {
        vault.buyGenesis(genesisId, owner);
    }
}
