# Genesis transition tracking for Operator Fee Router V2

The existing handoff starts transfer tracking when the Statics Diamond accepts the activation
consumer role. The Diamond records each ownership change before Genesis updates ownership.
Same-owner tier changes leave the transfer nonce and timestamp unchanged.

After the Genesis protocol binding and V2 source verification, call
`bindGenesisOperatorFeeRouter(address)` through Diamond governance. The binding is one-time.
It checks the Router's dependencies and tracking start time. Routine upgraders must preserve
the tracking namespace, callback selectors and forwarding behavior while V2 is funded.

The companion tracking facet fits the binding and read selectors within the Diamond's deployment
size budget. The new read selectors are `genesisTransferState(uint256)`,
`genesisTransferTrackingStartedAt()` and `genesisOperatorFeeRouter()`. They are additive to the
existing Genesis integration interface.

## Fork rehearsal

Build the paired Router V2 and current Bonanza and Rooms revenue facets from their reviewed
source. Copy the Foundry artifacts into the ignored `out/operator-router-integration/` directory as
`RouterV2.json`, `BonanzaRevenue.json` and `RoomsRevenue.json`. Both game artifacts come from
`out/RevenueFacet.sol/RevenueFacet.json` in their respective repositories.

With the configured Robinhood mainnet RPC loaded, run
`RUN_OPERATOR_ROUTER_V2_FORK=true forge test --match-path test/genesis/fork/GenesisOperatorRouterFork.t.sol -vv`.
The test uses real Genesis dependencies at a pinned block and runs the handoff and vault flows
in the fork. The game revenue facets receive seeded settled-revenue balances and run their
production flush methods. Chain contracts and balances are unchanged.
