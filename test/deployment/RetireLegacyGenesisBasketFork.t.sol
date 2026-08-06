// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {LegacyBasketRetirementConfig, RetireLegacyGenesisBasket} from "../../script/RetireLegacyGenesisBasket.s.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";

contract RetireLegacyGenesisBasketForkTest is Test {
    uint256 private constant FORK_BLOCK = 96_519_464;
    string private constant CONFIG_PATH = "script/config/robinhood-testnet-legacy-tpa1-retirement.json";

    RetireLegacyGenesisBasket private retirement;
    LegacyBasketRetirementConfig private config;
    TimelockController private timelock;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            vm.skip(true, "ROBINHOOD_TESTNET is not configured");
            return;
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        retirement = new RetireLegacyGenesisBasket();
        config = retirement.loadConfig(CONFIG_PATH);
        timelock = TimelockController(payable(config.timelock));
    }

    function test_quarantineAndAtomicRetirementRecoverProtocolLiquidity() public {
        retirement.validateReadyToQuarantine(config);
        uint256 supplyBefore = IERC20(config.basketToken).totalSupply();
        uint256[] memory treasuryBalancesBefore = _treasuryBalances();

        vm.prank(config.guardian);
        IStaticsGovernance(config.diamond).quarantineBasket(config.basketId);
        assertEq(
            uint8(IStaticsBasket(config.diamond).basketStatus(config.basketId)),
            uint8(IStaticsBasket.BasketStatus.Quarantined)
        );
        retirement.validateReadyToSchedule(config);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = retirement.buildBatch(config);
        uint256 delay = timelock.getMinDelay();
        bytes32 operation = retirement.operationId(config);
        vm.prank(config.guardian);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), config.salt, delay);
        assertTrue(timelock.isOperationPending(operation));

        vm.warp(block.timestamp + delay);
        vm.roll(block.number + 1);
        vm.prank(config.guardian);
        timelock.executeBatch(targets, values, payloads, bytes32(0), config.salt);

        retirement.validateRetired(config);
        assertTrue(timelock.isOperationDone(operation));
        assertLt(IERC20(config.basketToken).totalSupply(), supplyBefore);
        for (uint256 i; i < config.assets.length; ++i) {
            assertGt(IERC20(config.assets[i]).balanceOf(config.treasury), treasuryBalancesBefore[i]);
        }
    }

    function _treasuryBalances() private view returns (uint256[] memory balances) {
        balances = new uint256[](config.assets.length);
        for (uint256 i; i < config.assets.length; ++i) {
            balances[i] = IERC20(config.assets[i]).balanceOf(config.treasury);
        }
    }
}
