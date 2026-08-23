import assert from "node:assert/strict";
import {readFile, writeFile} from "node:fs/promises";
import {fileURLToPath} from "node:url";
import {dirname, resolve} from "node:path";
import {createModel, formatUnits, residualFor, simulateAtFdv, validateModel} from "./model.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const configPath = resolve(root, "config/robinhood-model.json");
const jsonPath = resolve(root, "reports/robinhood-launch-economics.json");
const markdownPath = resolve(root, "reports/robinhood-launch-economics.md");

function rounded(value, digits = 8) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function metric(model, fdv) {
  const result = simulateAtFdv(model, fdv);
  return Object.fromEntries(Object.entries(result).map(([key, value]) => [key, rounded(value)]));
}

function buildReport(model) {
  const curves = model.curves.map((curve) => ({
    name: curve.name,
    tickLower: curve.tickLower,
    tickUpper: curve.tickUpper,
    numPositions: curve.numPositions,
    sharesWad: curve.shares.toString(),
    inventoryTokens: curve.inventoryTokens
  }));
  const openingFdvUsd = model.totalSupplyTokens * model.wethUsd * 1.0001 ** model.curves[0].tickLower;
  const milestones = model.config.fdvMilestonesUsd.map((fdv) => metric(model, fdv));
  const accessibility = model.config.genesisBackingValueScenariosUsd.map((value) => {
    const fdv = Number(value) * model.totalSupplyTokens / model.genesisBackingTokens;
    return {targetGenesisBackingValueUsd: Number(value), ...metric(model, fdv)};
  });
  return {
    schemaVersion: 1,
    upstream: model.config.upstream,
    marketReference: model.config.marketReference,
    warnings: [
      "USD values are offchain modeling references, not oracle commitments.",
      "The model-only WETH/USD assumption must be replaced near launch before production ratification.",
      "Gas is measured by the required Foundry fork proof, not estimated by this offchain model."
    ],
    economics: {
      ...model.config.economics,
      openingFdvUsd: rounded(openingFdvUsd),
      openingGenesisBackingValueUsd: rounded(openingFdvUsd * model.genesisBackingTokens / model.totalSupplyTokens),
      totalPositions: model.positions.assetToken0.length,
      farTick: model.curves[5].tickUpper - model.config.economics.tickSpacing,
      token0ResidualTokens: formatUnits(residualFor(model, "assetToken0"), 18),
      token1ResidualTokens: formatUnits(residualFor(model, "assetToken1"), 18),
      forkGasMeasurement: null
    },
    curves,
    milestones,
    accessibility
  };
}

function markdown(report) {
  const decimal = (value, digits = 8) => Number(value).toLocaleString("en-US", {maximumFractionDigits: digits});
  const usd = (value) => `$${decimal(value, 8)}`;
  const lines = [
    "# Robinhood STATICS launch economics model",
    "",
    `Doppler source revision: \`${report.upstream.revision}\``,
    "",
    `WETH/USD assumption: **$${report.marketReference.wethUsd} (${report.marketReference.status})**`,
    "",
    `> ${report.marketReference.notice}`,
    "",
    "## Exact curve inputs",
    "",
    "| Region | Tick lower | Tick upper | Positions | Share | Inventory |",
    "|---|---:|---:|---:|---:|---:|",
    ...report.curves.map((curve) =>
      `| ${curve.name} | ${curve.tickLower} | ${curve.tickUpper} | ${curve.numPositions} | ${(Number(curve.sharesWad) / 1e16).toFixed(1)}% | ${Number(curve.inventoryTokens).toLocaleString("en-US")} STATICS |`
    ),
    "",
    "## Model checks",
    "",
    `- Opening FDV: ${usd(report.economics.openingFdvUsd)}`,
    `- Opening 180,000-STATICS value: $${report.economics.openingGenesisBackingValueUsd.toFixed(2)}`,
    `- Positions: ${report.economics.totalPositions}`,
    `- Far tick: ${report.economics.farTick}`,
    `- Asset-token0 residual: ${report.economics.token0ResidualTokens} STATICS`,
    `- Asset-token1 residual: ${report.economics.token1ResidualTokens} STATICS`,
    "- Token ordering: equivalent milestone results verified",
    "- Fork gas measurement: pending the production-configured fork proof",
    "",
    "## FDV milestones",
    "",
    "| FDV | Distributed | Remaining | Net WETH absorbed | Gross WETH at 1.5% | Average price | Genesis units |",
    "|---:|---:|---:|---:|---:|---:|---:|",
    ...report.milestones.map((row) =>
      `| ${usd(row.fdvUsd)} | ${decimal(row.staticsDistributed, 3)} | ${decimal(row.staticsRemaining, 3)} | ${decimal(row.netWethAbsorbed)} | ${decimal(row.grossWethInputAtFee)} | ${usd(row.averagePriceUsd)} | ${decimal(row.genesisBackingUnits, 3)} |`
    ),
    "",
    "## Genesis accessibility scenarios",
    "",
    "| 180,000-STATICS target value | FDV | Cumulative WETH | Distributed | Remaining | Genesis units |",
    "|---:|---:|---:|---:|---:|---:|",
    ...report.accessibility.map((row) =>
      `| ${usd(row.targetGenesisBackingValueUsd)} | ${usd(row.fdvUsd)} | ${decimal(row.grossWethInputAtFee)} | ${decimal(row.staticsDistributed, 3)} | ${decimal(row.staticsRemaining, 3)} | ${decimal(row.genesisBackingUnits, 3)} |`
    ),
    "",
    "## Proof boundary",
    "",
    ...report.warnings.map((warning) => `- ${warning}`),
    ""
  ];
  return lines.join("\n");
}

const config = JSON.parse(await readFile(configPath, "utf8"));
const model = createModel(config);
validateModel(model);
const report = buildReport(model);
const json = `${JSON.stringify(report, null, 2)}\n`;
const md = markdown(report);
const command = process.argv[2] ?? "check";

if (command === "generate") {
  await writeFile(jsonPath, json);
  await writeFile(markdownPath, md);
} else if (command === "check") {
  assert.equal(await readFile(jsonPath, "utf8"), json, "JSON report is stale; run npm run generate");
  assert.equal(await readFile(markdownPath, "utf8"), md, "Markdown report is stale; run npm run generate");
} else {
  throw new Error(`unknown command: ${command}`);
}
