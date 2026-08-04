---
name: zava-act2-scale
description: 'Act 2 of the Zava Lending Hyperscale workshop — Scale on Hyperscale. USE WHEN the user wants to run "Act 2", "the scale act", or to learn how Hyperscale scales: changing vCores as a minimal-downtime control-plane operation, serverless for variable load, and named read replicas for read-only scale-out. This act ships as a self-contained interactive dashboard (no Azure account needed) — guides opening scale/scale-dashboard/dashboard.html and stepping through the hypothetical 8-phase, 32→192 vCore scale-up.'
---

# Act 2 — Scale on Hyperscale

Show how the migrated `ZavaLendingDB` scales for launch. **This act ships as a self-contained,
interactive dashboard — no Azure account required.** Narrative + concepts:
[scale/README.md](../../../scale/README.md).

## Teach the three scaling concepts first

- **Changing vCores is a control-plane operation with minimal downtime.** Moving the tier
  (e.g. 32 → 192 vCores) is a compute reconfiguration against the same shared storage — not a
  data move — so it completes in seconds with only a brief reconnect. Scale up for peak, back
  down after to control cost.
- **Serverless** auto-scales compute within a min/max vCore range and bills for what you use —
  ideal for dev/test, spiky, or unpredictable load.
- **Named read replicas** are independent, read-only compute nodes over the *same* storage —
  their own endpoint and vCore tier, scaled independently, no data copying. Point reporting /
  analytics / (in Act 3) vector search at a replica so reads never compete with writes.

## Drive the dashboard

1. **Open** [scale/scale-dashboard/dashboard.html](../../../scale/scale-dashboard/dashboard.html)
   — double-click or open in any modern browser. Everything is inlined; nothing to install.
2. **Step or play** the 8 phases from the control bar (buttons **1–8**, **▶ Play Progression**,
   **Restart**). The story alternates **pressure** (load grows on fixed vCores → CPU saturates,
   latency spikes) and **relief** (scale vCores up online → recovers), ending with a nightly
   write-only batch.

| Phase | vCores | Users | What to point out |
|-------|--------|-------|-------------------|
| 1 | 32 | 250 | Baseline |
| 2 | 32 | 500 | Pressure |
| 3 | 64 | 500 | Relief (×2) |
| 4 | 64 | 1,000 | Pressure |
| 5 | 128 | 1,000 | Relief (×2) |
| 6 | 128 | 2,000 | Pressure (peak) |
| 7 | 192 | 2,000 | Relief (top SLO) |
| 8 | 192 | — | Nightly ETL |

**Two takeaways:** latency returns to the same low level after every relief phase ("users never
notice the scaling"), and throughput scales near-linearly with vCores.

Full panel-by-panel guide:
[scale/scale-dashboard/README.md](../../../scale/scale-dashboard/README.md).

## Important framing

This is a **hypothetical, illustrative scenario**: the vCore tiers (starting at 32) and user
counts are a representative launch-day story chosen to show the scaling *pattern*, not a literal
continuation of Act 1 (which lands the DB on a small ~8-vCore tier). Read the numbers as an
example of *how* Hyperscale scales.

## Next act

Continue to **Act 3 (AI)** via the `zava-act3-ai` skill.
