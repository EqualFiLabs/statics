# Robinhood Testnet Flash-Arbitrage Trial

## Summary

On 2026-07-31, the production `StaticsFlashArbitrageReceiver` was deployed to
Robinhood Chain Testnet and used to execute a live TPA1 mint-and-sell flash
arbitrage. The transaction flash-borrowed the three TPA1 constituents, minted
127 TPA1 through the ordinary fee-paying basket entrypoint, sold the complete
mint across the three canonical Uniswap v4 pools, repaid principal plus flash
fees, and returned a net profit in every constituent to the caller.

The trial succeeded at the EVM level. The receiver was subsequently source
verified through Robinhood Explorer's Blockscout verification API. The
canonical machine-readable record is
[`deployments/robinhood-testnet-46630-statics.json`](../deployments/robinhood-testnet-46630-statics.json).

## Network and contracts

| Item | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | `46630` |
| Broadcaster and arbitrage caller | `0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316` |
| StaticsDiamond | `0x69Af9C58e9E283032AE0087c38EF5E27c28E8345` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| StaticsSwapFeeHook | `0x9c683B8253578be82D741b592dc10a0c637CD0cc` |
| TPA1 BasketToken | `0xe930ab200Aa592CCcFA003625a0C6784F95B923b` |
| Flash-arbitrage receiver | `0xB522ACFADA7041Cc77A74BEB6Cce23A81b1cac47` |
| Receiver source commit | `a3ea5c9fae032c05b3e604b6e3e6321f2063990d` |
| Receiver runtime code hash | `0xf6ad83ff194a30511b9577351048832ce677fd8f5d860506cbbb5fc378923647` |
| Receiver runtime size | 10,620 bytes |

The deployed receiver's immutable getters return the StaticsDiamond and
PoolManager addresses shown above.

## Transactions

Every transaction below returned receipt status `0x1` through the Robinhood
testnet RPC.

| Action | Block | Gas used | Transaction |
| --- | ---: | ---: | --- |
| Deploy and bind receiver | 95,722,546 | 2,570,436 | [`0xa27e…ea0f`](https://explorer.testnet.chain.robinhood.com/tx/0xa27e339796e88a4f125723c85c25b94744b9bf578ef27a8f38acff026b42ea0f) |
| Approve `0.00001` TSLA top-up | 95,722,639 | 65,982 | [`0xe35d…8f12`](https://explorer.testnet.chain.robinhood.com/tx/0xe35d52b618cbd7995db182ccbe0cf144f3cfade4436ffef21347a1e73b238f12) |
| Approve `0.00001` PLTR top-up | 95,722,650 | 65,982 | [`0xd377…8c1f`](https://explorer.testnet.chain.robinhood.com/tx/0xd377e5eb3971864e0d4145805c9ccc0ef241a89caa83c0b6a33fc8f48e2c8c1f) |
| Approve `0.00001` AMD top-up | 95,722,656 | 65,982 | [`0xdf35…3d5c`](https://explorer.testnet.chain.robinhood.com/tx/0xdf35a2f2425d1d5acbcf5c77f779caded2a43bd081c89bed67b90ce69e323d5c) |
| Execute flash arbitrage | 95,722,748 | 2,654,959 | [`0xeb0f…7e74`](https://explorer.testnet.chain.robinhood.com/tx/0xeb0f727ee7a9174676f2fa5e4a4ac7083f72e42a5f7f52732f5c4da4b397e74c) |

All five transactions used an effective gas price of `10,000,000` wei. Total
gas cost across deployment, approvals, and execution was
`0.00005423341 ETH`.

## Executed route

The route used basket ID `0` and `127 TPA1` shares.

| Asset | Flash principal | Flash fee | Mint top-up | TPA1 sold into pool | Minimum net profit |
| --- | ---: | ---: | ---: | ---: | ---: |
| TSLA | 1.27 | 0.000635 | 0.00001 | 53.164 | 1 wei |
| PLTR | 1.27 | 0.000635 | 0.00001 | 4.136 | 10 PLTR |
| AMD | 1.27 | 0.000635 | 0.00001 | 69.700 | 1 wei |

The three TPA1 allocations sum exactly to the 127 TPA1 minted during the
callback. Each swap used the corresponding canonical BasketToken/constituent
pool registered by StaticsDiamond. The receiver had no arbitrary-call or
noncanonical venue path.

## Realized results

The transaction returned these profits to the caller after mint top-ups,
basket fees, hook fees, price impact, and flash fees, but before gas:

| Asset | Raw amount | Token amount |
| --- | ---: | ---: |
| TSLA | `2806215038604` | 0.000002806215038604 TSLA |
| PLTR | `11131181260416289175` | 11.131181260416289175 PLTR |
| AMD | `1996653216588` | 0.000001996653216588 AMD |

The distorted TPA1/PLTR pool moved in the corrective direction:

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| PLTR pool tick | -12,947 | -9,218 | +3,729 |
| PLTR basket vault | 21.446625000000000004 | 22.716625000000000004 | +1.27 PLTR |
| Locked PLTR-pool liquidity | `38355807710592508336` | `38369565834962461723` | `+13758124369953387` |

The vault increase is expected: repayment restores the flash principal while
the ordinary mint permanently adds the newly minted TPA1's constituent backing.
The hook also compounded additional permanent liquidity from the swap fees.

## Post-execution cleanup

After execution:

- the receiver held zero TPA1, TSLA, PLTR, and AMD;
- caller-to-receiver allowances for all three top-ups were zero;
- receiver-to-StaticsDiamond repayment allowances were zero; and
- the event-reported profits exactly matched the caller's measured balance
  increases.

These checks demonstrate that the receiver did not retain route inventory or
leave reusable approval authority behind.

## Source verification

Robinhood Explorer reports the receiver as `StaticsFlashArbitrageReceiver`
with:

- Solidity `0.8.33`;
- Cancun EVM target;
- optimizer enabled with 200 runs; and
- source verification status `Pass - Verified`.

Receiver page:
[`0xB522…ac47`](https://explorer.testnet.chain.robinhood.com/address/0xb522acfada7041cc77a74beb6cce23a81b1cac47)

## Explorer indexing note

Immediately after the trial, Robinhood Explorer displayed errors on the
transaction pages even though the RPC receipts succeeded. This was an explorer
indexing delay, not an EVM revert.

At the follow-up check:

- the RPC head was block 95,726,491;
- the explorer's latest indexed block was 95,720,925;
- the receiver deployment was at block 95,722,546; and
- the flash execution was at block 95,722,748.

The explorer transaction API therefore returned `Transaction not found` for
all five transactions because it had not reached their blocks. At the same
time, its separately updated smart-contract API reported the receiver as a
contract with `creation_status: success` and verified source. Until transaction
indexing catches up, an explorer-page error must not be interpreted as a failed
creation transaction.

The authoritative deployment evidence is the chain receipt, which contains
status `0x1` and the receiver address, together with the nonempty runtime
bytecode at that address. The later successful flash transaction provides an
additional functional proof that the receiver exists and executes correctly.

## Independent RPC checks

With `ROBINHOOD_TESTNET` configured locally, the deployment can be checked
without trusting the explorer UI:

```bash
cast receipt \
  0xa27e339796e88a4f125723c85c25b94744b9bf578ef27a8f38acff026b42ea0f \
  --rpc-url "$ROBINHOOD_TESTNET"

cast code \
  0xB522ACFADA7041Cc77A74BEB6Cce23A81b1cac47 \
  --rpc-url "$ROBINHOOD_TESTNET"

cast call \
  0xB522ACFADA7041Cc77A74BEB6Cce23A81b1cac47 \
  'staticsDiamond()(address)' \
  --rpc-url "$ROBINHOOD_TESTNET"

cast receipt \
  0xeb0f727ee7a9174676f2fa5e4a4ac7083f72e42a5f7f52732f5c4da4b397e74c \
  --rpc-url "$ROBINHOOD_TESTNET"
```

No private key is required for these read-only checks.
