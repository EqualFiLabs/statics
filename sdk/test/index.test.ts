import { decodeFunctionData } from "viem";
import { describe, expect, it, vi } from "vitest";
import {
  allowsExposureIncrease,
  BasketStatus,
  CanonicalPoolStatus,
  buildActivateLiquidityPositionCall,
  buildActivateCanonicalPoolCall,
  buildBorrowAndProvideLiquidityCall,
  buildBorrowCall,
  buildCheckpointCanonicalPoolCall,
  buildClearCanonicalPoolFeeAllocationCall,
  buildClaimRewardsCall,
  buildClaimLiquidityRewardsCall,
  buildCreateBasketTransaction,
  buildDecommissionBasketCall,
  buildDepositETHTransaction,
  buildInitializeCanonicalPoolCall,
  buildIncreaseStakedLiquidityCall,
  buildMintPeggedCall,
  buildRedeemPeggedCall,
  buildSetSwapFeeConfigurationCall,
  buildSetCanonicalPoolFeeAllocationCall,
  buildStakeLiquidityPositionCall,
  buildUnstakeLiquidityPositionCall,
  buildClaimPeggedProtocolRevenueCall,
  buildRecombineToWETHCall,
  buildRecombineToWETHWithPermitCall,
  buildRecombineToETHWithPermitCall,
  decodePositionInfo,
  effectiveCanonicalFees,
  getSqrtPriceAtTick,
  pendingLpFees,
  planMintUnderlyingRoutes,
  positionSalt,
  Q128,
  Q96,
  quoteBorrow,
  quoteBorrowAndProvideLiquidity,
  quoteExtension,
  quoteHookFee,
  quoteMint,
  quoteRangeAmounts,
  quoteRedeem,
  robinhoodChain,
  selectFeeShares,
  splitSwapFee,
  staticsAbi,
  staticsSwapFeeHookAbi,
  type BasketSnapshot,
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
  constituents: [
    { asset: assetA, bundleAmount: 2n * 10n ** 18n, vaultBalance: 20n * 10n ** 18n },
    { asset: assetB, bundleAmount: 5n * 10n ** 18n, vaultBalance: 50n * 10n ** 18n },
  ],
};

describe("Statics static basket quotes", () => {
  it("splits bilateral hook fees and redirects unavailable reward shares to POL", () => {
    const configuration = {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 5_000n,
      liquidityProviderShareBps: 1_000n,
      stakerShareBps: 3_000n,
      treasuryShareBps: 1_000n,
    };
    expect(splitSwapFee(101n, configuration, true, true)).toEqual({
      polAmount: 50n,
      liquidityProviderAmount: 10n,
      stakerAmount: 30n,
      treasuryAmount: 11n,
    });
    expect(splitSwapFee(101n, configuration, true, false)).toEqual({
      polAmount: 80n,
      liquidityProviderAmount: 10n,
      stakerAmount: 0n,
      treasuryAmount: 11n,
    });
    expect(splitSwapFee(101n, configuration, false, true)).toEqual({
      polAmount: 60n,
      liquidityProviderAmount: 0n,
      stakerAmount: 30n,
      treasuryAmount: 11n,
    });
  });

  it("rejects swap fee splits that do not conserve one hundred percent", () => {
    expect(() => splitSwapFee(100n, {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 5_000n,
      liquidityProviderShareBps: 1_000n,
      stakerShareBps: 3_000n,
      treasuryShareBps: 999n,
    }, true, true)).toThrow("invalid swap fee split");
    expect(() => splitSwapFee(100n, {
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: -1_000n,
      liquidityProviderShareBps: 0n,
      stakerShareBps: 1_000n,
      treasuryShareBps: 10_000n,
    }, true, true)).toThrow("invalid swap fee split");
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
    expect(quote.principals[0]?.amount).toBe(9_405_000_000_000_000_000n);
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
  });

  it("quotes pending PositionManager fees and decodes packed position metadata", () => {
    expect(pendingLpFees(2n, 3n * Q128, 5n * Q128, Q128, 2n * Q128)).toEqual({ amount0: 4n, amount1: 6n });
    const packed = (BigInt(120 & 0xff_ffff) << 32n) | (BigInt((-60) & 0xff_ffff) << 8n) | 1n;
    expect(decodePositionInfo(packed)).toEqual({ tickLower: -60, tickUpper: 120, hasSubscriber: true });
    expect(positionSalt(7n)).toBe(`0x${"0".repeat(63)}7`);
  });

  it("exports Robinhood addresses from the generated deployment binding", () => {
    expect(robinhoodChain.chainId).toBe(4_663);
    expect(robinhoodChain.inputFeeBps).toBe(25);
    expect(robinhoodChain.outputFeeBps).toBe(25);
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
  it("encodes permissionless basket creation with static fee tiers and LTV", () => {
    const transaction = buildCreateBasketTransaction({
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
      loanDuration: 7 * 24 * 60 * 60,
    }, 1n * 10n ** 18n);

    const decoded = decodeFunctionData({ abi: staticsAbi, data: transaction.data });
    expect(decoded.functionName).toBe("createBasket");
    expect(transaction.data.slice(0, 10)).toBe("0xc4b42fb5");
    expect(transaction.value).toBe(1n * 10n ** 18n);
  });

  it("keys basket borrowing by shared PositionNFT ID", () => {
    const data = buildBorrowCall(17n, 4n, 5n * 10n ** 18n, receiver);
    const decoded = decodeFunctionData({ abi: staticsAbi, data });
    expect(decoded.functionName).toBe("borrow");
    expect(data.slice(0, 10)).toBe("0x242011d5");
    expect(decoded.args).toEqual([17n, 4n, 5n * 10n ** 18n, receiver]);
  });

  it("exposes position reward claims and terminal lifecycle calls", () => {
    expect(buildClaimRewardsCall(17n, [assetA, assetB], receiver, [0n, 0n])).toMatch(/^0x[0-9a-f]+$/);
    expect(allowsExposureIncrease(BasketStatus.Active)).toBe(true);
    expect(allowsExposureIncrease(BasketStatus.Quarantined)).toBe(false);
    expect(allowsExposureIncrease(BasketStatus.ExitOnly)).toBe(false);
    expect(buildDecommissionBasketCall(7n)).toMatch(/^0x[0-9a-f]+$/);
  });

  it("encodes the fixed canonical-pool lifecycle without caller-supplied pool policy", () => {
    const sqrtPriceX96 = 2n ** 96n;
    const initialize = buildInitializeCanonicalPoolCall(7n, assetA, sqrtPriceX96);
    const initializeDecoded = decodeFunctionData({ abi: staticsAbi, data: initialize });
    expect(initializeDecoded.functionName).toBe("initializeCanonicalPool");
    expect(initializeDecoded.args).toEqual([7n, assetA, sqrtPriceX96]);

    const checkpoint = buildCheckpointCanonicalPoolCall(7n, assetA);
    expect(decodeFunctionData({ abi: staticsAbi, data: checkpoint }).functionName)
      .toBe("checkpointCanonicalPool");
    const activate = buildActivateCanonicalPoolCall(7n, assetA);
    expect(decodeFunctionData({ abi: staticsAbi, data: activate }).functionName)
      .toBe("activateCanonicalPool");
    expect(CanonicalPoolStatus.Warming).toBe(1);
    expect(CanonicalPoolStatus.Active).toBe(2);
  });

  it("encodes governed bilateral fee configuration", () => {
    const data = buildSetSwapFeeConfigurationCall({
      inputFeeBps: 25n,
      outputFeeBps: 25n,
      polShareBps: 5_000n,
      liquidityProviderShareBps: 1_000n,
      stakerShareBps: 3_000n,
      treasuryShareBps: 1_000n,
    });
    expect(decodeFunctionData({ abi: staticsAbi, data }).functionName).toBe("setSwapFeeConfiguration");
    expect(() => buildSetSwapFeeConfigurationCall({
      inputFeeBps: 65_536n,
      outputFeeBps: 0n,
      polShareBps: 5_000n,
      liquidityProviderShareBps: 1_000n,
      stakerShareBps: 3_000n,
      treasuryShareBps: 1_000n,
    })).toThrow("inputFeeBps exceeds uint16");
  });

  it("encodes canonical pool allocation overrides and exports their events", () => {
    const set = buildSetCanonicalPoolFeeAllocationCall(7n, assetA, {
      polShareBps: 0n,
      liquidityProviderShareBps: 0n,
      stakerShareBps: 8_000n,
      treasuryShareBps: 2_000n,
    });
    const decoded = decodeFunctionData({ abi: staticsAbi, data: set });
    expect(decoded.functionName).toBe("setCanonicalPoolFeeAllocation");
    expect(decoded.args).toEqual([7n, assetA, {
      polShareBps: 0,
      liquidityProviderShareBps: 0,
      stakerShareBps: 8_000,
      treasuryShareBps: 2_000,
    }]);
    const clear = buildClearCanonicalPoolFeeAllocationCall(7n, assetA);
    expect(decodeFunctionData({ abi: staticsAbi, data: clear }).functionName)
      .toBe("clearCanonicalPoolFeeAllocation");
    expect(staticsAbi.some((item) => item.type === "function" && item.name === "canonicalPoolFeeAllocation"))
      .toBe(true);
    expect(staticsAbi.some((item) => item.type === "event" && item.name === "CanonicalPoolFeeAllocationSet"))
      .toBe(true);
    expect(staticsSwapFeeHookAbi.some((item) => item.type === "event" && item.name === "PoolFeeAllocationCleared"))
      .toBe(true);
    expect(() => buildSetCanonicalPoolFeeAllocationCall(7n, assetA, {
      polShareBps: 0n,
      liquidityProviderShareBps: 0n,
      stakerShareBps: 8_000n,
      treasuryShareBps: 1_999n,
    })).toThrow("pool fee allocation must sum to 10000 BPS");
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

    const redeem = buildRedeemPeggedCall(2n, 100n, 99n, receiver);
    const redeemDecoded = decodeFunctionData({ abi: staticsAbi, data: redeem });
    expect(redeemDecoded.functionName).toBe("redeemPegged");
    expect(redeem.slice(0, 10)).toBe("0x7f6636e2");
    expect(redeemDecoded.args).toEqual([2n, 100n, 99n, receiver]);

    const claim = buildClaimPeggedProtocolRevenueCall(2n, 7n, receiver);
    const claimDecoded = decodeFunctionData({ abi: staticsAbi, data: claim });
    expect(claimDecoded.functionName).toBe("claimPeggedProtocolRevenue");
    expect(claimDecoded.args).toEqual([2n, 7n, receiver]);
  });
});
