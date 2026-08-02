// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";

import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {StakingFacet} from "../src/dollar/periphery/facets/StakingFacet.sol";
import {BasketCollateralFacet} from "../src/facets/BasketCollateralFacet.sol";
import {BasketFacet} from "../src/facets/BasketFacet.sol";
import {GlobalRewardsFacet} from "../src/facets/GlobalRewardsFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketCollateral} from "../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionFees} from "../src/interfaces/IStaticsPosition.sol";
import {IStaticsDollarRiskLiquidity} from "../src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {PositionNFTFacet} from "../src/position/PositionNFTFacet.sol";

struct PositionCreationFeeUpgrade {
    address positionFacet;
    address basketFacet;
    address basketCollateralFacet;
    address globalRewardsFacet;
    address stakingFacet;
    uint256 feeAmount;
}

/// @notice Deploys and timelocks the clean-break payable Position creation surface.
contract UpgradePositionCreationFee is Script {
    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidFacet(address facet);
    error UpgradeVerificationFailed();

    event PositionCreationFeeUpgradePrepared(
        bytes32 indexed operationId, address indexed diamond, address indexed timelock, uint256 feeAmount, uint256 delay
    );

    function runDeployFacets() external returns (PositionCreationFeeUpgrade memory upgrade) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 feeAmount = vm.envUint("POSITION_CREATION_FEE_AMOUNT");
        vm.startBroadcast(privateKey);
        upgrade = deployFacets(feeAmount);
        vm.stopBroadcast();
        _log(upgrade);
    }

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_POSITION_FEE_TIMELOCK_SALT");
        PositionCreationFeeUpgrade memory upgrade = _loadUpgrade();
        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, upgrade, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_POSITION_FEE_TIMELOCK_SALT");
        PositionCreationFeeUpgrade memory upgrade = _loadUpgrade();
        vm.startBroadcast(privateKey);
        execute(diamond, upgrade, salt);
        vm.stopBroadcast();
    }

    function deployFacets(uint256 feeAmount) public returns (PositionCreationFeeUpgrade memory upgrade) {
        upgrade = PositionCreationFeeUpgrade({
            positionFacet: address(new PositionNFTFacet()),
            basketFacet: address(new BasketFacet()),
            basketCollateralFacet: address(new BasketCollateralFacet()),
            globalRewardsFacet: address(new GlobalRewardsFacet()),
            stakingFacet: address(new StakingFacet()),
            feeAmount: feeAmount
        });
    }

    function schedule(address diamond, PositionCreationFeeUpgrade memory upgrade, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateContracts(diamond, upgrade);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, upgrade);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit PositionCreationFeeUpgradePrepared(operationId, diamond, address(timelock), upgrade.feeAmount, delay);
    }

    function execute(address diamond, PositionCreationFeeUpgrade memory upgrade, bytes32 salt) public {
        TimelockController timelock = _validateContracts(diamond, upgrade);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, upgrade);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validateInstalled(diamond, upgrade);
    }

    function buildBatch(address diamond, PositionCreationFeeUpgrade memory upgrade)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](3);
        targets[0] = diamond;
        targets[1] = diamond;
        targets[2] = diamond;
        values = new uint256[](3);
        payloads = new bytes[](3);
        payloads[0] = abi.encodeCall(IDiamondCut.diamondCut, (_cuts(upgrade), address(0), bytes("")));
        payloads[1] = abi.encodeCall(IStaticsPositionFees.setPositionCreationFee, (upgrade.feeAmount));
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = type(IStaticsPositionFees).interfaceId;
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        payloads[2] = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported));
    }

    function _cuts(PositionCreationFeeUpgrade memory upgrade)
        private
        pure
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](6);
        bytes4[] memory allPositionSelectors = StaticsSelectors.position();
        bytes4[] memory existingPositionSelectors = new bytes4[](20);
        for (uint256 i; i < 20; ++i) {
            existingPositionSelectors[i] = allPositionSelectors[i];
        }
        cuts[0] = _cut(upgrade.positionFacet, IDiamondCut.FacetCutAction.Replace, existingPositionSelectors);
        bytes4[] memory feeSelectors = new bytes4[](2);
        feeSelectors[0] = IStaticsPositionFees.setPositionCreationFee.selector;
        feeSelectors[1] = IStaticsPositionFees.positionCreationFee.selector;
        cuts[1] = _cut(upgrade.positionFacet, IDiamondCut.FacetCutAction.Add, feeSelectors);
        cuts[2] =
            _singleReplacement(upgrade.basketFacet, IStaticsBasketCollateral.createAndMintBasketCollateral.selector);
        cuts[3] = _singleReplacement(
            upgrade.basketCollateralFacet, IStaticsBasketCollateral.createAndDepositBasketCollateral.selector
        );
        cuts[4] = _singleReplacement(upgrade.globalRewardsFacet, IStaticsGlobalRewards.createAndStake.selector);
        cuts[5] =
            _singleReplacement(upgrade.stakingFacet, IStaticsDollarRiskLiquidity.createAndStakeRiskShares.selector);
    }

    function _singleReplacement(address facet, bytes4 selector) private pure returns (IDiamondCut.FacetCut memory cut) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        return _cut(facet, IDiamondCut.FacetCutAction.Replace, selectors);
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        private
        pure
        returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }

    function _validateContracts(address diamond, PositionCreationFeeUpgrade memory upgrade)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));
        _requireFacet(upgrade.positionFacet);
        _requireFacet(upgrade.basketFacet);
        _requireFacet(upgrade.basketCollateralFacet);
        _requireFacet(upgrade.globalRewardsFacet);
        _requireFacet(upgrade.stakingFacet);
    }

    function _validateInstalled(address diamond, PositionCreationFeeUpgrade memory upgrade) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        if (
            loupe.facetAddress(IStaticsPositionFees.positionCreationFee.selector) != upgrade.positionFacet
                || loupe.facetAddress(IStaticsBasketCollateral.createAndMintBasketCollateral.selector)
                    != upgrade.basketFacet
                || loupe.facetAddress(IStaticsBasketCollateral.createAndDepositBasketCollateral.selector)
                    != upgrade.basketCollateralFacet
                || loupe.facetAddress(IStaticsGlobalRewards.createAndStake.selector) != upgrade.globalRewardsFacet
                || loupe.facetAddress(IStaticsDollarRiskLiquidity.createAndStakeRiskShares.selector)
                    != upgrade.stakingFacet || IStaticsPositionFees(diamond).positionCreationFee() != upgrade.feeAmount
                || !IERC165(diamond).supportsInterface(type(IStaticsPositionFees).interfaceId)
        ) revert UpgradeVerificationFailed();
    }

    function _requireFacet(address facet) private view {
        if (facet.code.length == 0) revert InvalidFacet(facet);
    }

    function _loadUpgrade() private view returns (PositionCreationFeeUpgrade memory upgrade) {
        upgrade = PositionCreationFeeUpgrade({
            positionFacet: vm.envAddress("STATICS_POSITION_FACET_ADDRESS"),
            basketFacet: vm.envAddress("STATICS_BASKET_FACET_ADDRESS"),
            basketCollateralFacet: vm.envAddress("STATICS_BASKET_COLLATERAL_FACET_ADDRESS"),
            globalRewardsFacet: vm.envAddress("STATICS_GLOBAL_REWARDS_FACET_ADDRESS"),
            stakingFacet: vm.envAddress("STATICS_DOLLAR_STAKING_FACET_ADDRESS"),
            feeAmount: vm.envUint("POSITION_CREATION_FEE_AMOUNT")
        });
    }

    function _log(PositionCreationFeeUpgrade memory upgrade) private pure {
        console2.log("STATICS_POSITION_FACET_ADDRESS", upgrade.positionFacet);
        console2.log("STATICS_BASKET_FACET_ADDRESS", upgrade.basketFacet);
        console2.log("STATICS_BASKET_COLLATERAL_FACET_ADDRESS", upgrade.basketCollateralFacet);
        console2.log("STATICS_GLOBAL_REWARDS_FACET_ADDRESS", upgrade.globalRewardsFacet);
        console2.log("STATICS_DOLLAR_STAKING_FACET_ADDRESS", upgrade.stakingFacet);
    }
}
