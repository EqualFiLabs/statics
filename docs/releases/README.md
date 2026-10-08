# Statics release records

These records describe the source, deployment boundary, launch configuration,
and evidence for a particular Statics release. Deployment dates and retrospective
documentation dates are recorded separately.

| Release | Network | Original deployment | Recorded source | Documentation | GitHub release |
| --- | --- | --- | --- | --- | --- |
| Standalone Genesis launch | Robinhood Chain Mainnet, chain ID 4663 | August 27, 2026 | [`43018f1`](https://github.com/EqualFiLabs/statics/commit/43018f109006aa2c2eef2808adc2aa74dfc9a6d4) | [Retrospective release record](./genesis-launch.md) | [`genesis-v1.0.0`](https://github.com/EqualFiLabs/statics/releases/tag/genesis-v1.0.0) |

Genesis establishes the standalone STATICS token, Operators collection, vault,
launch market, fee ingress, activation registry, rewards, and treasury vesting.
The phased `StaticsDiamond` deployment has a separate release boundary described
in the [staged-launch ADR](../adr/staged-phase-one-launch.md).
