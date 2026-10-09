# Position NFT statement events

Statements follow a Position NFT throughout ownership changes, including closure. The
Phase 1 liquidity, allocation and global claim events supply exact accounting data
without scraping unrelated transfers or inferring amounts from price.

## Amounts and identity

Liquidity movement currencies follow the PoolKey's currency0/currency1 order.
`paid0/1` are actual funding-pull payer debits, including gross funds later refunded.
`received0/1` are actual recipient credits from refunds or outputs. Native funding uses
the validated call value, excluding gas. Zero payer/paid amounts identify output-only
operations. Approved operators may pay while the NFT owner receives outputs/refunds.

The payer debit measurements already enforced by the funding path are reused. No
transaction-wide wallet audit is added. Function selectors, returned movement structs,
storage layout, authorization, minimums and transfer behavior remain unchanged.

`ManagedLiquidityRebalanced` distinguishes wallet movements from `RebalanceSettlement`:
old-position proceeds go to the diamond, then fund the replacement mint. Its mint spend
and return are internal manager settlement. A wallet may supply extra funds and receive
a final refund; internally recycled proceeds must not be counted as a wallet payout.
Decrease and exit proceeds may combine principal and trading fees; the event does not
invent an economic split. `ManagedLiquidityAttached` moves no currencies.

`ManagedLiquidityFeesCollected` reports the Position NFT, LP NFT, pool, recipient and
actual outputs, including successful zero collection. `PositionGaugeAllocationsSet`
contains the exact ordered replacement arrays, including an empty clear. Directory
snapshots can remain block-ending while statements retain intermediate replacements.
The allocation event uses standard ABI encoding with a bounded calldata copy to retain
facet deployability; tests exercise empty, one and sixteen entries and wrapped calls.

`RewardClaimed` distinguishes actual custody debit from actual legacy recipient credit.
Taxed legacy receipts remain supported. Aggregated claims report individual entitlements
and final exact transfers; `AggregatedRewardPaid` must not create additional Position NFT
statement credits. Entitlement settlement/forfeiture are distinct from wallet credits.

Transaction sender is transport context, not proof of the original caller of a wrapped
wallet call. Payer/receiver attribution requires event fields. Creation-fee events prove
the treasury receipt; they do not identify the payer.

## Compatibility and replay

These prelaunch event topics replace the old signatures. Consumers require the matching
SDK ABI. Existing function selectors and existing ERC-165 IDs do not change; the separate
non-swap revenue configuration interface adds its own ID and governance selectors.

A fresh indexer replay must read a deployment that emits these payloads. Replaying old
logs cannot recover missing amounts. Mint/burn Transfer logs establish ownership;
PositionCreated/PositionClosed supply the single canonical opening/closing entry.
Ordinary transfers remain statement entries. Batch claim events retain separate log
indices, even when positions and assets repeat.

The default non-swap staker share remains 9000 basis points. Governance can set 0–10000;
the remainder and rounding go to treasury. Changes affect future accrual only. No-eligible
stake and reward restrictions retain their treasury fallback.

## Gas and deployability evidence

Baseline `573b06b51d2f9c51609f4610d30813eec991d124` and candidate use solc 0.8.33,
Cancun, optimizer 200 and no Statics IR. Scoped upstream compiler exceptions are unchanged.
`PositionStatementGasTest` runs identical real-v4 fixtures at both revisions; measurements
are gasleft deltas in the same test-call warm-state sequence, not submitted transaction
estimates. Provision includes its funding fixture; the other liquidity samples measure
only the external action. Allocation replacement's one-entry sample removes sixteen old
entries. Mixed claims contain six groups and ten entries, with settlement.

| Operation | Baseline gas | Candidate gas | Increase |
|---|---:|---:|---:|
| Provision including fixture | 1,607,415 | 1,610,178 | 2,763 |
| Increase | 679,373 | 682,431 | 3,058 |
| Decrease | 475,168 | 477,721 | 2,553 |
| Zero fee collection | 246,333 | 249,256 | 2,923 |
| Rebalance | 1,177,098 | 1,184,243 | 7,145 |
| Exit | 526,005 | 528,884 | 2,879 |
| Allocate sixteen | 3,817,555 | 3,827,319 | 9,764 |
| Replace sixteen with one | 1,457,356 | 1,459,111 | 1,755 |
| Mixed legacy batch | 3,231,006 | 3,231,620 | 614 |
| Mixed aggregated batch | 3,154,660 | 3,156,070 | 1,410 |

Measured runtime bytecode: GaugeIncentiveFacet 24,542 bytes, GlobalRewardsFacet 24,428,
RangeGaugeLivenessFacet 22,066, BatchRewardsFacet 6,778. The first two have limited remaining
EIP-170 headroom; future features should consider separate facets. The deployability tests
assert the limit rather than changing compiler settings.

Solidity log fixtures are produced with:

```sh
WRITE_STATEMENT_FIXTURES=true RAYON_NUM_THREADS=1 forge test --threads 1 \
  --match-path test/range/PositionStatementAbi.t.sol
```

Extract the eight matching event definitions from the compiled interface ABIs for the SDK's
ABI fixture. The SDK tests normalize compiler-only internalType/default-false fields and
compare every topic, indexed identifier and tuple payload.
