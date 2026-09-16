# Statics Slither campaign

This campaign reviews every owned production Solidity contract and deployment
script in the repository. Slither analyzes the composed source graph, then the
normalizer reduces findings by source mapping into the `production-contracts`
and `production-scripts` passes defined in `scope.json`.

The scope manifest starts from every `*.sol` file below `src/` and `script/`.
Local fixtures, testnet-only contracts and scripts, and empty third-party
compiler-selection units are excluded individually with a concrete reason. The
scope check fails before Slither runs if a new owned Solidity file is neither
included nor explicitly excluded.

## Reproduce

GitHub Actions is the release-evidence runner. It pins Python 3.12, Foundry
`nightly-bdd1162b2c24814d2424ffad4f8c587827f1a6ab` (`1.8.2-nightly`), and
Slither 0.11.6 and publishes the complete `slither-results/` directory. The
same campaign can be reproduced with:

```sh
python3.12 -m venv .slither-venv
.slither-venv/bin/pip install slither-analyzer==0.11.6
SLITHER_BIN="$PWD/.slither-venv/bin/slither" scripts/run-slither.sh
```

The runner uses the `slither` Foundry profile, performs a normal
`forge build --build-info`, and then passes `--foundry-ignore-compile` to
Slither. The profile disables Foundry's dynamic test linker because its
ephemeral `foundry-pp` sources cannot be reopened from cached build-info by
Crytic Compile. Ignoring Slither's compile step is still required because the
default Slither Foundry adapter invokes `forge clean` and a forced build, which
are not allowed by this repository. Raw machine-specific output is written to
the ignored `slither-results/` directory.

`baseline.json` contains a classification and rationale for each exact reviewed
finding fingerprint; detector-wide defaults are not applied. Repeated findings
from multiple Foundry compile units are collapsed into one fingerprint with an
occurrence count. Fingerprints use detector names and scoped source identities
including source spans. CI fails when a new high/medium finding is absent
from the baseline or when a current high/medium finding remains `CONFIRMED` or
`INVESTIGATE`. New low/informational findings are printed for review but do not
block the gate. `current.json` retains the complete normalized result and
`scope.json` records the exact files covered by that run.

## Evidence boundary

The baseline is a reviewed static-analysis result, not a claim that Slither
proves protocol correctness. `triage.md` summarizes common detector families;
the authoritative decision remains attached to each fingerprint in
`baseline.json`. Halmos, Certora, Foundry fuzz and invariant suites separately
check the accounting and composed callback properties that static analysis
cannot prove.
