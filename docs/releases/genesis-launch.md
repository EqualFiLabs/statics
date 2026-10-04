# Genesis Launch — Robinhood Chain Mainnet

The standalone Statics Genesis release launched on August 27, 2026. It established
the fixed-supply STATICS token, a permanent STATICS/WETH Doppler Multicurve market,
the 5,555 Statics Operators NFTs and their backing vault, activation tracking,
launch rewards, fee ingress, and treasury vesting.

This retrospective records the original deployment and its source provenance.
Its documentation date is October 4, 2026; it does not represent a new deployment,
an upgrade, or a change to the launch configuration. All timestamps below are UTC.

| Field | Record |
| --- | --- |
| Network | Robinhood Chain Mainnet |
| Chain ID | `4663` |
| Preparation began | August 27, 2026, `19:22:37 UTC`, block `47688979` |
| Market launched | August 27, 2026, `19:24:28 UTC`, block `47690074` |
| Finalization completed | August 27, 2026, `19:25:22 UTC`, block `47690599` |
| Recorded launch source | [`43018f109006aa2c2eef2808adc2aa74dfc9a6d4`](https://github.com/EqualFiLabs/statics/commit/43018f109006aa2c2eef2808adc2aa74dfc9a6d4) |
| Original deployment manifest | [`97ef0056e8c61d32a0ef4d05c5d74fd50a61d9bf`](https://github.com/EqualFiLabs/statics/blob/97ef0056e8c61d32a0ef4d05c5d74fd50a61d9bf/deployments/robinhood-mainnet-genesis.json) |

## Released capabilities

- A fixed supply of 1 billion STATICS, with 800 million assigned to the public
  Doppler launch inventory and 200 million assigned to protocol bootstrap and
  treasury vesting.
- A permanent, six-curve STATICS/WETH market created through the deployed Doppler
  Airlock. The canonical market is PoolManager state, rather than a separately
  deployed pool contract.
- The 5,555 Statics Operators collection, onchain artwork and metadata, activation
  tracking, and a standalone vault with a fixed 180,000-STATICS backing amount per
  circulating Operator.
- Public acquisition and redemption through the vault, an accumulating native ETH
  reserve, and the immutable Genesis Epoch ending September 11, 2026, at
  `11:59:00 UTC`.
- Pull-based launch rewards and treasury accounting, with permanent fee ingress
  kept separate from the temporary launch distributor.
- Post-epoch Genesis secured credit backed by an Operator's STATICS, with
  repayment, extension, and recovery paths.
- Treasury STATICS and treasury Operator vesting, each over 60 days. The token
  implements STATICS vesting; `StaticsTreasuryVesting` implements the Operator
  release and bootstrap backing commitment.

The release is independent of `StaticsDiamond`. It does not deploy PositionNFT,
baskets, the phased protocol DEX and staking surface, basket credit or flash loans,
Statics Dollar, or Morpho. The existing Genesis contracts expose handoff surfaces
for later integration; a later binding or activation is a separate governed event.

## Original supply allocation

| Allocation | Amount | Original destination |
| --- | ---: | --- |
| Public launch inventory | 800,000,000 STATICS | Doppler Multicurve market |
| Treasury Operator backing | 99,900,000 STATICS | Genesis Vault, backing 555 treasury Operators |
| Treasury token vesting | 100,100,000 STATICS | Native Doppler token vesting schedule |
| **Total** | **1,000,000,000 STATICS** | |

At finalization, Operator IDs `1` through `5000` were vault inventory and IDs
`5001` through `5555` were assigned to treasury vesting. Acquiring a vault-owned
Operator supplies its required STATICS backing. The 99.9-million bootstrap backing
therefore describes the treasury Operators, rather than prefunding all 5,555 NFTs.
Treasury Operator releases are capped at 50 NFTs per call.

These are original allocation and lifecycle facts. They do not describe current
balances, circulating inventory, outstanding rewards, or how much vesting has
subsequently been claimed.

## Contract inventory

The deployment contains eight Statics-owned standalone contracts and a STATICS
token created by the existing Doppler token factory. Addresses and expected
runtime hashes are recorded in the original manifest; explorer links provide
the corresponding public contract pages.

| Contract | Address | Deployment block |
| --- | --- | ---: |
| STATICS token | [`0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd`](https://robinhoodchain.blockscout.com/address/0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd) | 47690074 |
| Statics Operators (`StaticsGenesis`) | [`0xad5E9F96A91D1A6F550580b157af2068A0e8F0BE`](https://robinhoodchain.blockscout.com/address/0xad5E9F96A91D1A6F550580b157af2068A0e8F0BE) | 47690440 |
| `StaticsGenesisVault` | [`0x8AAAF9a22f439589987B8f1e69d79ca4f648C297`](https://robinhoodchain.blockscout.com/address/0x8AAAF9a22f439589987B8f1e69d79ca4f648C297) | 47690390 |
| `GenesisActivationRegistry` | [`0xfC62e99CaE93878f83801f3d6Bb4f1762E720B30`](https://robinhoodchain.blockscout.com/address/0xfC62e99CaE93878f83801f3d6Bb4f1762E720B30) | 47690385 |
| `StaticsFeeReceiver` | [`0x4aa7237527A120c5aFD8Eb89718b57DaB3EDb6cc`](https://robinhoodchain.blockscout.com/address/0x4aa7237527A120c5aFD8Eb89718b57DaB3EDb6cc) | 47688979 |
| `GenesisLaunchDistributor` | [`0xB6583f04e8C606e9F07E39e754Aba77B250Dc3FD`](https://robinhoodchain.blockscout.com/address/0xB6583f04e8C606e9F07E39e754Aba77B250Dc3FD) | 47690515 |
| `StaticsTreasuryVesting` | [`0xBcf0e357c359858aB166aEBb74f0E527aAb3d6ee`](https://robinhoodchain.blockscout.com/address/0xBcf0e357c359858aB166aEBb74f0E527aAb3d6ee) | 47688982 |
| `StaticsGenesisRenderer` | [`0xBbF960f837166ab687FA5d69b605c2E70a83a017`](https://robinhoodchain.blockscout.com/address/0xBbF960f837166ab687FA5d69b605c2E70a83a017) | 47690417 |
| `StaticsAvatarSVG` | [`0x39601dFDDad3aa66303E231b0445Cd4Cb2D60204`](https://robinhoodchain.blockscout.com/address/0x39601dFDDad3aa66303E231b0445Cd4Cb2D60204) | 47690395 |

The original configured governance Safe was
`0x603A8A2f22ac1d61E9c932A4F6Fa23170CEcb9Ff`. The treasury was the separate address
`0x0Ce4140f3Ab03024623a75F248D467912C7E1725`.
The manifest's pending ownership-acceptance fields record the initial
post-finalization handoff snapshot. They are not a current ownership report or
an outstanding-release-blocker claim.

## Canonical market and launch settings

| Setting | Original value |
| --- | --- |
| Pair | STATICS / WETH |
| Pool ID | `0xe79228d6cae086a58bf5b22220b454e5d1ca4f13da767ea5bbe032d5a1e82e8a` |
| PoolKey currency0 | WETH, `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| PoolKey currency1 | STATICS, `0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd` |
| PoolKey hook / Doppler initializer | `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` |
| Doppler LP fee | `15000` pips, or 1.5% |
| Tick spacing | `100` |
| Curve count | Six |
| Launch-position fee beneficiaries | 5% Doppler/Airlock owner; 95% Statics fee ingress |
| WETH ingress reserve allocation | 5%, before the remaining WETH reaches the distributor |
| Launch distributor allocation | 40% Genesis rewards; 60% treasury |
| Genesis credit maximum principal | 171,000 STATICS per Operator |
| Genesis credit term / recovery grace | 30 days / one hour |
| Genesis credit origination or draw fee | 0.02 native ETH |
| Genesis credit extension fee | 0.008 native ETH |
| Initial credit-service allocation | 10% reserve; 90% treasury |
| Recovery caller share | 20% of the fixed 9,000-STATICS recovery residual |

The fee allocations operate at separate stages; the percentages are not all
shares of gross trading fees. These settings describe the original release.
Governed parameters and later handoffs require a separately dated observation.
Launch valuation models are WETH-denominated design references and do not promise
a USD price, future trading volume, or future reserve value.

## Deployment ceremony and commitments

1. **Prepare:** deploy the permanent fee receiver and treasury bootstrap/vesting
   contract. The original receipts are recorded at blocks `47688979` and `47688982`.
2. **Launch:** create the token and market in the canonical Airlock transaction,
   [`0x4ab656be8c63583735636694b029b43b052a01b3169e674c94adc5ec542ebd8e`](https://robinhoodchain.blockscout.com/tx/0x4ab656be8c63583735636694b029b43b052a01b3169e674c94adc5ec542ebd8e).
3. **Finalize:** install and bind the standalone Genesis contracts, establish the
   treasury Operator backing, activate launch rewards, and propose the governance
   handoffs. The original manifest lists all 20 finalization receipts and actions.

| Commitment | Recorded hash |
| --- | --- |
| Approved launch configuration | `0xa56443c159762b4470695ee98bd1681fb38202129dbcf474cbffae936b82ce22` |
| Launch artifact | `0x62b18ac6f391ffc9f0bae7c17309994db5b918e2c7c02f64c6a2e4a3ce92e10b` |
| Airlock create calldata | `0x6b7ace963970bac4d7b38460af84b0fcd9152a850a3f558970f445725622df62` |

## Source and build provenance

The manifest identifies `43018f1` as the launch source commit. That commit ratifies
the configuration hash above. The original Genesis sources, launch script,
Foundry configuration, remappings, and root dependency pins are unchanged between
that commit and `97ef0056`, which added the deployment manifest after launch.
Later master revisions are not substituted for the recorded launch source.

The [launch-time Foundry configuration](https://github.com/EqualFiLabs/statics/blob/43018f109006aa2c2eef2808adc2aa74dfc9a6d4/foundry.toml)
uses Cancun, optimizer enabled with 200 runs, and `bytecode_hash = "none"`.
Statics-owned launch sources pin Solidity `0.8.33` and use the default profile
without global IR. Third-party compiler restrictions are recorded separately in
that configuration.

| Dependency | Recorded revision |
| --- | --- |
| OpenZeppelin Contracts | `5fd1781b1454fd1ef8e722282f86f9293cacf256` |
| OpenZeppelin Contracts Upgradeable | `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf` |
| Uniswap v4 periphery | `3779387e5d296f39df543d23524b050f89a62917` |
| Forge Standard Library | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| Doppler source revision committed by the launcher | `86a5200456b148c156d2eb81a893747dd601c3ca` |

The existing Airlock, Doppler modules, WETH, and Uniswap v4 contracts are external
dependencies. Their addresses and expected runtime hashes are recorded in the
original manifest. The STATICS token is factory-created; its deployed runtime
hash is checked separately from the eight Statics-owned standalone contracts.

## Retrospective verification

The October 4, 2026 check used read-only Robinhood Mainnet RPC calls and the
finalized checkpoint at block `79944745`, hash
`0xedcc496deea4801439fbfe7ceac67a16f30fa72cc497205df2905c4c3f060f61`,
with block timestamp `2026-10-04T12:44:48Z`.
The [machine-readable evidence](./genesis-launch-verification.json) records
the exact checkpoint, expected and observed runtime hashes, original receipts,
and verification limits.

| Check | Result | Evidence boundary |
| --- | --- | --- |
| Network identity | Chain ID `4663` | Configured private RPC |
| Contract runtime inventory | 9 of 9 hashes match | Deployed code at the finalized checkpoint versus the original manifest |
| Original ceremony transactions | 23 of 23 match and succeed | Canonical receipts, recorded blocks, and inclusion before the checkpoint |
| Preparation, launch and finalization timestamps | Match the original manifest | Original transaction block timestamps |
| Genesis source/build provenance | No delta in the checked paths | Recorded launch source versus original manifest commit |
| Airlock launch calldata | Hash matches the original manifest | Original transaction input, recipient, deployer, and zero native value |

Runtime-to-manifest comparison does not independently reproduce compilation.
Successful receipts do not establish every semantic postcondition of the
ceremony. The artifact hash above is a recorded commitment; the original offchain launch
artifact was not independently reconstructed by this check.
Current ownership, balances, configuration, and later integrations were not
queried. No new contract tests, fork rehearsals, formal proofs, or independent
security audit were executed for this documentation change.

## Integration reference

Use the recorded contract addresses and launch source when integrating the
standalone Genesis system. Event indexing starts at the deployment blocks listed
above; STATICS market activity starts at block `47690074`. A phased Diamond release
has its own contracts, selectors, configuration, review, and deployment record.

The original manifest also contains provisioning and handoff fields captured at
launch. Its historical RPC provisioning entries are not integration endpoint
recommendations. Operational state should be documented with its observation
block and date, without rewriting this original release snapshot.
