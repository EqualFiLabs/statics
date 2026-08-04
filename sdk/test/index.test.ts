import {
  decodeAbiParameters,
  decodeErrorResult,
  decodeFunctionData,
  encodeErrorResult,
  encodeFunctionData,
  hashTypedData,
  parseAbiParameters,
} from "viem";
import { describe, expect, it, vi } from "vitest";
import {
  allowsExposureIncrease,
  BasketStatus,
  buildActivateLiquidityPositionCall,
  buildBorrowAndProvideLiquidityCall,
  buildBorrowAndStakeLiquidityCall,
  buildBorrowCall,
  buildClearCanonicalPoolFeeConfigurationCall,
  buildClaimRewardsCall,
  buildClaimBasketRewardsCall,
  buildClaimLiquidityRewardsCall,
  buildCreateAndStakeCall,
  buildCreatePositionCall,
  buildCreateBasketTransaction,
  buildDecommissionBasketCall,
  buildDepositETHTransaction,
  buildErc20PermitTypedData,
  buildIncreaseStakedLiquidityCall,
  buildMintPeggedAndRecombineCall,
  buildMintPeggedAndRecombineWithPermitCall,
  buildMintPeggedCall,
  buildMintPeggedWithPermitCall,
  buildMintV4PositionCall,
  buildQuoteMintPeggedAndRecombineCall,
  buildOptInRewardAssetsCall,
  buildOptOutRewardAssetsCall,
  buildPermit2ApproveCall,
  buildPermit2PermitTypedData,
  buildQuoteV4ExactInputSingleCall,
  buildApproveV4PositionCall,
  buildRedeemPeggedCall,
  buildRedeemPeggedWithPermitCall,
  buildRecoverCall,
  buildRepayCall,
  buildExtendCall,
  buildSetSwapFeeConfigurationCall,
  buildSetPositionCreationFeeCall,
  buildSetPositionRendererCall,
  buildSetCanonicalPoolFeeConfigurationCall,
  buildStakeLiquidityPositionCall,
  buildTestnetFaucetClaimCall,
  buildUnstakeLiquidityPositionCall,
  buildClaimPeggedProtocolRevenueCall,
  buildRecombineToWETHCall,
  buildRecombineToWETHWithPermitCall,
  buildRecombineToETHWithPermitCall,
  buildV4ExactInputSingleSwap,
  decodePositionInfo,
  effectiveCanonicalFees,
  encodeSqrtPriceAssetPerBasketX96,
  getSqrtPriceAtTick,
  pendingLpFees,
  maximumLiquidityForAmounts,
  planMintUnderlyingRoutes,
  positionSalt,
  LOAN_RECOVERY_GRACE_PERIOD,
  Q128,
  Q96,
  quoteBorrow,
  quoteBorrowAndProvideLiquidity,
  quoteRecovery,
  quoteExtension,
  quoteHookFee,
  quoteMint,
  quoteRangeAmounts,
  quoteRedeem,
  robinhoodChain,
  selectFeeShares,
  splitSwapFee,
  staticsAbi,
  staticsBasketErrorAbi,
  staticsCollateralErrorAbi,
  staticsDollarCoreAbi,
  staticsDollarErrorAbi,
  staticsDollarPeripheryAbi,
  staticsDollarRiskTokenAbi,
  staticsDollarTokenAbi,
  staticsLendingErrorAbi,
  staticsPositionErrorAbi,
  staticsRewardsErrorAbi,
  staticsSwapFeeHookAbi,
  staticsTestnetFaucetAbi,
  staticsTokenErrorAbi,
  permit2AllowanceAbi,
  universalRouterAbi,
  v4QuoterAbi,
  v4PositionManagerReadAbi,
  type BasketSnapshot,
  type Permit2PermitSingle,
  type PermitSignature,
  type UnderlyingLiquidityAdapter,
} from "../src/index.js";

const assetA = "0x0000000000000000000000000000000000000001";
const assetB = "0x0000000000000000000000000000000000000002";
const basketToken = "0x0000000000000000000000000000000000000003";
const sourceToken = "0x0000000000000000000000000000000000000004";
const receiver = "0x0000000000000000000000000000000000000005";

const snapshot: BasketSnapshot = {
  basketId: 0n,
  basketToken,
  status: BasketStatus.Active,
  totalSupply: 10n * 10n ** 18n,
  mintFeeTiers: [
    { minActionShares: 0n, feeShares: 5n * 10n ** 16n },
    { minActionShares: 1_000n * 10n ** 18n, feeShares: 10n ** 16n },
  ],
  redemptionFeeTiers: [{ minActionShares: 0n, feeShares: 5n * 10n ** 16n }],
  originationFeeBps: 100n,
  extensionFeeBps: 25n,
  ltvBps: 9_500n,
  recoveryPenaltyBps: 500n,
  constituents: [
    { asset: assetA, bundleAmount: 2n * 10n ** 18n, vaultBalance: 20n * 10n ** 18n },
    { asset: assetB, bundleAmount: 5n * 10n ** 18n, vaultBalance: 50n * 10n ** 18n },
  ],
};

describe("Statics static basket quotes", () => {
  it("splits five-way hook fees and redirects unavailable reward shares to POL", () => {
    const configuration = {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 4_000n,
      liquidityProviderShareBps: 1_000n,
      basketStakerShareBps: 2_000n,
      staticsStakerShareBps: 2_000n,
      treasuryShareBps: 1_000n,
    };
    expect(splitSwapFee(101n, configuration, true, true, true)).toEqual({
      polAmount: 40n,
      liquidityProviderAmount: 10n,
      basketStakerAmount: 20n,
      staticsStakerAmount: 20n,
      treasuryAmount: 11n,
    });
    expect(splitSwapFee(101n, configuration, true, false, true)).toEqual({
      polAmount: 60n,
      liquidityProviderAmount: 10n,
      basketStakerAmount: 0n,
      staticsStakerAmount: 20n,
      treasuryAmount: 11n,
    });
    expect(splitSwapFee(101n, configuration, false, true, false)).toEqual({
      polAmount: 70n,
      liquidityProviderAmount: 0n,
      basketStakerAmount: 20n,
      staticsStakerAmount: 0n,
      treasuryAmount: 11n,
    });
  });

  it("rejects swap fee splits that do not conserve one hundred percent", () => {
    expect(() => splitSwapFee(100n, {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 4_000n,
      liquidityProviderShareBps: 1_000n,
      basketStakerShareBps: 2_000n,
      staticsStakerShareBps: 2_000n,
      treasuryShareBps: 999n,
    }, true, true, true)).toThrow("invalid swap fee split");
    expect(() => splitSwapFee(100n, {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: -1_000n,
      liquidityProviderShareBps: 0n,
      basketStakerShareBps: 500n,
      staticsStakerShareBps: 500n,
      treasuryShareBps: 10_000n,
    }, true, true, true)).toThrow("invalid swap fee split");
  });

  it("uses the greatest qualifying threshold for a flat fee", () => {
    expect(selectFeeShares(snapshot.mintFeeTiers, 1n)).toBe(5n * 10n ** 16n);
    expect(selectFeeShares(snapshot.mintFeeTiers, 1_000n * 10n ** 18n)).toBe(10n ** 16n);
  });

  it("quotes static backing plus the selected mint fee without historical buy-in", () => {
    const quote = quoteMint(snapshot, 10n * 10n ** 18n);
    expect(quote[0]?.baseAmount).toBe(20n * 10n ** 18n);
    expect(quote[0]?.feeAmount).toBe(10n ** 17n);
    expect(quote[0]?.amountIn).toBe(20_100_000_000_000_000_000n);
  });

  it("quotes static backing less the selected redemption fee", () => {
    const quote = quoteRedeem(snapshot, snapshot.totalSupply);
    expect(quote[0]?.baseAmount).toBe(20n * 10n ** 18n);
    expect(quote[0]?.feeAmount).toBe(10n ** 17n);
    expect(quote[0]?.amountOut).toBe(19_900_000_000_000_000_000n);
  });

  it("applies origination fees and the basket LTV to proportional principal", () => {
    const quote = quoteBorrow(snapshot, 5n * 10n ** 18n);
    expect(quote.feeShares).toBe(5n * 10n ** 16n);
    expect(quote.collateralShares).toBe(4_950_000_000_000_000_000n);
    expect(quote.debtShares).toBe(4_702_500_000_000_000_000n);
    expect(quote.penaltyShares).toBe(235_125_000_000_000_000n);
    expect(quote.principals[0]?.amount).toBe(9_405_000_000_000_000_000n);
  });

  it("quotes proportional recovery and unlocks collateral beyond debt plus penalty", () => {
    const borrow = quoteBorrow(snapshot, 5n * 10n ** 18n);
    const recovery = quoteRecovery(snapshot, {
      positionId: 17n,
      basketId: snapshot.basketId,
      collateralShares: borrow.collateralShares,
      feeShares: borrow.feeShares,
      debtShares: borrow.debtShares,
      penaltyShares: borrow.penaltyShares,
      maturity: 10_000n,
      assets: borrow.principals.map(({ asset }) => asset),
      principals: borrow.principals.map(({ amount }) => amount),
    });
    expect(recovery.recoverableAt).toBe(13_600n);
    expect(recovery.burnShares).toBe(4_937_625_000_000_000_000n);
    expect(recovery.unlockedShares).toBe(12_375_000_000_000_000n);
    expect(recovery.callerAmounts[0]).toBe(94_050_000_000_000_000n);
    expect(recovery.protocolAmounts[0]).toBe(376_200_000_000_000_000n);
  });

  it("quotes extension fees from stored underlying principals", () => {
    const principals = quoteBorrow(snapshot, 5n * 10n ** 18n).principals;
    const fees = quoteExtension(snapshot, principals);
    expect(fees[0]).toEqual({ asset: assetA, amount: 23_512_500_000_000_000n });
    expect(fees[1]).toEqual({ asset: assetB, amount: 58_781_250_000_000_000n });
  });

  it("routes only constituent tokens during mint preparation", async () => {
    const quote = quoteMint(snapshot, 1n * 10n ** 18n);
    const quoteExactOutput = vi.fn(async () => ({
      maxAmountIn: 123n,
      execution: { target: sourceToken, calldata: "0x" as const, value: 0n },
    }));
    const adapter: UnderlyingLiquidityAdapter = {
      quoteExactOutput,
      quoteExactInput: vi.fn(),
    };

    const routes = await planMintUnderlyingRoutes(sourceToken, quote, adapter);
    expect(routes).toHaveLength(2);
    expect(quoteExactOutput).toHaveBeenCalledTimes(2);
    expect(quoteExactOutput).not.toHaveBeenCalledWith(expect.objectContaining({ tokenOut: basketToken }));
  });

  it("matches bilateral hook and zero-native-LP fee vectors", () => {
    expect(quoteHookFee(1n, 1n)).toBe(1n);
    expect(quoteHookFee(10_001n, 1n)).toBe(2n);
    expect(effectiveCanonicalFees(0n, 25n, 25n)).toEqual({
      lpFeePips: 0n,
      lpFeeBps: 0n,
      inputFeeBps: 25n,
      outputFeeBps: 25n,
    });
  });

  it("matches Solidity tick and range amount vectors", () => {
    expect(getSqrtPriceAtTick(0)).toBe(Q96);
    expect(getSqrtPriceAtTick(-887_270)).toBe(4_295_558_252n);
    expect(getSqrtPriceAtTick(887_270)).toBe(1_461_300_573_427_867_316_570_072_651_998_408_279_850_435_624_081n);
    expect(quoteRangeAmounts(Q96, -887_270, 887_270, 5n * 10n ** 18n)).toEqual({
      amount0: 5n * 10n ** 18n,
      amount1: 5n * 10n ** 18n,
    });
  });

  it("quotes the real combined borrow and full-range liquidity vector", () => {
    const oneAssetSnapshot: BasketSnapshot = {
      ...snapshot,
      totalSupply: 100n * 10n ** 18n,
      mintFeeTiers: [{ minActionShares: 0n, feeShares: 2n * 10n ** 17n }],
      constituents: [{ asset: assetA, bundleAmount: 1n * 10n ** 18n, vaultBalance: 100n * 10n ** 18n }],
    };
    const quote = quoteBorrowAndProvideLiquidity(oneAssetSnapshot, 20n * 10n ** 18n, [{
      asset: assetA,
      currency0: assetA,
      currency1: basketToken,
      sqrtPriceX96: Q96,
      tickLower: -887_270,
      tickUpper: 887_270,
      liquidity: 5n * 10n ** 18n,
      deadline: 7_201n,
    }]);
    expect(quote.borrow.principals[0]?.amount).toBe(18_810_000_000_000_000_000n);
    expect(quote.basketSharesMinted).toBe(5n * 10n ** 18n);
    expect(quote.totalPrincipalRequirements[0]).toEqual({
      asset: assetA,
      amount: 10_200_000_000_000_000_000n,
      refund: 8_610_000_000_000_000_000n,
    });
    expect(quote.pools[0]?.amount0Max).toBe(5n * 10n ** 18n);
    expect(quote.pools[0]?.amount1Max).toBe(5n * 10n ** 18n);

    const data = buildBorrowAndProvideLiquidityCall(17n, 4n, 20n * 10n ** 18n, quote.pools, receiver);
    expect(decodeFunctionData({ abi: staticsAbi, data }).functionName).toBe("borrowAndProvideLiquidity");
    const staked = buildBorrowAndStakeLiquidityCall(17n, 4n, 20n * 10n ** 18n, quote.pools);
    expect(decodeFunctionData({ abi: staticsAbi, data: staked }).functionName).toBe("borrowAndStakeLiquidity");
  });

  it("quotes pending PositionManager fees and decodes packed position metadata", () => {
    expect(pendingLpFees(2n, 3n * Q128, 5n * Q128, Q128, 2n * Q128)).toEqual({ amount0: 4n, amount1: 6n });
    const packed = (BigInt(120 & 0xff_ffff) << 32n) | (BigInt((-60) & 0xff_ffff) << 8n) | 1n;
    expect(decodePositionInfo(packed)).toEqual({ tickLower: -60, tickUpper: 120, hasSubscriber: true });
    expect(positionSalt(7n)).toBe(`0x${"0".repeat(63)}7`);
  });

  it("exports Robinhood addresses from the generated deployment binding", () => {
    expect(robinhoodChain.chainId).toBe(4_663);
    expect(robinhoodChain.inputFeeBps).toBe(50);
    expect(robinhoodChain.outputFeeBps).toBe(50);
    expect(robinhoodChain.hookPermissionMask).toBe("0x10cc");
    expect(robinhoodChain.liquidityCalibration.canonicalLpFeePips).toBe(0);
    expect(robinhoodChain.liquidityCalibration.hookPermissions).toEqual([
      "afterInitialize",
      "beforeSwap",
      "beforeSwapReturnDelta",
      "afterSwap",
      "afterSwapReturnDelta",
    ]);
    expect(robinhoodChain.contracts.poolManager.address.toLowerCase())
      .toBe("0x8366a39cc670b4001a1121b8f6a443a643e40951");
  });
});

describe("Statics unified calldata", () => {
  it("exports the Dollar read and approval surfaces used by clients", () => {
    expect(
      decodeFunctionData({
        abi: staticsDollarCoreAbi,
        data: encodeFunctionData({
          abi: staticsDollarCoreAbi,
          functionName: "previewDeposit",
          args: [1n, 10n ** 18n],
        }),
      })
    ).toEqual({
      functionName: "previewDeposit",
      args: [1n, 10n ** 18n],
    });

    expect(
      decodeFunctionData({
        abi: staticsDollarTokenAbi,
        data: encodeFunctionData({
          abi: staticsDollarTokenAbi,
          functionName: "approve",
          args: [receiver, 12n],
        }),
      }).functionName
    ).toBe("approve");

    expect(
      decodeFunctionData({
        abi: staticsDollarRiskTokenAbi,
        data: encodeFunctionData({
          abi: staticsDollarRiskTokenAbi,
          functionName: "setApprovalForAll",
          args: [receiver, true],
        }),
      }).functionName
    ).toBe("setApprovalForAll");
  });

  it("exports consumption-only Risk Share liquidity calls", () => {
    expect(
      decodeFunctionData({
        abi: staticsDollarPeripheryAbi,
        data: encodeFunctionData({
          abi: staticsDollarPeripheryAbi,
          functionName: "createAndStakeRiskShares",
          args: [1n, 25n, receiver],
        }),
      }),
    ).toEqual({
      functionName: "createAndStakeRiskShares",
      args: [1n, 25n, receiver],
    });

    expect(
      decodeFunctionData({
        abi: staticsDollarPeripheryAbi,
        data: encodeFunctionData({
          abi: staticsDollarPeripheryAbi,
          functionName: "unstakeRiskShares",
          args: [7n, 1n, 10n, receiver],
        }),
      }).functionName,
    ).toBe("unstakeRiskShares");

    expect(
      staticsDollarPeripheryAbi.some(
        (entry) => entry.type === "function" && entry.name === "activateLeg",
      ),
    ).toBe(false);
    expect(
      staticsDollarPeripheryAbi.some(
        (entry) => entry.type === "function" && entry.name === "optIn",
      ),
    ).toBe(false);

    expect(
      decodeFunctionData({
        abi: staticsDollarPeripheryAbi,
        data: encodeFunctionData({
          abi: staticsDollarPeripheryAbi,
          functionName: "fundRiskStaticsIncentives",
          args: [1n, 100n],
        }),
      }),
    ).toEqual({
      functionName: "fundRiskStaticsIncentives",
      args: [1n, 100n],
    });
    expect(
      staticsDollarPeripheryAbi.some(
        (entry) => entry.type === "function" && entry.name === "fundRiskIncentives",
      ),
    ).toBe(false);
  });

  it("encodes typed pegged mint-and-recombine quote and execution calls", () => {
    const quoteData = buildQuoteMintPeggedAndRecombineCall(2n, 1n, 7n, 100n);
    expect(decodeFunctionData({ abi: staticsAbi, data: quoteData })).toEqual({
      functionName: "quoteMintPeggedAndRecombine",
      args: [2n, 1n, 7n, 100n],
    });

    const executionData = buildMintPeggedAndRecombineCall(2n, 1n, 7n, 100n, 101n, 99n, receiver);
    expect(decodeFunctionData({ abi: staticsAbi, data: executionData })).toEqual({
      functionName: "mintPeggedAndRecombine",
      args: [2n, 1n, 7n, 100n, 101n, 99n, receiver],
    });
    const executionAbi = staticsAbi.find(
      (entry) => entry.type === "function" && entry.name === "mintPeggedAndRecombine",
    );
    expect(executionAbi && "outputs" in executionAbi
      ? executionAbi.outputs.map((output) => output.type)
      : []).toEqual(["uint8", "uint256", "uint256"]);

    const permit: PermitSignature = {
      value: 101n,
      deadline: 1_700_000_000n,
      v: 27,
      r: `0x${"11".repeat(32)}`,
      s: `0x${"22".repeat(32)}`,
    };
    const permitData = buildMintPeggedAndRecombineWithPermitCall(
      2n,
      1n,
      7n,
      100n,
      101n,
      99n,
      receiver,
      permit,
    );
    expect(decodeFunctionData({ abi: staticsAbi, data: permitData })).toMatchObject({
      functionName: "mintPeggedAndRecombineWithPermit",
      args: [2n, 1n, 7n, 100n, 101n, 99n, receiver, permit],
    });
    expect(staticsAbi.some((entry) => entry.type === "event" && entry.name === "PeggedMintedAndRecombined"))
      .toBe(true);
    expect(staticsAbi.some((entry) => entry.type === "event" && entry.name === "PeggedMintAndRecombineDeferred"))
      .toBe(true);
  });

  it("decodes bounded-output Dollar failures for actionable clients", () => {
    const encoded = encodeErrorResult({
      abi: staticsDollarErrorAbi,
      errorName: "SharesAboveMaximum",
      args: [101n, 100n],
    });
    expect(decodeErrorResult({ abi: staticsDollarErrorAbi, data: encoded })).toMatchObject({
      errorName: "SharesAboveMaximum",
      args: [101n, 100n],
    });
  });

  it("encodes exact-fee basket creation with static fee tiers and LTV", () => {
    const transaction = buildCreateBasketTransaction(
      {
        name: "Static Basket",
        symbol: "STATIC",
        assets: [assetA, assetB],
        bundleAmounts: [2n * 10n ** 18n, 5n * 10n ** 18n],
        mintFeeTiers: [{ minActionShares: 0n, feeShares: 5n * 10n ** 16n }],
        redemptionFeeTiers: [{ minActionShares: 0n, feeShares: 5n * 10n ** 16n }],
        flashFeeBps: 10,
        originationFeeBps: 100,
        extensionFeeBps: 25,
        ltvBps: 9_500,
        recoveryPenaltyBps: 500,
        loanDuration: 7 * 24 * 60 * 60,
      },
      [
        { sqrtPriceAssetPerBasketX96: Q96, pairedAssetAmount: 1n * 10n ** 18n },
        { sqrtPriceAssetPerBasketX96: Q96, pairedAssetAmount: 2n * 10n ** 18n },
      ],
      [25n * 10n ** 18n, 60n * 10n ** 18n],
      1_900_000_000n,
      1n * 10n ** 18n,
    );

    const decoded = decodeFunctionData({ abi: staticsAbi, data: transaction.data });
    expect(decoded.functionName).toBe("createBasket");
    expect(decoded.args[1]).toEqual([
      { sqrtPriceAssetPerBasketX96: Q96, pairedAssetAmount: 1n * 10n ** 18n },
      { sqrtPriceAssetPerBasketX96: Q96, pairedAssetAmount: 2n * 10n ** 18n },
    ]);
    expect(decoded.args[2]).toEqual([25n * 10n ** 18n, 60n * 10n ** 18n]);
    expect(decoded.args[3]).toBe(1_900_000_000n);
    expect(transaction.value).toBe(1n * 10n ** 18n);
  });

  it("encodes semantic launch prices from raw token units", () => {
    expect(encodeSqrtPriceAssetPerBasketX96(10n ** 18n, 10n ** 18n)).toBe(Q96);
    expect(encodeSqrtPriceAssetPerBasketX96(10n ** 6n, 10n ** 18n)).toBe(Q96 / 1_000_000n);
    expect(encodeSqrtPriceAssetPerBasketX96(10n ** 8n, 10n ** 18n)).toBe(Q96 / 100_000n);
    expect(() => encodeSqrtPriceAssetPerBasketX96(0n, 1n)).toThrow("raw price amounts must be positive");
  });

  it("exposes authoritative basket reads, events, and errors", () => {
    const basketRead = encodeFunctionData({
      abi: staticsAbi,
      functionName: "basket",
      args: [7n],
    });
    expect(decodeFunctionData({ abi: staticsAbi, data: basketRead })).toMatchObject({
      functionName: "basket",
      args: [7n],
    });

    const encoded = encodeErrorResult({
      abi: staticsBasketErrorAbi,
      errorName: "MaximumInputExceeded",
      args: [assetA, 101n, 100n],
    });
    expect(decodeErrorResult({ abi: staticsBasketErrorAbi, data: encoded })).toMatchObject({
      errorName: "MaximumInputExceeded",
      args: [assetA, 101n, 100n],
    });

    expect(staticsAbi.some((entry) => entry.type === "event" && entry.name === "BasketCreated"))
      .toBe(true);
    expect(staticsAbi.some((entry) => entry.type === "event" && entry.name === "BasketLaunched"))
      .toBe(true);
  });

  it("keys basket borrowing by shared PositionNFT ID", () => {
    const data = buildBorrowCall(17n, 4n, 5n * 10n ** 18n, receiver);
    const decoded = decodeFunctionData({ abi: staticsAbi, data });
    expect(decoded.functionName).toBe("borrow");
    expect(data.slice(0, 10)).toBe("0x242011d5");
    expect(decoded.args).toEqual([17n, 4n, 5n * 10n ** 18n, receiver]);
  });

  it("exposes authoritative loan lifecycle reads, events, errors, and writes", () => {
    const loanRead = encodeFunctionData({
      abi: staticsAbi,
      functionName: "loan",
      args: [23n],
    });
    expect(decodeFunctionData({ abi: staticsAbi, data: loanRead })).toEqual({
      functionName: "loan",
      args: [23n],
    });

    for (const functionName of [
      "quoteBorrow",
      "quoteRecovery",
      "quoteExtension",
      "outstandingPrincipal",
    ]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "function" && entry.name === functionName,
        ),
      ).toBe(true);
    }
    for (const eventName of [
      "LoanOriginated",
      "LoanRepaid",
      "LoanExtended",
      "LoanExtensionFeePaid",
      "LoanRecovered",
      "RecoveryPenaltyDistributed",
    ]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "event" && entry.name === eventName,
        ),
      ).toBe(true);
    }

    const lendingError = encodeErrorResult({
      abi: staticsLendingErrorAbi,
      errorName: "LoanNotRecoverable",
      args: [23n, 1_700_000_000n],
    });
    expect(
      decodeErrorResult({ abi: staticsLendingErrorAbi, data: lendingError }),
    ).toMatchObject({
      errorName: "LoanNotRecoverable",
      args: [23n, 1_700_000_000n],
    });

    expect(LOAN_RECOVERY_GRACE_PERIOD).toBe(3_600n);
    expect(
      decodeFunctionData({ abi: staticsAbi, data: buildRepayCall(23n) }),
    ).toEqual({ functionName: "repay", args: [23n] });
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: buildExtendCall(23n, [3n, 5n]),
      }),
    ).toEqual({ functionName: "extend", args: [23n, [3n, 5n]] });
    expect(
      decodeFunctionData({ abi: staticsAbi, data: buildRecoverCall(23n) }),
    ).toEqual({ functionName: "recover", args: [23n] });
  });

  it("exposes position reward claims and terminal lifecycle calls", () => {
    expect(buildClaimRewardsCall(17n, [assetA, assetB], receiver, [0n, 0n])).toMatch(/^0x[0-9a-f]+$/);
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: buildClaimBasketRewardsCall(17n, 7n, receiver),
      }),
    ).toEqual({
      functionName: "claimBasketRewards",
      args: [17n, 7n, receiver],
    });
    for (const functionName of [
      "getBasketRewardAssets",
      "getBasketRewards",
      "basketRewardState",
      "rewardSelection",
      "rewardEligibilityDelay",
      "rewardEligibilityBucketSize",
    ]) {
      expect(
        staticsAbi.some((entry) => entry.type === "function" && entry.name === functionName),
      ).toBe(true);
    }
    const poolId = `0x${"11".repeat(32)}` as const;
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: encodeFunctionData({
          abi: staticsAbi,
          functionName: "canAccrueBasketRewards",
          args: [poolId],
        }),
      }),
    ).toEqual({ functionName: "canAccrueBasketRewards", args: [poolId] });
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: buildCreateAndStakeCall(10n ** 18n, receiver, [assetA, assetB]),
      }),
    ).toEqual({
      functionName: "createAndStake",
      args: [10n ** 18n, receiver, [assetA, assetB]],
    });
    expect(
      decodeFunctionData({ abi: staticsAbi, data: buildOptInRewardAssetsCall(17n, [assetA]) }).functionName,
    ).toBe("optInRewardAssets");
    expect(
      decodeFunctionData({ abi: staticsAbi, data: buildOptOutRewardAssetsCall(17n, [assetB]) }).functionName,
    ).toBe("optOutRewardAssets");
    expect(allowsExposureIncrease(BasketStatus.Active)).toBe(true);
    expect(allowsExposureIncrease(BasketStatus.Quarantined)).toBe(false);
    expect(allowsExposureIncrease(BasketStatus.ExitOnly)).toBe(false);
    expect(buildDecommissionBasketCall(7n)).toMatch(/^0x[0-9a-f]+$/);
  });

  it("exposes authoritative PositionNFT, collateral, and selected-reward interfaces", () => {
    const ownerRead = encodeFunctionData({
      abi: staticsAbi,
      functionName: "ownerOf",
      args: [17n],
    });
    expect(decodeFunctionData({ abi: staticsAbi, data: ownerRead })).toEqual({
      functionName: "ownerOf",
      args: [17n],
    });
    expect(
      decodeFunctionData({ abi: staticsAbi, data: buildCreatePositionCall(receiver) }),
    ).toEqual({ functionName: "createPosition", args: [receiver] });
    expect(
      staticsAbi.find(
        (entry) => entry.type === "function" && entry.name === "createPosition",
      ),
    ).toMatchObject({ stateMutability: "payable" });
    for (const functionName of [
      "createAndMintBasketCollateral",
      "createAndDepositBasketCollateral",
      "createAndStake",
    ]) {
      expect(
        staticsAbi.find(
          (entry) => entry.type === "function" && entry.name === functionName,
        ),
      ).toMatchObject({ stateMutability: "payable" });
    }
    expect(
      staticsDollarPeripheryAbi.find(
        (entry) => entry.type === "function" && entry.name === "createAndStakeRiskShares",
      ),
    ).toMatchObject({ stateMutability: "payable" });
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: buildSetPositionCreationFeeCall(10n ** 15n),
      }),
    ).toEqual({ functionName: "setPositionCreationFee", args: [10n ** 15n] });
    expect(
      staticsAbi.some(
        (entry) => entry.type === "function" && entry.name === "positionCreationFee",
      ),
    ).toBe(true);
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: buildSetPositionRendererCall(receiver),
      }),
    ).toEqual({ functionName: "setPositionRenderer", args: [receiver] });
    expect(
      staticsAbi.some(
        (entry) => entry.type === "function" && entry.name === "positionRenderer",
      ),
    ).toBe(true);
    expect(
      staticsAbi.some(
        (entry) => entry.type === "event" && entry.name === "PositionCreated",
      ),
    ).toBe(true);
    expect(
      staticsAbi.some(
        (entry) => entry.type === "event" && entry.name === "PositionCreationFeePaid",
      ),
    ).toBe(true);
    expect(
      staticsAbi.some(
        (entry) => entry.type === "event" && entry.name === "PositionRendererSet",
      ),
    ).toBe(true);
    for (const functionName of ["positionState", "isLegActive", "isPositionClosable"]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "function" && entry.name === functionName,
        ),
      ).toBe(true);
    }
    for (const functionName of [
      "positionCount",
      "positionsOfOwner",
      "syncPositionOwnerIndex",
    ]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "function" && entry.name === functionName,
        ),
      ).toBe(true);
    }
    expect(
      decodeFunctionData({
        abi: staticsAbi,
        data: encodeFunctionData({
          abi: staticsAbi,
          functionName: "syncPositionOwnerIndex",
          args: [17n],
        }),
      }),
    ).toEqual({ functionName: "syncPositionOwnerIndex", args: [17n] });
    for (const eventName of ["PositionLegAttached", "PositionLegDetached", "PositionStateChanged"]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "event" && entry.name === eventName,
        ),
      ).toBe(true);
    }
    for (const eventName of [
      "PositionOwnerIndexSynced",
      "MetadataUpdate",
      "BatchMetadataUpdate",
    ]) {
      expect(
        staticsAbi.some(
          (entry) => entry.type === "event" && entry.name === eventName,
        ),
      ).toBe(true);
    }
    expect(
      staticsAbi.some(
        (entry) => entry.type === "function" && entry.name === "positionKey",
      ),
    ).toBe(false);
    expect(
      staticsAbi.some(
        (entry) =>
          entry.type === "event" && entry.name === "BasketCollateralDeposited",
      ),
    ).toBe(true);

    const positionError = encodeErrorResult({
      abi: staticsPositionErrorAbi,
      errorName: "PositionHasActiveLegs",
      args: [17n, 2n],
    });
    expect(
      decodeErrorResult({ abi: staticsPositionErrorAbi, data: positionError }),
    ).toMatchObject({
      errorName: "PositionHasActiveLegs",
      args: [17n, 2n],
    });

    const feeError = encodeErrorResult({
      abi: staticsPositionErrorAbi,
      errorName: "IncorrectPositionCreationFee",
      args: [10n ** 15n, 0n],
    });
    expect(
      decodeErrorResult({ abi: staticsPositionErrorAbi, data: feeError }),
    ).toMatchObject({
      errorName: "IncorrectPositionCreationFee",
      args: [10n ** 15n, 0n],
    });

    const collateralError = encodeErrorResult({
      abi: staticsCollateralErrorAbi,
      errorName: "PositionSharesLocked",
      args: [10n, 8n],
    });
    expect(
      decodeErrorResult({
        abi: staticsCollateralErrorAbi,
        data: collateralError,
      }),
    ).toMatchObject({ errorName: "PositionSharesLocked", args: [10n, 8n] });

    const rewardError = encodeErrorResult({
      abi: staticsRewardsErrorAbi,
      errorName: "RewardAssetLimitExceeded",
      args: [17n],
    });
    expect(
      decodeErrorResult({ abi: staticsRewardsErrorAbi, data: rewardError }),
    ).toMatchObject({
      errorName: "RewardAssetLimitExceeded",
      args: [17n],
    });

    const tokenError = encodeErrorResult({
      abi: staticsTokenErrorAbi,
      errorName: "ERC20InsufficientAllowance",
      args: [receiver, 5n, 10n],
    });
    expect(
      decodeErrorResult({ abi: staticsTokenErrorAbi, data: tokenError }),
    ).toMatchObject({
      errorName: "ERC20InsufficientAllowance",
      args: [receiver, 5n, 10n],
    });
  });

  it("exposes canonical pools without a post-launch activation lifecycle", () => {
    expect(staticsAbi.some((entry) => entry.type === "function" && entry.name === "initializeCanonicalPool"))
      .toBe(false);
    expect(staticsAbi.some((entry) => entry.type === "function" && entry.name === "syncCanonicalPoolToManager"))
      .toBe(false);
    expect(staticsAbi.some((entry) => entry.type === "function" && entry.name === "checkpointCanonicalPool"))
      .toBe(false);
    expect(staticsAbi.some((entry) => entry.type === "function" && entry.name === "activateCanonicalPool"))
      .toBe(false);
  });

  it("encodes governed five-way fee configuration", () => {
    const data = buildSetSwapFeeConfigurationCall({
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 4_000n,
      liquidityProviderShareBps: 1_000n,
      basketStakerShareBps: 2_000n,
      staticsStakerShareBps: 2_000n,
      treasuryShareBps: 1_000n,
    });
    expect(decodeFunctionData({ abi: staticsAbi, data }).functionName).toBe("setSwapFeeConfiguration");
    expect(() => buildSetSwapFeeConfigurationCall({
      inputFeeBps: 65_536n,
      outputFeeBps: 0n,
      polShareBps: 4_000n,
      liquidityProviderShareBps: 1_000n,
      basketStakerShareBps: 2_000n,
      staticsStakerShareBps: 2_000n,
      treasuryShareBps: 1_000n,
    })).toThrow("inputFeeBps exceeds uint16");
  });

  it("encodes full canonical pool fee overrides and exports their events", () => {
    const set = buildSetCanonicalPoolFeeConfigurationCall(7n, assetA, {
      inputFeeBps: 40n,
      outputFeeBps: 60n,
      polShareBps: 0n,
      liquidityProviderShareBps: 0n,
      basketStakerShareBps: 4_000n,
      staticsStakerShareBps: 4_000n,
      treasuryShareBps: 2_000n,
    });
    const decoded = decodeFunctionData({ abi: staticsAbi, data: set });
    expect(decoded.functionName).toBe("setCanonicalPoolFeeConfiguration");
    expect(decoded.args).toEqual([7n, assetA, {
      inputFeeBps: 40,
      outputFeeBps: 60,
      polShareBps: 0,
      liquidityProviderShareBps: 0,
      basketStakerShareBps: 4_000,
      staticsStakerShareBps: 4_000,
      treasuryShareBps: 2_000,
    }]);
    const clear = buildClearCanonicalPoolFeeConfigurationCall(7n, assetA);
    expect(decodeFunctionData({ abi: staticsAbi, data: clear }).functionName)
      .toBe("clearCanonicalPoolFeeConfiguration");
    expect(staticsAbi.some((item) => item.type === "function" && item.name === "canonicalPoolFeeConfiguration"))
      .toBe(true);
    expect(staticsAbi.some((item) => item.type === "event" && item.name === "CanonicalPoolFeeConfigurationSet"))
      .toBe(true);
    expect(staticsSwapFeeHookAbi.some((item) => item.type === "event" && item.name === "PoolFeeConfigurationCleared"))
      .toBe(true);
    expect(() => buildSetCanonicalPoolFeeConfigurationCall(7n, assetA, {
      inputFeeBps: 40n,
      outputFeeBps: 60n,
      polShareBps: 0n,
      liquidityProviderShareBps: 0n,
      basketStakerShareBps: 4_000n,
      staticsStakerShareBps: 4_000n,
      treasuryShareBps: 1_999n,
    })).toThrow("pool fee shares must sum to 10000 BPS");
    expect(() => buildSetCanonicalPoolFeeConfigurationCall(7n, assetA, {
      inputFeeBps: 101n,
      outputFeeBps: 100n,
      polShareBps: 0n,
      liquidityProviderShareBps: 0n,
      basketStakerShareBps: 4_000n,
      staticsStakerShareBps: 4_000n,
      treasuryShareBps: 2_000n,
    })).toThrow("combined pool fee rate exceeds 200 BPS");
  });

  it("encodes canonical LP custody, activation, increase, claim, and exit calls", () => {
    const positionId = 17n;
    const tokenId = 23n;
    const stake = buildStakeLiquidityPositionCall(positionId, tokenId);
    expect(decodeFunctionData({ abi: staticsAbi, data: stake }).functionName)
      .toBe("stakeLiquidityPosition");
    const activate = buildActivateLiquidityPositionCall(tokenId);
    expect(decodeFunctionData({ abi: staticsAbi, data: activate }).functionName)
      .toBe("activateLiquidityPosition");
    const increase = buildIncreaseStakedLiquidityCall(positionId, tokenId, {
      liquidityDelta: 5n,
      amount0Max: 100n,
      amount1Max: 200n,
      deadline: 1_700_003_600n,
    }, receiver);
    expect(decodeFunctionData({ abi: staticsAbi, data: increase }).functionName)
      .toBe("increaseStakedLiquidity");
    const claim = buildClaimLiquidityRewardsCall(positionId, tokenId, receiver, 1n, 2n);
    expect(decodeFunctionData({ abi: staticsAbi, data: claim }).functionName)
      .toBe("claimLiquidityRewards");
    const unstake = buildUnstakeLiquidityPositionCall(positionId, tokenId, receiver);
    expect(decodeFunctionData({ abi: staticsAbi, data: unstake }).functionName)
      .toBe("unstakeLiquidityPosition");
  });

  it("quotes and encodes bounded wallet-funded v4 position creation", () => {
    const liquidity = maximumLiquidityForAmounts(Q96, -887_270, 887_270, 100n, 100n);
    expect(liquidity).toBeGreaterThan(0n);
    const quoted = quoteRangeAmounts(Q96, -887_270, 887_270, liquidity);
    expect(quoted.amount0).toBeLessThanOrEqual(100n);
    expect(quoted.amount1).toBeLessThanOrEqual(100n);

    const approval = buildApproveV4PositionCall(receiver, 23n);
    expect(decodeFunctionData({ abi: v4PositionManagerReadAbi, data: approval }).functionName)
      .toBe("approve");
    const permit2Approval = buildPermit2ApproveCall(assetA, receiver, 100n, 1_700_003_600);
    expect(decodeFunctionData({ abi: permit2AllowanceAbi, data: permit2Approval }).functionName)
      .toBe("approve");
    const mint = buildMintV4PositionCall({
      poolKey: {
        currency0: assetA,
        currency1: basketToken,
        fee: 0,
        tickSpacing: 10,
        hooks: receiver,
      },
      tickLower: -887_270,
      tickUpper: 887_270,
      liquidity,
      amount0Max: 100n,
      amount1Max: 100n,
      recipient: receiver,
      deadline: 1_700_003_600n,
    });
    expect(decodeFunctionData({ abi: v4PositionManagerReadAbi, data: mint }).functionName)
      .toBe("modifyLiquidities");
  });

  it("builds canonical v4 quotes and Permit2-backed exact-input swaps", () => {
    const poolKey = {
      currency0: assetA,
      currency1: basketToken,
      fee: 0,
      tickSpacing: 10,
      hooks: receiver,
    };
    const quote = buildQuoteV4ExactInputSingleCall(poolKey, true, 100n);
    expect(decodeFunctionData({ abi: v4QuoterAbi, data: quote })).toEqual({
      functionName: "quoteExactInputSingle",
      args: [{ poolKey, zeroForOne: true, exactAmount: 100n, hookData: "0x" }],
    });

    const permitSingle: Permit2PermitSingle = {
      details: {
        token: assetA,
        amount: 100n,
        expiration: 1_700_001_200,
        nonce: 3,
      },
      spender: receiver,
      sigDeadline: 1_700_001_200n,
    };
    const permitTypedData = buildPermit2PermitTypedData(46630, robinhoodChain.contracts.permit2.address, permitSingle);
    expect(hashTypedData(permitTypedData)).toMatch(/^0x[0-9a-f]{64}$/);

    const execution = buildV4ExactInputSingleSwap({
      router: receiver,
      poolKey,
      zeroForOne: true,
      amountIn: 100n,
      amountOutMinimum: 95n,
      deadline: 1_700_001_200n,
      permit: {
        permitSingle,
        signature: `0x${"11".repeat(65)}`,
      },
    });
    expect(execution.target).toBe(receiver);
    expect(execution.value).toBe(0n);

    const decoded = decodeFunctionData({ abi: universalRouterAbi, data: execution.calldata });
    expect(decoded.functionName).toBe("execute");
    expect(decoded.args[0]).toBe("0x0a10");
    expect(decoded.args[2]).toBe(1_700_001_200n);

    const [decodedPermit] = decodeAbiParameters(
      parseAbiParameters(
        "((address token,uint160 amount,uint48 expiration,uint48 nonce) details,address spender,uint256 sigDeadline) permitSingle,bytes signature",
      ),
      decoded.args[1][0],
    );
    expect(decodedPermit).toEqual(permitSingle);

    const [actions, actionParams] = decodeAbiParameters(
      parseAbiParameters("bytes actions,bytes[] params"),
      decoded.args[1][1],
    );
    expect(actions).toBe("0x060c0f");

    const [swapParams] = decodeAbiParameters(
      parseAbiParameters(
        "((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)",
      ),
      actionParams[0],
    );
    expect(swapParams).toEqual({
      poolKey,
      zeroForOne: true,
      amountIn: 100n,
      amountOutMinimum: 95n,
      minHopPriceX36: 0n,
      hookData: "0x",
    });
    expect(decodeAbiParameters(
      parseAbiParameters("address currency,uint256 amount"),
      actionParams[1],
    )).toEqual([assetA, 100n]);
    expect(decodeAbiParameters(
      parseAbiParameters("address currency,uint256 minimumAmount"),
      actionParams[2],
    )).toEqual([basketToken, 95n]);
  });

  it("rejects a Permit2 signature for a different swap authority", () => {
    expect(() => buildV4ExactInputSingleSwap({
      router: receiver,
      poolKey: {
        currency0: assetA,
        currency1: basketToken,
        fee: 0,
        tickSpacing: 10,
        hooks: receiver,
      },
      zeroForOne: true,
      amountIn: 100n,
      amountOutMinimum: 95n,
      deadline: 1_700_001_200n,
      permit: {
        permitSingle: {
          details: {
            token: assetA,
            amount: 100n,
            expiration: 1_700_001_200,
            nonce: 3,
          },
          spender: assetB,
          sigDeadline: 1_700_001_200n,
        },
        signature: `0x${"11".repeat(65)}`,
      },
    })).toThrow("Permit2 spender must be the Universal Router");
  });

  it("encodes the typed Statics Dollar ETH and ordinary exit paths", () => {
    const deposit = buildDepositETHTransaction(2n * 10n ** 18n, receiver, receiver, 1n, 1n);
    const depositDecoded = decodeFunctionData({ abi: staticsAbi, data: deposit.data });
    expect(depositDecoded.functionName).toBe("depositETH");
    expect(deposit.data.slice(0, 10)).toBe("0xbe1a35f6");
    expect(deposit.value).toBe(2n * 10n ** 18n);

    const recombine = buildRecombineToWETHCall(3n, 100n, 101n, receiver, 99n);
    const recombineDecoded = decodeFunctionData({ abi: staticsAbi, data: recombine });
    expect(recombineDecoded.functionName).toBe("recombineToWETH");
    expect(recombine.slice(0, 10)).toBe("0xa9824eaa");
    expect(recombineDecoded.args).toEqual([3n, 100n, 101n, receiver, 99n]);

    const permitSignature: PermitSignature = {
      value: 100n,
      deadline: 1_700_003_600n,
      v: 27,
      r: "0x1111111111111111111111111111111111111111111111111111111111111111",
      s: "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    const permitRecombine = buildRecombineToWETHWithPermitCall(
      3n,
      100n,
      101n,
      receiver,
      99n,
      permitSignature,
    );
    const permitDecoded = decodeFunctionData({ abi: staticsAbi, data: permitRecombine });
    expect(permitDecoded.functionName).toBe("recombineToWETHWithPermit");
    expect(permitDecoded.args).toEqual([3n, 100n, 101n, receiver, 99n, permitSignature]);

    const permitEthRecombine = buildRecombineToETHWithPermitCall(
      3n,
      100n,
      101n,
      receiver,
      99n,
      permitSignature,
    );
    expect(decodeFunctionData({ abi: staticsAbi, data: permitEthRecombine }).functionName)
      .toBe("recombineToETHWithPermit");
  });

  it("encodes pegged wrapper and protocol revenue paths", () => {
    const mint = buildMintPeggedCall(2n, 100n, 101n, receiver);
    const mintDecoded = decodeFunctionData({ abi: staticsAbi, data: mint });
    expect(mintDecoded.functionName).toBe("mintPegged");
    expect(mint.slice(0, 10)).toBe("0x8a27ba67");
    expect(mintDecoded.args).toEqual([2n, 100n, 101n, receiver]);

    const permitSignature: PermitSignature = {
      value: 101n,
      deadline: 1_700_003_600n,
      v: 27,
      r: "0x1111111111111111111111111111111111111111111111111111111111111111",
      s: "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    const permitTypedData = buildErc20PermitTypedData({
      tokenName: "USDG",
      chainId: 46630,
      token: assetA,
      owner: receiver,
      spender: basketToken,
      value: 101n,
      nonce: 4n,
      deadline: permitSignature.deadline,
    });
    expect(hashTypedData(permitTypedData)).toMatch(/^0x[0-9a-f]{64}$/);

    const permitMint = buildMintPeggedWithPermitCall(2n, 100n, 101n, receiver, permitSignature);
    expect(decodeFunctionData({ abi: staticsAbi, data: permitMint })).toEqual({
      functionName: "mintPeggedWithPermit",
      args: [2n, 100n, 101n, receiver, permitSignature],
    });

    const redeem = buildRedeemPeggedCall(2n, 100n, 99n, receiver);
    const redeemDecoded = decodeFunctionData({ abi: staticsAbi, data: redeem });
    expect(redeemDecoded.functionName).toBe("redeemPegged");
    expect(redeem.slice(0, 10)).toBe("0x7f6636e2");
    expect(redeemDecoded.args).toEqual([2n, 100n, 99n, receiver]);

    const permitRedeem = buildRedeemPeggedWithPermitCall(2n, 100n, 99n, receiver, permitSignature);
    expect(decodeFunctionData({ abi: staticsAbi, data: permitRedeem })).toEqual({
      functionName: "redeemPeggedWithPermit",
      args: [2n, 100n, 99n, receiver, permitSignature],
    });

    const claim = buildClaimPeggedProtocolRevenueCall(2n, 7n, receiver);
    const claimDecoded = decodeFunctionData({ abi: staticsAbi, data: claim });
    expect(claimDecoded.functionName).toBe("claimPeggedProtocolRevenue");
    expect(claimDecoded.args).toEqual([2n, 7n, receiver]);
  });

  it("encodes the fixed testnet faucet claim", () => {
    expect(
      decodeFunctionData({
        abi: staticsTestnetFaucetAbi,
        data: buildTestnetFaucetClaimCall(),
      }),
    ).toEqual({ functionName: "claim", args: undefined });
  });
});
