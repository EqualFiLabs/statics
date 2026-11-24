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

The staged Phase 1 launcher and its six-call liquidity configuration ceremony
are production scripts, so they enter this mandatory scope automatically. No
new exclusion or detector-family suppression is added for the staged launch.
A separate file-list expansion would be misleading because all owned
production contracts and scripts are already classified; tests and formal
harnesses remain covered by their executable engines rather than the
production Slither baseline. The phased launch does not add a Genesis ownership
migration or modify the already deployed Genesis system.

## Reproduce

GitHub Actions is the release-evidence runner. It pins Python 3.12, Foundry
`nightly-bdd1162b2c24814d2424ffad4f8c587827f1a6ab` (`1.8.2-nightly`), and
Slither 0.11.6. The public check reports aggregate counts and the gate result.
Run the same campaign locally to collect private review evidence.

```sh
python3.12 -m venv .slither-venv
.slither-venv/bin/pip install slither-analyzer==0.11.6
SLITHER_BIN="$PWD/.slither-venv/bin/slither" scripts/run-slither.sh
```

The runner uses the `slither` Foundry profile, performs
`forge build --build-info --skip test`, and then passes
`--foundry-ignore-compile` to Slither. Tests and formal harnesses are executable
verification inputs rather than production Slither subjects; omitting their
compilation units keeps the analysis graph bounded while every owned `src/`
and `script/` source remains classified by `scope.json`. The profile also
disables Foundry's dynamic test linker because its ephemeral `foundry-pp`
sources cannot be reopened from cached build-info by Crytic Compile. Ignoring
Slither's compile step is still required because the default Slither Foundry
adapter invokes `forge clean` and a forced build, which are not allowed by this
repository.

## Reviewed baseline

`baseline.json` tracks only exact finding IDs, detector names, severity,
reviewed dispositions, and occurrence counts. Its approved dispositions are
`FALSE POSITIVE` and `INTENTIONAL`. Review exact source evidence before adding
a disposition or increasing an approved count. A move that changes a
fingerprint requires review against its new source location.

The gate rejects new or unresolved High and Medium findings and increases
in their occurrence counts. It also rejects detector or severity changes for
an existing ID. New Low and Informational findings remain nonblocking.
The scope, fingerprint, and comparison rules apply to every run.

Keep raw scan output, normalized findings, and detailed rationales in private
storage outside Git. The runner writes its local evidence to the ignored
`slither-results/` directory, or to `SLITHER_RESULTS_DIR` if set. Public CI
emits aggregate results and leaves the detailed files on its ephemeral runner.

The baseline records reviewed static-analysis results. Halmos, Certora, and
Foundry fuzz and invariant suites separately check accounting and composed
callback properties.
