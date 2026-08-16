// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {LiquidityOperations} from "@uniswap/v4-periphery/test/shared/LiquidityOperations.sol";
import {Permit2SignatureHelpers} from "@uniswap/v4-periphery/test/shared/Permit2SignatureHelpers.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "@uniswap/v4-periphery/test/shared/PositionConfig.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../../script/DeployStaticsGenesis.s.sol";
import {StaticsHookController} from "../../../src/genesis/StaticsHookController.sol";
import {RevenueChannel} from "../../../src/interfaces/IStaticsHookController.sol";
import {IStaticsV4Hook} from "../../../src/interfaces/IStaticsV4Hook.sol";
import {StaticsV4Hook} from "../../../src/liquidity/StaticsV4Hook.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../../../src/tokens/StaticsToken.sol";

interface IRobinhoodGenesisUniversalRouter {
    function poolManager() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IRobinhoodGenesisPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function tokenDescriptor() external view returns (address);
    function WETH9() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}

abstract contract RobinhoodStandaloneGenesisForkTest is Test, LiquidityOperations, Permit2SignatureHelpers {
    using Planner for Plan;
    using StateLibrary for IPoolManager;

    bytes private constant EMPTY = "";
    bytes1 private constant PERMIT2_PERMIT_COMMAND = 0x0a;
    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    uint256 private constant FIRST_SWAPPER_KEY = 0xA11CE;
    uint256 private constant SECOND_SWAPPER_KEY = 0xB0B;
    uint256 private constant THIRD_SWAPPER_KEY = 0xCA11;
    uint256 private constant FOURTH_SWAPPER_KEY = 0xD00D;

    struct RobinhoodV4Deployment {
        uint256 chainId;
        uint256 forkBlock;
        address poolManager;
        address positionManager;
        address positionDescriptor;
        address quoter;
        address stateView;
        address universalRouter;
        address permit2;
        address weth;
    }

    // Robinhood's deployed router includes the per-hop minimum price field
    // introduced by the V4 periphery version recorded in the chain manifest.
    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct RouterExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    RobinhoodV4Deployment private robinhood;
    string private manifest;
    IPoolManager private poolManager;
    IPositionManager private positionManager;
    IAllowanceTransfer private permit2;
    IV4Quoter private quoter;
    IStateView private stateView;
    IRobinhoodGenesisUniversalRouter private universalRouter;

    StaticsGenesisDeployment private genesisDeployment;
    StaticsToken private statics;
    StaticsHookController private controller;
    StaticsV4Hook private hook;
    PoolKey private poolKey;
    PoolId private poolId;

    function setUp() public {
        manifest = vm.readFile(_manifestPath());
        robinhood = _readRobinhoodDeployment(manifest);
        _selectFork();

        poolManager = IPoolManager(robinhood.poolManager);
        positionManager = IPositionManager(robinhood.positionManager);
        permit2 = IAllowanceTransfer(robinhood.permit2);
        quoter = IV4Quoter(robinhood.quoter);
        stateView = IStateView(robinhood.stateView);
        universalRouter = IRobinhoodGenesisUniversalRouter(robinhood.universalRouter);
        lpm = positionManager;
        _deadline = block.timestamp + 1 hours;
    }

    function testPinnedRobinhoodInfrastructureMatchesManifest() public view {
        assertEq(block.chainid, robinhood.chainId);
        assertEq(block.number, robinhood.forkBlock);
        _assertCodeHash("poolManager", robinhood.poolManager);
        _assertCodeHash("positionManager", robinhood.positionManager);
        _assertCodeHash("positionDescriptor", robinhood.positionDescriptor);
        _assertCodeHash("quoter", robinhood.quoter);
        _assertCodeHash("stateView", robinhood.stateView);
        _assertCodeHash("universalRouter", robinhood.universalRouter);
        _assertCodeHash("permit2", robinhood.permit2);
        assertGt(robinhood.weth.code.length, 0, "WETH has no code");

        IRobinhoodGenesisPositionManager bindings = IRobinhoodGenesisPositionManager(robinhood.positionManager);
        assertEq(bindings.poolManager(), robinhood.poolManager);
        assertEq(bindings.permit2(), robinhood.permit2);
        assertEq(bindings.tokenDescriptor(), robinhood.positionDescriptor);
        address positionManagerWeth = bindings.WETH9();
        assertEq(address(quoter.poolManager()), robinhood.poolManager);
        assertEq(address(stateView.poolManager()), robinhood.poolManager);
        assertEq(address(IPositionDescriptor(robinhood.positionDescriptor).poolManager()), robinhood.poolManager);
        assertEq(IPositionDescriptor(robinhood.positionDescriptor).wrappedNative(), positionManagerWeth);
        assertEq(universalRouter.poolManager(), robinhood.poolManager);
    }

    function testPinnedForkProductionScriptDeploysInertStack() public {
        uint256 deployerKey = 0x51A71C5;
        address deployer = vm.addr(deployerKey);
        address governance = makeAddr("forkGenesisGovernance");
        address treasury = makeAddr("forkGenesisTreasury");
        vm.deal(deployer, 100 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerKey));
        vm.setEnv("STATICS_GENESIS_GOVERNANCE", vm.toString(governance));
        vm.setEnv("STATICS_GENESIS_TREASURY", vm.toString(treasury));
        vm.setEnv("WETH_ADDRESS", vm.toString(robinhood.weth));
        vm.setEnv("POOL_MANAGER_ADDRESS", vm.toString(robinhood.poolManager));
        vm.setEnv("STATICS_GENESIS_INPUT_FEE_BPS", "50");
        vm.setEnv("STATICS_GENESIS_OUTPUT_FEE_BPS", "50");

        StaticsGenesisDeployment memory deployment = new DeployStaticsGenesis().run();
        StaticsToken deployedStatics = StaticsToken(deployment.statics);
        StaticsHookController deployedController = StaticsHookController(deployment.hookController);
        StaticsV4Hook deployedHook = StaticsV4Hook(deployment.v4Hook);

        assertEq(deployedStatics.totalSupply(), 999_955_550 ether);
        assertEq(deployedStatics.balanceOf(deployment.v4Hook), 810_045_000 ether);
        assertEq(deployedStatics.balanceOf(treasury), 90_005_000 ether);
        assertEq(deployedController.owner(), governance);
        assertEq(deployedController.hook(), deployment.v4Hook);
        assertFalse(deployedHook.poolConfiguration(deployedHook.canonicalPoolId()).initialized);
        assertFalse(deployedHook.launchInventoryInstalled());
    }

    function testPinnedForkCompletesStandaloneLaunchTradingAndClaims() public {
        _deployGenesis();

        uint256 gasBefore = gasleft();
        controller.initializeCanonicalPool();
        uint256 initializationGas = gasBefore - gasleft();
        emit log_named_uint("pinned-fork cold Genesis initialization gas", initializationGas);
        assertLt(initializationGas, 16_000_000);
        _assertLaunchInstalled();

        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == robinhood.weth;
        _universalExactInput(robinhood.weth, address(statics), wethToStaticsZeroForOne, 1 ether, FIRST_SWAPPER_KEY);
        _universalExactInput(
            address(statics), robinhood.weth, !wethToStaticsZeroForOne, 1_000 ether, SECOND_SWAPPER_KEY
        );
        _universalExactOutput(robinhood.weth, address(statics), wethToStaticsZeroForOne, 100 ether, THIRD_SWAPPER_KEY);
        _universalExactOutput(address(statics), robinhood.weth, !wethToStaticsZeroForOne, 1e12, FOURTH_SWAPPER_KEY);

        assertGt(hook.lockedPermanentLiquidity(poolId), 0);
        Currency wethCurrency = Currency.wrap(robinhood.weth);
        Currency staticsCurrency = Currency.wrap(address(statics));
        uint256 wethClaim = controller.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, address(this));
        uint256 staticsClaim =
            controller.claimableRevenue(poolId, staticsCurrency, RevenueChannel.Treasury, address(this));
        assertGt(wethClaim, 0);
        assertGt(staticsClaim, 0);

        address receiver = makeAddr("forkTreasuryReceiver");
        controller.claimRevenue(poolId, wethCurrency, RevenueChannel.Treasury, receiver);
        controller.claimRevenue(poolId, staticsCurrency, RevenueChannel.Treasury, receiver);
        assertEq(IERC20(robinhood.weth).balanceOf(receiver), wethClaim);
        assertEq(statics.balanceOf(receiver), staticsClaim);

        hook.compoundPermanentLiquidity(poolKey);
    }

    function testPinnedForkExternalLiquidityKeepsLpRewardRoute() public {
        _deployGenesis();
        controller.initializeCanonicalPool();
        _approvePositionManagerAssets();

        PositionConfig memory position = PositionConfig({
            poolKey: poolKey,
            tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing)
        });
        uint256 tokenId = positionManager.nextTokenId();
        vm.expectRevert();
        mint(position, 1 ether, address(this), EMPTY);
        assertEq(positionManager.nextTokenId(), tokenId);

        address lpRewards = makeAddr("forkLpRewards");
        IStaticsV4Hook.FeeConfiguration memory fees = _initialFees();
        fees.polShareBps = 2_000;
        fees.liquidityProviderShareBps = 1_000;
        fees.treasuryShareBps = 7_000;
        IStaticsV4Hook.RevenueRecipients memory recipients;
        recipients.liquidityProvider = lpRewards;
        recipients.treasury = address(this);
        controller.activateExternalLiquidity(poolId, fees, recipients);

        mint(position, 1 ether, address(this), EMPTY);
        assertEq(IRobinhoodGenesisPositionManager(robinhood.positionManager).ownerOf(tokenId), address(this));
        assertEq(positionManager.getPositionLiquidity(tokenId), 1 ether);

        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == robinhood.weth;
        _universalExactInput(robinhood.weth, address(statics), wethToStaticsZeroForOne, 1 ether, FIRST_SWAPPER_KEY);
        assertGt(
            controller.claimableRevenue(
                poolId, Currency.wrap(robinhood.weth), RevenueChannel.LiquidityProvider, lpRewards
            ),
            0
        );

        IStaticsV4Hook.RevenueRecipients memory treasuryOnly;
        treasuryOnly.treasury = address(this);
        vm.expectRevert(StaticsV4Hook.ExternalLiquidityRequiresLpRewards.selector);
        controller.configurePool(poolId, _initialFees(), treasuryOnly);
    }

    function testPinnedForkRoutesZeroShareRemainderToTreasury() public {
        _deployGenesis();

        address partner = makeAddr("forkPartner");
        IStaticsV4Hook.FeeConfiguration memory fees = _initialFees();
        fees.polShareBps = 5_000;
        fees.partnerShareBps = 5_000;
        fees.treasuryShareBps = 0;
        IStaticsV4Hook.RevenueRecipients memory recipients;
        recipients.partner = partner;
        recipients.treasury = address(this);
        controller.configurePool(poolId, fees, recipients);
        controller.initializeCanonicalPool();

        PoolSwapTest directRouter = new PoolSwapTest(poolManager);
        IERC20(robinhood.weth).approve(address(directRouter), 101);
        bool wethToStaticsZeroForOne = Currency.unwrap(poolKey.currency0) == robinhood.weth;
        directRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: wethToStaticsZeroForOne,
                amountSpecified: -int256(101),
                sqrtPriceLimitX96: wethToStaticsZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            EMPTY
        );

        Currency wethCurrency = Currency.wrap(robinhood.weth);
        assertEq(controller.claimableRevenue(poolId, wethCurrency, RevenueChannel.Partner, partner), 0);
        assertEq(controller.claimableRevenue(poolId, wethCurrency, RevenueChannel.Treasury, address(this)), 1);
    }

    function _deployGenesis() private {
        DeployStaticsGenesis deployer = new DeployStaticsGenesis();
        genesisDeployment = deployer.deploy(
            StaticsGenesisDeploymentConfig({
                governance: address(this),
                treasury: address(this),
                weth: robinhood.weth,
                poolManager: robinhood.poolManager,
                inputFeeBps: 50,
                outputFeeBps: 50
            })
        );
        statics = StaticsToken(genesisDeployment.statics);
        controller = StaticsHookController(genesisDeployment.hookController);
        hook = StaticsV4Hook(genesisDeployment.v4Hook);
        poolKey = hook.canonicalPoolKey();
        poolId = hook.canonicalPoolId();

        vm.deal(address(this), 100 ether);
        IWETH9(robinhood.weth).deposit{value: 100 ether}();
        StaticsGenesis genesis = StaticsGenesis(genesisDeployment.genesis);
        assertEq(statics.totalSupply(), 999_955_550 ether);
        assertEq(genesis.mintedSupply(), 5_555);
        assertEq(genesis.balanceOf(address(this)), 555);
        assertEq(genesis.balanceOf(genesisDeployment.genesisVault), 5_000);
        assertEq(statics.balanceOf(genesisDeployment.v4Hook), 810_045_000 ether);
        assertEq(controller.owner(), address(this));
        assertEq(controller.hook(), genesisDeployment.v4Hook);
    }

    function _assertLaunchInstalled() private view {
        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        assertTrue(configuration.initialized);
        assertTrue(hook.launchInventoryInstalled());
        assertEq(configuration.fees.polShareBps, 2_500);
        assertEq(configuration.fees.treasuryShareBps, 7_500);
        assertEq(configuration.recipients.treasury, address(this));
        (uint160 managerPrice,,,) = poolManager.getSlot0(poolId);
        (uint160 observedPrice,,, uint24 nativeFee) = stateView.getSlot0(poolId);
        assertEq(managerPrice, configuration.expectedSqrtPriceX96);
        assertEq(observedPrice, managerPrice);
        assertEq(nativeFee, 0);

        uint256 installed;
        for (uint8 band = 1; band <= 6; ++band) {
            assertGt(hook.launchBandLiquidity(band), 0);
            assertLe(hook.launchBandStatics(band), hook.launchBandTarget(band));
            installed += hook.launchBandStatics(band);
        }
        assertEq(installed + hook.launchRoundingDust(), 810_045_000 ether);
        assertEq(statics.balanceOf(address(hook)), hook.launchRoundingDust());
        assertEq(IERC20(robinhood.weth).balanceOf(address(hook)), 0);
    }

    function _approvePositionManagerAssets() private {
        statics.approve(robinhood.permit2, type(uint256).max);
        IERC20(robinhood.weth).approve(robinhood.permit2, type(uint256).max);
        permit2.approve(address(statics), robinhood.positionManager, type(uint160).max, type(uint48).max);
        permit2.approve(robinhood.weth, robinhood.positionManager, type(uint160).max, type(uint48).max);
    }

    function _universalExactInput(address input, address output, bool zeroForOne, uint128 amountIn, uint256 swapperKey)
        private
        returns (uint256 amountOut)
    {
        (uint256 quotedOutput, uint256 gasEstimate) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: EMPTY
            })
        );
        assertGt(quotedOutput, 0);
        assertGt(gasEstimate, 0);
        assertLe(quotedOutput, type(uint128).max);

        address swapper = vm.addr(swapperKey);
        IERC20(input).transfer(swapper, amountIn);
        (IAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature) =
            _permitSwapper(swapper, swapperKey, input, amountIn);

        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                RouterExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: uint128(quotedOutput),
                    minHopPriceX36: 0,
                    hookData: EMPTY
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(input), amountIn));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(output), uint128(quotedOutput)));

        uint256 inputBefore = IERC20(input).balanceOf(swapper);
        uint256 outputBefore = IERC20(output).balanceOf(swapper);
        _executeRouterPlan(swapper, permitSingle, signature, plan);
        assertEq(inputBefore - IERC20(input).balanceOf(swapper), amountIn);
        amountOut = IERC20(output).balanceOf(swapper) - outputBefore;
        assertEq(amountOut, quotedOutput);
    }

    function _universalExactOutput(
        address input,
        address output,
        bool zeroForOne,
        uint128 amountOut,
        uint256 swapperKey
    ) private returns (uint256 amountIn) {
        (uint256 quotedInput, uint256 gasEstimate) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: EMPTY
            })
        );
        assertGt(quotedInput, 0);
        assertGt(gasEstimate, 0);
        assertLe(quotedInput, type(uint128).max);
        uint128 amountInMaximum = uint128(quotedInput);

        address swapper = vm.addr(swapperKey);
        IERC20(input).transfer(swapper, amountInMaximum);
        (IAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature) =
            _permitSwapper(swapper, swapperKey, input, amountInMaximum);

        Plan memory plan = Planner.init();
        plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                RouterExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: amountOut,
                    amountInMaximum: amountInMaximum,
                    minHopPriceX36: 0,
                    hookData: EMPTY
                })
            )
        );
        plan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(input), amountInMaximum));
        plan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(output), amountOut));

        uint256 inputBefore = IERC20(input).balanceOf(swapper);
        uint256 outputBefore = IERC20(output).balanceOf(swapper);
        _executeRouterPlan(swapper, permitSingle, signature, plan);
        amountIn = inputBefore - IERC20(input).balanceOf(swapper);
        assertLe(amountIn, quotedInput);
        assertEq(IERC20(output).balanceOf(swapper) - outputBefore, amountOut);
    }

    function _permitSwapper(address swapper, uint256 swapperKey, address token, uint160 amount)
        private
        returns (IAllowanceTransfer.PermitSingle memory permitSingle, bytes memory signature)
    {
        vm.prank(swapper);
        IERC20(token).approve(robinhood.permit2, amount);
        (,, uint48 nonce) = permit2.allowance(swapper, token, robinhood.universalRouter);
        permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token, amount: amount, expiration: uint48(block.timestamp + 20 minutes), nonce: nonce
            }),
            spender: robinhood.universalRouter,
            sigDeadline: block.timestamp + 20 minutes
        });
        signature = getPermitSignature(permitSingle, swapperKey, permit2.DOMAIN_SEPARATOR());
    }

    function _executeRouterPlan(
        address swapper,
        IAllowanceTransfer.PermitSingle memory permitSingle,
        bytes memory signature,
        Plan memory plan
    ) private {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(permitSingle, signature);
        inputs[1] = plan.encode();
        vm.prank(swapper);
        universalRouter.execute(
            abi.encodePacked(PERMIT2_PERMIT_COMMAND, V4_SWAP_COMMAND), inputs, block.timestamp + 1 minutes
        );
    }

    function _initialFees() private pure returns (IStaticsV4Hook.FeeConfiguration memory fees) {
        fees = IStaticsV4Hook.FeeConfiguration({
            inputFeeBps: 50,
            outputFeeBps: 50,
            polShareBps: 2_500,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 0,
            partnerShareBps: 0,
            creatorShareBps: 0,
            treasuryShareBps: 7_500
        });
    }

    function _selectFork() private {
        uint256 requestedBlock = _requestedForkBlock(robinhood.forkBlock);
        assertEq(requestedBlock, robinhood.forkBlock, "fork block differs from manifest");
        if (block.chainid == robinhood.chainId) {
            assertEq(block.number, robinhood.forkBlock, "selected fork is not pinned");
            return;
        }
        string memory rpcUrl = _forkRpcUrl();
        if (bytes(rpcUrl).length == 0) {
            if (_forkRequired()) fail("Robinhood fork required");
            vm.skip(true, "Robinhood fork RPC is not configured");
            return;
        }
        vm.createSelectFork(rpcUrl, robinhood.forkBlock);
        assertEq(block.chainid, robinhood.chainId);
        assertEq(block.number, robinhood.forkBlock);
    }

    function _readRobinhoodDeployment(string memory json)
        private
        pure
        returns (RobinhoodV4Deployment memory deployment)
    {
        deployment.chainId = vm.parseJsonUint(json, ".chainId");
        deployment.forkBlock = vm.parseJsonUint(json, ".forkBlock");
        deployment.poolManager = vm.parseJsonAddress(json, ".contracts.poolManager.address");
        deployment.positionManager = vm.parseJsonAddress(json, ".contracts.positionManager.address");
        deployment.positionDescriptor = vm.parseJsonAddress(json, ".contracts.positionDescriptor.address");
        deployment.quoter = vm.parseJsonAddress(json, ".contracts.quoter.address");
        deployment.stateView = vm.parseJsonAddress(json, ".contracts.stateView.address");
        deployment.universalRouter = vm.parseJsonAddress(json, ".contracts.universalRouter.address");
        deployment.permit2 = vm.parseJsonAddress(json, ".contracts.permit2.address");
        deployment.weth = vm.parseJsonAddress(json, _wethManifestPath());
    }

    function _assertCodeHash(string memory name, address target) private view {
        bytes32 expected = vm.parseJsonBytes32(manifest, string.concat(".contracts.", name, ".runtimeCodeHash"));
        assertTrue(target.code.length != 0, string.concat(name, " has no code"));
        assertEq(target.codehash, expected, string.concat(name, " code hash drift"));
    }

    function _manifestPath() internal pure virtual returns (string memory);
    function _wethManifestPath() internal pure virtual returns (string memory);
    function _forkRpcUrl() internal view virtual returns (string memory);
    function _forkRequired() internal view virtual returns (bool);
    function _requestedForkBlock(uint256 manifestBlock) internal view virtual returns (uint256);
}

contract RobinhoodMainnetStandaloneGenesisForkTest is RobinhoodStandaloneGenesisForkTest {
    function _manifestPath() internal pure override returns (string memory) {
        return "deployments/robinhood-chain-4663.json";
    }

    function _wethManifestPath() internal pure override returns (string memory) {
        return ".contracts.weth.address";
    }

    function _forkRpcUrl() internal view override returns (string memory) {
        return vm.envOr("ROBINHOOD_MAINNET", string(""));
    }

    function _forkRequired() internal view override returns (bool) {
        return vm.envOr("REQUIRE_ROBINHOOD_FORK", false);
    }

    function _requestedForkBlock(uint256 manifestBlock) internal view override returns (uint256) {
        return vm.envOr("ROBINHOOD_FORK_BLOCK", manifestBlock);
    }
}

contract RobinhoodTestnetStandaloneGenesisForkTest is RobinhoodStandaloneGenesisForkTest {
    function _manifestPath() internal pure override returns (string memory) {
        return "deployments/robinhood-chain-testnet-46630.json";
    }

    function _wethManifestPath() internal pure override returns (string memory) {
        return ".staticsDollarDependencies.weth.address";
    }

    function _forkRpcUrl() internal view override returns (string memory rpcUrl) {
        rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        }
    }

    function _forkRequired() internal view override returns (bool) {
        return vm.envOr("REQUIRE_ROBINHOOD_TESTNET_FORK", false);
    }

    function _requestedForkBlock(uint256 manifestBlock) internal view override returns (uint256) {
        return vm.envOr("ROBINHOOD_TESTNET_FORK_BLOCK", manifestBlock);
    }
}
