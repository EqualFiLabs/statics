import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {
  createModel,
  fdvToTick,
  formatUnits,
  formatWadPercentage,
  residualFor,
  simulateAtFdv,
  sqrtPriceAtTick,
  validateModel
} from "../src/model.mjs";

const config = JSON.parse(
  await readFile(new URL("../config/robinhood-model.json", import.meta.url), "utf8")
);

test("ports the Uniswap v4 tick constants exactly", () => {
  assert.equal(sqrtPriceAtTick(-887272), 4295128739n);
  assert.equal(sqrtPriceAtTick(0), 1n << 96n);
  assert.equal(sqrtPriceAtTick(887272), 1461446703485210103287273052203988822378723970342n);
});

test("aligns the opening price to the cheaper tick", () => {
  const wethUsd = Number(config.marketReference.wethUsd);
  const raw = Math.log((111111.11111111111 / 1e9) / wethUsd) / Math.log(1.0001);
  const aligned = fdvToTick("111111.111111111111", "1000000000", wethUsd, 100);
  assert.ok(aligned <= raw);
  assert.equal(Math.abs(aligned % 100), 0);
});

test("formats WAD percentages without lossy Number conversion", () => {
  assert.equal(formatWadPercentage(123456789012345678n), "12.3");
  assert.equal(formatWadPercentage(999999999999999999n), "100.0");
});

test("clamps distribution-derived metrics together", () => {
  const baseline = createModel(config);
  const model = {...baseline, inventoryTokens: baseline.inventoryTokens - 0.001};
  const result = simulateAtFdv(model, 1);
  assert.equal(result.staticsDistributed, 0);
  assert.equal(result.averagePriceUsd, 0);
  assert.equal(result.genesisBackingUnits, 0);
});

test("validates curve topology, token ordering, and residual bounds", () => {
  const model = createModel(config);
  validateModel(model);
  assert.equal(model.positions.assetToken0.length, 56);
  assert.equal(model.positions.assetToken1.length, 56);
  assert.ok(residualFor(model, "assetToken0") <= model.maximumResidual);
  assert.ok(residualFor(model, "assetToken1") <= model.maximumResidual);
  assert.match(formatUnits(residualFor(model, "assetToken0"), 18), /^0(?:\..*)?$/);
  assert.match(formatUnits(0n, 18), /^0(?:\..*)?$/);
});
