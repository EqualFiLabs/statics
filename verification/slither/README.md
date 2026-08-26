# Statics Slither campaign

This campaign reviews the effective runtime and deployment surface carried by
the Genesis PR stack. It intentionally analyzes the composed source graph, then
reduces findings by source mapping into three explicit passes defined in
`scope.json`: standalone launch, permanent Diamond integration, and deployment
handoff.

## Reproduce

Use Python 3.12, Foundry 1.7.1, and Slither 0.11.6:

```sh
python3.12 -m venv .slither-venv
.slither-venv/bin/pip install slither-analyzer==0.11.6
SLITHER_BIN="$PWD/.slither-venv/bin/slither" scripts/run-slither.sh
```

The runner performs a normal `forge build --build-info` and then passes
`--foundry-ignore-compile` to Slither. This is required because the default
Slither Foundry adapter invokes `forge clean` and a forced build, which are not
allowed by this repository. Raw machine-specific output is written to the
ignored `slither-results/` directory.

`baseline.json` contains stable fingerprints for every reviewed in-scope
finding. Repeated findings from multiple Foundry compile units are collapsed
into one fingerprint with an occurrence count. Fingerprints use detector names
and scoped source identities rather than line numbers. CI fails when a new high/medium finding is absent from the
baseline or when a current high/medium finding remains `CONFIRMED` or
`INVESTIGATE`. New low/informational findings are printed for review but do not
block the gate.

## Evidence boundary

The baseline is a reviewed static-analysis result, not a claim that Slither
proves protocol correctness. `triage.md` records why every retained detector
family is non-actionable on this source graph. Halmos, Certora, Foundry fuzz and
invariant suites separately check the accounting and composed callback
properties that static analysis cannot prove.
