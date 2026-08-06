# Statics — Robinhood Chain Testnet Deployment

This is the current Statics testnet release. It replaces all previous Robinhood
testnet deployments.

## Release

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | `46630` |
| Explorer | <https://explorer.testnet.chain.robinhood.com> |
| Release start block | `97382446` |
| Protocol deployment start block | `97383161` |
| Genesis basket execution block | `97392218` |
| Deployer | `0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316` |
| Source branch | `feat/position-portfolio` |
| Runtime source commit | `724df0fe80be8e376a5cb61811d02e1ef7413707` |
| Deployment tooling commit | `9baa3a87bf120fdd02340359a2594590394181a8` |

## Protocol contracts

| Contract | Address |
| --- | --- |
| StaticsDiamond / Position NFT | `0x2340741Ec94dF12678312f564eBc2c776d8FaA6a` |
| StaticsDollarCoreDiamond | `0x6AB8009073e0e6E0b0458e39E3b547DA31b5724f` |
| Statics Dollar (`USDstx`) | `0xd1F2DC3Ed9b70a85B6629C04afCEdb43B2Ca25ce` |
| Dollar risk shares | `0x5E316e8961C9C5ef4bbd6dc0573dc3cf232eEd6c` |
| Statics token (`STATICS`) | `0xF46cC8F00C24bb622ECe0f771Cc4B53b40722d81` |
| Statics Dollar oracle | `0x69a88C213eda8db22373Fd9C113bB988231652e2` |
| Swap-fee hook | `0x9718C37742F6650BdD7147e0e4854f5bb0Bd90Cc` |
| Liquidity manager | `0xbE5A795ae0754D8D36F6EdFD546e55f5E60d6455` |
| Position renderer | `0x6da774A3B27B267D1926fEf7FFeB71cC80a6700C` |
| Avatar SVG | `0x4D5513E2e4B0A0f547E850420437D841CFF6Ca8C` |
| Statics faucet | `0xDc74E592efbe3CE5A86785E89E50b53Fe0F8F04E` |

## Governance

| Field | Current value |
| --- | --- |
| Timelock | `0xd6DCf8aDE20bA8874f5c9A79870e6456B301dc29` |
| Minimum delay | `120` seconds |
| StaticsDiamond owner | Timelock |
| StaticsDollarCoreDiamond owner | Timelock |
| Proposer and canceller | Deployer |
| Executor | Open (`address(0)`) |
| Guardian and treasury | Deployer |
| Basket creation fee | `0` |
| Position creation fee | `0.001 ETH` |

These values preserve the governance policy that was active immediately before
the redeployment and were confirmed by live readback.

## Position NFT interfaces

The StaticsDiamond advertises both interfaces through ERC-165.

| Interface | ID | Live result |
| --- | --- | --- |
| Minimal modular Position NFT | `0x212b8e93` | Supported |
| Statics position portfolio enumeration | `0xcc04fb90` | Supported |

Portfolio pages are limited to 100 entries. A client should read all pages at
one block because ordering may change when attached protocol state changes.

## USDG profile and testnet fixtures

| Contract | Address |
| --- | --- |
| Mock USDG | `0x3c9dCe3FD17f3FC8A1929B1614b2c99124129Da1` |
| Mock USDG oracle | `0x2da7445953d5f3E3128B967c476DF38F1783Fa38` |
| ETH/USD feed | `0xc13527fc5b442E18844476E9a01e483F56962a4e` |
| Sequencer uptime feed | `0xA9c1d13D7714ea511b1607F5f20fC6B3393eA5B6` |

Profile `2` is active with 6-decimal Mock USDG collateral, a 0.95–1.05 peg
band, 5 bps mint fee, 7 bps redemption fee, and a `1,000,000 USDstx` debt
ceiling.

## Genesis basket

The basket and its canonical full-range pools were live immediately when the
timelock executed creation. There is no warmup or separate activation.

| Field | Value |
| --- | --- |
| Basket ID | `0` |
| Name | Tesla-Palantir-AMD-1 |
| Symbol | `TPA1` |
| Basket token | `0x8Dce6B4AC21769e437F414EA6dDacb407C5b4F83` |
| Creator | Governance timelock |
| Execution transaction | `0x6dea9be534f3562079a0ae1d0abf64d0a3586e5cb46e6d45c05697cd48696589` |

| Canonical pool | Pool ID |
| --- | --- |
| TPA1 / TSLA | `0xa046b35fa1fa5de399b403d5dc0f8d1ac836304af6ba84b2097ea3003002f395` |
| TPA1 / PLTR | `0x78c00dcabb24279078b94ac61676a46c295f0385ffebd6c169fc833a51e77846` |
| TPA1 / AMD | `0x506945b7cae6b7c5e9a260c1613dac4dd7a39d235af5e10747079aa3ae086308` |

## Faucet

The faucet is funded with 100 complete claim bundles:

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
| Quoter | `0x8dc178eFb8111Bb0973Dd9d722eBefF267c98F94` |
| StateView | `0xF3334192D15450cdD385c8B70E03f9a6Bd9E673B` |
| Universal Router | `0x8876789976DecbFCbBbe364623C63652db8c0904` |

All reused dependencies passed live runtime-code checks. All fresh Statics
contracts, fixtures, the basket token, and the faucet are source verified.
Broadcast artifacts and signing configuration remain local and ignored.

The machine-readable companion record is
[`deployments/robinhood-testnet-46630-statics.json`](deployments/robinhood-testnet-46630-statics.json).
