# ADR: PositionNFT branded onchain metadata

- Status: Accepted
- Date: 2026-08-16
- Scope: Statics PositionNFT metadata and visual identity

## Context

The Statics Diamond is the ERC-721 PositionNFT contract. A PositionNFT carries
protocol assets, claims, rights, and liabilities, but it is a financial account
rather than the protocol's scarce collectible. Wallets still need a recognizable
image for the account instead of a blank marketplace placeholder.

The earlier deterministic avatar system now belongs exclusively to Genesis
NFTs. PositionNFT artwork should communicate the Statics brand and token
identity without duplicating live financial information that belongs in the
application.

## Decision

Every valid PositionNFT returns self-contained Base64 JSON with a Base64 SVG
image. The SVG contains only the Statics logo and `POSITION #<positionId>`.

The artwork is assembled directly by an internal pure Solidity library used by
the PositionNFT facet. There is no renderer address, separate renderer
deployment, mutable artwork setting, token-level metadata storage, or metadata
update transaction.

Ownership, active legs, balances, claims, rewards, debt, health, and other
position state do not enter the image. Metadata therefore remains stable across
transfers and ordinary protocol activity.

## Visual and metadata format

The 256 by 256 SVG uses the approved Statics identity:

- an off-white frame and black field;
- the geometric white Statics mark;
- the `#82CA17` green terminal square; and
- a centered `POSITION #<positionId>` label.

The JSON contains:

- `name`: `Statics Position #<positionId>`;
- `description`: `A transferable financial account containing its Statics protocol assets and liabilities.`; and
- `image`: a `data:image/svg+xml;base64,...` URI.

The SVG and JSON contain no external images, asset URLs, scripts, stylesheets,
imports, user-controlled strings, live financial attributes, or external font
dependencies. The standard SVG namespace declaration is the only URL-shaped
markup.

## Consequences

- Wallets and marketplaces receive a recognizable image for every PositionNFT.
- Position identity stays legible without competing with Genesis artwork.
- Transfers and financial state changes do not create metadata refresh work.
- Updating the artwork requires an ordinary Diamond facet upgrade rather than a
  separate renderer administration surface.
- The Solidity SVG implementation is the canonical deployed artwork; local
  vector previews are review tooling only.
