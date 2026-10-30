# External PositionNFT accounts

Statics provides account closure protection and ordered NFT ownership changes.
Each admitted product retains its own custody, balances, backing, liabilities,
receipts, staking, and revenue accounting. Adding a compatible product requires
admin configuration, not another Statics facet or callback implementation.

## Lifecycle and authority

`IStaticsExternalModules` is exposed on the Statics Diamond and advertised through
ERC-165. `setExternalModule(authority, moduleType, enabled)` admits a caller/type
pair under the existing protocol admin. There is no code-hash admission handshake.

The module calls `attachExternalAccountLeg(positionId, moduleType, localId)` in
the same transaction that first creates unresolved financial state. The returned
leg key is `keccak256(abi.encode(msg.sender, moduleType, localId))`, scoped to the
PositionNFT. A module cannot supply another authority, change internal legs, or
clear another module's marker. Duplicate attachment and missing detachment revert.
Nonexistent and initializing positions cannot acquire external legs.

One aggregate account leg per product/PositionNFT is recommended. Trades,
receipts, payment assets, and individual claims stay in product bookkeeping.
There are 64 external legs per PositionNFT, including disabled occupied namespaces.
Capacity failure reverts the entire account-opening transaction. Internal legs do
not consume this external capacity.

Admission disablement stops new attachments, while the original caller retains
authority to service and detach its existing accounts. Address rotation creates
a separate namespace; it never transfers or erases the old address's legs. The
existing module must finish its supported cleanup. There is no owner/admin
force-detach path. Statics trusts admitted modules' emptiness assertions.

A module detaches only after all balances, receipt value, stake, obligations,
and pending/claimable revenue have been resolved. Existing leg, obligation,
initialization, and Morpho checks continue to protect PositionNFT closure.

`externalLegCount`, `externalLegCapacity`, and `externalLegs(positionId, cursor,
limit)` expose attached authority, type, local identifier, and key. Pages contain
at most 100 entries. Removal uses swap-and-pop: compare the structural
`positionState.stateNonce` before/after pagination and restart if it changes.
That nonce does not track a product's changing financial balances.

Financial actions must verify the current `ownerOf(positionId)`. ERC-721
approvals do not grant financial authority. A transfer changes account control,
including historical module rewards, immediately; sellers must claim before
selling if they wish to retain those rewards. Product-specific ticket/winner
rights are outside this interface. Position creation and fees are unchanged.

## Ordered transfer history

- `transferHead()` is the global sequence, initially zero.
- `transferState(collection, tokenId)` returns a dedicated nonce, timestamp, and
  last sequence. These are independent of the structural position nonce.
- `transferChanges(afterSequence, limit)` returns consecutive changes after an
  exclusive cursor, plus the next cursor. Limits are 1 through 100; cursors may
  equal, but cannot exceed, the head. Each returned record carries collection,
  token ID, nonce, and timestamp; its sequence is `afterSequence + index + 1`.
- `historyCoverage(collection)` returns the start block, exclusive starting
  sequence, and current readiness. Unknown collections are not ready.

PositionNFT changes are recorded after ownership mutation and before an ERC-721
receiver callback. Operator changes use the existing authenticated Activation
Registry notification, including unlinked Operators, base activation, and vault
purchases/recovery. Recovery is recorded once through its actual ownership change.
Minting, burning, self-transfers, and activation increases do not append changes.
Minted NFTs start with zero markers; burning retains their historical records.

Timestamps alone do not order transactions within a block. Sequence and nonce
separate same-block transfers, round trips, and revenue funding boundaries.
The append-only journal retains every recorded change indefinitely. There is no
pruning, cursor reset, module fan-out, or external product call during recording.
A module processes irrelevant records by advancing its own cursor.

Position coverage starts at installation. Operator coverage starts only once the
recorder is installed and Statics holds the registry consumer role with its fee
receiver integration ready. Existing Genesis readiness checks determine current
readiness. The upstream single-consumer notification remains necessary for
Statics' own rewards and this journal; external products receive no callbacks.

Before enabling boosts, complete and qualify the existing distributor/consumer
handoff. Coverage must then remain continuous. The start marker is not a proof
that governance never moved the consumer away and back. There is no automatic
gap recovery or reconstruction of transfers before installation. Downstream
boosted operation must not rely on an interval without recording coverage.

## Consumer boost and revenue rules

External registration is independent of Statics Genesis linking/unlinking.
Verify that the caller owns both NFTs and read activation directly from the
canonical Activation Registry. Maintain one Operator per PositionNFT and one
PositionNFT per Operator **within each module**, using forward/reverse mappings.
Modules may independently register the same Operator. Boosts never stack.

Store the applied multiplier and both NFTs' registration transfer markers.
Either NFT's next ownership change invalidates that boost prospectively to
10,000 bps. Raw stake, backing, and earned revenue remain unchanged. Higher
activation takes effect only through explicit prospective refresh. Clear stale
reverse mappings during reconciliation without requiring the previous owner.
Switching/removing a registration must settle prior earnings first.

For each funded revenue allocation:

1. Capture `transferHead()` as its boundary.
2. Replay changes through that boundary, checkpoint affected registered accounts
   at the existing indexes, invalidate their boosts, and correct total weight.
3. Allocate the funded revenue using that corrected global denominator.

Checking only the claimant is insufficient: dormant accounts also affect total
weight. If catch-up cannot fit, reserve actual funds and queue the allocation
with its original boundary. Permissionless bounded calls replay changes and
allocations in order. Do not apply later transfers to earlier revenue. Complete
prior allocations before changing stake or registrations. Product closes and
liquidations must not acquire unbounded loops. Preserve pending entitlement in
closure checks; separate indexed and pending views. Keep zero-stake revenue and
rounding dust from being captured by future entrants.

## Installation and qualification

Fresh and staged deployment plans install the external-module facet in Phase 1.
For an existing deployment, the upgrade preparer returns a cut that adds the new
facet, replaces the PositionNFT facet, and replaces Genesis routes when already
installed. Execute that cut together with `StaticsExternalModulesInit.initialize`
through existing governance. Initialization does not reset existing position,
reward, owner-index, or internal-leg storage. It cannot run twice.

The integration suite uses actual Statics/Genesis/registry contracts with funded
single-asset and multi-asset reference consumers plus a lifecycle-only consumer.
Those consumers are test fixtures, not production adapters. A pinned fork
qualifies the checked-in immutable bindings and existing registry handoff.

Production BucketPerps integration remains in EqualFiLabs/bucketperps#1; Fiddy
integration remains in EqualFiLabs/fiddy#25. Both products still need their own
custody/backing, pending-revenue, pause, cleanup, and end-to-end qualification.
Public wrapping and unwrapping remain disabled at launch with wrap capacity zero.
This Statics foundation does not close their acceptance requirements or all of
EqualFiLabs/statics#143.
