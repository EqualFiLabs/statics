// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {StaticsDiamond} from "../../src/diamond/StaticsDiamond.sol";
import {StaticsProtocolInit} from "../../src/diamond/StaticsProtocolInit.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {BasketCollateralFacet} from "../../src/facets/BasketCollateralFacet.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {GenesisFacet} from "../../src/facets/GenesisFacet.sol";
import {ProtocolRevenueFacet} from "../../src/facets/ProtocolRevenueFacet.sol";
import {LiquidityRewardsFacet} from "../../src/facets/LiquidityRewardsFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {PositionPortfolioFacet} from "../../src/facets/PositionPortfolioFacet.sol";
import {ProtocolPoolFacet} from "../../src/facets/ProtocolPoolFacet.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLaunchLiquidityManager} from "../mocks/MockLaunchLiquidityManager.sol";

contract StaticsTestDeployer {
    function deploy(address owner, address guardian, address treasury, address stakingToken)
        external
        returns (StaticsDiamond diamond)
    {
        StaticsGenesisRenderer renderer = new StaticsGenesisRenderer(new StaticsAvatarSVG());
        StaticsGenesis genesisCollection = new StaticsGenesis(treasury, renderer);
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](20);
        cut[0] = _cut(address(new DiamondCutFacet()), StaticsSelectors.diamondCut());
        cut[1] = _cut(address(new DiamondLoupeFacet()), StaticsSelectors.diamondLoupe());
        cut[2] = _cut(address(new OwnershipFacet()), StaticsSelectors.ownership());
        cut[3] = _cut(address(new GovernanceFacet()), StaticsSelectors.governance());
        cut[4] = _cut(address(new PositionNFTFacet()), StaticsSelectors.position());
        cut[5] = _cut(address(new CustodyFacet()), StaticsSelectors.custody());
        cut[6] = _cut(address(new BasketFacet()), StaticsSelectors.basket());
        cut[7] = _cut(address(new BasketAdminFacet()), StaticsSelectors.basketAdmin());
        cut[8] = _cut(address(new LendingFacet()), StaticsSelectors.lending());
        cut[9] = _cut(address(new FlashLoanFacet()), StaticsSelectors.flashLoan());
        cut[10] = _cut(address(new BasketCollateralFacet()), StaticsSelectors.basketCollateral());
        cut[11] = _cut(address(new BasketLiquidityFacet()), StaticsSelectors.basketLiquidity());
        cut[12] = _cut(address(new BorrowLiquidityFacet()), StaticsSelectors.borrowLiquidity());
        cut[13] = _cut(address(new GlobalRewardsFacet()), StaticsSelectors.globalRewards());
        cut[14] = _cut(address(new LiquidityRewardsFacet()), StaticsSelectors.liquidityRewards());
        cut[15] = _cut(address(new BasketRewardsFacet()), StaticsSelectors.basketRewards());
        cut[16] = _cut(address(new PositionPortfolioFacet()), StaticsSelectors.positionPortfolio());
        cut[17] = _cut(address(new ProtocolPoolFacet()), StaticsSelectors.protocolPools());
        cut[18] = _cut(address(new GenesisFacet()), StaticsSelectors.genesis());
        cut[19] = _cut(address(new ProtocolRevenueFacet()), StaticsSelectors.protocolRevenue());
        StaticsProtocolInit init = new StaticsProtocolInit();
        diamond = new StaticsDiamond(
            owner,
            cut,
            address(init),
            abi.encodeCall(
                StaticsProtocolInit.initialize,
                (guardian, treasury, stakingToken, address(genesisCollection), address(0), 1 ether, 0)
            ),
            address(0)
        );
        genesisCollection.bindProtocol(address(diamond));
    }

    function _cut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }
}

abstract contract StaticsTestBase is Test {
    uint160 internal constant DEFAULT_LAUNCH_SQRT_PRICE = 1 << 96;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    StaticsDiamond internal diamond;
    IStaticsBasket internal baskets;
    IStaticsBasketAdmin internal basketAdmin;
    IStaticsBasketCollateral internal basketCollateral;
    IStaticsBasketRewards internal basketRewards;
    IStaticsGlobalRewards internal globalRewards;
    IStaticsBasketLiquidity internal basketLiquidity;
    IStaticsCustody internal custody;
    IStaticsGovernance internal governance;
    IStaticsLending internal lending;
    IStaticsFlashLoan internal flashLoans;
    IStaticsPositionPortfolio internal positionPortfolio;
    MockERC20 internal assetA;
    MockERC20 internal assetB;
    MockERC20 internal stakingAsset;
    IPoolManager private _localPoolManager;
    StaticsSwapFeeHook private _localSwapFeeHook;

    function setUp() public virtual {
        assetA = new MockERC20("Asset A", "A", 18);
        assetB = new MockERC20("Asset B", "B", 18);
        stakingAsset = new MockERC20("Statics", "STAT", 18);

        diamond = new StaticsTestDeployer().deploy(address(this), guardian, treasury, address(stakingAsset));

        baskets = IStaticsBasket(address(diamond));
        basketAdmin = IStaticsBasketAdmin(address(diamond));
        basketCollateral = IStaticsBasketCollateral(address(diamond));
        basketRewards = IStaticsBasketRewards(address(diamond));
        globalRewards = IStaticsGlobalRewards(address(diamond));
        basketLiquidity = IStaticsBasketLiquidity(address(diamond));
        custody = IStaticsCustody(address(diamond));
        governance = IStaticsGovernance(address(diamond));
        lending = IStaticsLending(address(diamond));
        flashLoans = IStaticsFlashLoan(address(diamond));
        positionPortfolio = IStaticsPositionPortfolio(address(diamond));
        vm.deal(alice, 100 ether);

        if (_installLocalLiquidityIntegration()) {
            _localPoolManager =
                IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
            _localSwapFeeHook = _deployLocalHook(_localPoolManager);
            basketLiquidity.installCanonicalPoolIntegration(address(_localPoolManager), address(_localSwapFeeHook));
            if (_installDefaultLiquidityManager()) {
                basketLiquidity.installLiquidityManager(
                    address(new MockLaunchLiquidityManager(address(diamond), address(_localPoolManager)))
                );
            }
        }
    }

    function _createDefaultBasket(uint256 mintFeeShares, uint256 redemptionFeeShares)
        internal
        returns (uint256 basketId, address token)
    {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(mintFeeShares, redemptionFeeShares);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        (basketId, token) = baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);
        deal(address(assetA), alice, 0);
        deal(address(assetB), alice, 0);
    }

    function _defaultParams(uint256 mintFeeShares, uint256 redemptionFeeShares)
        internal
        view
        returns (IStaticsBasket.CreateBasketParams memory params)
    {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 5 ether;
        IStaticsBasket.FeeTier[] memory mintFeeTiers = _singleFeeTier(mintFeeShares);
        IStaticsBasket.FeeTier[] memory redemptionFeeTiers = _singleFeeTier(redemptionFeeShares);
        params = IStaticsBasket.CreateBasketParams({
            name: "Static A-B",
            symbol: "sAB",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: mintFeeTiers,
            redemptionFeeTiers: redemptionFeeTiers,
            flashFeeBps: 5,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
    }

    function _singleFeeTier(uint256 feeShares) internal pure returns (IStaticsBasket.FeeTier[] memory tiers) {
        tiers = new IStaticsBasket.FeeTier[](1);
        tiers[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: feeShares});
    }

    function _fundAndApprove(address user, uint256 amountA, uint256 amountB) internal {
        assetA.mint(user, amountA);
        assetB.mint(user, amountB);
        vm.startPrank(user);
        assetA.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }

    function _fundDefaultLaunch(address[] memory assets, address creator)
        internal
        returns (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums)
    {
        uint256 length = assets.length;
        pools = new IStaticsBasket.PoolLaunchParams[](length);
        maximums = new uint256[](length);
        vm.startPrank(creator);
        for (uint256 i; i < length; ++i) {
            MockERC20(assets[i]).mint(creator, 1_000_000 ether);
            IERC20(assets[i]).approve(address(diamond), 1_000_000 ether);
            pools[i] = IStaticsBasket.PoolLaunchParams({
                sqrtPriceAssetPerBasketX96: DEFAULT_LAUNCH_SQRT_PRICE, pairedAssetAmount: 1 ether
            });
            maximums[i] = 1_000_000 ether;
        }
        vm.stopPrank();
    }

    function _defaultPoolLaunchParams(uint256 length)
        internal
        pure
        returns (IStaticsBasket.PoolLaunchParams[] memory pools)
    {
        pools = new IStaticsBasket.PoolLaunchParams[](length);
        for (uint256 i; i < length; ++i) {
            pools[i] = IStaticsBasket.PoolLaunchParams({
                sqrtPriceAssetPerBasketX96: DEFAULT_LAUNCH_SQRT_PRICE, pairedAssetAmount: 1 ether
            });
        }
    }

    function _defaultLaunchMaximums(uint256 length) internal pure returns (uint256[] memory maximums) {
        maximums = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            maximums[i] = 1_000_000 ether;
        }
    }

    function _launchBasket(IStaticsBasket.CreateBasketParams memory params, address creator, uint256 value)
        internal
        returns (uint256 basketId, address token)
    {
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, creator);
        vm.prank(creator);
        return baskets.createBasket{value: value}(params, pools, maximums, type(uint256).max);
    }

    function _launchBasketWithMinimalSeed(
        IStaticsBasket.CreateBasketParams memory params,
        address creator,
        uint256 value
    ) internal returns (uint256 basketId, address token) {
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, creator);
        for (uint256 i; i < pools.length; ++i) {
            pools[i].pairedAssetAmount = 1;
        }
        vm.prank(creator);
        return baskets.createBasket{value: value}(params, pools, maximums, type(uint256).max);
    }

    function _localLiquidity() internal view returns (IPoolManager manager, StaticsSwapFeeHook hook) {
        return (_localPoolManager, _localSwapFeeHook);
    }

    function _installLocalLiquidityIntegration() internal pure virtual returns (bool) {
        return true;
    }

    function _installDefaultLiquidityManager() internal pure virtual returns (bool) {
        return true;
    }

    function _deployLocalHook(IPoolManager manager) private returns (StaticsSwapFeeHook deployed) {
        bytes memory constructorArgs = abi.encode(manager, address(diamond), uint16(25), uint16(25));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        deployed = new StaticsSwapFeeHook{salt: salt}(manager, address(diamond), 25, 25);
        assertEq(address(deployed), expected);
    }
}
