import assert from "node:assert/strict";

export const WAD = 10n ** 18n;
export const Q96 = 1n << 96n;
const UINT256_MAX = (1n << 256n) - 1n;
const TICK_MULTIPLIERS = [
  0xfffcb933bd6fad37aa2d162d1a594001n,
  0xfff97272373d413259a46990580e213an,
  0xfff2e50f5f656932ef12357cf3c7fdccn,
  0xffe5caca7e10e4e61c3624eaa0941cd0n,
  0xffcb9843d60f6159c9db58835c926644n,
  0xff973b41fa98c081472e6896dfb254c0n,
  0xff2ea16466c96a3843ec78b326b52861n,
  0xfe5dee046a99a2a811c461f1969c3053n,
  0xfcbe86c7900a88aedcffc83b479aa3a4n,
  0xf987a7253ac413176f2b074cf7815e54n,
  0xf3392b0822b70005940c7a398e4b70f3n,
  0xe7159475a2c29b7443b29c7fa6e889d9n,
  0xd097f3bdfd2022b8845ad8f792aa5825n,
  0xa9f746462d870fdf8a65dc1f90e061e5n,
  0x70d869a156d2a1b890bb3df62baf32f7n,
  0x31be135f97d08fd981231505542fcfa6n,
  0x9aa508b5b7a84e1c677de54f3e99bc9n,
  0x5d6af8dedb81196699c329225ee604n,
  0x2216e584f5fa1ea926041bedfe98n,
  0x48a170391f7dc42444e8fa2n
];

export function parseTokenAmount(value) {
  const [whole, fraction = ""] = String(value).split(".");
  assert.match(whole, /^\d+$/);
  assert.match(fraction, /^\d*$/);
  assert.ok(fraction.length <= 18, "token amount exceeds 18 decimals");
  return BigInt(whole) * WAD + BigInt((fraction + "0".repeat(18)).slice(0, 18));
}

export function formatUnits(value, decimals = 6) {
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const whole = absolute / WAD;
  const fraction = (absolute % WAD).toString().padStart(18, "0").slice(0, decimals).replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

export function formatWadPercentage(value, decimals = 1) {
  assert.ok(value >= 0n && value <= WAD, "WAD percentage is out of range");
  assert.ok(Number.isInteger(decimals) && decimals >= 0 && decimals <= 18, "invalid percentage decimals");
  const scale = 10n ** BigInt(decimals);
  const rounded = (value * 100n * scale + WAD / 2n) / WAD;
  const whole = rounded / scale;
  if (decimals === 0) return whole.toString();
  return `${whole}.${(rounded % scale).toString().padStart(decimals, "0")}`;
}

export function sqrtPriceAtTick(tick) {
  assert.ok(Number.isInteger(tick) && Math.abs(tick) <= 887272, "invalid tick");
  const absolute = Math.abs(tick);
  let ratio = absolute & 1 ? TICK_MULTIPLIERS[0] : 1n << 128n;
  for (let bit = 1; bit < TICK_MULTIPLIERS.length; bit += 1) {
    if (absolute & (1 << bit)) ratio = (ratio * TICK_MULTIPLIERS[bit]) >> 128n;
  }
  if (tick > 0) ratio = UINT256_MAX / ratio;
  return (ratio + ((1n << 32n) - 1n)) >> 32n;
}

export function alignTick(isToken0, tick, spacing) {
  assert.ok(Number.isInteger(tick) && Number.isInteger(spacing) && spacing > 0);
  if (isToken0) return Math.floor(tick / spacing) * spacing;
  return Math.ceil(tick / spacing) * spacing;
}

export function fdvToTick(fdvUsd, totalSupplyTokens, wethUsd, spacing) {
  const wethPerToken = Number(fdvUsd) / Number(totalSupplyTokens) / Number(wethUsd);
  assert.ok(Number.isFinite(wethPerToken) && wethPerToken > 0);
  return alignTick(true, Math.floor(Math.log(wethPerToken) / Math.log(1.0001)), spacing);
}

function divRoundingUp(numerator, denominator) {
  return numerator / denominator + (numerator % denominator === 0n ? 0n : 1n);
}

function liquidityForAmount0(sqrtA, sqrtB, amount0) {
  const intermediate = (sqrtA * sqrtB) / Q96;
  return (amount0 * intermediate) / (sqrtB - sqrtA);
}

function liquidityForAmount1(sqrtA, sqrtB, amount1) {
  return (amount1 * Q96) / (sqrtB - sqrtA);
}

function amount0Delta(sqrtA, sqrtB, liquidity, roundUp) {
  const numerator1 = liquidity << 96n;
  const numerator2 = sqrtB - sqrtA;
  if (!roundUp) return ((numerator1 * numerator2) / sqrtB) / sqrtA;
  return divRoundingUp(divRoundingUp(numerator1 * numerator2, sqrtB), sqrtA);
}

function amount1Delta(sqrtA, sqrtB, liquidity, roundUp) {
  const numerator = liquidity * (sqrtB - sqrtA);
  return roundUp ? divRoundingUp(numerator, Q96) : numerator / Q96;
}

function startingTick(curve, index, isToken0, spacing) {
  const farTick = isToken0 ? curve.tickUpper : curve.tickLower;
  const closeTick = isToken0 ? curve.tickLower : curve.tickUpper;
  const spread = curve.tickUpper - curve.tickLower;
  const offset = Math.floor((index * spread) / curve.numPositions);
  const unaligned = isToken0 ? closeTick + offset : closeTick - offset;
  return {farTick, startTick: alignTick(isToken0, unaligned, spacing)};
}

export function buildPositions(curves, inventory, spacing, isToken0) {
  const positions = [];
  for (const [curveIndex, canonicalCurve] of curves.entries()) {
    const curve = isToken0
      ? canonicalCurve
      : {...canonicalCurve, tickLower: -canonicalCurve.tickUpper, tickUpper: -canonicalCurve.tickLower};
    const curveSupply = (inventory * curve.shares) / WAD;
    const amountPerPosition = curveSupply / BigInt(curve.numPositions);
    for (let index = 0; index < curve.numPositions; index += 1) {
      const {farTick, startTick} = startingTick(curve, index, isToken0, spacing);
      assert.notEqual(startTick, farTick, `${curve.name} creates an empty position`);
      const tickLower = Math.min(startTick, farTick);
      const tickUpper = Math.max(startTick, farTick);
      const sqrtA = sqrtPriceAtTick(tickLower);
      const sqrtB = sqrtPriceAtTick(tickUpper);
      const requested = amountPerPosition - 1n;
      const liquidity = isToken0
        ? liquidityForAmount0(sqrtA, sqrtB, requested)
        : liquidityForAmount1(sqrtA, sqrtB, requested);
      const deposited = isToken0
        ? amount0Delta(sqrtA, sqrtB, liquidity, true)
        : amount1Delta(sqrtA, sqrtB, liquidity, true);
      positions.push({
        curve: curve.name,
        curveIndex,
        index,
        tickLower,
        tickUpper,
        liquidity,
        requested,
        deposited
      });
    }
  }
  return positions;
}

function positionState(position, assetWethPrice, isToken0) {
  const sqrtA = Math.sqrt(1.0001 ** position.tickLower);
  const sqrtB = Math.sqrt(1.0001 ** position.tickUpper);
  const poolPrice = isToken0 ? assetWethPrice : 1 / assetWethPrice;
  const sqrtP = Math.sqrt(poolPrice);
  const liquidity = Number(position.liquidity) / 1e18;
  if (isToken0) {
    if (sqrtP <= sqrtA) return {assetRemaining: liquidity * (sqrtB - sqrtA) / (sqrtA * sqrtB), wethAbsorbed: 0};
    if (sqrtP >= sqrtB) return {assetRemaining: 0, wethAbsorbed: liquidity * (sqrtB - sqrtA)};
    return {
      assetRemaining: liquidity * (sqrtB - sqrtP) / (sqrtP * sqrtB),
      wethAbsorbed: liquidity * (sqrtP - sqrtA)
    };
  }
  if (sqrtP >= sqrtB) return {assetRemaining: liquidity * (sqrtB - sqrtA), wethAbsorbed: 0};
  if (sqrtP <= sqrtA) return {assetRemaining: 0, wethAbsorbed: liquidity * (1 / sqrtA - 1 / sqrtB)};
  return {
    assetRemaining: liquidity * (sqrtP - sqrtA),
    wethAbsorbed: liquidity * (1 / sqrtP - 1 / sqrtB)
  };
}

export function simulateAtFdv(model, fdvUsd, isToken0 = true) {
  const priceWeth = Number(fdvUsd) / model.totalSupplyTokens / model.wethUsd;
  let remaining = 0;
  let absorbed = 0;
  for (const position of model.positions[isToken0 ? "assetToken0" : "assetToken1"]) {
    const state = positionState(position, priceWeth, isToken0);
    remaining += state.assetRemaining;
    absorbed += state.wethAbsorbed;
  }
  const distributed = model.inventoryTokens - remaining;
  const staticsDistributed = Math.max(0, distributed);
  const staticsRemaining = Math.max(0, remaining);
  const grossWeth = absorbed / (1 - model.feePips / 1_000_000);
  return {
    fdvUsd: Number(fdvUsd),
    staticsPriceUsd: Number(fdvUsd) / model.totalSupplyTokens,
    staticsDistributed,
    staticsRemaining,
    netWethAbsorbed: absorbed,
    grossWethInputAtFee: grossWeth,
    averagePriceUsd: staticsDistributed > 0 ? absorbed * model.wethUsd / staticsDistributed : 0,
    genesisBackingUnits: staticsDistributed / model.genesisBackingTokens
  };
}

export function createModel(config) {
  const spacing = config.economics.tickSpacing;
  const inventory = parseTokenAmount(config.economics.dopplerInventoryTokens);
  const inventoryTokens = Number(config.economics.dopplerInventoryTokens);
  const totalSupplyTokens = Number(config.economics.totalSupplyTokens);
  const wethUsd = Number(config.marketReference.wethUsd);
  let precedingUpperTick;
  const curves = config.curves.map((input, index) => {
    const tickLower = input.lowerFdvUsd
      ? fdvToTick(input.lowerFdvUsd, totalSupplyTokens, wethUsd, spacing)
      : precedingUpperTick;
    const tickUpper = input.upperTick ?? fdvToTick(input.upperFdvUsd, totalSupplyTokens, wethUsd, spacing);
    const inventoryAmount = parseTokenAmount(input.inventoryTokens);
    const shares = (inventoryAmount * WAD) / inventory;
    precedingUpperTick = tickUpper;
    return {...input, index, tickLower, tickUpper, shares, inventoryAmount};
  });
  const positions = {
    assetToken0: buildPositions(curves, inventory, spacing, true),
    assetToken1: buildPositions(curves, inventory, spacing, false)
  };
  return {
    config,
    curves,
    positions,
    inventory,
    inventoryTokens,
    totalSupplyTokens,
    genesisBackingTokens: Number(config.economics.genesisBackingTokens),
    maximumResidual: parseTokenAmount(config.economics.maximumResidualTokens),
    feePips: config.economics.feePips,
    wethUsd
  };
}

export function validateModel(model) {
  assert.equal(model.curves.reduce((sum, curve) => sum + curve.shares, 0n), WAD, "curve shares must sum to WAD");
  assert.equal(
    model.curves.reduce((sum, curve) => sum + curve.inventoryAmount, 0n),
    model.inventory,
    "curve inventory must equal Doppler inventory"
  );
  assert.deepEqual(model.curves.map((curve) => curve.numPositions), [11, 11, 11, 11, 11, 1]);
  assert.equal(model.curves[4].tickUpper, model.curves[5].tickLower, "tail must continue from growth");
  assert.equal(model.curves[5].tickUpper, 887200, "tail must end at the maximum usable tick");
  for (const ordering of Object.values(model.positions)) {
    assert.equal(ordering.length, 56);
    const deposited = ordering.reduce((sum, position) => sum + position.deposited, 0n);
    const residual = model.inventory - deposited;
    assert.ok(residual >= 0n && residual <= model.maximumResidual, `residual ${formatUnits(residual)} exceeds bound`);
  }
  const opening = simulateAtFdv(model, 111111.11111111111);
  assert.ok(opening.genesisBackingUnits < 1, "opening tick exposes a full Genesis backing unit immediately");
  for (const fdv of model.config.fdvMilestonesUsd) {
    const token0 = simulateAtFdv(model, fdv, true);
    const token1 = simulateAtFdv(model, fdv, false);
    const distributedDifference = Math.abs(token0.staticsDistributed - token1.staticsDistributed);
    const wethDifference = Math.abs(token0.netWethAbsorbed - token1.netWethAbsorbed);
    assert.ok(distributedDifference < 0.001, `token ordering distribution drift at ${fdv}`);
    assert.ok(wethDifference < 1e-9, `token ordering WETH drift at ${fdv}`);
  }
}

export function residualFor(model, ordering) {
  const deposited = model.positions[ordering].reduce((sum, position) => sum + position.deposited, 0n);
  return model.inventory - deposited;
}
