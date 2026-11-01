# External PositionNFT accounts

Statics authorizes external modules, tracks their PositionNFT account attachments,
exposes module discovery, and prevents NFT closure while external financial state
remains active. Each product independently owns its financial accounting and reward logic.

## Authority and lifecycle

Governance calls `setExternalModule(authority, moduleType, enabled)` using the
existing Diamond owner authority. `externalModuleEnabled(authority, moduleType)`
reports admission. Approval is specific to both the calling contract and module type.

An approved module calls `attachExternalAccountLeg(positionId, moduleType, localId)`
in the same transaction that creates financial state. The leg key is
`keccak256(abi.encode(msg.sender, moduleType, localId))`; callers cannot choose
another module's authority. Nonexistent or initializing positions, duplicate legs,
and a 65th external leg revert. Attachment failure must revert the product's entire
financial operation, including custody transfers. A product must never swallow that failure.

Only the original calling module can `detachExternalAccountLeg` for its namespace.
Disabling admission blocks new attachments but keeps existing legs and cleanup authority.
The module must check its own balances, liabilities, stake, rewards, registrations,
and pending entitlements before detaching. Statics trusts approved modules to enforce
these checks; approval is not a solvency or safety guarantee. Governance cannot clean up
an unavailable module's accounts through this interface.

Attachments share the existing PositionNFT active-leg count and closure guard with
internal Statics modules. Internal keys, storage, events and accounting are unchanged.
External accounts do not prevent transfers, and transfers never call external products.
Financial state remains in product custody and follows the account identifier. Products
must use current `ownerOf(positionId)` for financial authority; ERC-721 approvals alone
must not authorize withdrawals or other financial actions.

## Discovery and interface

The seven selectors are:

- `setExternalModule(address,bytes32,bool)`
- `externalModuleEnabled(address,bytes32)`
- `attachExternalAccountLeg(uint256,bytes32,bytes32)`
- `detachExternalAccountLeg(uint256,bytes32,bytes32)`
- `externalLegCount(uint256)`
- `externalLegCapacity()`
- `externalLegs(uint256,uint256,uint256)`

`externalLegCapacity()` is 64. Pages accept limits from 1 through 100 and cursors
up to the current count. The result includes each authority, type, local identifier
and leg key, followed by the next cursor. Detachment uses swap-and-pop ordering;
use PositionNFT `stateNonce` to detect attachment changes between pages.
ERC-165 reports the reduced `IStaticsExternalModules` interface. Consumers must
update their interface definition and interface ID together.

There is no shared ownership journal, replay service, reward synchronization or
Operator boost reconciliation. Products such as Fiddy read NFT ownership and the
Activation Registry directly and own their staking indexes, forfeiture rules and
account nonces. Genesis activation, transfer, recovery and reward behavior are unchanged.

## Deployment and upgrade

Fresh and staged deployments install the external-module facet and register its
interface in Phase 1. For existing Diamonds without this interface, the upgrade
preparer returns one Add cut with seven selectors plus an initializer that registers
ERC-165 support. Execute both atomically through existing governance. The initializer
only sets the interface flag and is idempotent; the Add cut rejects duplicate installation.
It does not change financial, position, owner-index or internal-leg storage. Neither
the PositionNFT facet nor the Genesis facet needs replacement.

This preparer targets pre-extension Diamonds. An installation of the earlier
11-selector candidate requires a separately reviewed cut to remove its obsolete
selectors, clear its old interface flag, and replace any journal-enabled facets;
it must not use this Add-only preparer. No deployed candidate migration is asserted.

Fiddy compatibility uses the reduced interface and a pinned matching Statics dependency.
The local funded lifecycle fixture and Fiddy actual-source integration tests establish
local behavior only. Production deployment bindings and upgrade execution still need
separate qualification. Future casino and BucketPerps products implement their own
financial lifecycle and require module registration rather than new Statics selectors.
