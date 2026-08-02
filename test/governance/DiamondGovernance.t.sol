// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {FeeRouterFacet} from "../../src/dollar/periphery/facets/FeeRouterFacet.sol";
import {PairingVaultFacet} from "../../src/dollar/periphery/facets/PairingVaultFacet.sol";

contract VersionFacet {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract DiamondGovernanceTest is Test {
    uint256 internal constant PAUSE_MINT = 1 << 0;
    uint256 internal constant PAUSE_BORROW = 1 << 1;
    uint256 internal constant PAUSE_EXTEND = 1 << 2;
    uint256 internal constant PAUSE_FLASH = 1 << 3;
    uint256 internal constant PAUSE_REDEEM = 1 << 4;
    uint256 internal constant PAUSE_LIQUIDITY = 1 << 5;

    address internal multisig = makeAddr("multisig");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    StaticsDiamond internal diamond;
    StaticsTimelock internal timelock;

    function setUp() public {
        DeployStatics deployer = new DeployStatics();
        (StaticsDollarStackDeployment memory deployment, StaticsTimelock deployedTimelock) = deployer.deploy(
            DeployStatics.Config({
                multisig: multisig,
                guardian: guardian,
                treasury: makeAddr("treasury"),
                stakingToken: address(deployer),
                creationFeeAmount: 1 ether
            })
        );
        diamond = StaticsDiamond(payable(deployment.diamond));
        timelock = deployedTimelock;
    }

    function testExposesStandardLoupeAndOwnership() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        assertEq(loupe.facetAddresses().length, 23);
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), loupe.facetAddresses()[0]);
        assertEq(IERC173(address(diamond)).owner(), address(timelock));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC173).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsGovernance).interfaceId));
    }

    function testUpgradeCannotBypassSevenDayTimelock() public {
        VersionFacet versionFacet = new VersionFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VersionFacet.version.selector;
        IDiamondCut.FacetCut[] memory upgrade = new IDiamondCut.FacetCut[](1);
        upgrade[0] = _cut(address(versionFacet), selectors);
        bytes memory payload = abi.encodeCall(IDiamondCut.diamondCut, (upgrade, address(0), bytes("")));

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, address(this), address(timelock)));
        IDiamondCut(address(diamond)).diamondCut(upgrade, address(0), bytes(""));

        bytes32 salt = keccak256("add version facet");
        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);

        vm.expectRevert();
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);

        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
        assertEq(VersionFacet(address(diamond)).version(), 1);
    }

    function testProposerCanCancelScheduledUpgradeButGuardianCannot() public {
        VersionFacet versionFacet = new VersionFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VersionFacet.version.selector;
        IDiamondCut.FacetCut[] memory upgrade = new IDiamondCut.FacetCut[](1);
        upgrade[0] = _cut(address(versionFacet), selectors);
        bytes memory payload = abi.encodeCall(IDiamondCut.diamondCut, (upgrade, address(0), bytes("")));
        bytes32 salt = keccak256("guardian cancellation");

        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);
        bytes32 operationId = timelock.hashOperation(address(diamond), 0, payload, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(guardian);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        timelock.cancel(operationId);
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(multisig);
        timelock.cancel(operationId);
        assertFalse(timelock.isOperation(operationId));

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(VersionFacet.version.selector), address(0));
    }

    function testGuardianCanStopRiskIncreasingActionsButNotRedemption() public {
        IStaticsGovernance governance = IStaticsGovernance(address(diamond));
        uint256 guardianActions = PAUSE_MINT | PAUSE_BORROW | PAUSE_EXTEND | PAUSE_FLASH | PAUSE_LIQUIDITY;

        vm.prank(guardian);
        governance.pause(guardianActions);
        assertEq(governance.pausedActions(), guardianActions);
        assertTrue(governance.isPaused(PAUSE_MINT));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(GovernanceFacet.InvalidActions.selector, PAUSE_REDEEM));
        governance.pause(PAUSE_REDEEM);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(timelock)));
        governance.unpause(PAUSE_MINT);
    }

    function testTimelockCanPauseAndUnpauseRedemption() public {
        IStaticsGovernance governance = IStaticsGovernance(address(diamond));
        _executeThroughTimelock(abi.encodeCall(IStaticsGovernance.pause, (PAUSE_REDEEM)), "pause redeem");
        assertTrue(governance.isPaused(PAUSE_REDEEM));

        _executeThroughTimelock(abi.encodeCall(IStaticsGovernance.unpause, (PAUSE_REDEEM)), "unpause redeem");
        assertFalse(governance.isPaused(PAUSE_REDEEM));
    }

    function testOnlyGuardianOrTimelockCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GovernanceFacet.NotGuardianOrOwner.selector, stranger));
        IStaticsGovernance(address(diamond)).pause(PAUSE_MINT);
    }

    function testTimelockControlsQuarantineReleaseAndExitOnly() public {
        uint256 basketId = _createBasket();
        IStaticsGovernance governance = IStaticsGovernance(address(diamond));
        IStaticsBasket baskets = IStaticsBasket(address(diamond));
        vm.prank(guardian);
        governance.quarantineBasket(basketId);

        _executeThroughTimelock(
            abi.encodeCall(IStaticsGovernance.releaseBasketQuarantine, (basketId)), "release basket quarantine"
        );
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.Active));

        _executeThroughTimelock(
            abi.encodeCall(IStaticsGovernance.decommissionBasket, (basketId)), "decommission basket"
        );
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.ExitOnly));

        bytes memory payload = abi.encodeCall(IStaticsGovernance.releaseBasketQuarantine, (basketId));
        bytes32 salt = keccak256("reactivate exit-only basket");
        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.ExitOnly));
    }

    function testRejectsRawEtherBecauseConstituentsAreErc20Only() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(diamond).call{value: 1 ether}(bytes(""));
        assertFalse(success);
        assertEq(address(diamond).balance, 0);
    }

    function testTimelockCanGovernItsOwnDelay() public {
        bytes memory payload = abi.encodeCall(TimelockController.updateDelay, (0));
        bytes32 salt = keccak256("reduce delay");
        vm.prank(multisig);
        timelock.schedule(address(timelock), 0, payload, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days);
        timelock.execute(address(timelock), 0, payload, bytes32(0), salt);
        assertEq(timelock.getMinDelay(), 0);
    }

    function testTimelockCanReconfigurePeripheryParametersRepeatedly() public {
        FeeRouterFacet feeRouter = FeeRouterFacet(address(diamond));
        PairingVaultFacet pairingVault = PairingVaultFacet(address(diamond));

        _executeThroughTimelock(abi.encodeCall(FeeRouterFacet.setSplit, (uint16(7_500), uint16(2_500))), "split one");
        _executeThroughTimelock(abi.encodeCall(FeeRouterFacet.setSplit, (uint16(6_500), uint16(3_500))), "split two");
        (uint16 baseBps, uint16 insuranceBps) = feeRouter.splits();
        assertEq(baseBps, 6_500);
        assertEq(insuranceBps, 3_500);

        _executeThroughTimelock(
            abi.encodeCall(PairingVaultFacet.setRedemptionParams, (uint16(75), uint16(8_500))), "redemption one"
        );
        _executeThroughTimelock(
            abi.encodeCall(PairingVaultFacet.setRedemptionParams, (uint16(25), uint16(7_500))), "redemption two"
        );
        (uint16 redemptionFeeBps, uint16 stakerShareBps) = pairingVault.redemptionParams();
        assertEq(redemptionFeeBps, 25);
        assertEq(stakerShareBps, 7_500);
    }

    function testUpgradeEntryPointCanBeRemovedAsTerminalCut() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](1);
        removal[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: selectors
        });
        bytes memory payload = abi.encodeCall(IDiamondCut.diamondCut, (removal, address(0), bytes("")));
        bytes32 salt = keccak256("remove cut");
        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days);
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IDiamondCut.diamondCut.selector), address(0));
    }

    function testOwnershipTransferExecutesThroughTimelock() public {
        _executeThroughTimelock(abi.encodeCall(IERC173.transferOwnership, (multisig)), "transfer ownership");
        assertEq(IERC173(address(diamond)).owner(), multisig);
    }

    function testGovernorCanInheritTimelockProposalRoles() public {
        address governor = makeAddr("governor");
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes memory grantProposer = abi.encodeCall(IAccessControl.grantRole, (proposerRole, governor));
        bytes memory grantCanceller = abi.encodeCall(IAccessControl.grantRole, (cancellerRole, governor));
        bytes32 proposerSalt = keccak256("grant governor proposer");
        bytes32 cancellerSalt = keccak256("grant governor canceller");
        vm.startPrank(multisig);
        timelock.schedule(address(timelock), 0, grantProposer, bytes32(0), proposerSalt, 7 days);
        timelock.schedule(address(timelock), 0, grantCanceller, bytes32(0), cancellerSalt, 7 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        timelock.execute(address(timelock), 0, grantProposer, bytes32(0), proposerSalt);
        timelock.execute(address(timelock), 0, grantCanceller, bytes32(0), cancellerSalt);

        assertTrue(timelock.hasRole(proposerRole, governor));
        assertTrue(timelock.hasRole(cancellerRole, governor));
        assertEq(IERC173(address(diamond)).owner(), address(timelock));

        bytes memory payload = abi.encodeCall(IStaticsGovernance.pause, (PAUSE_MINT));
        vm.prank(governor);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), keccak256("governor proposal"), 7 days);
    }

    function testInterfaceMetadataCanUpdateAtomicallyWithCut() public {
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = 0xdeadbeef;
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        IDiamondCut.FacetCut[] memory emptyCut = new IDiamondCut.FacetCut[](0);
        bytes memory initData = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported));
        bytes memory payload = abi.encodeCall(IDiamondCut.diamondCut, (emptyCut, address(diamond), initData));
        bytes32 salt = keccak256("sync interface");
        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days);
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
        assertTrue(IERC165(address(diamond)).supportsInterface(0xdeadbeef));
    }

    function testInterfaceMetadataCannotUpdateOutsideTimelock() public {
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = 0xdeadbeef;
        bool[] memory supported = new bool[](1);
        supported[0] = true;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, address(timelock)));
        StaticsInterfaceInit(address(diamond)).setInterfaces(interfaceIds, supported);

        assertFalse(IERC165(address(diamond)).supportsInterface(0xdeadbeef));
    }

    function _executeThroughTimelock(bytes memory payload, string memory label) internal {
        bytes32 salt = keccak256(bytes(label));
        vm.prank(multisig);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days);
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);
    }

    function _createBasket() private returns (uint256 basketId) {
        address[] memory assets = new address[](1);
        assets[0] = makeAddr("constituent");
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Governed Basket",
            symbol: "sGOV",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (basketId,) = IStaticsBasket(address(diamond)).createBasket{value: 1 ether}(params);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }
}
