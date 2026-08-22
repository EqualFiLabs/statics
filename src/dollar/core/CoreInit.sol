// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDiamondCut} from "../../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IStaticsDollarRiskShares} from "../interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "../interfaces/IStaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "../interfaces/IStaticsDollarCoreTypes.sol";
import {IUsdOracle} from "../interfaces/IUsdOracle.sol";
import {LibCore} from "./libraries/LibCore.sol";
import {LibCoreStorage} from "./libraries/LibCoreStorage.sol";

contract CoreInit {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant STATICS_DOLLAR_KIND = keccak256("STATICS_DOLLAR_TOKEN_V1");
    bytes32 internal constant STATICS_DOLLAR_RISK_KIND = keccak256("STATICS_DOLLAR_RISK_V1");

    struct InitArgs {
        address staticsDollar;
        address staticsDollarRisk;
        address initialOracle;
        address requiredSequencerUptimeFeed;
        uint256 minimumSequencerGracePeriod;
        address profileGuardian;
        address initialCollateralToken;
        uint256 collateralRatioBps;
        uint256 priceBandBps;
        uint256 debtCeiling;
    }

    error AlreadyInitialized();
    error ZeroAddress();
    error InvalidTokenPool(address token, address expectedPool, address actualPool);
    error InvalidTokenKind(address token, bytes32 expectedKind, bytes32 actualKind);
    error InvalidCollateralRatio(uint256 collateralRatioBps);
    error InvalidPriceBand(uint256 priceBandBps);
    error InvalidDebtCeiling();
    error InvalidCollateralDecimals(uint8 decimals);

    event VolatileCollateralProfileCreated(
        uint256 indexed profileId,
        address indexed collateralToken,
        address indexed oracle,
        uint8 decimals,
        uint256 activeSeriesId
    );
    event SeriesOpened(uint256 indexed profileId, uint256 indexed seriesId, uint256 priceWad);

    /// @dev Applies the genesis facet cut before core initialization inside the Diamond's
    /// constructor, keeping nested facet arrays out of diamond constructor arguments.
    function genesis(IDiamondCut.FacetCut[] calldata genesisCut, InitArgs calldata args) external {
        LibDiamond.diamondCut(genesisCut, address(0), "");
        _init(args);
    }

    function init(InitArgs calldata args) external {
        _init(args);
    }

    function _init(InitArgs calldata args) private {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        if (cs.initialized) revert AlreadyInitialized();
        if (
            args.staticsDollar == address(0) || args.staticsDollarRisk == address(0)
                || args.profileGuardian == address(0) || args.initialCollateralToken == address(0)
        ) revert ZeroAddress();
        LibCore.requireContract(args.staticsDollar);
        LibCore.requireContract(args.staticsDollarRisk);
        LibCore.requireContract(args.initialCollateralToken);
        if (args.collateralRatioBps <= BPS || args.collateralRatioBps > 30_000) {
            revert InvalidCollateralRatio(args.collateralRatioBps);
        }
        if (args.priceBandBps <= BPS || args.priceBandBps > 30_000 || args.priceBandBps > args.collateralRatioBps) {
            revert InvalidPriceBand(args.priceBandBps);
        }
        if (args.debtCeiling == 0) revert InvalidDebtCeiling();
        LibCore.validateSequencerRequirement(args.requiredSequencerUptimeFeed, args.minimumSequencerGracePeriod);
        LibCore.validateOracle(args.initialOracle, args.requiredSequencerUptimeFeed, args.minimumSequencerGracePeriod);
        bytes32 staticsDollarKind = IStaticsDollar(args.staticsDollar).coreTokenKind();
        if (staticsDollarKind != STATICS_DOLLAR_KIND) {
            revert InvalidTokenKind(args.staticsDollar, STATICS_DOLLAR_KIND, staticsDollarKind);
        }
        bytes32 staticsDollarRiskKind = IStaticsDollarRiskShares(args.staticsDollarRisk).coreTokenKind();
        if (staticsDollarRiskKind != STATICS_DOLLAR_RISK_KIND) {
            revert InvalidTokenKind(args.staticsDollarRisk, STATICS_DOLLAR_RISK_KIND, staticsDollarRiskKind);
        }
        address staticsDollarPool = IStaticsDollar(args.staticsDollar).pool();
        if (staticsDollarPool != address(this)) {
            revert InvalidTokenPool(args.staticsDollar, address(this), staticsDollarPool);
        }
        address staticsDollarRiskPool = IStaticsDollarRiskShares(args.staticsDollarRisk).pool();
        if (staticsDollarRiskPool != address(this)) {
            revert InvalidTokenPool(args.staticsDollarRisk, address(this), staticsDollarRiskPool);
        }

        cs.staticsDollar = args.staticsDollar;
        cs.staticsDollarRisk = args.staticsDollarRisk;
        cs.initialOracle = args.initialOracle;
        cs.requiredSequencerUptimeFeed = args.requiredSequencerUptimeFeed;
        cs.minimumSequencerGracePeriod = args.minimumSequencerGracePeriod;
        cs.profileGuardian = args.profileGuardian;
        cs.bootstrapAuthority = msg.sender;
        cs.initialized = true;
        cs.nextProfileId = 2;
        cs.nextSeriesId = 2;

        uint8 collateralDecimals = IERC20Metadata(args.initialCollateralToken).decimals();
        if (collateralDecimals > 18) revert InvalidCollateralDecimals(collateralDecimals);
        uint256 priceWad = IUsdOracle(args.initialOracle).priceWad();
        uint256 collateralPerPairWad = Math.mulDiv(Math.mulDiv(WAD, args.collateralRatioBps, BPS), WAD, priceWad);
        uint256 seniorCollateralPerUnitWad = Math.mulDiv(WAD, WAD, priceWad);
        cs.collateralProfiles[1] = IStaticsDollarCoreTypes.StableCollateralProfile({
            collateralToken: args.initialCollateralToken,
            oracle: args.initialOracle,
            decimals: collateralDecimals,
            collateralRatioBps: uint16(args.collateralRatioBps),
            priceBandBps: uint16(args.priceBandBps),
            mintFeeBps: 0,
            redemptionFeeBps: 0,
            insuranceTargetBps: 0,
            insuranceFeeBps: 0,
            kind: IStaticsDollarCoreTypes.ProfileKind.Volatile,
            mode: IStaticsDollarCoreTypes.ProfileMode.Active,
            pegMinPriceWad: 0,
            pegMaxPriceWad: 0,
            activeSeriesId: 1,
            accountedCollateral: 0,
            insuranceReserve: 0,
            seniorOutstanding: 0,
            debtCeiling: args.debtCeiling
        });
        cs.riskSeries[1] = IStaticsDollarCoreTypes.RiskSeries({
            profileId: 1,
            collateralToken: args.initialCollateralToken,
            seniorOutstanding: 0,
            riskSharesOutstanding: 0,
            accountedCollateral: 0,
            startPriceWad: priceWad,
            collateralPerPairWad: collateralPerPairWad,
            seniorCollateralPerUnitWad: seniorCollateralPerUnitWad,
            juniorCollateralPerUnitWad: collateralPerPairWad - seniorCollateralPerUnitWad,
            collateralRatioBps: args.collateralRatioBps,
            priceBandBps: args.priceBandBps,
            startedAt: block.timestamp,
            retiredAt: 0,
            successorSeriesId: 0,
            status: IStaticsDollarCoreTypes.SeriesStatus.Active
        });
        cs.profileSeries[1].push(1);
        cs.profileIdByCollateralToken[args.initialCollateralToken] = 1;
        cs.profileOracleRevision[1] = 1;
        emit VolatileCollateralProfileCreated(1, args.initialCollateralToken, args.initialOracle, collateralDecimals, 1);
        emit SeriesOpened(1, 1, priceWad);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC1155Receiver).interfaceId] = true;
    }
}
