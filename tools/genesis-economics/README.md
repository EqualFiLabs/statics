# Genesis launch economics simulator

This dependency-free Node tool reproduces the position construction used by
Doppler `Multicurve.sol` at source revision
`86a5200456b148c156d2eb81a893747dd601c3ca`.

It models the candidate Robinhood STATICS/WETH launch in both possible token
orderings and writes deterministic JSON and Markdown reports. The checked-in
USD value is deliberately labeled as a modeling assumption. It is not an
approved launch-time market observation and cannot ratify a production hash.

```sh
npm --prefix tools/genesis-economics test
npm --prefix tools/genesis-economics run generate
npm --prefix tools/genesis-economics run check
```

`generate` updates the committed reports. `check` fails when either report is
stale or when opening accessibility, curve continuity, position counts, token
ordering equivalence, share totals, or the onchain residual ceiling no longer
holds.
