# ADR: Diamond-Wide Flash Liquidity and Composable Callbacks

- Status: Accepted
- Date: 2026-07-22
- Amended: 2026-09-11
- Scope: Basket-vector and single-asset flash loans, callback composition, custody, fees, and governance

## Context

Statics originally treated a basket flash loan as a temporary withdrawal from
that basket's vault. Principal was removed from the basket vault and custody
reservation before the callback, then restored during repayment. That model
limited a loan to one basket's accounted balance even when the Diamond held
more of the same ERC-20 for other protocol books.

Flash principal has no persistent owner change: either the receiver restores
the required balance in the same transaction or the entire transaction,
including every outbound transfer and callback effect, reverts. The durable
invariant is therefore physical and reservation-aware rather than basket-scoped:

```text
ending Diamond balance >= starting unreserved balance
                          + post-callback reservations
                          + quoted fee
```

Using only the raw starting balance would incorrectly reject legitimate
callback minting and redemption, because those operations change both physical
balances and their matching custody reservations.

Statics also needs an explicit way to borrow one physically held asset without
inventing a basket or a sentinel basket ID. Basket-vector and single-asset
loans have different integration semantics and fee sources, but share the same
atomic balance engine.

## Decision

### Physical balances supply flash principal

Both flash entrypoints snapshot each requested ERC-20 balance, require the
requested principal to fit within that physical balance, transfer the exact
amount, invoke the typed callback, collect exact principal plus the quoted fee,
and enforce the reservation-aware ending-balance invariant.

Flash principal never changes:

- basket vault balances;
- basket custody reservations;
- account-level custody reservations; or
- global custody reservations.

Only the newly earned fee is reserved after repayment and accrued through the
existing global non-swap reward and treasury books. A fee-on-transfer,
sender-taxed, rebasing-during-transfer, or otherwise inexact token is rejected
when the measured sender debit or receiver credit differs from the requested
transfer.

### Two external semantics

`flashLoan(basketId, shares, receiver, data)` remains the basket-vector API.
The basket defines the constituent addresses, bundle-scaled amounts, and its
own `flashFeeBps`; the Diamond's physical balances supply the vector. The
existing `IStaticsFlashBorrower.onStaticsFlashLoan` callback and
`BasketFlashLoan` event remain unchanged.

`flashLoanAsset(asset, amount, receiver, data)` borrows one ERC-20 and uses the
dedicated `IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset` callback. Its
success value is:

```solidity
keccak256("IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset")
```

`maxFlashLoan(asset)` reports the Diamond's raw physical balance.
`quoteFlashLoanAsset(asset, amount)` uses a protocol-wide
`singleAssetFlashFeeBps` with ceiling division. There is no arbitrary public
multi-asset API.

The single-asset fee is an explicit initial deployment input, bounded to
10,000 BPS, and initially configured to 5 BPS. The Diamond owner, which is the
Statics timelock after deployment, may later change it through
`setSingleAssetFlashFeeBps`.

### Callback composition and exclusion

`FlashLoanFacet` uses OpenZeppelin `ReentrancyGuardTransient` across the entire
flash operation. Basket and asset flash loans therefore cannot nest in any
combination.

Disbursement and repayment additionally acquire the same persistent storage
guard used by other value-moving Diamond facets. The explicit receiver
callback runs outside that persistent guard, allowing ordinary public Statics
operations such as minting and redemption to compose when their own physical
liquidity requirements remain satisfied. No callback receives special custody
authority, fee exemption, arbitrary execution facility, or synthesized
temporary backing.

A callback may fail because another operation needs an asset that is currently
lent. That is intentional: the borrower must request less or structure the
route differently. Any callback, repayment, slippage, or external-pool failure
reverts the complete transaction.

## Arbitrage integration contract

The optional `StaticsFlashArbitrageReceiver` remains a narrowly typed
overpriced-basket mint-and-sell receiver. It uses the basket callback, binds
swaps to configured canonical pools, enforces per-asset profit floors, returns
profit to the caller, and exposes no owner, allowlist, or arbitrary-call path.
Searchers implement other strategies and single-asset receivers themselves.

Routes must account for basket fees, flash fees, hook fees, price impact,
rounding, gas, approvals, and token behavior. The protocol does not discover
prices or profitability.

## Deployment and compatibility

The Diamond has not previously been deployed, so the fee is added directly to
the initial initializer and deployment configuration. There is no migration,
legacy storage fallback, or secondary initialization guard. The separately
deployed Genesis launch is not a deployed Statics Diamond.

Production deployment requires `STATICS_SINGLE_ASSET_FLASH_FEE_BPS`; examples
set it to `5`. The selector manifest includes both flash modes and the fee
administration surface.

Transient storage requires Cancun/EIP-1153. A chain without EIP-1153 support
is incompatible with this facet. Foundry targets Cancun, and production
addresses continue to come from deployment manifests rather than Solidity
constants.

## Consequences

Diamond-wide liquidity improves atomic routing and arbitrage without scanning
baskets or changing persistent ownership books for principal. A basket-vector
loan may exceed its originating basket's vault when every physical constituent
balance is sufficient. Arbitrarily transferred ERC-20 balances also become
available to the flash engine without being assigned to a custody account.

The temporary physical under-backing exists only inside the transiently
guarded transaction. Successful completion preserves the starting unreserved
balance, covers every post-callback reservation, and adds the quoted fee;
unsuccessful completion is atomic. Integrators must use the callback matching
the selected API and approve exact repayment before returning its distinct
success value.
