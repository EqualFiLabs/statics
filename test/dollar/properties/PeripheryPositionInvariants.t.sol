// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {PairingVaultFacet} from "src/dollar/periphery/facets/PairingVaultFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";

contract PeripheryPositionHandler is Test, IERC1155Receiver, IERC721Receiver {
    uint256 internal constant SERIES_ID = 1;

    CanonicalWETH9 internal immutable weth;
    IStaticsDollarCore internal immutable core;
    StaticsDollarRiskShares internal immutable staticsDollarRisk;
    StaticsDollar internal immutable staticsDollar;
    StakingFacet internal immutable staking;
    PairingVaultFacet internal immutable vault;
    address internal immutable diamond;

    uint256[] internal positions;

    constructor(StaticsDollarStackDeployment memory deployment) {
        weth = CanonicalWETH9(payable(deployment.weth));
        core = IStaticsDollarCore(deployment.core);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staking = StakingFacet(deployment.diamond);
        vault = PairingVaultFacet(deployment.diamond);
        diamond = deployment.diamond;
        staticsDollarRisk.setApprovalForAll(diamond, true);
        staticsDollar.approve(diamond, type(uint256).max);
        weth.approve(diamond, type(uint256).max);
    }

    function depositAndStake(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e12, 1 ether);
        try core.previewDeposit(1, amount) returns (IStaticsDollarCoreTypes.DepositPreview memory preview) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.approve(address(core), amount);
            (, uint256 minted, uint256 shares) =
                core.depositCollateral(1, amount, preview.staticsDollarMinted, preview.sharesMinted, address(this), address(this));
            if (minted == 0 || shares == 0) return;
            positions.push(staking.createAndStakeRiskShares(SERIES_ID, shares, address(this)));
        } catch {}
    }

    function redeem(uint256 rawAmount) external {
        uint256 available = staking.totalRiskLiquidity(SERIES_ID);
        uint256 dollars = staticsDollar.balanceOf(address(this));
        uint256 maximum = available < dollars ? available : dollars;
        if (maximum == 0) return;
        uint256 amount = bound(rawAmount, 1, maximum);
        try vault.redeem(SERIES_ID, amount, 1, 0, block.timestamp, address(this)) {} catch {}
    }

    function unstake(uint256 rawIndex, uint256 rawAmount) external {
        if (positions.length == 0) return;
        uint256 positionId = positions[rawIndex % positions.length];
        uint256 available = staking.riskLiquidity(positionId, SERIES_ID).effectiveShares;
        if (available == 0) return;
        try staking.unstakeRiskShares(positionId, SERIES_ID, bound(rawAmount, 1, available), address(this)) {}
        catch {}
    }

    function claim(uint256 rawIndex) external {
        if (positions.length == 0) return;
        uint256 positionId = positions[rawIndex % positions.length];
        StakingFacet.RiskLiquidityView memory state = staking.riskLiquidity(positionId, SERIES_ID);
        if (state.claimableCollateral == 0 && state.claimableStaticsDollar == 0 && state.claimableStatics == 0) return;
        try staking.claimRiskProceeds(positionId, SERIES_ID, address(this)) {} catch {}
    }

    function fundCanonicalRiskIncentives(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e6, 0.1 ether);
        vm.deal(address(this), address(this).balance + amount * 2);
        weth.deposit{value: amount * 2}();
        try staking.fundRiskCollateralIncentives(SERIES_ID, amount) {} catch {}
        try staking.fundRiskStaticsIncentives(SERIES_ID, amount) {} catch {}
    }

    function aggregateEffective() external view returns (uint256 total) {
        for (uint256 i; i < positions.length; ++i) {
            total += staking.riskLiquidity(positions[i], SERIES_ID).effectiveShares;
        }
    }

    function aggregateClaimableWeth() external view returns (uint256 total) {
        for (uint256 i; i < positions.length; ++i) {
            StakingFacet.RiskLiquidityView memory position = staking.riskLiquidity(positions[i], SERIES_ID);
            total += position.claimableCollateral + position.claimableStatics;
        }
    }

    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC721Receiver).interfaceId;
    }
}

contract PeripheryPositionInvariants is StdInvariant, Test {
    StaticsDollarRiskShares internal staticsDollarRisk;
    StakingFacet internal staking;
    PeripheryPositionHandler internal handler;
    IStaticsCustody internal custody;
    address internal diamond;
    address internal weth;

    function setUp() public {
        StaticsDollarLocalConfig memory config;
        config.owner = address(this);
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        StaticsDollarStackDeployment memory deployment = new DeployStaticsDollar().deployLocal(config);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        staking = StakingFacet(deployment.diamond);
        custody = IStaticsCustody(deployment.diamond);
        diamond = deployment.diamond;
        weth = deployment.weth;
        handler = new PeripheryPositionHandler(deployment);
        targetContract(address(handler));
    }

    function invariant_RiskLiquidityNeverExceedsPhysicalCustody() public view {
        uint256 physical = staticsDollarRisk.balanceOf(diamond, 1);
        uint256 aggregate = handler.aggregateEffective();
        uint256 total = staking.totalRiskLiquidity(1);
        assertLe(aggregate, total);
        assertLe(total, physical);
    }

    function invariant_ClaimableRiskProceedsRemainReservedAndSolvent() public view {
        uint256 reserved = staking.reservedBalance(weth);
        assertLe(handler.aggregateClaimableWeth(), reserved);
        assertEq(custody.reservedByAccount(custody.dollarCustodyAccount(), weth), reserved);
        assertLe(reserved, CanonicalWETH9(payable(weth)).balanceOf(diamond));
    }

    function invariant_RiskLiquidityScaleRemainsLive() public view {
        if (staking.totalRiskLiquidity(1) != 0) {
            assertGt(staking.riskLiquidityScaleRay(1), 0);
        }
    }
}
