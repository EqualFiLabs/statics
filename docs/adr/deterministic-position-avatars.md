# ADR: Deterministic PositionNFT avatars

- Status: Superseded by `genesis-tokenomics-and-swap-revenue.md`
- Date: 2026-08-02
- Scope: Statics PositionNFT metadata and visual identity

> **Superseded (2026-08-13).** PositionNFT metadata is now minimal
> financial-account JSON. The deterministic SVG renderer and activation-tier
> presentation belong to Genesis NFTs.

## Context

The Statics Diamond is the ERC-721 PositionNFT contract. A PositionNFT carries
protocol rights and obligations, but its current `tokenURI` is empty. Wallets
therefore display an anonymous token identifier rather than a recognizable
Statics identity.

The visual identity should be fully onchain, deterministic, legible at profile
size, and independent of external metadata services. It is cosmetic: position
value continues to come from its assets, claims, and obligations rather than
artwork rarity.

## Decision

Every valid PositionNFT receives a deterministic SVG avatar. The base seed is:

```solidity
keccak256(
    abi.encodePacked(
        bytes32("STATICS_AVATAR_V1"),
        block.chainid,
        address(staticsDiamond),
        positionId
    )
)
```

Ownership, position state, active legs, balances, claims, and obligations do
not enter the seed. Transfer and ordinary position activity therefore do not
change the avatar.

The renderer is a stateless standalone implementation contract selected by one
address in PositionNFT storage. The Diamond owner may replace or clear that
address through `setPositionRenderer`. A renderer change may change metadata
for every PositionNFT. No token-level renderer versions or migration records
are stored.

To remain comfortably below EIP-170, the renderer delegates SVG assembly to one
stateless `StaticsAvatarSVG` helper fixed immutably in the renderer constructor.
The helper has no storage, authority, or independent protocol action surface.

`tokenURI` returns Base64 JSON containing a Base64 SVG under `image` and fixed
visual attributes. It returns an empty string while the renderer is unset.
The metadata contains no achievements, balances, yield, debt, health, status,
or other live protocol state.

## Visual system

The SVG uses a 256 by 256 integer-coordinate canvas, black and white geometry,
and one deterministic accent color. Layers render in this order:

1. Field
2. Telemetry
3. Mantle
4. Shell
5. Interface
6. Sigil
7. Boundary

Trait selection is unweighted. Each trait consumes two bytes from the seed at
offsets `0/1`, `3/4`, `6/7`, `9/10`, `12/13`, `15/16`, `18/19`, and `21/22`,
then applies modulo by its option count.

| Layer | Options |
| --- | --- |
| Field | Void, Grid, Target, Split Horizon, Static Field, Data Panel, Signal Bands, Vault |
| Boundary | Single Ring, Double Ring, Broken Ring, Reticle Ring, Peg Frame, Shield Ring |
| Shell | Round Shell, Angular Helm, Operator Hood, Hex Mask, Box Visor, Heavy Plate, Slim Mask, Split Head |
| Interface | Equal Sign, Narrow Visor, Dual Blocks, Glider, Double Pipe, Peg Bar, Dollar Glyph, Basket Grid |
| Mantle | Minimal Collar, High Collar, Hood Wrap, Armor Neck, Tactical Coat, Split Mantle |
| Telemetry | None, Bar Chart, Line Graph, Metric Blocks, Basket Indicators, Liquidity Panel, Yield Readout, Risk Readout |
| Sigil | Equal Seal, Dollar Core, Basket Core, Risk Share, Staking Sigil, Liquidity Mark, Position Key, Empty |
| Signal | Neon Green, Cyan, Amber, Red, Purple, White Only |

The Glider interface represents Conway's Game of Life glider as five circular
dots: three across the bottom, one at the right in the row above, and one at
the center in the next row above.

## Metadata format

The canonical response is:

```text
data:application/json;base64,<json>
```

The JSON contains:

- `name`: `Statics Position #<positionId>`;
- `description`: `A transferable position in the Statics Protocol.`;
- `image`: a `data:image/svg+xml;base64,...` URI; and
- visual `attributes` in Field, Boundary, Shell, Interface, Mantle,
  Telemetry, Sigil, and Signal order.

There are no external fonts, images, stylesheets, scripts, external asset URLs,
user strings, or arbitrary token metadata in the SVG or JSON. The standard SVG
namespace declaration is the only URL-shaped markup.

## Deployment and compatibility

Fresh deployments install the renderer during protocol initialization and
record its immutable SVG helper. The
PositionNFT remains the Statics Diamond and keeps standard ERC-721 metadata
support. The renderer is an implementation dependency rather than a second
user entrypoint.

The modular PositionNFT release is fresh-deployment-only. This work does not
restore a legacy upgrade ceremony or migrate the earlier testnet PositionNFT.
Wallet and marketplace indexing of nested data URIs remains best effort;
Statics and Eves are the primary rendering clients.

## Consequences

- PositionNFTs gain recognizable identities without per-token storage.
- Existing IDs in a compatible deployment render immediately after a renderer
  is configured.
- Governance can deliberately refresh or disable collection-wide artwork.
- Marketplace caches may retain an earlier renderer's metadata until refreshed.
- The browser avatar lab is design tooling only; Solidity is the canonical
  deployed renderer.
