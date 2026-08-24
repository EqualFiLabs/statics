// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {DeployStaticsGenesis, StaticsGenesisDeploymentConfig} from "../../script/DeployStaticsGenesis.s.sol";
import {DopplerLaunchTypes, IDopplerAirlock} from "../../src/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsDopplerLaunchConfig} from "../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";

contract MetadataDeploymentModule {}

contract CapturingMetadataAirlock is IDopplerAirlock {
    error CapturedTokenURI(string tokenURI);
    error MetadataCaptureUnexpectedlySucceeded();

    address public immutable override owner;

    constructor() {
        owner = address(this);
    }

    function create(DopplerLaunchTypes.CreateParams calldata params)
        external
        returns (address, address, address, address, address)
    {
        (bool success, bytes memory reason) = address(this).staticcall(
            abi.encodePacked(this.captureTokenFactoryData.selector, params.tokenFactoryData)
        );
        if (success) revert MetadataCaptureUnexpectedlySucceeded();
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    function captureTokenFactoryData(
        string calldata,
        string calldata,
        DopplerLaunchTypes.VestingSchedule[] calldata,
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        string calldata tokenURI,
        uint256,
        uint48,
        address,
        address[] calldata
    ) external pure {
        revert CapturedTokenURI(tokenURI);
    }
}

contract DeployStaticsGenesisMetadataTest is Test {
    DeployStaticsGenesis private deployer;

    function setUp() public {
        deployer = new DeployStaticsGenesis();
    }

    function testCanonicalTokenURIUsesPinnedIPFSMetadata() public view {
        assertEq(deployer.staticsTokenURI(), "ipfs://Qmb9a5F2iNCBc2kCveJaDY7rPw5ycZNt7W6tVDX9uuunFR");
    }

    function testLaunchConfigHashBindsConfiguredTokenURI() public view {
        StaticsGenesisDeploymentConfig memory config = _config(deployer.staticsTokenURI());
        StaticsDopplerLaunchConfig.RuntimeCodeHashes memory codeHashes;
        bytes32 originalHash = deployer.launchConfigHash(config, bytes32(uint256(1)), codeHashes);

        config.tokenURI = "ipfs://different-metadata-cid";

        assertNotEq(deployer.launchConfigHash(config, bytes32(uint256(1)), codeHashes), originalHash);
    }

    function testDeployPassesConfiguredTokenURIToDopplerFactory() public {
        string memory tokenURI = "ipfs://configured-doppler-token-metadata";
        MetadataDeploymentModule module = new MetadataDeploymentModule();
        CapturingMetadataAirlock airlock = new CapturingMetadataAirlock();
        StaticsGenesisDeploymentConfig memory config = _config(tokenURI);
        config.numeraire = address(module);
        config.modules = StaticsDopplerLaunchConfig.Modules({
            airlock: address(airlock),
            tokenFactory: address(module),
            governanceFactory: address(module),
            poolInitializer: address(module),
            noOpMigrator: address(module)
        });

        vm.expectRevert(abi.encodeWithSelector(CapturingMetadataAirlock.CapturedTokenURI.selector, tokenURI));
        deployer.deploy(config, address(this));
    }

    function _config(string memory tokenURI) private pure returns (StaticsGenesisDeploymentConfig memory config) {
        config.governance = address(0x1001);
        config.treasury = address(0x1002);
        config.numeraire = address(0x1003);
        config.integrator = address(0);
        config.modules = StaticsDopplerLaunchConfig.Modules({
            airlock: address(0x2001),
            tokenFactory: address(0x2002),
            governanceFactory: address(0x2003),
            poolInitializer: address(0x2004),
            noOpMigrator: address(0x2005)
        });
        config.salt = bytes32(uint256(1));
        config.fee = 3_000;
        config.genesisRewardShareBps = 5_000;
        config.reserveShareBps = 5_000;
        config.creditOriginationFee = 0.003 ether;
        config.creditExtensionFee = 0.003 ether;
        config.recoveryCallerShareBps = 2_000;
        config.genesisEpochEnd = 1_900_000_000;
        config.tokenURI = tokenURI;
        config.contractURI = "ipfs://genesis-contract-metadata";
        config.externalURLBase = "https://staticsprotocol.com/genesis/";
    }
}
