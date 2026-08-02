# ADR: Canonical LP NFT custody and rewards

## Status

Accepted and implemented.

## Decision

Statics allocates a configurable share of bilateral canonical-pool hook fees to
activated, full-range Uniswap v4 PositionManager liquidity. The launch split is
50% hook-owned permanent liquidity, 10% canonical LPs, 30% global stakers, and
10% treasury. Governance may select any nonnegative four-way split totaling
10,000 BPS; the LP share has no independent cap.

Eligibility is based on current custody and canonical pool identity, not NFT
provenance. `borrowAndProvideLiquidity` remains a typed convenience path but
provides no automatic enrollment or privileged economics.

## Custody and authorization

A stake must be nonzero, unsubscribed, full range, and belong to the exact
active canonical PoolKey. The LP NFT owner must also own the PositionNFT, and
the caller must be the PositionNFT owner or an approved operator. The Diamond
uses an ordinary PositionManager `transferFrom`, avoiding an inbound ERC-721
callback, and verifies ownership and unchanged live liquidity afterward.

The LP NFT becomes a shared PositionNFT leg. PositionNFT transfer therefore
moves custody, claim, increase, and exit authority. Externally held NFTs remain
independent. The Diamond never exposes arbitrary PositionManager execution.

## Eligibility and exit

Initial liquidity becomes eligible in the next block. An in-custody increase
settles existing rewards, preserves existing eligible weight, and places only
the added delta into next-block pending state. Activation is permissionless and
O(1); no keeper runs automatically.

There is no LP withdrawal cooldown. The authorized PositionNFT controller may
unstake immediately, during pauses, quarantine, or `ExitOnly`. Exit settles the
eligible index, removes the pool denominator, and returns the NFT without
requiring reward delivery. Crystallized claims remain attached to the
PositionNFT. Users unstake before decreasing, collecting, or burning through
PositionManager.

## Fee accounting

Each pool maintains independent indexes for currency0 and currency1. Activated
v4 liquidity is the denominator. Pending liquidity never earns, and liquidity
from different pools is never compared. When no activated liquidity exists,
the hook redirects the configured LP share to POL before transferring funds.

LP, staker, and treasury amounts enter the Diamond's fee custody reservation in
one exact pool-aware transfer. LP index liabilities, global rewards, and
treasury accrual remain separate books over that common physical reservation.
Index remainder is reset when liquidity changes; once the final eligible
position settles and exits, whole-token epoch dust is reclassified to treasury.

## In-place increases

The installed immutable manager receives PositionManager operator approval from
the Diamond during installation. Its typed increase function accepts only a
registered canonical PoolKey and a token owned by the Diamond. The user supplies
an exact liquidity delta, per-currency maximums, a deadline, and a refund
receiver. The Diamond funds the manager only with transaction-scoped unreserved
inputs. The manager clears ERC-20 and Permit2 approvals, returns unused assets,
and verifies ownership and measured movements. The facet verifies the exact
live-liquidity delta before recording it as pending.

## Lifecycle and security properties

- Staking and increasing require an active basket, active canonical pool, and
  unpaused liquidity actions.
- Activation of already deposited liquidity remains permissionless until pool
  decommissioning; claim and exit remain available afterward.
- Pool decommissioning stops new accrual but never decreases, burns, or seizes a
  user PositionManager NFT.
- One-block activation prevents atomic stake/swap/unstake and flash-funded
  reward capture without trapping the NFT for a time period.
- Physical fee balances must cover LP, global reward, and treasury liabilities;
  one basket or pool cannot debit another's reservation or reward index.
- No production router, allowlist, provenance registry, fee exemption, or
  arbitrary execution surface is introduced.
