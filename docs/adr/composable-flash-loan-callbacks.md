# ADR: Composable Flash-Loan Callbacks

- Status: Accepted
- Date: 2026-07-22
- Scope: Basket flash loans, basket minting and redemption, canonical v4 arbitrage

## Context

Statics flash loans lend the exact constituent vector represented by a basket
share quantity. Their natural use is atomic price correction: a receiver can
mint and sell an overpriced BasketToken, or buy and redeem an underpriced one.
Both routes must be able to use the ordinary public basket entrypoints during
the flash callback.

The Diamond's value-moving facets share OpenZeppelin's persistent
`ReentrancyGuard` slot. Applying that same guard to `flashLoan` blocks every
guarded basket operation during the callback, even though custody has already
released and debited the flash principal from the selected basket's books.
Removing reentrancy protection entirely would instead permit nested flash
loans and make the callback state machine harder to reason about.

## Decision

`FlashLoanFacet` uses OpenZeppelin `ReentrancyGuardTransient`. Basket minting,
redemption, lending, rewards, and liquidity operations retain the common
persistent guard.

The transient guard spans the entire flash operation. Flash disbursement and
repayment additionally acquire the exact persistent storage slot used by
OpenZeppelin `ReentrancyGuard`, releasing it only around the explicit receiver
callback. This phase boundary prevents callback-capable constituent token hooks
from entering a persistent value path while outbound or inbound balance deltas
are being measured, without blocking ordinary guarded composition from the
receiver callback itself.

The transient and persistent guards use separate EVM storage domains. During a
flash callback:

- another `flashLoan` observes the transient guard and reverts;
- an ordinary basket mint or redemption can enter the persistent guard;
- the callback receives no special role, allowance, custody authority, or fee
  exemption; and
- any callback, minimum-profit, swap, or repayment failure reverts the entire
  transaction, including v4 pool and reward-accounting changes.

The flash ABI, callback hash, quote, pause check, constituent-vector limit,
measured repayment, reservation accounting, event, and fee routing remain
unchanged. Flash principal is restored to the originating basket vault.
Disbursement requires the Diamond debit and receiver credit to equal the quoted
principal, so incompatible outbound-tax behavior reverts rather than reducing
backing. The measured amount received above principal during repayment is
routed through the ordinary global non-swap fee ledger.

## Arbitrage integration contract

Statics ships one optional purpose-built receiver for the overpriced
mint-and-sell direction. `StaticsFlashArbitrageReceiver` accepts only a basket,
share quantity, complete per-pool BasketToken allocation, per-asset net profit
floors, and deadline. It binds every swap to the Diamond's configured canonical
pool, settles directly with that Diamond's configured PoolManager, and returns
all profit to the caller. It has no owner, retained balances, receiver registry,
allowlist, arbitrary-call executor, or privileged callback mode.

The receiver does not discover prices or allocations and does not implement
the underpriced buy-and-redeem direction. Searchers remain responsible for
route construction, quote freshness, gas economics, and transaction ordering.

For an overpriced multi-asset basket, a receiver:

1. flash-borrows the constituent vector;
2. approves and calls the ordinary `mint` entrypoint, paying its configured
   static fee;
3. divides and sells the minted BasketTokens through the canonical
   BasketToken/constituent pools;
4. checks every constituent balance against its starting balance, flash
   principal, flash fee, and required minimum profit; and
5. approves the Diamond for exact repayment.

For an underpriced single-asset basket, a receiver:

1. flash-borrows the underlying;
2. buys BasketTokens from the canonical pool;
3. calls the ordinary `redeem` entrypoint and pays its configured static fee;
4. checks underlying profit after both hook fee legs and the flash fee; and
5. approves exact repayment.

Both routes include the canonical pool's input and output hook fees. The hook
continues to route its configured shares to permanent liquidity, global
stakers, and treasury. Profit exists only after basket fees, both hook fee
legs, price impact, rounding, flash fees, and gas are covered.

## Deployment and compatibility

Transient storage requires Cancun/EIP-1153. A chain that does not implement
EIP-1153 is incompatible with this facet and must not receive a Statics
deployment. Foundry targets `cancun`, and deployment preflight must confirm the
target network supports transient storage.

Robinhood Chain compatibility is covered by a pinned-fork test using the
PoolManager address and block recorded in
`deployments/robinhood-chain-4663.json`. The RPC is supplied through
`ROBINHOOD_MAINNET`; `ROBINHOOD_RPC_URL` remains a compatibility fallback.
Production addresses continue to come from the deployment manifest rather
than Solidity constants.

The observed Robinhood testnet TPA1/PLTR distortion is separately replayed at
its pinned historical block. That test deploys the production receiver only
inside the fork, reads the live Diamond and basket configuration from the
repository manifests, repays the three-asset flash vector, realizes net profit,
moves the PLTR pool toward its launch price, and compounds hook-owned liquidity.
It does not broadcast a testnet transaction.

## Consequences

Flash callbacks intentionally expose the same permissionless basket surface as
any other contract call. Receivers must use bounded approvals, validate the
pool key, enforce slippage and minimum profit, and treat token quirks and v4
state as external dependencies. The originating basket cannot spend another
basket's reservations, and a route that cannot restore every measured
principal reverts atomically.
