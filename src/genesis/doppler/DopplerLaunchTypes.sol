// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @dev ABI-compatible subset of the Doppler contracts pinned by the Genesis launch ADR.
library DopplerLaunchTypes {
    struct Curve {
        int24 tickLower;
        int24 tickUpper;
        uint16 numPositions;
        uint256 shares;
    }

    struct BeneficiaryData {
        address beneficiary;
        uint96 shares;
    }

    struct VestingSchedule {
        uint64 cliff;
        uint64 duration;
    }

    struct PoolInitializerData {
        uint24 fee;
        int24 tickSpacing;
        int24 farTick;
        Curve[] curves;
        BeneficiaryData[] beneficiaries;
        address dopplerHook;
        bytes onInitializationDopplerHookCalldata;
        bytes graduationDopplerHookCalldata;
    }

    struct CreateParams {
        uint256 initialSupply;
        uint256 numTokensToSell;
        address numeraire;
        address tokenFactory;
        bytes tokenFactoryData;
        address governanceFactory;
        bytes governanceFactoryData;
        address poolInitializer;
        bytes poolInitializerData;
        address liquidityMigrator;
        bytes liquidityMigratorData;
        address integrator;
        bytes32 salt;
    }
}

interface IDopplerERC20V1Factory {
    function IMPLEMENTATION() external view returns (address);
}

interface IDopplerAirlock {
    function owner() external view returns (address);

    function create(DopplerLaunchTypes.CreateParams calldata createData)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool);

    function getAssetData(address asset)
        external
        view
        returns (
            address numeraire,
            address timelock,
            address governance,
            address liquidityMigrator,
            address poolInitializer,
            address pool,
            address migrationPool,
            uint256 numTokensToSell,
            uint256 totalSupply,
            address integrator
        );
}
