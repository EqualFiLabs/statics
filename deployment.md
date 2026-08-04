# Statics — Robinhood Chain Testnet Deployment

This document records the current Statics deployment on Robinhood Chain
Testnet. It is a testnet release, not a production deployment.

## Release

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | `46630` |
| Explorer | <https://explorer.testnet.chain.robinhood.com> |
| STATICS token block | `96751264` |
| Oracle fixture blocks | `96751410`–`96751411` |
| Core deployment blocks | `96752884`–`96752890` |
| StaticsDiamond creation transaction | `0x051f4ba3a5485cac46c41ce9979faffce403a0c33a5f81f57da6cf824fa62ebf` |
| Genesis basket execution block | `96758350` |
| Genesis basket execution transaction | `0x050b4b90d7d37cb50368ae4d788cd6854700f5632e4cf3bc285f6c37bcfa799e` |
| Deployer | `0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316` |
| Source branch | `master` |
| Source commit | `71606762de01d63cd38261a88ae71a32e5f66aba` |

## Protocol contracts

| Contract | Address |
| --- | --- |
| StaticsDiamond / Position NFT | `0xfb3Baf22daCADE66f7CF0356aC2E342235af74bf` |
| StaticsDollarCoreDiamond | `0xB142E9c8f80Fe67a96c8B3e152BfB7fF546312CC` |
| Statics Dollar (`USDstx`) | `0x2bDE36A981353fb31a1237013e460Cac7AeAeA85` |
| Dollar risk shares | `0x3D17519DD5280eDE9aCB027563fAF9343C41969e` |
| Statics token (`STATICS`) | `0x210aa4E724C9173819054eec630D323d9De33494` |
| Statics Dollar oracle | `0xdfFDd9DbF8b5207D834Bea05af0C7C68008545f4` |
| Swap-fee hook | `0xD358C79d23BA23B773BF6b71bAC54d3bF07aD0cc` |
| Liquidity manager | `0xb1B6470A40E082C31BDe4499152890a2E58fd13b` |
| Position renderer | `0xa735dD169e7E13C638eB7544556a14f8c3DFD470` |
| Avatar SVG | `0x287188A08D9BF9421f5B089e95d40d2a2d649C31` |
| Statics faucet | `0x6B3d3886feDFedCD7D39a601349E88DA64D74B6f` |

## Governance

| Field | Current value |
| --- | --- |
| Timelock | `0x13aC9D28B149a57019EDa9fed48E5523b253699b` |
| Minimum delay | `120` seconds |
| StaticsDiamond owner | Timelock |
| StaticsDollarCoreDiamond owner | Timelock |
| Proposer | Deployer |
| Canceller | Deployer |
| Executor | Open (`address(0)`) |
| Timelock admin | Timelock itself |
| Guardian | Deployer |
| Treasury | Deployer |
| Basket creation fee | `0` |
| Position creation fee | `0.001 ETH` |

These values reproduce the previously active onchain governance policy and were
confirmed by live readback after deployment.

## Modular Position NFT interface

The StaticsDiamond advertises the planned modular Position NFT interface via
ERC-165.

| Field | Value |
| --- | --- |
| Interface ID | `0x212b8e93` |
| Live `supportsInterface` result | `true` |
| Position state nonce | Enabled |
| Position creation fee | `0.001 ETH` |

### Position owner-index upgrade — 2026-08-03

The StaticsDiamond was upgraded in place through its existing timelock. No
protocol, token, basket, pool, renderer, or application address changed.

| Field | Value |
| --- | --- |
| PositionNFTFacet | `0x1120d7282f852823b9e29e7e9d28Ca31B141E8DB` |
| Facet runtime code hash | `0x22f409552f822fff8bb17163617308ac1243ebe0f5e99eb24dbc1560edad5345` |
| Owner-index interface ID | `0x7ef5913d` |
| ERC-4906 interface ID | `0x49064906` |
| Timelock operation ID | `0xbcc7574e72ea63613749258e6527c8d71c056c1635a4eb841bca731baa16ca1d` |
| Timelock salt | `0x70f60cc324218784219c453a2963d4501de3441541c9e7e0e914844f4b040066` |
| Protocol source commit | `1c63511` |
| Upgrade ceremony commit | `b72a743` |

| Action | Block | Transaction |
| --- | ---: | --- |
| Deploy verified PositionNFTFacet | `96877243` | `0x92a57642a700a3ef81c7bfcdc67cab5b793466423c36549c0abd05aaf9117116` |
| Schedule governed diamond cut | `96877551` | `0xf6c4efe228107cd9ff54f4f962eec9e589ba60a021bdf25e1697a8b5d2d487d2` |
| Execute governed diamond cut | `96878117` | `0xbdcec23ec0dc29efa575328882dc0aff02ac16fea7c6cca6c924c4cfc16180d5` |
| Synchronize Position `1` | `96878343` | `0x57fb4700cabec46374c01893cc3c94e03bf8f92eea5d73394e598bc827ac6358` |
| Synchronize Position `2` | `96878343` | `0x4e75e7bcd3186d2f3934d644293a46d416e9eb6a6e3c4d843357ff99595bec11` |

Live readback confirmed all 28 Position selectors route to the verified facet,
both new interface IDs are advertised, and the timelock operation is complete.
Historical Positions `1` and `2` remain owned by
`0x81709E16Bf99936891Cc720689f269103fabeD91`, preserve their pre-upgrade
Position state, and are returned by the paginated owner index as `[1, 2]`.
Each synchronization emitted both `PositionOwnerIndexSynced` and ERC-4906
`MetadataUpdate`.

## Testnet collateral and oracle fixtures

| Contract | Address |
| --- | --- |
| Mock USDG | `0xBF85818cf213868c7aAE46d527b747e720B93054` |
| Mock USDG oracle | `0x75bCB3bf9DA6C70Fb9F4d9873Df7a22b24F07FfF` |
| ETH/USD feed | `0xA04cd33dfb1847D99f1157223e229B9636A8B275` |
| Sequencer uptime feed | `0x6cF7375Eb718a529820CBCC9FAD0E04397980B06` |

The active pegged profile is profile `2`: Mock USDG collateral, 6 decimals,
0.95–1.05 peg band, 5 bps mint fee, 7 bps redemption fee, and a
`1,000,000 USDstx` debt ceiling. The profile and liquidity integration were
installed through the new timelock and confirmed live.

## Genesis basket

The genesis basket is live immediately upon creation. There is no warmup,
checkpoint, or separate activation transaction.

| Field | Value |
| --- | --- |
| Basket ID | `0` |
| Name | Tesla-Palantir-AMD-1 |
| Symbol | `TPA1` |
| Basket token | `0xa52A77b8301dE7FE54F854177Cf4266F25cD24e2` |
| Live status | Active |
| TSLA | `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E` |
| PLTR | `0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0` |
| AMD | `0x71178BAc73cBeb415514eB542a8995b82669778d` |

| Canonical pool | Pool ID |
| --- | --- |
| TPA1 / TSLA | `0x6931379fe73c1348843274b62fb6d6c7fe8c65208edc2d9f47079c535b9b497f` |
| TPA1 / PLTR | `0x5f92e9b03ad71058018213473e07a6c084839e68618a2b8ec6011bb72dcf306a` |
| TPA1 / AMD | `0x1be46327fc89c4e7614343b6ab2b4c646976ba089e6f19f5c88ddb74f895c4c8` |

Each canonical pool was created with full-range protocol-owned liquidity and
is registered with the fresh hook and liquidity manager.

## Faucets

The Statics faucet was freshly deployed at block `96757014` in transaction
`0xa1928fdd53f7c70cb2f45e02078c8b1a100e590691d69cee434b30cbe08fafc6`.
Its live inventory at deployment completion was:

| Asset | Inventory |
| --- | ---: |
| Mock USDG | `1,000,000` |
| STATICS | `1,000,000` |
| TSLA | `10` |
| PLTR | `10` |
| AMD | `10` |

## Reused chain dependencies

| Contract | Address |
| --- | --- |
| WETH | `0x33e4191705c386532ba27cBF171Db86919200B94` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 PositionManager | `0x58DaEC3116AAe6D93017BaaEA7749052E8a04fa7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

The chain-owned WETH and Uniswap v4 infrastructure were reused after live
runtime-code checks. All release-coupled Statics contracts, tokens, oracle
fixtures, the genesis basket token, and the faucet were freshly deployed.

## Validation and verification

- The focused deployment suite passed: 25 tests, 0 failures.
- The Robinhood deployment fork check passed: 1 test, 0 failures.
- All 49 receipts in the three base deployment broadcast artifacts succeeded.
- The governance ceremonies, genesis launch, faucet deployment, and faucet
  funding transactions succeeded and their resulting state was confirmed live.
- Blockscout source verification was confirmed for all 51 freshly deployed
  contracts, including the TPA1 basket token and Statics faucet.
- Broadcast artifacts remain local and intentionally ignored because they may
  contain operational metadata. No RPC credentials or signing material belong
  in this document.

Published source: <https://github.com/EqualFiLabs/statics>
