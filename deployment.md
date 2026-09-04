# Statics — Robinhood Chain Testnet Deployment

The newest full-stack rehearsal is recorded first. The earlier public testnet
release remains documented below so existing integrations retain a stable
reference while rehearsal deployments are discarded and repeated.

## Full-stack rehearsal — September 2, 2026

This rehearsal deployed a fresh Statics and USDstx stack from merged `master`,
attached the existing mainnet-faithful Genesis replica, launched a fresh TPA1
basket with the same pool geometry, and configured two isolated markets on the
shared Robinhood testnet Morpho deployment.

| Contract | Address |
| --- | --- |
| StaticsDiamond / Position NFT | `0xA37016d1d5daA516c2E9cE32d335048D11FeA395` |
| StaticsDollarCoreDiamond | `0x800dd1E86595575Cd0938a08ceF51244Db39eceB` |
| Statics Dollar (`USDstx`) | `0x1d86aA03bC74eE3582Cc23e0818f3c2f8f533491` |
| Dollar risk shares | `0x054Ce0D82A7178a0Cf4b63901B98c91337419973` |
| Governance timelock | `0x6E34079786d6C6B53814070544f9aC77d6b36518` |
| Swap-fee hook | `0x8afD614Eb367Ed71d19568511C141847bbBc10EC` |
| Liquidity manager | `0x5BbBC16824a84192781aE26B88C61a058A73f10e` |
| TPA1 basket | `0xf6aC2b2B59133f3691C63e99Cb7b3ac507F7528B` |
| Genesis replica | `0x6c9197347161FC140a209175849d443FeaAF509c` |
| Public rehearsal faucet | `0xb80f88145315a772829B42c0Efb6F79ee8A55645` |

The public rehearsal faucet was deployed as the separate final ceremony step,
so this disposable shot binds and funds only its own fresh token addresses. It
contains 100 daily claim bundles. Each bundle provides `5,000 USDG`, `5,000
USDstx`, `1,000 STATICS`, and `0.001` each of TSLA, PLTR, and AMD. Deployment,
mint, release, and funding transactions are recorded in the machine-readable
rehearsal record below.

| Morpho market | Market ID |
| --- | --- |
| Staked STATICS / USDstx | `0xe33389dd66e032400d80cc014ef2364a74e0f75d0bbce938d27155d62680227b` |
| TPA1 / USDstx | `0xb9e6cd50636f45bd8b73a15b0b15168bcc44b3b1b5a42c2e23d997bdc0651040` |

Both markets use the shared Morpho Blue and AdaptiveCurveIRM deployment, a 77%
LLTV, disposable owner-adjustable testnet oracles initialized to `1e36`, and
`100,000 USDstx` of supplied liquidity. The Morpho performance-fee router is
intentionally unset because the lender reward router remains out of scope.

Live readback confirmed timelock ownership, all 34 Diamond facets and 283
selectors, the active pegged profile, all three initialized and permanently
locked TPA1 pools, both active Morpho registrations, and the completed Genesis
fee-distributor, activation-consumer, and irreversible protocol handoff. The
handoff completed in transaction
`0xc9a9ca3f1c5e90cf9e4b6d483c1f402bd279e4e54319911141a73a241d495eb9`.

The complete machine-readable record, including runtime hashes, governance
operation IDs, transaction hashes, pool IDs, and validation results, is
[`deployments/robinhood-testnet-46630-rehearsal-20260903T033729Z.json`](deployments/robinhood-testnet-46630-rehearsal-20260903T033729Z.json).

## Previous public release

## Release

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | `46630` |
| Explorer | <https://explorer.testnet.chain.robinhood.com> |
| Release start block | `97382446` |
| Protocol deployment start block | `97383161` |
| Genesis basket execution block | `97392218` |
| Governed protocol pools upgrade block | `97967966` |
| Deployer | `0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316` |
| Initial source branch | `feat/position-portfolio` |
| Initial runtime source commit | `724df0fe80be8e376a5cb61811d02e1ef7413707` |
| Deployment tooling commit | `9baa3a87bf120fdd02340359a2594590394181a8` |
| Current source branch | `master` |
| Current protocol commit | `aeed216abe9d8d08d589b5a66aba637f9a04822b` |
| Statics SDK commit | `135b68b8c404a1f567ae834c2e46e517e5788e28` |

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
| Liquidity manager | `0x9E8B33ff86e36fe64ba2f1504fF53bE586F4183A` |
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

## Governed protocol pools upgrade

The existing StaticsDiamond was upgraded in place through its governance
timelock. The Diamond, Dollar contracts, hook, PoolManager, and existing pool
IDs did not change. Integrators continue to use the same StaticsDiamond address.

| Field | Value |
| --- | --- |
| ERC-165 interface ID | `0xa076af5a` |
| BasketLiquidityFacet | `0x8d9F1307c4659Bd49372c50F26455cc9B561d935` |
| BorrowLiquidityFacet | `0xa2a4C8214af55Fd3f0eB9ecf393E6D18a33789Ab` |
| LiquidityRewardsFacet | `0x9F7eB83b08a40a9Fb8474E2C81C37922F0810779` |
| ProtocolPoolFacet | `0x117FBbb83daF7c20fCd4f05a7D17DCfA1b354b0C` |
| Previous liquidity manager | `0xbE5A795ae0754D8D36F6EdFD546e55f5E60d6455` |
| Current liquidity manager | `0x9E8B33ff86e36fe64ba2f1504fF53bE586F4183A` |
| Timelock operation | `0xfc6796b6a905c0d756dcd1600d26f03f43fbcb1e6fa0ecfa83e5f8947dadc3fb` |
| Schedule transaction | `0xfe15fa5aa9be31fd0351e38ed29e131baf12480ecd3a39637c774e0487548b54` |
| Execute transaction | `0xddaba73eb230742db2be8ab8712c0975e5eb24d15b2ab574bf46ff5af2063220` |

Live post-upgrade readback confirmed the new selector routes and ERC-165
interface, revoked the old manager's PositionManager approval, and approved the
new manager. The TSLA, PLTR, and AMD canonical pool definitions, fee settings,
and locked-liquidity values exactly matched their pre-upgrade snapshots. No
governance proof pool was created during deployment.

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

## Reusable Morpho Blue infrastructure

The shared lending base for repeatable Statics rehearsals was deployed on
September 1, 2026. Future Basket/USDstx attempts reuse these contracts while
creating isolated markets for each rehearsal. This deployment intentionally
does not create an oracle or a Morpho market.

| Field | Value |
| --- | --- |
| Morpho Blue | `0xC0dd6aB9E1e59F9dF696cc90Ba947B4E6C74E6A9` |
| AdaptiveCurveIRM | `0x6e8555DAbbAe94aDfA5b606E3eaF35246E346332` |
| Owner | `0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316` |
| Fee recipient | `0x0000000000000000000000000000000000000000` |
| Deployment blocks | `111138899`–`111138919` |
| Deployment source commit | `f5f8939d75f0cd426213e605b8e8e9f1a7ed52fa` |

The AdaptiveCurveIRM and zero-address IRM are enabled. The enabled LLTV set is
`0`, `38.5%`, `62.5%`, `77%`, `86%`, `91.5%`, `94.5%`, `96.5%`, and `98%`,
matching the Robinhood mainnet Morpho configuration inspected for this replica.
Both contracts are source verified, and live readback confirmed the owner,
fee recipient, IRM binding, runtime hashes, and every enabled LLTV.

The machine-readable companion record is
[`deployments/robinhood-testnet-46630-morpho.json`](deployments/robinhood-testnet-46630-morpho.json).

The broader Statics deployment remains recorded in
[`deployments/robinhood-testnet-46630-statics.json`](deployments/robinhood-testnet-46630-statics.json).
