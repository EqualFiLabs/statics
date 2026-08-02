import {
  encodeAbiParameters,
  encodeFunctionData,
  parseAbi,
  parseAbiParameters,
  toHex,
  type Address,
  type ContractEventArgs,
  type Hex,
} from "viem";

export { robinhoodChain } from "./generated/robinhoodChain.js";

export const BPS = 10_000n;
export const SHARE_SCALE = 10n ** 18n;
export const MAX_LTV_BPS = 9_500n;
export const LOAN_RECOVERY_GRACE_PERIOD = 3_600n;
export const RECOVERY_CALLER_SHARE_BPS = 2_000n;
export const Q96 = 1n << 96n;
export const Q128 = 1n << 128n;
export const Q192 = 1n << 192n;
export const MAX_UINT256 = (1n << 256n) - 1n;
export const MIN_TICK = -887_272;
export const MAX_TICK = 887_272;

export const BasketStatus = {
  Active: 0,
  Quarantined: 1,
  ExitOnly: 2,
} as const;

export type BasketStatus = typeof BasketStatus[keyof typeof BasketStatus];

export const CanonicalPoolStatus = {
  Unconfigured: 0,
  Warming: 1,
  Active: 2,
} as const;

export type CanonicalPoolStatus = typeof CanonicalPoolStatus[keyof typeof CanonicalPoolStatus];

export type FeeTier = {
  minActionShares: bigint;
  feeShares: bigint;
};

export type SwapFeeConfiguration = {
  inputFeeBps: bigint;
  outputFeeBps: bigint;
  polShareBps: bigint;
  liquidityProviderShareBps: bigint;
  basketStakerShareBps: bigint;
  staticsStakerShareBps: bigint;
  treasuryShareBps: bigint;
};

export type PoolFeeConfiguration = SwapFeeConfiguration & { overridden: boolean };

export type SwapFeeSplit = {
  polAmount: bigint;
  liquidityProviderAmount: bigint;
  basketStakerAmount: bigint;
  staticsStakerAmount: bigint;
  treasuryAmount: bigint;
};

export type ConstituentSnapshot = {
  asset: Address;
  bundleAmount: bigint;
  vaultBalance: bigint;
};

export type BasketSnapshot = {
  basketId: bigint;
  basketToken: Address;
  status: BasketStatus;
  totalSupply: bigint;
  mintFeeTiers: readonly FeeTier[];
  redemptionFeeTiers: readonly FeeTier[];
  originationFeeBps: bigint;
  extensionFeeBps: bigint;
  ltvBps: bigint;
  recoveryPenaltyBps: bigint;
  constituents: readonly ConstituentSnapshot[];
};

export type BasketConfiguration = {
  token: Address;
  creator: Address;
  status: BasketStatus;
  assets: readonly Address[];
  bundleAmounts: readonly bigint[];
  mintFeeTiers: readonly FeeTier[];
  redemptionFeeTiers: readonly FeeTier[];
  flashFeeBps: number;
  originationFeeBps: number;
  extensionFeeBps: number;
  ltvBps: number;
  recoveryPenaltyBps: number;
  loanDuration: number;
};

export type CreateBasketParams = {
  name: string;
  symbol: string;
  assets: readonly Address[];
  bundleAmounts: readonly bigint[];
  mintFeeTiers: readonly FeeTier[];
  redemptionFeeTiers: readonly FeeTier[];
  flashFeeBps: number;
  originationFeeBps: number;
  extensionFeeBps: number;
  ltvBps: number;
  recoveryPenaltyBps: number;
  loanDuration: number;
};

export type PoolLaunchParams = {
  sqrtPriceAssetPerBasketX96: bigint;
  pairedAssetAmount: bigint;
};

export type PreparedTransaction = {
  data: Hex;
  value: bigint;
};

export type GlobalRewardAsset = {
  eligibleStake: bigint;
  pendingStake: bigint;
  indexRay: bigint;
  indexedReserve: bigint;
  totalClaimable: bigint;
};

export type GlobalRewardSelection = {
  selected: boolean;
  eligibleStake: bigint;
  pendingStake: bigint;
  eligibleAt: bigint;
};

export type PermitSignature = {
  deadline: bigint;
  v: number;
  r: Hex;
  s: Hex;
};

export type PeggedMintAndRecombineQuote = {
  eligible: boolean;
  exitStatus: number;
  peggedCollateralToken: Address;
  volatileCollateralToken: Address;
  staticsDollarAmount: bigint;
  peggedCollateralPrincipal: bigint;
  peggedMintFee: bigint;
  totalPeggedCollateralIn: bigint;
  volatileCollateralOut: bigint;
  volatileRecombinationFee: bigint;
};

export type MintQuoteLeg = {
  asset: Address;
  baseAmount: bigint;
  feeAmount: bigint;
  amountIn: bigint;
};

export type RedeemQuoteLeg = {
  asset: Address;
  baseAmount: bigint;
  feeAmount: bigint;
  amountOut: bigint;
};

export type BorrowQuote = {
  feeShares: bigint;
  collateralShares: bigint;
  debtShares: bigint;
  penaltyShares: bigint;
  principals: readonly { asset: Address; amount: bigint }[];
};

export type LoanSnapshot = {
  positionId: bigint;
  basketId: bigint;
  collateralShares: bigint;
  feeShares: bigint;
  debtShares: bigint;
  penaltyShares: bigint;
  maturity: bigint;
  assets: readonly Address[];
  principals: readonly bigint[];
};

export type RecoveryQuote = {
  recoverableAt: bigint;
  burnShares: bigint;
  unlockedShares: bigint;
  assets: readonly Address[];
  callerAmounts: readonly bigint[];
  protocolAmounts: readonly bigint[];
};

export type EffectiveCanonicalFees = {
  lpFeePips: bigint;
  lpFeeBps: bigint;
  inputFeeBps: bigint;
  outputFeeBps: bigint;
};

export type LiquidityParams = {
  asset: Address;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  amount0Max: bigint;
  amount1Max: bigint;
  deadline: bigint;
};

export type StakedLiquidityIncreaseRequest = {
  liquidityDelta: bigint;
  amount0Max: bigint;
  amount1Max: bigint;
  deadline: bigint;
};

export type V4PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

export type V4MintPositionRequest = {
  poolKey: V4PoolKey;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  amount0Max: bigint;
  amount1Max: bigint;
  recipient: Address;
  deadline: bigint;
};

export type CanonicalLiquidityInput = {
  asset: Address;
  currency0: Address;
  currency1: Address;
  sqrtPriceX96: bigint;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  deadline: bigint;
};

export type CombinedLiquidityQuote = {
  borrow: BorrowQuote;
  basketSharesMinted: bigint;
  mintInputs: readonly MintQuoteLeg[];
  poolAssetAmounts: readonly { asset: Address; amount: bigint }[];
  totalPrincipalRequirements: readonly { asset: Address; amount: bigint; refund: bigint }[];
  pools: readonly LiquidityParams[];
};

export function mulDivDown(value: bigint, multiplier: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("division by zero");
  return (value * multiplier) / denominator;
}

export function mulDivUp(value: bigint, multiplier: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("division by zero");
  const product = value * multiplier;
  return product === 0n ? 0n : (product - 1n) / denominator + 1n;
}

function integerSquareRoot(value: bigint): bigint {
  if (value < 0n) throw new Error("square root input must be non-negative");
  if (value < 2n) return value;
  let current = 1n << ((BigInt(value.toString(2).length) + 1n) >> 1n);
  while (true) {
    const next = (current + value / current) >> 1n;
    if (next >= current) return current;
    current = next;
  }
}

export function encodeSqrtPriceAssetPerBasketX96(
  assetAmountRaw: bigint,
  basketAmountRaw: bigint,
): bigint {
  if (assetAmountRaw <= 0n || basketAmountRaw <= 0n) {
    throw new Error("raw price amounts must be positive");
  }
  const sqrtPriceX96 = integerSquareRoot((assetAmountRaw * Q192) / basketAmountRaw);
  if (sqrtPriceX96 === 0n || sqrtPriceX96 >= (1n << 160n)) {
    throw new Error("raw price is outside uint160 range");
  }
  return sqrtPriceX96;
}

export function quoteHookFee(realizedAmount: bigint, hookFeeBps: bigint): bigint {
  if (realizedAmount < 0n || hookFeeBps < 0n || hookFeeBps > BPS) throw new Error("invalid hook fee input");
  return mulDivUp(realizedAmount, hookFeeBps, BPS);
}

export function splitSwapFee(
  chargedAmount: bigint,
  configuration: SwapFeeConfiguration,
  liquidityProvidersEligible: boolean,
  basketStakersEligible: boolean,
  staticsStakersEligible: boolean,
): SwapFeeSplit {
  const shareTotal = configuration.polShareBps + configuration.liquidityProviderShareBps
    + configuration.basketStakerShareBps + configuration.staticsStakerShareBps
    + configuration.treasuryShareBps;
  if (
    chargedAmount < 0n
    || configuration.inputFeeBps < 0n
    || configuration.outputFeeBps < 0n
    || configuration.inputFeeBps + configuration.outputFeeBps > 200n
    || configuration.polShareBps < 0n
    || configuration.liquidityProviderShareBps < 0n
    || configuration.basketStakerShareBps < 0n
    || configuration.staticsStakerShareBps < 0n
    || configuration.treasuryShareBps < 0n
    || shareTotal !== BPS
  ) throw new Error("invalid swap fee split");
  let polAmount = mulDivDown(chargedAmount, configuration.polShareBps, BPS);
  let liquidityProviderAmount = mulDivDown(chargedAmount, configuration.liquidityProviderShareBps, BPS);
  let basketStakerAmount = mulDivDown(chargedAmount, configuration.basketStakerShareBps, BPS);
  let staticsStakerAmount = mulDivDown(chargedAmount, configuration.staticsStakerShareBps, BPS);
  const treasuryAmount =
    chargedAmount - polAmount - liquidityProviderAmount - basketStakerAmount - staticsStakerAmount;
  if (!liquidityProvidersEligible) {
    polAmount += liquidityProviderAmount;
    liquidityProviderAmount = 0n;
  }
  if (!basketStakersEligible) {
    polAmount += basketStakerAmount;
    basketStakerAmount = 0n;
  }
  if (!staticsStakersEligible) {
    polAmount += staticsStakerAmount;
    staticsStakerAmount = 0n;
  }
  return { polAmount, liquidityProviderAmount, basketStakerAmount, staticsStakerAmount, treasuryAmount };
}

export function effectiveCanonicalFees(
  lpFeePips: bigint,
  inputFeeBps: bigint,
  outputFeeBps: bigint,
): EffectiveCanonicalFees {
  if (lpFeePips < 0n || lpFeePips % 100n !== 0n) throw new Error("LP fee must convert exactly to bps");
  if (inputFeeBps < 0n || outputFeeBps < 0n || inputFeeBps + outputFeeBps > 200n) {
    throw new Error("invalid hook fees");
  }
  const lpFeeBps = lpFeePips / 100n;
  return { lpFeePips, lpFeeBps, inputFeeBps, outputFeeBps };
}

export function getSqrtPriceAtTick(tick: number): bigint {
  if (!Number.isInteger(tick) || tick < MIN_TICK || tick > MAX_TICK) throw new Error("invalid tick");
  const absTick = Math.abs(tick);
  let price = (absTick & 0x1) !== 0
    ? 0xfffcb933bd6fad37aa2d162d1a594001n
    : 0x100000000000000000000000000000000n;
  const factors: readonly [number, bigint][] = [
    [0x2, 0xfff97272373d413259a46990580e213an],
    [0x4, 0xfff2e50f5f656932ef12357cf3c7fdccn],
    [0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
    [0x10, 0xffcb9843d60f6159c9db58835c926644n],
    [0x20, 0xff973b41fa98c081472e6896dfb254c0n],
    [0x40, 0xff2ea16466c96a3843ec78b326b52861n],
    [0x80, 0xfe5dee046a99a2a811c461f1969c3053n],
    [0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
    [0x200, 0xf987a7253ac413176f2b074cf7815e54n],
    [0x400, 0xf3392b0822b70005940c7a398e4b70f3n],
    [0x800, 0xe7159475a2c29b7443b29c7fa6e889d9n],
    [0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825n],
    [0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5n],
    [0x4000, 0x70d869a156d2a1b890bb3df62baf32f7n],
    [0x8000, 0x31be135f97d08fd981231505542fcfa6n],
    [0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
    [0x20000, 0x5d6af8dedb81196699c329225ee604n],
    [0x40000, 0x2216e584f5fa1ea926041bedfe98n],
    [0x80000, 0x48a170391f7dc42444e8fa2n],
  ];
  for (const [mask, factor] of factors) {
    if ((absTick & mask) !== 0) price = (price * factor) >> 128n;
  }
  if (tick > 0) price = MAX_UINT256 / price;
  return (price + ((1n << 32n) - 1n)) >> 32n;
}

function amount0Delta(sqrtPriceA: bigint, sqrtPriceB: bigint, liquidity: bigint): bigint {
  const [lower, upper] = sqrtPriceA <= sqrtPriceB
    ? [sqrtPriceA, sqrtPriceB]
    : [sqrtPriceB, sqrtPriceA];
  if (lower === 0n) throw new Error("invalid sqrt price");
  return mulDivUp(mulDivUp(liquidity << 96n, upper - lower, upper), 1n, lower);
}

function amount1Delta(sqrtPriceA: bigint, sqrtPriceB: bigint, liquidity: bigint): bigint {
  const difference = sqrtPriceA <= sqrtPriceB
    ? sqrtPriceB - sqrtPriceA
    : sqrtPriceA - sqrtPriceB;
  return mulDivUp(liquidity, difference, Q96);
}

export function quoteRangeAmounts(
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number,
  liquidity: bigint,
): { amount0: bigint; amount1: bigint } {
  if (tickLower >= tickUpper || liquidity <= 0n || liquidity > ((1n << 128n) - 1n)) {
    throw new Error("invalid liquidity range");
  }
  const sqrtLower = getSqrtPriceAtTick(tickLower);
  const sqrtUpper = getSqrtPriceAtTick(tickUpper);
  if (sqrtPriceX96 <= sqrtLower) return { amount0: amount0Delta(sqrtLower, sqrtUpper, liquidity), amount1: 0n };
  if (sqrtPriceX96 < sqrtUpper) {
    return {
      amount0: amount0Delta(sqrtPriceX96, sqrtUpper, liquidity),
      amount1: amount1Delta(sqrtLower, sqrtPriceX96, liquidity),
    };
  }
  return { amount0: 0n, amount1: amount1Delta(sqrtLower, sqrtUpper, liquidity) };
}

export function maximumLiquidityForAmounts(
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number,
  amount0Max: bigint,
  amount1Max: bigint,
): bigint {
  if (amount0Max < 0n || amount1Max < 0n || (amount0Max === 0n && amount1Max === 0n)) {
    throw new Error("invalid liquidity amounts");
  }
  let low = 0n;
  let high = (1n << 128n) - 1n;
  while (low < high) {
    const midpoint = (low + high + 1n) >> 1n;
    const amounts = quoteRangeAmounts(sqrtPriceX96, tickLower, tickUpper, midpoint);
    if (amounts.amount0 <= amount0Max && amounts.amount1 <= amount1Max) low = midpoint;
    else high = midpoint - 1n;
  }
  return low;
}

export function pendingLpFees(
  liquidity: bigint,
  currentFeeGrowth0X128: bigint,
  currentFeeGrowth1X128: bigint,
  lastFeeGrowth0X128: bigint,
  lastFeeGrowth1X128: bigint,
): { amount0: bigint; amount1: bigint } {
  const growth0 = (currentFeeGrowth0X128 - lastFeeGrowth0X128) & MAX_UINT256;
  const growth1 = (currentFeeGrowth1X128 - lastFeeGrowth1X128) & MAX_UINT256;
  return {
    amount0: mulDivDown(liquidity, growth0, Q128),
    amount1: mulDivDown(liquidity, growth1, Q128),
  };
}

export function decodePositionInfo(info: bigint): {
  tickLower: number;
  tickUpper: number;
  hasSubscriber: boolean;
} {
  const signed24 = (value: bigint) => {
    const masked = value & 0xff_ffffn;
    return Number(masked >= 0x80_0000n ? masked - 0x1_000000n : masked);
  };
  return {
    tickLower: signed24(info >> 8n),
    tickUpper: signed24(info >> 32n),
    hasSubscriber: (info & 0xffn) !== 0n,
  };
}

export function positionSalt(tokenId: bigint): Hex {
  if (tokenId < 0n || tokenId > MAX_UINT256) throw new Error("invalid token ID");
  return toHex(tokenId, { size: 32 });
}

export function backingAtSupply(bundleAmount: bigint, supply: bigint): bigint {
  return mulDivUp(bundleAmount, supply, SHARE_SCALE);
}

export function selectFeeShares(tiers: readonly FeeTier[], actionShares: bigint): bigint {
  let selected = 0n;
  let selectedThreshold = 0n;
  let found = false;
  for (const tier of tiers) {
    if (tier.minActionShares <= actionShares && (!found || tier.minActionShares >= selectedThreshold)) {
      selected = tier.feeShares;
      selectedThreshold = tier.minActionShares;
      found = true;
    }
  }
  return selected;
}

export function quoteMint(snapshot: BasketSnapshot, shares: bigint): readonly MintQuoteLeg[] {
  if (shares <= 0n) throw new Error("shares must be positive");
  const feeShares = selectFeeShares(snapshot.mintFeeTiers, shares);
  return snapshot.constituents.map((constituent) => {
    const baseAmount = backingAtSupply(constituent.bundleAmount, snapshot.totalSupply + shares)
      - backingAtSupply(constituent.bundleAmount, snapshot.totalSupply);
    const feeAmount = mulDivUp(constituent.bundleAmount, feeShares, SHARE_SCALE);
    return {
      asset: constituent.asset,
      baseAmount,
      feeAmount,
      amountIn: baseAmount + feeAmount,
    };
  });
}

export function quoteRedeem(snapshot: BasketSnapshot, shares: bigint): readonly RedeemQuoteLeg[] {
  if (shares <= 0n || shares > snapshot.totalSupply) throw new Error("invalid shares");
  const feeShares = selectFeeShares(snapshot.redemptionFeeTiers, shares);
  return snapshot.constituents.map((constituent) => {
    const baseAmount = backingAtSupply(constituent.bundleAmount, snapshot.totalSupply)
      - backingAtSupply(constituent.bundleAmount, snapshot.totalSupply - shares);
    if (baseAmount > constituent.vaultBalance) throw new Error(`insufficient vault balance for ${constituent.asset}`);
    const feeAmount = mulDivUp(constituent.bundleAmount, feeShares, SHARE_SCALE);
    return {
      asset: constituent.asset,
      baseAmount,
      feeAmount,
      amountOut: feeAmount < baseAmount ? baseAmount - feeAmount : 0n,
    };
  });
}

export function quoteBorrow(snapshot: BasketSnapshot, sharesIn: bigint): BorrowQuote {
  if (sharesIn <= 0n) throw new Error("shares must be positive");
  if (snapshot.ltvBps > MAX_LTV_BPS) throw new Error("LTV exceeds protocol maximum");
  const feeShares = mulDivUp(sharesIn, snapshot.originationFeeBps, BPS);
  if (feeShares >= sharesIn) throw new Error("fee consumes shares");
  const collateralShares = sharesIn - feeShares;
  const debtShares = mulDivUp(collateralShares, snapshot.ltvBps, BPS);
  const penaltyShares = mulDivUp(debtShares, snapshot.recoveryPenaltyBps, BPS);
  if (debtShares + penaltyShares > collateralShares) {
    throw new Error("debt and recovery penalty exceed collateral");
  }
  const principals = snapshot.constituents.map(({ asset, bundleAmount }) => ({
    asset,
    amount: mulDivDown(bundleAmount, debtShares, SHARE_SCALE),
  }));
  if (!principals.some(({ amount }) => amount !== 0n)) throw new Error("zero principal");
  return { feeShares, collateralShares, debtShares, penaltyShares, principals };
}

export function quoteRecovery(snapshot: BasketSnapshot, loan: LoanSnapshot): RecoveryQuote {
  if (loan.basketId !== snapshot.basketId) throw new Error("loan and basket do not match");
  if (loan.assets.length !== snapshot.constituents.length || loan.principals.length !== loan.assets.length) {
    throw new Error("loan constituent lengths do not match");
  }
  const burnShares = loan.debtShares + loan.penaltyShares;
  if (burnShares > loan.collateralShares || burnShares > snapshot.totalSupply) {
    throw new Error("invalid recovery shares");
  }
  const callerAmounts: bigint[] = [];
  const protocolAmounts: bigint[] = [];
  for (let index = 0; index < snapshot.constituents.length; index += 1) {
    const constituent = snapshot.constituents[index]!;
    if (loan.assets[index]?.toLowerCase() !== constituent.asset.toLowerCase()) {
      throw new Error("loan constituent order does not match");
    }
    const backingRemoved =
      backingAtSupply(constituent.bundleAmount, snapshot.totalSupply)
      - backingAtSupply(constituent.bundleAmount, snapshot.totalSupply - burnShares);
    const principal = loan.principals[index]!;
    if (principal > backingRemoved) throw new Error("principal exceeds recovered backing");
    const penaltyAmount = backingRemoved - principal;
    const callerAmount = mulDivDown(penaltyAmount, RECOVERY_CALLER_SHARE_BPS, BPS);
    callerAmounts.push(callerAmount);
    protocolAmounts.push(penaltyAmount - callerAmount);
  }
  return {
    recoverableAt: loan.maturity + LOAN_RECOVERY_GRACE_PERIOD,
    burnShares,
    unlockedShares: loan.collateralShares - burnShares,
    assets: loan.assets,
    callerAmounts,
    protocolAmounts,
  };
}

export function quoteBorrowAndProvideLiquidity(
  snapshot: BasketSnapshot,
  sharesIn: bigint,
  poolInputs: readonly CanonicalLiquidityInput[],
  maxInputSlippageBps = 0n,
): CombinedLiquidityQuote {
  if (poolInputs.length !== snapshot.constituents.length) throw new Error("one pool per constituent is required");
  if (maxInputSlippageBps < 0n || maxInputSlippageBps > BPS) throw new Error("invalid input slippage");

  const borrow = quoteBorrow(snapshot, sharesIn);
  if (borrow.feeShares > snapshot.totalSupply) throw new Error("origination fee exceeds current supply");
  const seen = new Set<string>();
  const quotedPools = poolInputs.map((input) => {
    const assetKey = input.asset.toLowerCase();
    if (seen.has(assetKey)) throw new Error(`duplicate pool asset ${input.asset}`);
    seen.add(assetKey);
    if (!snapshot.constituents.some(({ asset }) => asset.toLowerCase() === assetKey)) {
      throw new Error(`asset is not a basket constituent ${input.asset}`);
    }
    const currency0 = input.currency0.toLowerCase();
    const currency1 = input.currency1.toLowerCase();
    const basket = snapshot.basketToken.toLowerCase();
    if (!(
      (currency0 === basket && currency1 === assetKey)
      || (currency1 === basket && currency0 === assetKey)
    )) throw new Error(`invalid canonical pair for ${input.asset}`);
    if (input.tickLower % 10 !== 0 || input.tickUpper % 10 !== 0 || input.deadline <= 0n) {
      throw new Error(`invalid canonical liquidity input for ${input.asset}`);
    }
    const { amount0, amount1 } = quoteRangeAmounts(
      input.sqrtPriceX96,
      input.tickLower,
      input.tickUpper,
      input.liquidity,
    );
    const basketIsCurrency0 = currency0 === basket;
    const basketAmount = basketIsCurrency0 ? amount0 : amount1;
    const assetAmount = basketIsCurrency0 ? amount1 : amount0;
    if (basketAmount === 0n || assetAmount === 0n) throw new Error(`range must require both currencies for ${input.asset}`);
    return { input, amount0, amount1, basketAmount, assetAmount };
  });

  const basketSharesMinted = quotedPools.reduce((total, pool) => total + pool.basketAmount, 0n);
  const mintInputs = quoteMint({ ...snapshot, totalSupply: snapshot.totalSupply - borrow.feeShares }, basketSharesMinted);
  const poolAssetAmounts = snapshot.constituents.map(({ asset }) => ({
    asset,
    amount: quotedPools.find((pool) => pool.input.asset.toLowerCase() === asset.toLowerCase())?.assetAmount ?? 0n,
  }));
  const totalPrincipalRequirements = snapshot.constituents.map(({ asset }, index) => {
    const mintAmount = mintInputs[index]?.amountIn ?? 0n;
    const poolAmount = poolAssetAmounts[index]?.amount ?? 0n;
    const principal = borrow.principals[index]?.amount ?? 0n;
    const amount = mintAmount + poolAmount;
    if (amount > principal) throw new Error(`insufficient borrowed principal for ${asset}`);
    return { asset, amount, refund: principal - amount };
  });
  const cap = (amount: bigint) => mulDivUp(amount, BPS + maxInputSlippageBps, BPS);
  const pools = quotedPools.map(({ input, amount0, amount1 }): LiquidityParams => ({
    asset: input.asset,
    tickLower: input.tickLower,
    tickUpper: input.tickUpper,
    liquidity: input.liquidity,
    amount0Max: cap(amount0),
    amount1Max: cap(amount1),
    deadline: input.deadline,
  }));

  return { borrow, basketSharesMinted, mintInputs, poolAssetAmounts, totalPrincipalRequirements, pools };
}

export function quoteExtension(
  snapshot: BasketSnapshot,
  principals: readonly { asset: Address; amount: bigint }[],
): readonly { asset: Address; amount: bigint }[] {
  return principals.map(({ asset, amount }) => ({
    asset,
    amount: mulDivUp(amount, snapshot.extensionFeeBps, BPS),
  }));
}

export function allowsExposureIncrease(status: BasketStatus): boolean {
  return status === BasketStatus.Active;
}

export const staticsAbi = parseAbi([
  "function createBasket((string name,string symbol,address[] assets,uint256[] bundleAmounts,(uint256 minActionShares,uint256 feeShares)[] mintFeeTiers,(uint256 minActionShares,uint256 feeShares)[] redemptionFeeTiers,uint16 flashFeeBps,uint16 originationFeeBps,uint16 extensionFeeBps,uint16 ltvBps,uint16 recoveryPenaltyBps,uint40 loanDuration) params,(uint160 sqrtPriceAssetPerBasketX96,uint256 pairedAssetAmount)[] pools,uint256[] maxAmountsIn,uint256 launchDeadline) payable returns (uint256 basketId,address token)",
  "function mint(uint256 basketId,uint256 shares,address receiver,uint256[] maxAmountsIn) returns (uint256[] amountsIn)",
  "function redeem(uint256 basketId,uint256 shares,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function quoteMint(uint256 basketId,uint256 shares) view returns (uint256[] amountsIn)",
  "function quoteRedeem(uint256 basketId,uint256 shares) view returns (uint256[] amountsOut)",
  "function basket(uint256 basketId) view returns ((address token,address creator,uint8 status,address[] assets,uint256[] bundleAmounts,(uint256 minActionShares,uint256 feeShares)[] mintFeeTiers,(uint256 minActionShares,uint256 feeShares)[] redemptionFeeTiers,uint16 flashFeeBps,uint16 originationFeeBps,uint16 extensionFeeBps,uint16 ltvBps,uint16 recoveryPenaltyBps,uint40 loanDuration) result)",
  "function basketStatus(uint256 basketId) view returns (uint8)",
  "function basketCount() view returns (uint256)",
  "function basketIdOf(address token) view returns (uint256 basketId,bool exists)",
  "function vaultBalance(uint256 basketId,address asset) view returns (uint256)",
  "function feeSharesFor(uint256 basketId,bool mintAction,uint256 actionShares) view returns (uint256 feeShares)",
  "function createAndDepositBasketCollateral(uint256 basketId,uint256 shares,address receiver) returns (uint256 positionId)",
  "function depositBasketCollateral(uint256 positionId,uint256 basketId,uint256 shares)",
  "function withdrawBasketCollateral(uint256 positionId,uint256 basketId,uint256 shares,address receiver)",
  "function createAndMintBasketCollateral(uint256 basketId,uint256 shares,address receiver,uint256[] maxAmountsIn) returns (uint256 positionId,uint256[] amountsIn)",
  "function mintBasketCollateral(uint256 positionId,uint256 basketId,uint256 shares,uint256[] maxAmountsIn) returns (uint256[] amountsIn)",
  "function redeemBasketCollateral(uint256 positionId,uint256 basketId,uint256 shares,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function basketCollateralPosition(uint256 positionId,uint256 basketId) view returns ((uint256 depositedShares,uint256 lockedShares,uint256 withdrawableAfterBlock) position)",
  "function getBasketRewardAssets(uint256 basketId) view returns (address[] assets)",
  "function getBasketRewards(uint256 positionId,uint256 basketId) view returns (address[] assets,uint256[] amounts)",
  "function claimBasketRewards(uint256 positionId,uint256 basketId,address receiver) returns (address[] assets,uint256[] amounts)",
  "function basketRewardState(uint256 basketId,address asset) view returns ((uint256 totalEligibleShares,uint256 indexRay,uint256 indexedReserve,uint256 crystallizedReserve,uint256 totalClaimable) state)",
  "function createAndStake(uint256 amount,address receiver,address[] rewardAssets) returns (uint256 positionId)",
  "function stake(uint256 positionId,uint256 amount)",
  "function unstake(uint256 positionId,uint256 amount,address receiver)",
  "function optInRewardAssets(uint256 positionId,address[] assets)",
  "function optOutRewardAssets(uint256 positionId,address[] assets)",
  "function claimRewards(uint256 positionId,address[] assets,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function distributeTreasuryFees(address asset) returns (uint256 amount)",
  "function pendingRewards(uint256 positionId,address[] assets) view returns (uint256[] amounts)",
  "function stakePosition(uint256 positionId) view returns ((uint256 stakedBalance,uint256 claimAssetCount,uint256 optedInAssetCount) position)",
  "function rewardAsset(address asset) view returns ((uint256 eligibleStake,uint256 pendingStake,uint256 indexRay,uint256 indexedReserve,uint256 totalClaimable) state)",
  "function positionRewardAssets(uint256 positionId) view returns (address[] assets)",
  "function isRewardAssetOptedIn(uint256 positionId,address asset) view returns (bool)",
  "function rewardSelection(uint256 positionId,address asset) view returns ((bool selected,uint256 eligibleStake,uint256 pendingStake,uint40 eligibleAt) selection)",
  "function maxRewardAssetsPerPosition() pure returns (uint256)",
  "function rewardEligibilityDelay() pure returns (uint256)",
  "function rewardEligibilityBucketSize() pure returns (uint256)",
  "function stakingToken() view returns (address)",
  "function totalStaked() view returns (uint256)",
  "function treasuryAccrued(address asset) view returns (uint256)",
  "function borrow(uint256 positionId,uint256 basketId,uint256 sharesIn,address receiver) returns (uint256 loanId,uint256[] principals)",
  "function repay(uint256 loanId)",
  "function extend(uint256 loanId,uint256[] grossAmountsIn) returns (uint256[] receivedAmounts)",
  "function recover(uint256 loanId)",
  "function quoteBorrow(uint256 basketId,uint256 sharesIn) view returns ((uint256 feeShares,uint256 collateralShares,uint256 debtShares,uint256 penaltyShares,address[] assets,uint256[] principals) result)",
  "function quoteRecovery(uint256 loanId) view returns ((uint256 recoverableAt,uint256 burnShares,uint256 unlockedShares,address[] assets,uint256[] callerAmounts,uint256[] protocolAmounts) result)",
  "function quoteExtension(uint256 loanId) view returns (address[] assets,uint256[] requiredFees)",
  "function loan(uint256 loanId) view returns ((uint256 positionId,uint256 basketId,uint256 collateralShares,uint256 feeShares,uint256 debtShares,uint256 penaltyShares,uint40 maturity,address[] assets,uint256[] principals) result)",
  "function outstandingPrincipal(uint256 basketId,address asset) view returns (uint256)",
  "function flashLoan(uint256 basketId,uint256 shares,address receiver,bytes data)",
  "function balanceOf(address owner) view returns (uint256)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner,address operator) view returns (bool)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function createPosition(address receiver) returns (uint256 positionId)",
  "function closePosition(uint256 positionId)",
  "function nextPositionId() view returns (uint256)",
  "function activeLegCount(uint256 positionId) view returns (uint256)",
  "function positionInitializing(uint256 positionId) view returns (bool)",
  "function isPositionLegActive(uint256 positionId,bytes32 legKey) view returns (bool)",
  "function positionKey(uint256 positionId) view returns (bytes32)",
  "function quarantineBasket(uint256 basketId)",
  "function releaseBasketQuarantine(uint256 basketId)",
  "function decommissionBasket(uint256 basketId)",
  "function depositETH(address staticsDollarReceiver,address shareReceiver,uint256 minStaticsDollar,uint256 minShares) payable returns (uint256 seriesId,uint256 staticsDollarMinted,uint256 sharesMinted)",
  "function depositWETH(uint256 wethAmount,address staticsDollarReceiver,address shareReceiver,uint256 minStaticsDollar,uint256 minShares) returns (uint256 seriesId,uint256 staticsDollarMinted,uint256 sharesMinted)",
  "function recombineToWETH(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minWETHOut) returns (uint8 status,uint256 wethOut)",
  "function recombineToWETHWithPermit(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minWETHOut,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint8 status,uint256 wethOut)",
  "function recombineToETH(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minETHOut) returns (uint8 status,uint256 ethOut)",
  "function recombineToETHWithPermit(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minETHOut,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint8 status,uint256 ethOut)",
  "function pool() view returns (address)",
  "function weth() view returns (address)",
  "function staticsDollar() view returns (address)",
  "function staticsDollarRisk() view returns (address)",
  "function wethProfileId() pure returns (uint256)",
  "function previewPeggedMint(uint256 profileId,uint256 staticsDollarAmount) view returns ((uint256 profileId,address collateralToken,uint256 staticsDollarMinted,uint256 principalCollateral,uint256 feeAmount,uint256 totalCollateralIn,uint256 priceWad) preview)",
  "function mintPegged(uint256 profileId,uint256 staticsDollarAmount,uint256 maximumCollateralIn,address staticsDollarReceiver) returns (uint256 collateralIn)",
  "function mintPeggedWithPermit(uint256 profileId,uint256 staticsDollarAmount,uint256 maximumCollateralIn,address staticsDollarReceiver,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint256 collateralIn)",
  "function quoteMintPeggedAndRecombine(uint256 peggedProfileId,uint256 volatileProfileId,uint256 seriesId,uint256 riskAmount) view returns ((bool eligible,uint8 exitStatus,address peggedCollateralToken,address volatileCollateralToken,uint256 staticsDollarAmount,uint256 peggedCollateralPrincipal,uint256 peggedMintFee,uint256 totalPeggedCollateralIn,uint256 volatileCollateralOut,uint256 volatileRecombinationFee) quote)",
  "function mintPeggedAndRecombine(uint256 peggedProfileId,uint256 volatileProfileId,uint256 seriesId,uint256 riskAmount,uint256 maximumPeggedCollateralIn,uint256 minimumVolatileCollateralOut,address receiver) returns (uint8 status,uint256 peggedCollateralIn,uint256 volatileCollateralOut)",
  "function mintPeggedAndRecombineWithPermit(uint256 peggedProfileId,uint256 volatileProfileId,uint256 seriesId,uint256 riskAmount,uint256 maximumPeggedCollateralIn,uint256 minimumVolatileCollateralOut,address receiver,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint8 status,uint256 peggedCollateralIn,uint256 volatileCollateralOut)",
  "function previewPeggedRedemption(uint256 profileId,uint256 staticsDollarAmount) view returns ((uint256 profileId,address collateralToken,uint256 staticsDollarBurned,uint256 grossCollateral,uint256 feeAmount,uint256 collateralOut,uint256 priceWad) preview)",
  "function redeemPegged(uint256 profileId,uint256 staticsDollarAmount,uint256 minimumCollateralOut,address receiver) returns (uint8 status,uint256 collateralOut)",
  "function peggedRedemptionStatus() view returns (uint8 status,uint256 unhealthyProfileBitmap,uint256 totalSeniorDeficitWad,uint256 recoveryAvailableAt)",
  "function peggedProtocolRevenue(uint256 profileId,address token) view returns (uint256 amount)",
  "function claimPeggedProtocolRevenue(uint256 profileId,uint256 amount,address receiver) returns (uint256 spent,uint256 received)",
  "function installCanonicalPoolIntegration(address poolManager,address hook)",
  "function checkpointCanonicalPool(uint256 basketId,address asset) returns (bool observationStored)",
  "function activateCanonicalPool(uint256 basketId,address asset) returns (int24 referenceTick,int24 spotTick)",
  "function canonicalPool(uint256 basketId,address asset) view returns ((bytes32 poolId,address basketToken,address asset,address currency0,address currency1,address hook,uint24 lpFee,int24 tickSpacing,uint8 status,uint40 initializedAt,uint40 activatedAt,int24 spotTick,int24 referenceTick,uint8 observationCardinality,bool referenceAvailable) pool)",
  "function liquidityIntegration() view returns (address poolManager,address hook,bool installed)",
  "function liquiditySafetyParameters() pure returns (uint24 lpFee,int24 tickSpacing,uint40 warmup,uint32 referenceWindow,uint16 maxDeviationBps)",
  "function installLiquidityManager(address manager)",
  "function setSwapFeeConfiguration((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) configuration)",
  "function swapFeeConfiguration() view returns ((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) configuration)",
  "function setCanonicalPoolFeeConfiguration(uint256 basketId,address asset,(uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) configuration)",
  "function clearCanonicalPoolFeeConfiguration(uint256 basketId,address asset)",
  "function canonicalPoolFeeConfiguration(uint256 basketId,address asset) view returns ((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps,bool overridden) configuration)",
  "function liquidityManager() view returns (address manager,bool installed)",
  "function unwindBasketLiquidity(uint256 basketId,address asset)",
  "function basketLiquidityUnwound(uint256 basketId,address asset) view returns (bool unwound)",
  "function borrowAndProvideLiquidity(uint256 positionId,uint256 basketId,uint256 sharesIn,(address asset,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Max,uint256 amount1Max,uint256 deadline)[] pools,address lpRecipient) returns (uint256 loanId,uint256[] v4TokenIds)",
  "function borrowAndStakeLiquidity(uint256 positionId,uint256 basketId,uint256 sharesIn,(address asset,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Max,uint256 amount1Max,uint256 deadline)[] pools) returns (uint256 loanId,uint256[] v4TokenIds)",
  "function stakeLiquidityPosition(uint256 positionId,uint256 tokenId)",
  "function activateLiquidityPosition(uint256 tokenId)",
  "function increaseStakedLiquidity(uint256 positionId,uint256 tokenId,(uint256 liquidityDelta,uint256 amount0Max,uint256 amount1Max,uint256 deadline) request,address refundReceiver) returns (uint256 spent0,uint256 spent1,uint256 refund0,uint256 refund1)",
  "function unstakeLiquidityPosition(uint256 positionId,uint256 tokenId,address receiver)",
  "function claimLiquidityRewards(uint256 positionId,uint256 tokenId,address receiver,uint256 minAmount0,uint256 minAmount1) returns (uint256 amount0,uint256 amount1)",
  "function stakedLiquidityPosition(uint256 tokenId) view returns ((uint256 positionId,uint256 basketId,address asset,bytes32 poolId,address currency0,address currency1,uint256 eligibleLiquidity,uint256 pendingLiquidity,uint256 eligibleAtBlock,uint256 claimable0,uint256 claimable1,bool staked) position)",
  "function poolLiquidityRewards(bytes32 poolId) view returns ((uint256 totalEligibleLiquidity,uint256 index0Ray,uint256 index1Ray,uint256 indexRemainder0,uint256 indexRemainder1,uint256 indexed0,uint256 indexed1,uint256 crystallized0,uint256 crystallized1,uint256 totalClaimable0,uint256 totalClaimable1) pool)",
  "function pendingLiquidityRewards(uint256 positionId,uint256 tokenId) view returns (address currency0,uint256 amount0,address currency1,uint256 amount1)",
  "function canAccrueLiquidityRewards(bytes32 poolId) view returns (bool)",
  "function canAccrueBasketRewards(bytes32 poolId) view returns (bool)",
  "function treasury() view returns (address)",
  "function creationFee() view returns (uint256 amount)",
  "event PeggedMintedAndRecombined(address indexed caller,address indexed receiver,uint256 indexed peggedProfileId,uint256 volatileProfileId,uint256 seriesId,uint256 riskSharesBurned,uint256 peggedCollateralIn,uint256 staticsDollarMintedAndBurned,uint256 volatileCollateralOut)",
  "event PeggedMintAndRecombineDeferred(address indexed caller,address indexed receiver,uint256 indexed peggedProfileId,uint256 volatileProfileId,uint256 seriesId,uint8 status,uint256 unhealthyProfileBitmap)",
  "event BasketCreated(uint256 indexed basketId,address indexed token,address indexed creator,string name,string symbol)",
  "event BasketConfigured(uint256 indexed basketId,address[] assets,uint256[] bundleAmounts,uint16 flashFeeBps,uint16 originationFeeBps,uint16 extensionFeeBps,uint16 ltvBps,uint16 recoveryPenaltyBps,uint40 loanDuration)",
  "event BasketFeeTiersConfigured(uint256 indexed basketId,bool indexed mintAction,uint256[] minActionShares,uint256[] feeShares)",
  "event BasketLaunched(uint256 indexed basketId,address indexed token,address indexed creator,uint256 basketShares,uint256 poolCount)",
  "event BasketMinted(uint256 indexed basketId,address indexed payer,address indexed receiver,uint256 shares)",
  "event BasketRedeemed(uint256 indexed basketId,address indexed owner,address indexed receiver,uint256 shares)",
  "event PositionCreated(uint256 indexed positionId,address indexed owner)",
  "event PositionClosed(uint256 indexed positionId)",
  "event PositionLegActivated(uint256 indexed positionId,bytes32 indexed legKey)",
  "event PositionLegDeactivated(uint256 indexed positionId,bytes32 indexed legKey)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
  "event BasketCollateralDeposited(uint256 indexed positionId,uint256 indexed basketId,address indexed payer,uint256 shares)",
  "event BasketCollateralWithdrawn(uint256 indexed positionId,uint256 indexed basketId,address indexed receiver,uint256 shares)",
  "event BasketCollateralRedeemed(uint256 indexed positionId,uint256 indexed basketId,address indexed receiver,uint256 shares)",
  "event LoanOriginated(uint256 indexed loanId,uint256 indexed positionId,uint256 indexed basketId,address operator,address receiver,uint256 sharesIn,uint256 feeShares,uint256 collateralShares,uint256 debtShares,uint256 penaltyShares,uint40 maturity)",
  "event LoanRepaid(uint256 indexed loanId,uint256 indexed positionId,address indexed payer)",
  "event LoanExtended(uint256 indexed loanId,uint40 maturity)",
  "event LoanExtensionFeePaid(uint256 indexed loanId,address indexed asset,uint256 requiredFee,uint256 receivedFee)",
  "event LoanRecovered(uint256 indexed loanId,uint256 indexed positionId,address indexed caller,uint256 burnedShares,uint256 unlockedShares)",
  "event RecoveryPenaltyDistributed(uint256 indexed loanId,address indexed asset,uint256 callerAmount,uint256 callerReceived,uint256 protocolAmount)",
  "event StakingPositionCreated(uint256 indexed positionId,address indexed owner,uint256 amount)",
  "event Staked(uint256 indexed positionId,address indexed payer,uint256 amount,uint256 totalPositionStake)",
  "event Unstaked(uint256 indexed positionId,address indexed receiver,uint256 amount,uint256 totalPositionStake)",
  "event GlobalFeeAccrued(address indexed asset,uint256 grossFee,uint256 stakerAmount,uint256 treasuryAmount,uint256 indexRay)",
  "event RewardClaimed(uint256 indexed positionId,address indexed receiver,address indexed asset,uint256 amount)",
  "event TreasuryFeesDistributed(address indexed asset,address indexed treasury,uint256 amount)",
  "event RewardAssetOptedIn(uint256 indexed positionId,address indexed asset,uint256 pendingStake,uint40 eligibleAt)",
  "event RewardStakeScheduled(uint256 indexed positionId,address indexed asset,uint256 pendingStake,uint40 eligibleAt)",
  "event RewardBucketMatured(address indexed asset,uint40 indexed eligibleAt,uint256 amount,uint256 eligibleStake,uint256 indexRay)",
  "event PositionRewardEligibilityActivated(uint256 indexed positionId,address indexed asset,uint256 amount,uint40 eligibleAt,uint256 activationIndexRay)",
  "event RewardAssetOptedOut(uint256 indexed positionId,address indexed asset,uint256 removedEligibleStake,uint256 removedPendingStake)",
  "event RewardAssetDustRouted(address indexed asset,uint256 amount)",
  "event PositionRewardSettled(uint256 indexed positionId,address indexed asset,uint256 amount)",
  "event LiquidityIntegrationInstalled(address indexed poolManager,address indexed hook)",
  "event CanonicalPoolInitialized(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,address currency0,address currency1,uint160 sqrtPriceX96,int24 tick)",
  "event CanonicalPoolCheckpointed(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,bool observationStored)",
  "event CanonicalPoolActivated(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,int24 referenceTick,int24 spotTick)",
  "event LiquidityManagerInstalled(address indexed manager)",
  "event CanonicalPoolSyncedToManager(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,address manager)",
  "event SwapFeeConfigurationChanged((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) configuration)",
  "event CanonicalPoolFeeConfigurationSet(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps)",
  "event CanonicalPoolFeeConfigurationCleared(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId)",
  "event PermanentLiquidityTreasuryAccrued(uint256 indexed basketId,address indexed sourcePoolAsset,address indexed rewardAsset,uint256 amount)",
  "event BasketLiquidityUnwound(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,uint256 constituentReleased,uint256 basketTokensBurned)",
  "event BorrowedLiquidityPositionMinted(uint256 indexed loanId,uint256 indexed basketId,address indexed asset,uint256 v4TokenId,address recipient,uint256 liquidity,uint256 spent0,uint256 spent1,uint256 refund0,uint256 refund1)",
  "event BorrowedLiquidityProvided(uint256 indexed loanId,uint256 indexed positionId,uint256 indexed basketId,address operator,address lpRecipient,uint256 sharesIn,uint256 basketSharesMinted,uint256[] v4TokenIds)",
  "event BorrowedLiquidityStaked(uint256 indexed loanId,uint256 indexed positionId,uint256 indexed basketId,address operator,address beneficiary,uint256 sharesIn,uint256 basketSharesMinted,uint256[] v4TokenIds)",
  "event BasketRewardAccrued(uint256 indexed basketId,address indexed asset,uint256 amount,uint256 indexRay)",
  "event BasketRewardSettled(uint256 indexed positionId,uint256 indexed basketId,address indexed asset,uint256 amount)",
  "event BasketRewardClaimed(uint256 indexed positionId,uint256 indexed basketId,address indexed asset,address receiver,uint256 amount)",
  "event BasketRewardDustRouted(uint256 indexed basketId,address indexed asset,uint256 amount)",
  "event LiquidityPositionStaked(uint256 indexed positionId,uint256 indexed tokenId,bytes32 indexed poolId,uint256 liquidity,uint256 eligibleAtBlock)",
  "event LiquidityPositionActivated(uint256 indexed positionId,uint256 indexed tokenId,bytes32 indexed poolId,uint256 liquidity)",
  "event StakedLiquidityIncreased(uint256 indexed positionId,uint256 indexed tokenId,bytes32 indexed poolId,uint256 liquidityDelta,uint256 spent0,uint256 spent1,uint256 refund0,uint256 refund1,uint256 eligibleAtBlock)",
  "event LiquidityPositionUnstaked(uint256 indexed positionId,uint256 indexed tokenId,bytes32 indexed poolId,address receiver)",
  "event LiquidityRewardAccrued(bytes32 indexed poolId,address indexed asset,uint256 amount,uint256 indexRay)",
  "event LiquidityRewardSettled(uint256 indexed positionId,uint256 indexed tokenId,address indexed asset,uint256 amount)",
  "event LiquidityRewardClaimed(uint256 indexed positionId,uint256 indexed tokenId,address indexed asset,address receiver,uint256 amount)",
]);

export const staticsSwapFeeHookAbi = parseAbi([
  "function staticsDiamond() view returns (address)",
  "function poolManager() view returns (address)",
  "function feeConfiguration() view returns ((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) config)",
  "function setFeeConfiguration(uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps)",
  "function setPoolFeeConfiguration(bytes32 poolId,(uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps) configuration)",
  "function clearPoolFeeConfiguration(bytes32 poolId)",
  "function poolFeeConfiguration(bytes32 poolId) view returns ((uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps,bool overridden) configuration)",
  "function registerPool((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) returns (bytes32 poolId)",
  "function decommissionPool((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)",
  "function poolDecommissioned(bytes32 poolId) view returns (bool decommissioned)",
  "function poolRegistration(bytes32 poolId) view returns ((address currency0,address currency1,bool registered) registration)",
  "function pendingPermanentLiquidity(bytes32 poolId,address currency) view returns (uint256 amount)",
  "function lockedLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
  "function compoundPermanentLiquidity((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) returns (uint128 liquidityAdded)",
  "function releasePermanentLiquidity((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,address receiver) returns (uint256 amount0,uint256 amount1)",
  "function checkpoint((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) returns (bool observationStored)",
  "function oracleState(bytes32 poolId) view returns ((uint40 initializedAt,uint40 lastCheckpointAt,uint40 latestObservationAt,int24 lastTick,int56 tickCumulative,uint8 observationIndex,uint8 observationCardinality) state)",
  "function observationAt(bytes32 poolId,uint8 index) view returns (uint40 timestamp,int56 tickCumulative)",
  "function consult(bytes32 poolId,uint32 window) view returns (int24 referenceTick,int24 spotTick,uint40 oldestObservationAt)",
  "event PoolRegistered(bytes32 indexed poolId,address indexed currency0,address indexed currency1)",
  "event SwapLegFeeAccrued(bytes32 indexed poolId,address indexed currency,bool indexed specifiedLeg,uint256 realizedAmount,uint256 chargedAmount,uint256 polAmount,uint256 liquidityProviderAmount,uint256 basketStakerAmount,uint256 staticsStakerAmount,uint256 treasuryAmount)",
  "event PermanentLiquidityAdded(bytes32 indexed poolId,uint128 liquidity,uint256 amount0,uint256 amount1,uint256 pending0,uint256 pending1)",
  "event PermanentLiquidityFeesCollected(bytes32 indexed poolId,address indexed currency,uint256 amount,uint256 pendingAmount)",
  "event PermanentLiquidityReleased(bytes32 indexed poolId,address indexed receiver,uint128 liquidity,uint256 amount0,uint256 amount1)",
  "event PoolDecommissioned(bytes32 indexed poolId)",
  "event FeeConfigurationSet(uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps)",
  "event PoolFeeConfigurationSet(bytes32 indexed poolId,uint16 inputFeeBps,uint16 outputFeeBps,uint16 polShareBps,uint16 liquidityProviderShareBps,uint16 basketStakerShareBps,uint16 staticsStakerShareBps,uint16 treasuryShareBps)",
  "event PoolFeeConfigurationCleared(bytes32 indexed poolId)",
  "event TickObservationRecorded(bytes32 indexed poolId,uint40 indexed timestamp,int24 tick,int56 tickCumulative,uint8 cardinality)",
]);

export const staticsLiquidityManagerAbi = parseAbi([
  "function staticsDiamond() view returns (address)",
  "function positionManager() view returns (address)",
  "function poolManager() view returns (address)",
  "function permit2() view returns (address)",
  "function registerCanonicalPool(uint256 basketId,address asset,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)",
  "function creditProtocolInventory(uint256 basketId,address token,uint256 amount)",
  "function mintProtocolPosition((uint256 basketId,address asset,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Limit,uint256 amount1Limit,uint256 deadline) request) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement)",
  "function increaseProtocolPosition((uint256 basketId,address asset,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Limit,uint256 amount1Limit,uint256 deadline) request) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement)",
  "function collectProtocolPosition(uint256 basketId,address asset,uint256 deadline) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement)",
  "function removeProtocolLiquidity(uint256 basketId,address asset,uint256 liquidity,uint256 amount0Min,uint256 amount1Min,uint256 deadline) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement)",
  "function burnProtocolPosition(uint256 basketId,address asset,uint256 amount0Min,uint256 amount1Min,uint256 deadline) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement)",
  "function returnProtocolInventory(uint256 basketId,address token,uint256 amount) returns (uint256 spent,uint256 received)",
  "function transferProtocolPosition(uint256 basketId,address asset,address receiver) returns (uint256 tokenId)",
  "function mintUserPosition((uint256 basketId,address asset,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Limit,uint256 amount1Limit,uint256 deadline) request,address recipient,address refundRecipient) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement,uint256 refund0,uint256 refund1)",
  "function increaseUserPosition((uint256 basketId,address asset,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Limit,uint256 amount1Limit,uint256 deadline) request,uint256 tokenId,address refundRecipient) returns ((uint256 tokenId,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1) movement,uint256 refund0,uint256 refund1)",
  "function canonicalPoolHash(uint256 basketId,address asset) view returns (bytes32)",
  "function protocolInventory(uint256 basketId,address token) view returns (uint256 amount)",
  "function totalProtocolInventory(address token) view returns (uint256 amount)",
  "function protocolPositionId(uint256 basketId,address asset) view returns (uint256 tokenId)",
  "event CanonicalPoolRegistered(uint256 indexed basketId,address indexed asset,bytes32 indexed poolKeyHash)",
  "event ProtocolInventoryCredited(uint256 indexed basketId,address indexed token,uint256 amount)",
  "event ProtocolInventoryReturned(uint256 indexed basketId,address indexed token,uint256 spent,uint256 received)",
  "event ProtocolPositionMinted(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,uint256 liquidity,uint256 spent0,uint256 spent1)",
  "event ProtocolPositionIncreased(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,uint256 liquidity,uint256 spent0,uint256 received0,uint256 spent1,uint256 received1)",
  "event ProtocolPositionCollected(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,uint256 received0,uint256 received1)",
  "event ProtocolPositionReduced(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,uint256 liquidity,uint256 received0,uint256 received1)",
  "event ProtocolPositionTransferred(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,address receiver)",
  "event ProtocolPositionBurned(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,uint256 received0,uint256 received1)",
  "event UserPositionMinted(uint256 indexed basketId,address indexed asset,uint256 indexed tokenId,address recipient,address refundRecipient,uint256 spent0,uint256 spent1,uint256 refund0,uint256 refund1)",
]);

export const v4PositionManagerReadAbi = parseAbi([
  "function nextTokenId() view returns (uint256)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function approve(address to,uint256 tokenId)",
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function getPoolAndPositionInfo(uint256 tokenId) view returns ((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,uint256 info)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
]);

export const v4StateViewReadAbi = parseAbi([
  "function poolManager() view returns (address)",
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
  "function getPositionInfo(bytes32 poolId,address owner,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint128 liquidity,uint256 feeGrowthInside0LastX128,uint256 feeGrowthInside1LastX128)",
  "function getFeeGrowthInside(bytes32 poolId,int24 tickLower,int24 tickUpper) view returns (uint256 feeGrowthInside0X128,uint256 feeGrowthInside1X128)",
]);

export const permit2AllowanceAbi = parseAbi([
  "function allowance(address owner,address token,address spender) view returns (uint160 amount,uint48 expiration,uint48 nonce)",
  "function approve(address token,address spender,uint160 amount,uint48 expiration)",
]);

export type StaticsLiquidityEventName =
  | "StakingPositionCreated"
  | "Staked"
  | "Unstaked"
  | "GlobalFeeAccrued"
  | "RewardClaimed"
  | "TreasuryFeesDistributed"
  | "RewardAssetOptedIn"
  | "RewardStakeScheduled"
  | "RewardBucketMatured"
  | "PositionRewardEligibilityActivated"
  | "RewardAssetOptedOut"
  | "RewardAssetDustRouted"
  | "PositionRewardSettled"
  | "LiquidityIntegrationInstalled"
  | "CanonicalPoolInitialized"
  | "CanonicalPoolCheckpointed"
  | "CanonicalPoolActivated"
  | "LiquidityManagerInstalled"
  | "CanonicalPoolSyncedToManager"
  | "SwapFeeConfigurationChanged"
  | "CanonicalPoolFeeConfigurationSet"
  | "CanonicalPoolFeeConfigurationCleared"
  | "PermanentLiquidityTreasuryAccrued"
  | "BasketLiquidityUnwound"
  | "BorrowedLiquidityPositionMinted"
  | "BorrowedLiquidityProvided"
  | "BorrowedLiquidityStaked"
  | "BasketRewardAccrued"
  | "BasketRewardSettled"
  | "BasketRewardClaimed"
  | "BasketRewardDustRouted"
  | "LiquidityPositionStaked"
  | "LiquidityPositionActivated"
  | "StakedLiquidityIncreased"
  | "LiquidityPositionUnstaked"
  | "LiquidityRewardAccrued"
  | "LiquidityRewardSettled"
  | "LiquidityRewardClaimed";

export type StaticsLiquidityEventArgs<Name extends StaticsLiquidityEventName> =
  ContractEventArgs<typeof staticsAbi, Name>;

export type StaticsPositionEventName =
  | "PositionCreated"
  | "PositionClosed"
  | "PositionLegActivated"
  | "PositionLegDeactivated"
  | "Transfer"
  | "BasketCollateralDeposited"
  | "BasketCollateralWithdrawn"
  | "BasketCollateralRedeemed"
  | "BasketRewardSettled"
  | "BasketRewardClaimed"
  | "StakingPositionCreated"
  | "Staked"
  | "Unstaked"
  | "RewardAssetOptedIn"
  | "RewardStakeScheduled"
  | "PositionRewardEligibilityActivated"
  | "RewardAssetOptedOut"
  | "PositionRewardSettled";

export type StaticsPositionEventArgs<Name extends StaticsPositionEventName> =
  ContractEventArgs<typeof staticsAbi, Name>;

export type StaticsLendingEventName =
  | "LoanOriginated"
  | "LoanRepaid"
  | "LoanExtended"
  | "LoanExtensionFeePaid"
  | "LoanRecovered"
  | "RecoveryPenaltyDistributed";

export type StaticsLendingEventArgs<Name extends StaticsLendingEventName> =
  ContractEventArgs<typeof staticsAbi, Name>;

export type StaticsHookEventName =
  | "PoolRegistered"
  | "SwapLegFeeAccrued"
  | "PermanentLiquidityAdded"
  | "PermanentLiquidityFeesCollected"
  | "PermanentLiquidityReleased"
  | "PoolDecommissioned"
  | "FeeConfigurationSet"
  | "PoolFeeConfigurationSet"
  | "PoolFeeConfigurationCleared"
  | "TickObservationRecorded";

export type StaticsHookEventArgs<Name extends StaticsHookEventName> =
  ContractEventArgs<typeof staticsSwapFeeHookAbi, Name>;

export type StaticsLiquidityManagerEventName =
  | "CanonicalPoolRegistered"
  | "ProtocolInventoryCredited"
  | "ProtocolInventoryReturned"
  | "ProtocolPositionMinted"
  | "ProtocolPositionIncreased"
  | "ProtocolPositionCollected"
  | "ProtocolPositionReduced"
  | "ProtocolPositionTransferred"
  | "ProtocolPositionBurned"
  | "UserPositionMinted";

export type StaticsLiquidityManagerEventArgs<Name extends StaticsLiquidityManagerEventName> =
  ContractEventArgs<typeof staticsLiquidityManagerAbi, Name>;

export const basketTokenAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 value) returns (bool)",
  "function permit(address owner,address spender,uint256 value,uint256 deadline,uint8 v,bytes32 r,bytes32 s)",
  "function nonces(address owner) view returns (uint256)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
]);

export const staticsDollarTokenAbi = basketTokenAbi;

export const staticsBasketErrorAbi = parseAbi([
  "error BasketNotFound(uint256 basketId)",
  "error InvalidBasketDefinition()",
  "error FeeExceedsCap(uint16 feeBps)",
  "error LtvExceedsMaximum(uint16 ltvBps)",
  "error InvalidReceiver()",
  "error InvalidShares()",
  "error InvalidAmountsLength()",
  "error MaximumInputExceeded(address asset,uint256 required,uint256 maximum)",
  "error MinimumOutputNotMet(address asset,uint256 actual,uint256 minimum)",
  "error ActionPaused(uint256 action)",
  "error InsufficientVaultBalance(address asset,uint256 required,uint256 available)",
  "error IncorrectCreationFee(uint256 expected,uint256 actual)",
  "error CreationFeeTransferFailed(address treasury,uint256 amount)",
  "error PermissionlessBasketCreationDisabled()",
  "error LiquidityIntegrationNotInstalled()",
  "error LiquidityManagerNotInstalled()",
  "error InvalidPoolLaunchParameters()",
  "error InvalidPoolLaunchPrice(address asset,uint160 sqrtPriceAssetPerBasketX96)",
  "error InvalidPoolLaunchLiquidity(address asset,uint256 pairedAssetAmount)",
  "error CanonicalPoolAlreadyAssociated(bytes32 poolId,uint256 basketId,address asset)",
  "error LaunchInputExceedsMaximum(address asset,uint256 required,uint256 maximum)",
  "error InsufficientLaunchAssetReceived(address asset,uint256 required,uint256 received)",
  "error LaunchDebitExceedsMaximum(address asset,uint256 actualDebit,uint256 maximum)",
  "error LaunchDeadlineExpired(uint256 deadline,uint256 timestamp)",
  "error InsufficientTransferReceived(address asset,uint256 required,uint256 received)",
  "error BasketNotActive(uint256 basketId,uint8 status)",
]);

export const staticsPositionErrorAbi = parseAbi([
  "error OnlyDiamondSelf(address caller)",
  "error PositionInitializing(uint256 positionId)",
  "error PositionHasActiveLegs(uint256 positionId,uint256 activeLegCount)",
  "error AlreadyInitialized()",
  "error NotInitialized()",
  "error NotPositionOwnerOrApproved(uint256 positionId,address caller)",
  "error ZeroLegKey()",
  "error PositionLegAlreadyActive(uint256 positionId,bytes32 legKey)",
  "error PositionLegNotActive(uint256 positionId,bytes32 legKey)",
  "error ERC721InvalidOwner(address owner)",
  "error ERC721NonexistentToken(uint256 tokenId)",
  "error ERC721IncorrectOwner(address sender,uint256 tokenId,address owner)",
  "error ERC721InvalidSender(address sender)",
  "error ERC721InvalidReceiver(address receiver)",
  "error ERC721InsufficientApproval(address operator,uint256 tokenId)",
  "error ERC721InvalidApprover(address approver)",
  "error ERC721InvalidOperator(address operator)",
]);

export const staticsCollateralErrorAbi = parseAbi([
  "error BasketNotFound(uint256 basketId)",
  "error BasketNotActive(uint256 basketId,uint8 status)",
  "error InvalidShares()",
  "error InvalidReceiver()",
  "error InsufficientTransferReceived(address token,uint256 required,uint256 received)",
  "error InsufficientPositionShares(uint256 requested,uint256 available)",
  "error PositionSharesLocked(uint256 requested,uint256 unlocked)",
  "error InsufficientLockedShares(uint256 requested,uint256 locked)",
  "error PositionDepositTooRecent(uint256 positionId,uint256 basketId,uint256 withdrawableAfterBlock)",
]);

export const staticsLendingErrorAbi = parseAbi([
  "error BasketNotFound(uint256 basketId)",
  "error LoanNotFound(uint256 loanId)",
  "error InvalidReceiver()",
  "error InvalidShares()",
  "error ZeroPrincipal()",
  "error ActionPaused(uint256 action)",
  "error InsufficientVaultBalance(address asset,uint256 required,uint256 available)",
  "error LoanExpired(uint256 loanId,uint40 maturity)",
  "error LoanNotRecoverable(uint256 loanId,uint256 recoverableAt)",
  "error MaturityOverflow()",
  "error InsufficientTransferReceived(address asset,uint256 required,uint256 received)",
  "error InvalidExtensionInputLength(uint256 provided,uint256 required)",
]);

export const staticsRewardsErrorAbi = parseAbi([
  "error InvalidAmount()",
  "error InvalidReceiver()",
  "error InvalidAmountsLength()",
  "error InvalidRewardAssets()",
  "error InsufficientStake(uint256 requested,uint256 available)",
  "error IncompatibleStakingToken(uint256 requested,uint256 received)",
  "error MinimumOutputNotMet(address asset,uint256 actual,uint256 minimum)",
  "error NoRewards(uint256 positionId)",
  "error OnlySwapFeeHook(address caller,address expected)",
  "error IncompatibleRewardAsset(address asset,uint256 requested,uint256 received)",
  "error InvalidStakingToken()",
  "error InvalidRewardAsset(address asset)",
  "error RewardAssetAlreadyOptedIn(uint256 positionId,address asset)",
  "error RewardAssetNotOptedIn(uint256 positionId,address asset)",
  "error RewardAssetLimitExceeded(uint256 positionId)",
  "error InvalidMaturitySchedule(uint40 eligibleAt)",
]);

export const staticsTokenErrorAbi = parseAbi([
  "error ERC20InsufficientBalance(address sender,uint256 balance,uint256 needed)",
  "error ERC20InvalidSender(address sender)",
  "error ERC20InvalidReceiver(address receiver)",
  "error ERC20InsufficientAllowance(address spender,uint256 allowance,uint256 needed)",
  "error ERC20InvalidApprover(address approver)",
  "error ERC20InvalidSpender(address spender)",
]);

export const staticsDollarRiskTokenAbi = parseAbi([
  "function balanceOf(address account,uint256 id) view returns (uint256)",
  "function isApprovedForAll(address account,address operator) view returns (bool)",
  "function setApprovalForAll(address operator,bool approved)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "event ApprovalForAll(address indexed account,address indexed operator,bool approved)",
  "event TransferSingle(address indexed operator,address indexed from,address indexed to,uint256 id,uint256 value)",
]);

export const wethAbi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 value) returns (bool)",
  "function deposit() payable",
  "function withdraw(uint256 amount)",
]);

export const staticsDollarCoreAbi = parseAbi([
  "function staticsDollar() view returns (address)",
  "function staticsDollarRisk() view returns (address)",
  "function periphery() view returns (address)",
  "function bootstrapFinalized() view returns (bool)",
  "function seniorLiabilities() view returns (uint256)",
  "function globalImpairmentLatched() view returns (bool)",
  "function collateralProfile(uint256 profileId) view returns ((address collateralToken,address oracle,uint8 decimals,uint16 collateralRatioBps,uint16 priceBandBps,uint16 mintFeeBps,uint16 redemptionFeeBps,uint16 insuranceTargetBps,uint16 insuranceFeeBps,uint8 kind,uint8 mode,uint256 pegMinPriceWad,uint256 pegMaxPriceWad,uint256 activeSeriesId,uint256 accountedCollateral,uint256 insuranceReserve,uint256 seniorOutstanding,uint256 debtCeiling) profile)",
  "function riskSeries(uint256 seriesId) view returns ((uint256 profileId,address collateralToken,uint256 seniorOutstanding,uint256 riskSharesOutstanding,uint256 accountedCollateral,uint256 startPriceWad,uint256 collateralPerPairWad,uint256 seniorCollateralPerUnitWad,uint256 juniorCollateralPerUnitWad,uint256 collateralRatioBps,uint256 priceBandBps,uint256 startedAt,uint256 retiredAt,uint256 successorSeriesId,uint8 status) series)",
  "function previewDeposit(uint256 profileId,uint256 collateralAmount) view returns ((uint256 profileId,uint256 seriesId,uint256 collateralIn,uint256 staticsDollarMinted,uint256 sharesMinted,uint256 feeAmount,uint256 insuranceContribution,uint256 priceWad,uint256 collateralPerPairWad,uint256 collateralRatioBpsAfter) preview)",
  "function previewRecombine(uint256 seriesId,uint256 staticsDollarAmount) view returns ((uint256 profileId,uint256 seriesId,address collateralToken,uint256 staticsDollarBurned,uint256 sharesBurned,uint256 collateralOut,uint256 feeAmount,uint256 priceWad,uint256 collateralRatioBpsAfter) preview)",
  "function profileSolvency(uint256 profileId) view returns ((uint256 collateralValueWad,uint256 seniorLiabilitiesWad,uint256 seniorDeficitWad,bool oracleAvailable,bool healthy) solvency)",
  "function globalImpairment() view returns (uint8 phase,uint256 unhealthyProfileBitmap,uint256 totalSeniorDeficitWad,uint256 recoveryAvailableAt)",
  "function peggedRedemptionStatus() view returns (uint8 status,uint256 unhealthyProfileBitmap,uint256 totalSeniorDeficitWad,uint256 recoveryAvailableAt)",
  "function profileOperationPaused(uint256 profileId,uint256 operation) view returns (bool paused)",
  "function pausedProfileOperations(uint256 profileId) view returns (uint256 operations)",
  "function collateralUsdPriceWad(uint256 profileId) view returns (uint256 priceWad)",
  "function profileSeriesCount(uint256 profileId) view returns (uint256 count)",
  "function profileSeriesAt(uint256 profileId,uint256 index) view returns (uint256 seriesId)",
]);

/**
 * Periphery diamond: consumable Risk Share liquidity and the Dollar-only exit
 * it backs.
 *
 * These live at a different address from the core pool. Read it from
 * `staticsDollarCoreAbi`'s `periphery()` rather than configuring it separately,
 * so the two can never disagree about which periphery is in use.
 *
 * The pairing vault is the reason `recombineManaged` is restricted to the
 * periphery: it burns a redeemer's Dollar against Risk Shares supplied through
 * a PositionNFT, which lets a holder exit without sourcing the junior tranche.
 * Ordinary `recombine` still requires both legs.
 */
export const staticsDollarPeripheryAbi = parseAbi([
  // -- StakingFacet: every staked Risk Share is immediately consumable.
  "function createAndStakeRiskShares(uint256 seriesId,uint256 amount,address receiver) returns (uint256 positionId)",
  "function stakeRiskShares(uint256 positionId,uint256 seriesId,uint256 amount)",
  "function unstakeRiskShares(uint256 positionId,uint256 seriesId,uint256 amount,address receiver) returns (uint256 principalOut)",
  "function claimRiskProceeds(uint256 positionId,uint256 seriesId,address receiver) returns (uint256 collateralAmount,uint256 staticsDollarAmount,uint256 staticsAmount)",
  "function fundRiskCollateralIncentives(uint256 seriesId,uint256 amount) returns (uint256 received)",
  "function fundRiskDollarIncentives(uint256 seriesId,uint256 amount) returns (uint256 received)",
  "function fundRiskStaticsIncentives(uint256 seriesId,uint256 amount) returns (uint256 received)",
  "function riskIncentives(uint256 seriesId) view returns ((address collateralToken,address staticsToken,uint256 collateralReserve,uint256 staticsDollarReserve,uint256 staticsReserve,uint256 destinationSeriesId,bool routedGlobal,bool finalized) view_)",
  "function finalizeRiskIncentives(uint256 seriesId) returns (uint256 destinationSeriesId,bool routedGlobal)",
  "function processSeriesTransition(uint256 oldSeriesId) returns (uint256 newSeriesId,uint256 newPrincipal)",
  "function settleSeriesMigration(uint256 positionId,uint256 oldSeriesId) returns (uint256 newSeriesId,uint256 newPrincipal)",
  "function closeRiskLiquidity(uint256 positionId,uint256 seriesId)",
  "function riskLiquidity(uint256 positionId,uint256 seriesId) view returns ((uint256 effectiveShares,uint256 claimableCollateral,uint256 claimableStaticsDollar,uint256 claimableStatics,uint64 epoch,bool exists) view_)",
  "function totalRiskLiquidity(uint256 seriesId) view returns (uint256 effectiveShares)",
  "function riskLiquidityScaleRay(uint256 seriesId) view returns (uint256 scaleRay)",
  "function positionSeriesCount(uint256 positionId) view returns (uint256 count)",
  "function positionSeriesAt(uint256 positionId,uint256 index) view returns (uint256 seriesId)",
  "function seriesMigration(uint256 oldSeriesId) view returns ((uint256 newSeriesId,uint256 oldPrincipal,uint256 remainingOldPrincipal,uint256 remainingNewPrincipal,uint256 remainingStaticsDollar,uint256 remainingCollateral,bool returned,bool claimed) migration)",
  "function reservedBalance(address token) view returns (uint256 amount)",
  "event RiskSharesStaked(uint256 indexed positionId,uint256 indexed seriesId,address indexed supplier,uint256 amount)",
  "event RiskSharesUnstaked(uint256 indexed positionId,uint256 indexed seriesId,address indexed receiver,uint256 amount)",
  "event RiskProceedsClaimed(uint256 indexed positionId,uint256 indexed seriesId,address indexed receiver,address collateralToken,address staticsToken,uint256 collateralAmount,uint256 staticsDollarAmount,uint256 staticsAmount)",
  "event RiskProceedsAccrued(uint256 indexed seriesId,uint64 indexed epoch,address indexed token,uint256 amount,bytes32 source)",
  "event RiskProceedsSettled(uint256 indexed positionId,uint256 indexed seriesId,uint256 collateralAdded,uint256 staticsDollarAdded,uint256 staticsAdded,uint256 accruedCollateral,uint256 accruedStaticsDollar,uint256 accruedStatics)",
  "event RiskIncentivesFunded(uint256 indexed seriesId,address indexed token,address indexed funder,uint256 requestedAmount,uint256 receivedAmount)",
  "event RiskIncentivesReleased(uint256 indexed seriesId,uint64 indexed epoch,uint256 riskSharesConsumed,uint256 collateralAmount,uint256 staticsDollarAmount,uint256 staticsAmount)",
  "event RiskIncentivesRolledOver(uint256 indexed seriesId,uint256 indexed destinationSeriesId,uint256 collateralAmount,uint256 staticsDollarAmount,uint256 staticsAmount)",
  "event RiskIncentivesRoutedGlobal(uint256 indexed seriesId,uint256 collateralAmount,uint256 staticsDollarAmount,uint256 staticsAmount)",

  // -- PairingVaultFacet: redeeming Dollar alone against that liquidity
  "function redeem(uint256 seriesId,uint256 staticsDollarAmount,uint256 minStaticsDollarRedeemed,uint256 minCollateralPerStaticsDollarWad,uint256 deadline,address receiver) returns (uint8 status,uint256 staticsDollarRedeemed,uint256 collateralOut)",
  "function redeemToETH(uint256 seriesId,uint256 staticsDollarAmount,uint256 minStaticsDollarRedeemed,uint256 minCollateralPerStaticsDollarWad,uint256 deadline,address receiver) returns (uint8 status,uint256 staticsDollarRedeemed,uint256 ethOut)",
  "function previewRedeem(uint256 seriesId,uint256 staticsDollarAmount) view returns ((uint256 staticsDollarRedeemed,uint256 grossCollateral,uint256 collateralToRedeemer,uint256 collateralToRiskSuppliers,uint256 collateralToInsurance,uint256 seniorCollateralPerUnitWad) preview)",
  "function redeemableLiquidity(uint256 seriesId) view returns (uint256 staticsDollarAmount)",
  "function redemptionParams() view returns (uint16 redemptionFeeBps,uint16 supplierShareBps)",
  "function setRedemptionParams(uint16 redemptionFeeBps,uint16 supplierShareBps)",
  "event Redeemed(address indexed caller,address indexed receiver,uint256 indexed seriesId,uint256 staticsDollarRedeemed,uint256 collateralToRedeemer,uint256 collateralToRiskSuppliers,uint256 collateralToInsurance)",
  "event RedemptionDeferred(address indexed caller,address indexed receiver,uint256 indexed seriesId,uint8 status,uint256 unhealthyProfileBitmap)",
  "event RedemptionParamsSet(uint16 redemptionFeeBps,uint16 supplierShareBps)",
  "event CustodyReserved(bytes32 indexed account,address indexed token,uint256 amount)",
]);

/**
 * Reverts unique to the periphery facets above.
 *
 * Shared names -- ZeroAmount, ZeroAddress, SeriesNotActive,
 * ProfileOperationPaused, InsufficientTransferReceived, UnexpectedExitStatus,
 * NativeTransferFailed -- are already in `staticsDollarErrorAbi` with identical
 * signatures and are deliberately not repeated, because a duplicate selector in
 * one array makes the decode ambiguous. Decode against both.
 */
export const staticsDollarPeripheryErrorAbi = parseAbi([
  "error NotPositionOwnerOrApproved(uint256 positionId,address caller)",
  "error UnknownRiskLiquidity(uint256 positionId,uint256 seriesId)",
  "error InsufficientRiskLiquidity(uint256 requested,uint256 available)",
  "error NoRiskProceeds(uint256 positionId,uint256 seriesId)",
  "error SeriesNotIncentiveEligible(uint256 seriesId)",
  "error SeriesIncentivesNotFinalizable(uint256 seriesId)",
  "error RiskLiquidityHasValue(uint256 positionId,uint256 seriesId)",
  "error RiskLiquidityAmountTooSmall(uint256 requested)",
  "error NoRiskLiquidity()",
  "error FillBelowMinimum(uint256 fill,uint256 minimum)",
  "error RateBelowMinimum(uint256 rateWad,uint256 minimumRateWad)",
  "error InvalidRedemptionParams(uint16 feeBps,uint16 supplierShareBps)",
  "error SeriesTransitionPending(uint256 seriesId)",
  "error NotWETHCollateral()",
  "error DeadlineExpired(uint256 deadline,uint256 currentTimestamp)",
  "error FixedAllocationExceedsGross(uint256 fixedSeniorCollateral,uint256 grossCollateral)",
  "error RiskLiquidityScaleExhausted(uint256 storedUnits)",
  "error ConsumeExceedsLiquidity(uint256 requested,uint256 available)",
  "error InsufficientUnreserved(address token,uint256 requested,uint256 available)",
  "error GlobalReservationShortfall(address token,uint256 reserved,uint256 balance)",
  "error DebitExceedsAuthorization(address token,uint256 spent,uint256 maximum)",
  "error BalanceDecreasedDuringPull(address token,uint256 beforeBalance,uint256 afterBalance)",
  "error SeriesMigrationNotReady(uint256 seriesId)",
  "error SeriesMigrationAlreadyProcessed(uint256 seriesId)",
  "error NotContractOwner(address caller,address owner)",
  // OpenZeppelin reverts these facets inherit. Without them an ordinary
  // transfer failure decodes as an unknown selector.
  "error SafeERC20FailedOperation(address token)",
  "error ReentrancyGuardReentrantCall()",
]);

export const staticsDollarErrorAbi = parseAbi([
  "error ZeroAddress()",
  "error ZeroAmount()",
  "error InvalidProfile(uint256 profileId)",
  "error InvalidSeries(uint256 seriesId)",
  "error InvalidProfileKind(uint256 profileId,uint8 expected,uint8 actual)",
  "error InvalidProfileMode(uint256 profileId,uint8 mode)",
  "error ProfileOperationPaused(uint256 profileId,uint256 operation)",
  "error ProfileImpaired(uint256 profileId,uint256 seniorDeficitWad)",
  "error OutputBelowMinimum(uint256 actual,uint256 minimum)",
  "error SharesAboveMaximum(uint256 required,uint256 maximum)",
  "error CollateralAboveMaximum(uint256 required,uint256 maximum)",
  "error DepositTooSmall()",
  "error RedemptionTooSmall()",
  "error DebtCeilingExceeded(uint256 profileId,uint256 attemptedSeniorOutstanding,uint256 debtCeiling)",
  "error SeriesNotActive(uint256 seriesId)",
  "error TransitionRequired(uint256 profileId,uint256 seriesId,uint256 currentPriceWad)",
  "error CollateralExitUnavailable(uint8 status,uint256 unhealthyProfileBitmap)",
  "error UnexpectedCollateralProfile(uint256 expectedProfileId,uint256 actualProfileId)",
  "error InsufficientTransferReceived(address token,uint256 required,uint256 received)",
  "error UnexpectedOutputAmount(address token,uint256 expected,uint256 observed)",
  "error SeriesUnavailableForOrdinaryRecombination(uint256 seriesId,uint8 status)",
  "error UnexpectedExitStatus(uint8 status)",
  "error UnexpectedRiskIngressState()",
  "error NativeTransferFailed(address receiver,uint256 amount)",
]);

export function buildCreateBasketTransaction(
  params: CreateBasketParams,
  pools: readonly PoolLaunchParams[],
  maxAmountsIn: readonly bigint[],
  launchDeadline: bigint,
  creationFee: bigint,
): PreparedTransaction {
  return {
    data: encodeFunctionData({
      abi: staticsAbi,
      functionName: "createBasket",
      args: [params, pools, maxAmountsIn, launchDeadline],
    }),
    value: creationFee,
  };
}

export function buildApproveV4PositionCall(operator: Address, tokenId: bigint): Hex {
  return encodeFunctionData({
    abi: v4PositionManagerReadAbi,
    functionName: "approve",
    args: [operator, tokenId],
  });
}

export function buildPermit2ApproveCall(
  token: Address,
  spender: Address,
  amount: bigint,
  expiration: number,
): Hex {
  if (amount < 0n || amount > ((1n << 160n) - 1n)) throw new Error("Permit2 amount exceeds uint160");
  if (!Number.isInteger(expiration) || expiration < 0 || expiration > 0xffff_ffff_ffff) {
    throw new Error("Permit2 expiration exceeds uint48");
  }
  return encodeFunctionData({
    abi: permit2AllowanceAbi,
    functionName: "approve",
    args: [token, spender, amount, expiration],
  });
}

export function buildMintV4PositionCall(request: V4MintPositionRequest): Hex {
  if (request.liquidity <= 0n || request.liquidity > ((1n << 128n) - 1n)) {
    throw new Error("liquidity exceeds uint128");
  }
  if (
    request.amount0Max < 0n
    || request.amount0Max > ((1n << 128n) - 1n)
    || request.amount1Max < 0n
    || request.amount1Max > ((1n << 128n) - 1n)
  ) throw new Error("position amount exceeds uint128");
  const position = encodeAbiParameters(
    parseAbiParameters(
      "(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks),int24,int24,uint256,uint128,uint128,address,bytes",
    ),
    [
      request.poolKey,
      request.tickLower,
      request.tickUpper,
      request.liquidity,
      request.amount0Max,
      request.amount1Max,
      request.recipient,
      "0x",
    ],
  );
  const unlockData = encodeAbiParameters(
    parseAbiParameters("bytes,bytes[]"),
    ["0x021212", [
      position,
      encodeAbiParameters(parseAbiParameters("address"), [request.poolKey.currency0]),
      encodeAbiParameters(parseAbiParameters("address"), [request.poolKey.currency1]),
    ]],
  );
  return encodeFunctionData({
    abi: v4PositionManagerReadAbi,
    functionName: "modifyLiquidities",
    args: [unlockData, request.deadline],
  });
}

export function buildMintCall(
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  maxAmountsIn: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "mint", args: [basketId, shares, receiver, maxAmountsIn] });
}

export function buildRedeemCall(
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  minAmountsOut: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "redeem", args: [basketId, shares, receiver, minAmountsOut] });
}

export function buildCreateAndDepositBasketCollateralCall(basketId: bigint, shares: bigint, receiver: Address): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "createAndDepositBasketCollateral", args: [basketId, shares, receiver] });
}

export function buildDepositBasketCollateralCall(positionId: bigint, basketId: bigint, shares: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "depositBasketCollateral", args: [positionId, basketId, shares] });
}

export function buildWithdrawBasketCollateralCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "withdrawBasketCollateral", args: [positionId, basketId, shares, receiver] });
}

export function buildCreateAndMintBasketCollateralCall(
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  maxAmountsIn: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "createAndMintBasketCollateral", args: [basketId, shares, receiver, maxAmountsIn] });
}

export function buildMintBasketCollateralCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  maxAmountsIn: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "mintBasketCollateral", args: [positionId, basketId, shares, maxAmountsIn] });
}

export function buildRedeemBasketCollateralCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  minAmountsOut: readonly bigint[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "redeemBasketCollateral",
    args: [positionId, basketId, shares, receiver, minAmountsOut],
  });
}

export function buildClaimRewardsCall(
  positionId: bigint,
  assets: readonly Address[],
  receiver: Address,
  minAmountsOut: readonly bigint[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "claimRewards",
    args: [positionId, assets, receiver, minAmountsOut],
  });
}

export function buildClaimBasketRewardsCall(positionId: bigint, basketId: bigint, receiver: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "claimBasketRewards",
    args: [positionId, basketId, receiver],
  });
}

export function buildCreateAndStakeCall(
  amount: bigint,
  receiver: Address,
  rewardAssets: readonly Address[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "createAndStake",
    args: [amount, receiver, rewardAssets],
  });
}

export function buildOptInRewardAssetsCall(positionId: bigint, assets: readonly Address[]): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "optInRewardAssets", args: [positionId, assets] });
}

export function buildOptOutRewardAssetsCall(positionId: bigint, assets: readonly Address[]): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "optOutRewardAssets", args: [positionId, assets] });
}

export function buildStakeCall(positionId: bigint, amount: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "stake", args: [positionId, amount] });
}

export function buildUnstakeCall(positionId: bigint, amount: bigint, receiver: Address): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "unstake", args: [positionId, amount, receiver] });
}

export function buildBorrowCall(positionId: bigint, basketId: bigint, sharesIn: bigint, receiver: Address): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "borrow", args: [positionId, basketId, sharesIn, receiver] });
}

export function buildRepayCall(loanId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "repay", args: [loanId] });
}

export function buildExtendCall(loanId: bigint, grossAmountsIn: readonly bigint[]): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "extend", args: [loanId, grossAmountsIn] });
}

export function buildRecoverCall(loanId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "recover", args: [loanId] });
}

export function buildFlashLoanCall(basketId: bigint, shares: bigint, receiver: Address, data: Hex): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "flashLoan", args: [basketId, shares, receiver, data] });
}

export function buildCreatePositionCall(receiver: Address): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "createPosition", args: [receiver] });
}

export function buildClosePositionCall(positionId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "closePosition", args: [positionId] });
}

export function buildQuarantineBasketCall(basketId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "quarantineBasket", args: [basketId] });
}

export function buildReleaseBasketQuarantineCall(basketId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "releaseBasketQuarantine", args: [basketId] });
}

export function buildDecommissionBasketCall(basketId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "decommissionBasket", args: [basketId] });
}

export function buildCheckpointCanonicalPoolCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "checkpointCanonicalPool",
    args: [basketId, asset],
  });
}

export function buildActivateCanonicalPoolCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "activateCanonicalPool",
    args: [basketId, asset],
  });
}

export function buildSetSwapFeeConfigurationCall(configuration: SwapFeeConfiguration): Hex {
  const uint16 = (value: bigint, field: string): number => {
    if (value < 0n || value > 65_535n) throw new Error(`${field} exceeds uint16`);
    return Number(value);
  };
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "setSwapFeeConfiguration",
    args: [{
      inputFeeBps: uint16(configuration.inputFeeBps, "inputFeeBps"),
      outputFeeBps: uint16(configuration.outputFeeBps, "outputFeeBps"),
      polShareBps: uint16(configuration.polShareBps, "polShareBps"),
      liquidityProviderShareBps: uint16(
        configuration.liquidityProviderShareBps,
        "liquidityProviderShareBps",
      ),
      basketStakerShareBps: uint16(configuration.basketStakerShareBps, "basketStakerShareBps"),
      staticsStakerShareBps: uint16(configuration.staticsStakerShareBps, "staticsStakerShareBps"),
      treasuryShareBps: uint16(configuration.treasuryShareBps, "treasuryShareBps"),
    }],
  });
}

export function buildSetCanonicalPoolFeeConfigurationCall(
  basketId: bigint,
  asset: Address,
  configuration: SwapFeeConfiguration,
): Hex {
  const uint16 = (value: bigint, field: string): number => {
    if (value < 0n || value > 65_535n) throw new Error(`${field} exceeds uint16`);
    return Number(value);
  };
  if (
    configuration.inputFeeBps + configuration.outputFeeBps > 200n
  ) {
    throw new Error("combined pool fee rate exceeds 200 BPS");
  }
  if (
    configuration.polShareBps + configuration.liquidityProviderShareBps
      + configuration.basketStakerShareBps + configuration.staticsStakerShareBps
      + configuration.treasuryShareBps !== BPS
  ) {
    throw new Error("pool fee shares must sum to 10000 BPS");
  }
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "setCanonicalPoolFeeConfiguration",
    args: [basketId, asset, {
      inputFeeBps: uint16(configuration.inputFeeBps, "inputFeeBps"),
      outputFeeBps: uint16(configuration.outputFeeBps, "outputFeeBps"),
      polShareBps: uint16(configuration.polShareBps, "polShareBps"),
      liquidityProviderShareBps: uint16(configuration.liquidityProviderShareBps, "liquidityProviderShareBps"),
      basketStakerShareBps: uint16(configuration.basketStakerShareBps, "basketStakerShareBps"),
      staticsStakerShareBps: uint16(configuration.staticsStakerShareBps, "staticsStakerShareBps"),
      treasuryShareBps: uint16(configuration.treasuryShareBps, "treasuryShareBps"),
    }],
  });
}

export function buildClearCanonicalPoolFeeConfigurationCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "clearCanonicalPoolFeeConfiguration",
    args: [basketId, asset],
  });
}

export function buildUnwindBasketLiquidityCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "unwindBasketLiquidity",
    args: [basketId, asset],
  });
}

export function buildBorrowAndProvideLiquidityCall(
  positionId: bigint,
  basketId: bigint,
  sharesIn: bigint,
  pools: readonly LiquidityParams[],
  lpRecipient: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "borrowAndProvideLiquidity",
    args: [positionId, basketId, sharesIn, pools, lpRecipient],
  });
}

export function buildBorrowAndStakeLiquidityCall(
  positionId: bigint,
  basketId: bigint,
  sharesIn: bigint,
  pools: readonly LiquidityParams[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "borrowAndStakeLiquidity",
    args: [positionId, basketId, sharesIn, pools],
  });
}

export function buildStakeLiquidityPositionCall(positionId: bigint, tokenId: bigint): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "stakeLiquidityPosition",
    args: [positionId, tokenId],
  });
}

export function buildActivateLiquidityPositionCall(tokenId: bigint): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "activateLiquidityPosition",
    args: [tokenId],
  });
}

export function buildIncreaseStakedLiquidityCall(
  positionId: bigint,
  tokenId: bigint,
  request: StakedLiquidityIncreaseRequest,
  refundReceiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "increaseStakedLiquidity",
    args: [positionId, tokenId, request, refundReceiver],
  });
}

export function buildUnstakeLiquidityPositionCall(
  positionId: bigint,
  tokenId: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "unstakeLiquidityPosition",
    args: [positionId, tokenId, receiver],
  });
}

export function buildClaimLiquidityRewardsCall(
  positionId: bigint,
  tokenId: bigint,
  receiver: Address,
  minAmount0: bigint,
  minAmount1: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "claimLiquidityRewards",
    args: [positionId, tokenId, receiver, minAmount0, minAmount1],
  });
}

export function buildDepositETHTransaction(
  ethAmount: bigint,
  staticsDollarReceiver: Address,
  shareReceiver: Address,
  minStaticsDollar: bigint,
  minShares: bigint,
): PreparedTransaction {
  return {
    data: encodeFunctionData({
      abi: staticsAbi,
      functionName: "depositETH",
      args: [staticsDollarReceiver, shareReceiver, minStaticsDollar, minShares],
    }),
    value: ethAmount,
  };
}

export function buildDepositWETHCall(
  wethAmount: bigint,
  staticsDollarReceiver: Address,
  shareReceiver: Address,
  minStaticsDollar: bigint,
  minShares: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "depositWETH",
    args: [wethAmount, staticsDollarReceiver, shareReceiver, minStaticsDollar, minShares],
  });
}

export function buildRecombineToWETHCall(
  seriesId: bigint,
  staticsDollarAmount: bigint,
  maxSharesIn: bigint,
  receiver: Address,
  minWETHOut: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "recombineToWETH",
    args: [seriesId, staticsDollarAmount, maxSharesIn, receiver, minWETHOut],
  });
}

export function buildRecombineToWETHWithPermitCall(
  seriesId: bigint,
  staticsDollarAmount: bigint,
  maxSharesIn: bigint,
  receiver: Address,
  minWETHOut: bigint,
  permitSignature: PermitSignature,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "recombineToWETHWithPermit",
    args: [seriesId, staticsDollarAmount, maxSharesIn, receiver, minWETHOut, permitSignature],
  });
}

export function buildRecombineToETHCall(
  seriesId: bigint,
  staticsDollarAmount: bigint,
  maxSharesIn: bigint,
  receiver: Address,
  minETHOut: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "recombineToETH",
    args: [seriesId, staticsDollarAmount, maxSharesIn, receiver, minETHOut],
  });
}

export function buildRecombineToETHWithPermitCall(
  seriesId: bigint,
  staticsDollarAmount: bigint,
  maxSharesIn: bigint,
  receiver: Address,
  minETHOut: bigint,
  permitSignature: PermitSignature,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "recombineToETHWithPermit",
    args: [seriesId, staticsDollarAmount, maxSharesIn, receiver, minETHOut, permitSignature],
  });
}

export function buildMintPeggedCall(
  profileId: bigint,
  staticsDollarAmount: bigint,
  maximumCollateralIn: bigint,
  staticsDollarReceiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "mintPegged",
    args: [profileId, staticsDollarAmount, maximumCollateralIn, staticsDollarReceiver],
  });
}

export function buildQuoteMintPeggedAndRecombineCall(
  peggedProfileId: bigint,
  volatileProfileId: bigint,
  seriesId: bigint,
  riskAmount: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "quoteMintPeggedAndRecombine",
    args: [peggedProfileId, volatileProfileId, seriesId, riskAmount],
  });
}

export function buildMintPeggedAndRecombineCall(
  peggedProfileId: bigint,
  volatileProfileId: bigint,
  seriesId: bigint,
  riskAmount: bigint,
  maximumPeggedCollateralIn: bigint,
  minimumVolatileCollateralOut: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "mintPeggedAndRecombine",
    args: [
      peggedProfileId,
      volatileProfileId,
      seriesId,
      riskAmount,
      maximumPeggedCollateralIn,
      minimumVolatileCollateralOut,
      receiver,
    ],
  });
}

export function buildMintPeggedAndRecombineWithPermitCall(
  peggedProfileId: bigint,
  volatileProfileId: bigint,
  seriesId: bigint,
  riskAmount: bigint,
  maximumPeggedCollateralIn: bigint,
  minimumVolatileCollateralOut: bigint,
  receiver: Address,
  permitSignature: PermitSignature,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "mintPeggedAndRecombineWithPermit",
    args: [
      peggedProfileId,
      volatileProfileId,
      seriesId,
      riskAmount,
      maximumPeggedCollateralIn,
      minimumVolatileCollateralOut,
      receiver,
      permitSignature,
    ],
  });
}

export function buildRedeemPeggedCall(
  profileId: bigint,
  staticsDollarAmount: bigint,
  minimumCollateralOut: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "redeemPegged",
    args: [profileId, staticsDollarAmount, minimumCollateralOut, receiver],
  });
}

export function buildClaimPeggedProtocolRevenueCall(
  profileId: bigint,
  amount: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "claimPeggedProtocolRevenue",
    args: [profileId, amount, receiver],
  });
}

export type SwapExecution = {
  target: Address;
  calldata: Hex;
  value: bigint;
};

export interface UnderlyingLiquidityAdapter {
  quoteExactOutput(request: {
    tokenIn: Address;
    tokenOut: Address;
    amountOut: bigint;
  }): Promise<{ maxAmountIn: bigint; execution: SwapExecution }>;

  quoteExactInput(request: {
    tokenIn: Address;
    tokenOut: Address;
    amountIn: bigint;
  }): Promise<{ minAmountOut: bigint; execution: SwapExecution }>;
}

export type UnderlyingRoute = {
  asset: Address;
  amount: bigint;
  sourceOrDestinationAmount: bigint;
  execution?: SwapExecution;
};

export async function planMintUnderlyingRoutes(
  sourceToken: Address,
  mintQuote: readonly MintQuoteLeg[],
  adapter: UnderlyingLiquidityAdapter,
): Promise<readonly UnderlyingRoute[]> {
  return Promise.all(mintQuote.map(async ({ asset, amountIn }) => {
    if (asset.toLowerCase() === sourceToken.toLowerCase()) {
      return { asset, amount: amountIn, sourceOrDestinationAmount: amountIn };
    }
    const route = await adapter.quoteExactOutput({ tokenIn: sourceToken, tokenOut: asset, amountOut: amountIn });
    return { asset, amount: amountIn, sourceOrDestinationAmount: route.maxAmountIn, execution: route.execution };
  }));
}

export async function planRedeemUnderlyingRoutes(
  destinationToken: Address,
  redeemQuote: readonly RedeemQuoteLeg[],
  adapter: UnderlyingLiquidityAdapter,
): Promise<readonly UnderlyingRoute[]> {
  return Promise.all(redeemQuote.map(async ({ asset, amountOut }) => {
    if (asset.toLowerCase() === destinationToken.toLowerCase()) {
      return { asset, amount: amountOut, sourceOrDestinationAmount: amountOut };
    }
    const route = await adapter.quoteExactInput({ tokenIn: asset, tokenOut: destinationToken, amountIn: amountOut });
    return { asset, amount: amountOut, sourceOrDestinationAmount: route.minAmountOut, execution: route.execution };
  }));
}
