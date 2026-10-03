# Atomic protocol POL repositioning

`rebalanceProtocolPolPositions` replaces one to eight existing POL positions
with one to eight new positions within a single registered public PoolId. It
requires the existing POL operator or Diamond owner, active liquidity ingress,
and an unexpired deadline. Duplicate close IDs and foreign-pool positions are
rejected before any position changes.

Each close uses its recorded originating manager, harvests native LP fees into
Treasury, returns principal to the same PoolId custody account, and clears its
gauge binding. Opens use the currently installed manager and bind new NFTs as
protocol POL. Every recipient is fixed by the existing custody library; the
caller supplies no destination. A failure in any close or open reverts all
position changes, custody reservations, fee accrual, refunds and bindings.

`maximumCustodyDebit0` and `maximumCustodyDebit1` bound the sum of the opening
amount maxima. These are gross limits; returned principal and refunds do not
net against them. Each close additionally supplies principal output minima,
and each open supplies liquidity, aligned ticks and input maxima. Deadlines,
amount bounds and pre-sign simulation remain necessary for price-movement
protection. Atomicity closes the inter-transaction gap without eliminating MEV.

This selector is part of the canonical protocol POL selector manifest for
future deployments. An existing Diamond requires a reviewed owner-controlled
cut before an offchain manager can use it. Automatic multi-transaction close
then open replacement is not an alternative to this dependency. Independently
closing a position during a liquidity pause remains available through the
existing exit entrypoint.
