# Basket bootstrap and shared v4 zap

Creators supply project-token payment inventory to isolated, fixed-term
campaigns. Suppliers sell basket underlyings for immediate project-token
payments through firm per-asset reverse Dutch auctions. They receive no LP,
refund or clawback rights. The launch positions become protocol-owned liquidity.

## Creation and funding

Deploy the periphery with `PrepareStaticsBootstrap.deployPeriphery`, supplying
the installed Diamond and a verified WETH runtime hash. The helper does not
broadcast, configure governance or enable external integrations.

Create fixed campaign terms through `BasketBootstrapFactory`. Predict its
address first: this campaign is the payer of the creator's signed creation
intent. Mine intent-owned hook nonces, then call campaign `prepare` with the
creator's EIP-712 or ERC-1271 authorization. Preview and execution share the
prepared token address, actual tick spacing, seed math, backing and fee rounding.
Changed implementation or economics commitments invalidate execution.

`fund`, `fundPayment` and `fundNative` credit explicit launch, project-token
payment and native-fee inventory. Unsolicited balances do not establish readiness.
Ordinary tokens work directly. Restricted BasketToken project inventory and
constituents require governance to install the fixed campaign factory with its
verified runtime and creation-code hashes. Its actual deployed campaigns and
asset lists are registered permanently. Approve the Diamond, not the campaign,
for restricted funding: each exact pull/push passes through Diamond custody,
restores its prior balance and leaves no reusable transfer authorization.
Project-token constituent backing and payment inventory remain separately
accounted even when they share the same ERC-20 address.

Anyone can activate an immutable per-asset auction when its entire rounded cap
liability is reserved. `quoteFill` and `fill` support partial fills, minimum
payments, expiry and terminal dust. Direct funding shrinks unused commitments.
All received and paid token amounts must be exact.

`finalize` requires complete funding strictly before the creator-set deadline.
It atomically creates the basket, verifies actual canonical POL ownership and
custody, and preserves creator attribution. It does not harvest external
sources or hand off fee rights. Funded but unfinalized campaigns expire too.
`claimTerminalInventory` sends settled terminal inventory to the fixed
beneficiary; successful suppliers keep their payments.

## Exact-output conversion

`StaticsAssetZap.mintBasket` and `purchaseCampaign` share typed Uniswap v4
conversion. Supply explicit currency paths and PoolKeys, per-route limits and
an aggregate input maximum. Native ETH is wrapped using configured WETH.
There is no arbitrary router calldata or PONS/Mosh conversion fallback.

Basket minting quotes requirements at execution, checks user bounds, and mints
directly to the receiver. Campaign purchasing delivers selected underlyings
and pays project tokens directly to the receiver. Conversion, bounds or
settlement failure reverts the complete transaction. Caller-attributable input
leftovers return to the caller; existing balances cannot fund another user.
Restricted BasketTokens are not accepted as raw wallet input; registered v4
routes may acquire restricted constituents or internally net restricted hops.

## Realized revenue

`MeasuredCampaignRevenue` binds once to a creator-approved campaign and exact
constituent. Explicit realized ERC-20 receipts fund the live campaign, then
route to its fixed beneficiary after success or expiry. It does not count
future fees, transfer share principal, or harvest an external protocol. Generic
delivery uses ordinary payout tokens; it does not bridge restricted revenue tokens.

`NativeCampaignRevenue` uses the same one-time binding and fixed routing. Its
`deliverNative()` wraps exactly `msg.value` using a runtime-pinned WETH, verifies
the exact receipt, forwards it, and clears campaign approval. It cannot sweep
preexisting WETH or force-sent ETH; ordinary unsolicited ETH sends revert.
Payout-wrapper proxy implementations and authorities still need deployment
review: a proxy runtime hash alone does not pin its implementation. The SDK's
`buildDeliverNativeRevenueCall(amount)` returns explicit calldata and transaction
value. Neither generic delivery contract independently harvests PONS or Mosh.

`LibMoshValidation` checks the configured chain, factory/registry/implementation
runtime pins, exact immutable Swarm clone target, recognized Swarm, project
token, and native counter asset. It checks a registered runtime-pinned market
and its current fee, then binds custody offers to exact seller, buyer, amount,
one-wei price, snapshotted fee, and strictly unexpired deadline. These are entry
checks, not authority to move claims; changing factory configuration must not
be used to lock existing users' exits. Callers must still measure actual claim
debits/receipts and automatic fee callbacks. Fork tests establish offer getter
layout, clearing on fill/cancel, and the exact-deadline rejection. SDK custody
encoders expose these market operations; they do not implement pooled adapter
accounting by themselves.

The closed-source Mosh integration uses its published documentation/ABIs and
runtime-pinned fork evidence, not a source-audit claim. Public Solidity source
is not a prerequisite. Each enabled generation still requires actual adapter
entry, recovery, collection and terminal-accounting tests.

`RobinhoodMoshClaimFork.t.sol` checks the current ETH-pair generation at
Robinhood L2 block 80,155,273. It pins the Swarm implementation, factory,
registry, market and PONS hook, and checks the Swarm's minimal-proxy binding.
Its contract-controlled probe fills buyer-bound listings and returns partial
or complete claims through new listings. Return is two-step: listing does not
escrow the claim; the designated depositor must fill it. Zero-price listings
are rejected, so the probe uses a one-wei price (the pinned 10% market fee
rounds to zero). Those sale proceeds are distinct from fee rewards.
An expired listing still occupies the market's listed-amount accounting; the
custody contract must cancel it before relisting that amount for recovery.

Permissionless collection works after rewards are realized. Returning claims
automatically pays the old custodian's available fees before removing its
claims. Unconverted PONS fees follow the owner when realized, and return does
not need to wait for conversion. The fork models the existing privileged PONS
operator only to produce upstream conversion; Statics does not gain that role.
These tests prove the probe's movement paths, not completed campaign reward
accounting or compatibility with other generations/payout assets.

`MoshShareRevenueAdapter` accounts native receipts lazily: funding-period
receipts reserve revenue for the campaign, and newly accounted terminal receipts
belong to depositors. Previously reserved campaign rewards stay campaign-owned.
Permissionless `sync()` collects only the adapter's available fees, not projected
PONS conversion. `flushCampaignRevenue()` wraps and forwards the existing reserve
separately; a failed forward leaves it retryable and does not enter withdrawal.
User rewards and return sale proceeds are paid as the configured WETH through
`claimRewards()`. Unsolicited native/WETH balances cannot fund those liabilities.

Deposit fills an exact creator-supplied buyer-bound offer with one wei and checks
both actual claim deltas. `withdraw(amount, deadline)` lists the return; the owner
then fills that market offer directly. Anyone calls `checkpointWithdrawal(owner)`
after a successful fill to reconcile its cleared record and measured custody
decrease. Reconciliation must precede another fill or share movement; it is not
owner/keeper-gated and does not push funds to a rejecting wallet. Concurrent
return listings are supported, including equal amounts, without scanning users.
Automatic fees use the old balance distribution; the one-wei sale receipt is
credited only to the returning owner, never counted as source fees. Expired
listings are cancelled by their owner through `cancelWithdrawal()` before retry.

The adapter uses Q160 reward indexing, per-owner sub-unit carry, and numerator
carry while the denominator is unchanged. Tracked claims are bounded to uint128;
terminal-index lifetime reward capacity is `2^96 - 1` raw native units. Changing
shares resets only a sub-`2^-32` raw-unit numerator fraction; reserved assets remain
backed. Entry pins current factory/market policy; exit does not require the current
factory implementation pointer and accepts supported zero-rounded current market
fees. Upstream registry/market authority remains an external recovery dependency.
`RobinhoodMoshShareAdapterFork.t.sol` executes the production adapter against the
pinned source, including multi-depositor/terminal accounting and forwarding
rollback, with a local real Statics/POL launch. This is not verified-source,
all-generation, deployment, or release-CI assurance. No trade-time entitlement
is reconstructed from harvest timestamps.

`MoshTeamRevenueAdapter` permanently routes authorized team fee claims. Deploy
before a new launch names it as team recipient, then bind the actual launched
source; alternatively the historical team recipient explicitly hands off selected
claims through an exact buyer-bound market offer. Campaign-creator authority
cannot substitute for that seller's authority. Collection and retryable wrapping/
delivery are separate; all terminal revenue belongs to the fixed beneficiary.
Existing-team handoff and later real swap fees are fork-tested. The new-source
regression also purchases actual gate tokens, creates and funds the real launcher,
completes PONS launch/graduation and Swarm vault finalization, then binds the
adapter's actually minted team claims. A subsequent real swap produces additional
measured campaign revenue without accessing agent principal. This evidence is
specific to the pinned factory, launcher, planner and supported native generation.

`PonsRevenueAdapter` binds one pinned V2 factory, launched token, curve and fee
escrow. The current fee recipient must first transfer its rights to the adapter
before campaign binding. Permissionless bounded `collect(maximum)` checks exact
escrow debit and native-to-WETH or configured quote-token receipt. Terminal
`handoff()` transfers future rights separately to the fixed beneficiary; old
adapter escrow credits remain collectible. Recipient-level escrow aggregates
credits, so collection does not independently attest per-token fee origin.
Upstream conversion/sweep authority remains a revenue-liveness dependency;
Statics gains no operator role and does not release buyback vesting or principal.
Native and approved quote-token collection, handoff/retry and independent real
POL finalization execute in pinned forks. Payout proxy implementations and the
upstream owner's delayed recipient override remain deployment-review concerns.

Combined-source fork regressions fund one campaign through direct contributions,
firm procurement, measured PONS receipts and both Mosh adapters, then prove real
POL custody or expiry, settled supplier payments and independent share recovery.
An independent PONS source uses authorized escrow collection, exact WETH wrapping
and generic measured delivery. It is not cross-project `PonsRevenueAdapter`
binding: moving the Mosh source's PONS rights would disrupt Swarm collection.
