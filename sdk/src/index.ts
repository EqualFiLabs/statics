import {
  encodeFunctionData,
  parseAbi,
  toHex,
  type Address,
  type ContractEventArgs,
  type Hex,
} from "viem";

export { robinhoodChain } from "./generated/robinhoodChain.js";

export const BPS = 10_000n;
export const SHARE_SCALE = 10n ** 18n;
export const MAX_LTV_BPS = 9_500n;
export const Q96 = 1n << 96n;
export const Q128 = 1n << 128n;
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

export type BasketFeeAllocation = {
  holderShareBps: bigint;
  liquidityShareBps: bigint;
  protocolShareBps: bigint;
};

export type PrimaryFeeClassification = {
  holderAmount: bigint;
  liquidityAmount: bigint;
  protocolAmount: bigint;
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
  constituents: readonly ConstituentSnapshot[];
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
  loanDuration: number;
};

export type PreparedTransaction = {
  data: Hex;
  value: bigint;
};

export type PermitSignature = {
  deadline: bigint;
  v: number;
  r: Hex;
  s: Hex;
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
  principals: readonly { asset: Address; amount: bigint }[];
};

export type BasketLiquidityState = {
  lastCompoundAt: bigint;
  nextCompoundAt: bigint;
  cumulativeSharesMinted: bigint;
};

export type LiquidityEpochParameters = {
  interval: bigint;
  youngPoolPeriod: bigint;
  youngPoolCapBps: bigint;
  minimumShares: bigint;
};

export type ProtocolLpFeeSplit = {
  polAmount: bigint;
  revenueAmount: bigint;
};

export type EffectiveCanonicalFees = {
  lpFeePips: bigint;
  lpFeeBps: bigint;
  hookFeeBps: bigint;
  nominalTotalBps: bigint;
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

export function quoteHookFee(realizedAmount: bigint, hookFeeBps: bigint): bigint {
  if (realizedAmount < 0n || hookFeeBps < 0n || hookFeeBps > BPS) throw new Error("invalid hook fee input");
  return mulDivUp(realizedAmount, hookFeeBps, BPS);
}

export function splitProtocolLpFee(
  collected: bigint,
  revenueShareBps = 1_000n,
): ProtocolLpFeeSplit {
  return nextProtocolLpFeeSplit(0n, 0n, collected, revenueShareBps);
}

export function nextProtocolLpFeeSplit(
  priorCollected: bigint,
  priorRevenueDebit: bigint,
  collected: bigint,
  revenueShareBps = 1_000n,
): ProtocolLpFeeSplit {
  if (
    priorCollected < 0n || priorRevenueDebit < 0n || collected < 0n
    || revenueShareBps < 0n || revenueShareBps > BPS
  ) {
    throw new Error("invalid LP fee input");
  }
  const priorTarget = mulDivDown(priorCollected, revenueShareBps, BPS);
  if (priorRevenueDebit > priorTarget) throw new Error("invalid LP fee checkpoint");
  const revenueAmount = mulDivDown(priorCollected + collected, revenueShareBps, BPS) - priorRevenueDebit;
  if (revenueAmount > collected) throw new Error("LP fee checkpoint requires retained inventory");
  return { polAmount: collected - revenueAmount, revenueAmount };
}

export function effectiveCanonicalFees(lpFeePips: bigint, hookFeeBps: bigint): EffectiveCanonicalFees {
  if (lpFeePips < 0n || lpFeePips % 100n !== 0n) throw new Error("LP fee must convert exactly to bps");
  if (hookFeeBps < 0n || hookFeeBps > BPS) throw new Error("invalid hook fee");
  const lpFeeBps = lpFeePips / 100n;
  return { lpFeePips, lpFeeBps, hookFeeBps, nominalTotalBps: lpFeeBps + hookFeeBps };
}

export function compoundEpochStatus(
  state: BasketLiquidityState,
  parameters: LiquidityEpochParameters,
  activatedAt: readonly bigint[],
  timestamp: bigint,
): { ready: boolean; readyAt: bigint; youngPoolCapApplies: boolean } {
  if (timestamp < 0n) throw new Error("invalid timestamp");
  const readyAt = state.nextCompoundAt;
  return {
    ready: readyAt === 0n || timestamp >= readyAt,
    readyAt,
    youngPoolCapApplies: activatedAt.some((activation) => (
      activation !== 0n && timestamp < activation + parameters.youngPoolPeriod
    )),
  };
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

export function classifyPrimaryFee(
  fee: bigint,
  allocation: BasketFeeAllocation,
  hasEligibleHolders: boolean,
): PrimaryFeeClassification {
  const totalBps = allocation.holderShareBps + allocation.liquidityShareBps + allocation.protocolShareBps;
  if (totalBps !== BPS) throw new Error("fee allocation must total 10000 bps");
  if (fee < 0n) throw new Error("fee must not be negative");
  const holderAmount = hasEligibleHolders ? mulDivDown(fee, allocation.holderShareBps, BPS) : 0n;
  const liquidityAmount = mulDivDown(fee, allocation.liquidityShareBps, BPS);
  return {
    holderAmount,
    liquidityAmount,
    protocolAmount: fee - holderAmount - liquidityAmount,
  };
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
  const principals = snapshot.constituents.map(({ asset, bundleAmount }) => ({
    asset,
    amount: mulDivDown(mulDivDown(bundleAmount, collateralShares, SHARE_SCALE), snapshot.ltvBps, BPS),
  }));
  if (!principals.some(({ amount }) => amount !== 0n)) throw new Error("zero principal");
  return { feeShares, collateralShares, principals };
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
  "function createBasket((string name,string symbol,address[] assets,uint256[] bundleAmounts,(uint256 minActionShares,uint256 feeShares)[] mintFeeTiers,(uint256 minActionShares,uint256 feeShares)[] redemptionFeeTiers,uint16 flashFeeBps,uint16 originationFeeBps,uint16 extensionFeeBps,uint16 ltvBps,uint40 loanDuration) params) payable returns (uint256 basketId,address token)",
  "function mint(uint256 basketId,uint256 shares,address receiver,uint256[] maxAmountsIn) returns (uint256[] amountsIn)",
  "function redeem(uint256 basketId,uint256 shares,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function createAndDepositBasket(uint256 basketId,uint256 shares,address receiver) returns (uint256 positionId)",
  "function depositBasket(uint256 positionId,uint256 basketId,uint256 shares)",
  "function withdrawBasket(uint256 positionId,uint256 basketId,uint256 shares,address receiver)",
  "function createAndMintBasket(uint256 basketId,uint256 shares,address receiver,uint256[] maxAmountsIn) returns (uint256 positionId,uint256[] amountsIn)",
  "function mintBasketToPosition(uint256 positionId,uint256 basketId,uint256 shares,uint256[] maxAmountsIn) returns (uint256[] amountsIn)",
  "function redeemBasketFromPosition(uint256 positionId,uint256 basketId,uint256 shares,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function claimBasketRewards(uint256 positionId,uint256 basketId,address receiver,uint256[] minAmountsOut) returns (uint256[] amountsOut)",
  "function borrow(uint256 positionId,uint256 basketId,uint256 sharesIn,address receiver) returns (uint256 loanId,uint256[] principals)",
  "function repay(uint256 loanId)",
  "function extend(uint256 loanId,uint256[] grossAmountsIn) returns (uint256[] receivedAmounts)",
  "function recover(uint256 loanId)",
  "function flashLoan(uint256 basketId,uint256 shares,address receiver,bytes data)",
  "function createPosition(address receiver) returns (uint256 positionId)",
  "function closePosition(uint256 positionId)",
  "function quarantineBasket(uint256 basketId)",
  "function releaseBasketQuarantine(uint256 basketId)",
  "function decommissionBasket(uint256 basketId)",
  "function depositETH(address staticsDollarReceiver,address shareReceiver,uint256 minStaticsDollar,uint256 minShares) payable returns (uint256 seriesId,uint256 staticsDollarMinted,uint256 sharesMinted)",
  "function depositWETH(uint256 wethAmount,address staticsDollarReceiver,address shareReceiver,uint256 minStaticsDollar,uint256 minShares) returns (uint256 seriesId,uint256 staticsDollarMinted,uint256 sharesMinted)",
  "function recombineToWETH(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minWETHOut) returns (uint8 status,uint256 wethOut)",
  "function recombineToWETHWithPermit(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minWETHOut,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint8 status,uint256 wethOut)",
  "function recombineToETH(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minETHOut) returns (uint8 status,uint256 ethOut)",
  "function recombineToETHWithPermit(uint256 seriesId,uint256 staticsDollarAmount,uint256 maxSharesIn,address receiver,uint256 minETHOut,(uint256 deadline,uint8 v,bytes32 r,bytes32 s) permitSignature) returns (uint8 status,uint256 ethOut)",
  "function previewPeggedMint(uint256 profileId,uint256 staticsDollarAmount) view returns ((uint256 profileId,address collateralToken,uint256 staticsDollarMinted,uint256 principalCollateral,uint256 feeAmount,uint256 totalCollateralIn,uint256 priceWad) preview)",
  "function mintPegged(uint256 profileId,uint256 staticsDollarAmount,uint256 maximumCollateralIn,address staticsDollarReceiver) returns (uint256 collateralIn)",
  "function previewPeggedRedemption(uint256 profileId,uint256 staticsDollarAmount) view returns ((uint256 profileId,address collateralToken,uint256 staticsDollarBurned,uint256 grossCollateral,uint256 feeAmount,uint256 collateralOut,uint256 priceWad) preview)",
  "function redeemPegged(uint256 profileId,uint256 staticsDollarAmount,uint256 minimumCollateralOut,address receiver) returns (uint8 status,uint256 collateralOut)",
  "function peggedRedemptionStatus() view returns (uint8 status,uint256 unhealthyProfileBitmap,uint256 totalSeniorDeficitWad,uint256 recoveryAvailableAt)",
  "function peggedProtocolRevenue(uint256 profileId,address token) view returns (uint256 amount)",
  "function claimPeggedProtocolRevenue(uint256 profileId,uint256 amount,address receiver) returns (uint256 spent,uint256 received)",
  "function setBasketFeeAllocation((uint16 holderShareBps,uint16 liquidityShareBps,uint16 protocolShareBps) allocation)",
  "function basketFeeAllocation() view returns ((uint16 holderShareBps,uint16 liquidityShareBps,uint16 protocolShareBps) allocation)",
  "function liquidityReserve(uint256 basketId,address asset) view returns (uint256 amount)",
  "function cumulativePrimaryFees(uint256 basketId,address asset) view returns ((uint256 holderAmount,uint256 liquidityAmount,uint256 protocolAmount) totals)",
  "function installCanonicalPoolIntegration(address poolManager,address hook)",
  "function initializeCanonicalPool(uint256 basketId,address asset,uint160 sqrtPriceX96) returns (bytes32 poolId,int24 tick)",
  "function checkpointCanonicalPool(uint256 basketId,address asset) returns (bool observationStored)",
  "function activateCanonicalPool(uint256 basketId,address asset) returns (int24 referenceTick,int24 spotTick)",
  "function canonicalPool(uint256 basketId,address asset) view returns ((bytes32 poolId,address basketToken,address asset,address currency0,address currency1,address hook,uint24 lpFee,int24 tickSpacing,uint8 status,uint40 initializedAt,uint40 activatedAt,int24 spotTick,int24 referenceTick,uint8 observationCardinality,bool referenceAvailable) pool)",
  "function liquidityIntegration() view returns (address poolManager,address hook,bool installed)",
  "function liquiditySafetyParameters() pure returns (uint24 lpFee,int24 tickSpacing,uint40 warmup,uint32 referenceWindow,uint16 maxDeviationBps)",
  "function settleCanonicalHookFees(uint256 basketId,address asset) returns ((uint256 constituentHookDebit,uint256 constituentRevenue,uint256 basketTokenHookDebit,uint256 basketTokensBurned) settled)",
  "function pendingCanonicalHookFees(uint256 basketId,address asset) view returns (uint256 basketTokenAmount,uint256 constituentAmount)",
  "function cumulativeCanonicalHookSettlement(uint256 basketId,address asset) view returns ((uint256 constituentHookDebit,uint256 constituentRevenue,uint256 basketTokenHookDebit,uint256 basketTokensBurned) totals)",
  "function cumulativeHookRevenue(uint256 basketId,address revenueAsset) view returns (uint256 amount)",
  "function installLiquidityManager(address manager)",
  "function syncCanonicalPoolToManager(uint256 basketId,address asset) returns (bool synced)",
  "function compoundBasketLiquidity(uint256 basketId) returns (uint256 sharesMinted)",
  "function liquidityManager() view returns (address manager,bool installed)",
  "function basketLiquidityState(uint256 basketId) view returns ((uint40 lastCompoundAt,uint40 nextCompoundAt,uint256 cumulativeSharesMinted) state)",
  "function cumulativeLiquidityFunding(uint256 basketId,address asset) view returns (uint256 assetSpent,uint256 assetReceived)",
  "function liquidityEpochParameters() pure returns (uint40 interval,uint40 youngPoolPeriod,uint16 youngPoolCapBps,uint256 minimumShares)",
  "function collectProtocolLpFees(uint256 basketId,address asset) returns ((uint256 constituentCollected,uint256 constituentPolRetained,uint256 constituentRevenueDebit,uint256 constituentRevenue,uint256 basketTokenCollected,uint256 basketTokenPolRetained,uint256 basketTokenRevenueDebit,uint256 basketTokensBurned) fees)",
  "function cumulativeProtocolLpFees(uint256 basketId,address asset) view returns ((uint256 constituentCollected,uint256 constituentPolRetained,uint256 constituentRevenueDebit,uint256 constituentRevenue,uint256 basketTokenCollected,uint256 basketTokenPolRetained,uint256 basketTokenRevenueDebit,uint256 basketTokensBurned) totals)",
  "function protocolLpFeeAllocation() pure returns (uint16 polShareBps,uint16 revenueShareBps)",
  "function unwindBasketLiquidity(uint256 basketId,address asset)",
  "function basketLiquidityUnwound(uint256 basketId,address asset) view returns (bool unwound)",
  "function borrowAndProvideLiquidity(uint256 positionId,uint256 basketId,uint256 sharesIn,(address asset,int24 tickLower,int24 tickUpper,uint256 liquidity,uint256 amount0Max,uint256 amount1Max,uint256 deadline)[] pools,address lpRecipient) returns (uint256 loanId,uint256[] v4TokenIds)",
  "function treasury() view returns (address)",
  "event BasketFeeAllocationChanged(uint16 previousHolderShareBps,uint16 previousLiquidityShareBps,uint16 previousProtocolShareBps,uint16 newHolderShareBps,uint16 newLiquidityShareBps,uint16 newProtocolShareBps)",
  "event BasketFeesAccrued(uint256 indexed basketId,address indexed asset,uint256 grossFee,uint256 holderAmount,uint256 liquidityAmount,uint256 protocolAmount,uint256 indexRay)",
  "event LiquidityIntegrationInstalled(address indexed poolManager,address indexed hook)",
  "event CanonicalPoolInitialized(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,address currency0,address currency1,uint160 sqrtPriceX96,int24 tick)",
  "event CanonicalPoolCheckpointed(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,bool observationStored)",
  "event CanonicalPoolActivated(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,int24 referenceTick,int24 spotTick)",
  "event CanonicalHookFeesSettled(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,uint256 constituentHookDebit,uint256 constituentRevenue,uint256 basketTokenHookDebit,uint256 basketTokensBurned)",
  "event HookBasketTokenRevenueReclassified(uint256 indexed basketId,address indexed sourcePoolAsset,address indexed revenueAsset,uint256 amount)",
  "event LiquidityManagerInstalled(address indexed manager)",
  "event CanonicalPoolSyncedToManager(uint256 indexed basketId,address indexed asset,bytes32 indexed poolId,address manager)",
  "event BasketLiquidityPoolFunded(uint256 indexed basketId,address indexed asset,uint256 indexed positionTokenId,uint256 backingAdded,uint256 assetSpent,uint256 assetReceived,uint256 basketTokenLimit,uint256 assetLimit,uint256 liquidity)",
  "event BasketLiquidityCompounded(uint256 indexed basketId,uint256 sharesMinted,uint40 nextCompoundAt,bool youngPoolCapApplied)",
  "event ProtocolLpFeesCollected(uint256 indexed basketId,address indexed asset,uint256 indexed positionTokenId,(uint256 constituentCollected,uint256 constituentPolRetained,uint256 constituentRevenueDebit,uint256 constituentRevenue,uint256 basketTokenCollected,uint256 basketTokenPolRetained,uint256 basketTokenRevenueDebit,uint256 basketTokensBurned) fees)",
  "event LpBasketTokenRevenueReclassified(uint256 indexed basketId,address indexed sourcePoolAsset,address indexed revenueAsset,uint256 amount)",
  "event BasketLiquidityUnwound(uint256 indexed basketId,address indexed asset,uint256 indexed positionTokenId,uint256 reserveReclassified,uint256 constituentInventoryDebit,uint256 constituentRevenue,uint256 basketTokenInventoryDebit,uint256 basketTokensBurned)",
  "event BorrowedLiquidityPositionMinted(uint256 indexed loanId,uint256 indexed basketId,address indexed asset,uint256 v4TokenId,address recipient,uint256 liquidity,uint256 spent0,uint256 spent1,uint256 refund0,uint256 refund1)",
  "event BorrowedLiquidityProvided(uint256 indexed loanId,uint256 indexed positionId,uint256 indexed basketId,address operator,address lpRecipient,uint256 sharesIn,uint256 basketSharesMinted,uint256[] v4TokenIds)",
]);

export const staticsSwapFeeHookAbi = parseAbi([
  "function staticsDiamond() view returns (address)",
  "function hookFeeBps() view returns (uint16)",
  "function registerPool((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) returns (bytes32 poolId)",
  "function poolRegistration(bytes32 poolId) view returns ((address currency0,address currency1,bool registered) registration)",
  "function accruedFees(bytes32 poolId,address currency) view returns (uint256 amount)",
  "function totalLiability(address currency) view returns (uint256 amount)",
  "function checkpoint((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key) returns (bool observationStored)",
  "function oracleState(bytes32 poolId) view returns ((uint40 initializedAt,uint40 lastCheckpointAt,uint40 latestObservationAt,int24 lastTick,int56 tickCumulative,uint8 observationIndex,uint8 observationCardinality) state)",
  "function observationAt(bytes32 poolId,uint8 index) view returns (uint40 timestamp,int56 tickCumulative)",
  "function consult(bytes32 poolId,uint32 window) view returns (int24 referenceTick,int24 spotTick,uint40 oldestObservationAt)",
  "function withdrawPoolFees(bytes32 poolId) returns (uint256 spent0,uint256 received0,uint256 spent1,uint256 received1)",
  "event PoolRegistered(bytes32 indexed poolId,address indexed currency0,address indexed currency1)",
  "event SwapFeeAccrued(bytes32 indexed poolId,address indexed currency,uint256 realizedAmount,uint256 chargedAmount,uint256 receivedAmount)",
  "event PoolFeesWithdrawn(bytes32 indexed poolId,address indexed currency,uint256 spentAmount,uint256 receivedAmount,uint256 remainingAmount)",
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
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function getPoolAndPositionInfo(uint256 tokenId) view returns ((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,uint256 info)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
]);

export const v4StateViewReadAbi = parseAbi([
  "function getPositionInfo(bytes32 poolId,address owner,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint128 liquidity,uint256 feeGrowthInside0LastX128,uint256 feeGrowthInside1LastX128)",
  "function getFeeGrowthInside(bytes32 poolId,int24 tickLower,int24 tickUpper) view returns (uint256 feeGrowthInside0X128,uint256 feeGrowthInside1X128)",
]);

export type StaticsLiquidityEventName =
  | "BasketFeeAllocationChanged"
  | "BasketFeesAccrued"
  | "LiquidityIntegrationInstalled"
  | "CanonicalPoolInitialized"
  | "CanonicalPoolCheckpointed"
  | "CanonicalPoolActivated"
  | "CanonicalHookFeesSettled"
  | "HookBasketTokenRevenueReclassified"
  | "LiquidityManagerInstalled"
  | "CanonicalPoolSyncedToManager"
  | "BasketLiquidityPoolFunded"
  | "BasketLiquidityCompounded"
  | "ProtocolLpFeesCollected"
  | "LpBasketTokenRevenueReclassified"
  | "BasketLiquidityUnwound"
  | "BorrowedLiquidityPositionMinted"
  | "BorrowedLiquidityProvided";

export type StaticsLiquidityEventArgs<Name extends StaticsLiquidityEventName> =
  ContractEventArgs<typeof staticsAbi, Name>;

export type StaticsHookEventName =
  | "PoolRegistered"
  | "SwapFeeAccrued"
  | "PoolFeesWithdrawn"
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
  "function approve(address spender,uint256 value) returns (bool)",
  "function permit(address owner,address spender,uint256 value,uint256 deadline,uint8 v,bytes32 r,bytes32 s)",
  "function nonces(address owner) view returns (uint256)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
]);

export const staticsDollarTokenAbi = basketTokenAbi;

export function buildCreateBasketTransaction(
  params: CreateBasketParams,
  creationFee: bigint,
): PreparedTransaction {
  return {
    data: encodeFunctionData({ abi: staticsAbi, functionName: "createBasket", args: [params] }),
    value: creationFee,
  };
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

export function buildCreateAndDepositBasketCall(basketId: bigint, shares: bigint, receiver: Address): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "createAndDepositBasket", args: [basketId, shares, receiver] });
}

export function buildDepositBasketCall(positionId: bigint, basketId: bigint, shares: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "depositBasket", args: [positionId, basketId, shares] });
}

export function buildWithdrawBasketCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  receiver: Address,
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "withdrawBasket", args: [positionId, basketId, shares, receiver] });
}

export function buildCreateAndMintBasketCall(
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  maxAmountsIn: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "createAndMintBasket", args: [basketId, shares, receiver, maxAmountsIn] });
}

export function buildMintBasketToPositionCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  maxAmountsIn: readonly bigint[],
): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "mintBasketToPosition", args: [positionId, basketId, shares, maxAmountsIn] });
}

export function buildRedeemBasketFromPositionCall(
  positionId: bigint,
  basketId: bigint,
  shares: bigint,
  receiver: Address,
  minAmountsOut: readonly bigint[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "redeemBasketFromPosition",
    args: [positionId, basketId, shares, receiver, minAmountsOut],
  });
}

export function buildClaimBasketRewardsCall(
  positionId: bigint,
  basketId: bigint,
  receiver: Address,
  minAmountsOut: readonly bigint[],
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "claimBasketRewards",
    args: [positionId, basketId, receiver, minAmountsOut],
  });
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

export function buildInitializeCanonicalPoolCall(
  basketId: bigint,
  asset: Address,
  sqrtPriceX96: bigint,
): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "initializeCanonicalPool",
    args: [basketId, asset, sqrtPriceX96],
  });
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

export function buildSettleCanonicalHookFeesCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "settleCanonicalHookFees",
    args: [basketId, asset],
  });
}

export function buildSyncCanonicalPoolToManagerCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "syncCanonicalPoolToManager",
    args: [basketId, asset],
  });
}

export function buildCompoundBasketLiquidityCall(basketId: bigint): Hex {
  return encodeFunctionData({ abi: staticsAbi, functionName: "compoundBasketLiquidity", args: [basketId] });
}

export function buildCollectProtocolLpFeesCall(basketId: bigint, asset: Address): Hex {
  return encodeFunctionData({
    abi: staticsAbi,
    functionName: "collectProtocolLpFees",
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
