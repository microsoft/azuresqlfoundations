# Act 2 — Scale on Hyperscale

## Scaling on Hyperscale — the concepts

Once ZavaFin's lending database lands on Azure SQL Hyperscale, "scaling for launch" stops
being a project and becomes a setting. A few ideas do all the work:

- **Changing vCores is a control-plane operation with minimal downtime.** Moving the compute
  tier up or down (for example 32 → 192 vCores) is a compute reconfiguration against the same
  shared storage — *not* a data movement. Hyperscale swaps in the new compute so the change
  completes in seconds: no data copy, no maintenance window, and only a brief reconnect for
  active sessions. You scale up for launch day or peak season and scale back down afterward to
  control cost.

- **Serverless for variable or unpredictable load.** Instead of a fixed provisioned tier,
  Hyperscale **serverless** auto-scales compute within a configured min/max vCore range based
  on demand and bills for the compute you actually use. It's ideal for dev/test, spiky
  traffic, or a new product whose curve you can't predict yet — set the ceiling and let the
  platform ride it.

- **Named read replicas for read-only scale-out.** A **named replica** is an independent,
  read-only compute node over the *same* shared storage — its own endpoint and its own vCore
  tier, scaled independently of the primary and of other replicas, with no data copying. Point
  reporting, dashboards, analytics, or (in Act 3) vector search at a replica and those reads
  never compete with writes on the primary. You can add up to 30 named replicas, each sized
  for its own workload.

Together these mean one database can absorb launch-day growth, isolate each team's workload,
and right-size cost — none of which the old on-prem box could do.

---

## What this act ships

Act 2 is delivered as a **self-contained, interactive scale dashboard** — no Azure account, no
database, no build step. It replays captured metrics from an 8-phase scale-up so you can
*see* the core pattern play out: **load grows → scale vCores online → latency recovers**. The
lending app front-ends are included for context.

> **This is a hypothetical, illustrative scenario.** The phases, the vCore tiers (starting at
> 32), and the user counts are a representative launch-day story chosen to show the scaling
> *pattern* clearly — they are **not** a literal continuation of Act 1 (which lands the
> database on a small ~8-vCore tier). Read the numbers as an example of *how* Hyperscale
> scales, not a fixed script you must reproduce.

- **Scale dashboard** — [scale-dashboard/dashboard.html](scale-dashboard/dashboard.html)
  (full panel + phase guide: [scale-dashboard/README.md](scale-dashboard/README.md)).
- **Customer site** — [../application/loan-platform-customer/index.html](../application/loan-platform-customer/index.html).
- **Internal staff app** — [../application/loan-platform-internal/index.html](../application/loan-platform-internal/index.html).

---

## The dashboard — how to load it

Just **double-click `scale-dashboard/dashboard.html`**, or open it in any modern browser.
Everything — styles, charts (Chart.js), and the captured phase data — is inlined; there's
nothing to install, no server, and no connection string.

---

## The dashboard — how to use it

The story alternates **pressure** (user load grows on fixed vCores → CPU saturates, latency
spikes) and **relief** (scale vCores up online → CPU cools, latency recovers), then finishes
with a nightly write-only batch. Drive it from the **control bar** at the bottom:

- **1 – 8** — jump straight to a specific phase.
- **▶ Play Progression** — auto-step through phases 1 → 8 hands-free.
- **Restart** — reset back to Phase 1.

The phase strip across the top shows where you are; each marker is a `vCores` value with a
status icon (✓ healthy, ⚠ under pressure, ⇒ N scaled up, ✍ nightly batch).

| Phase | vCores | Users | What you should see |
|-------|--------|-------|---------------------|
| 1 | 32 | 250 | Baseline — low CPU, low latency |
| 2 | 32 | 500 | **Pressure** — CPU pegs, latency spikes |
| 3 | 64 | 500 | **Relief** (scaled ×2) — recovers |
| 4 | 64 | 1,000 | **Pressure** |
| 5 | 128 | 1,000 | **Relief** (scaled ×2) |
| 6 | 128 | 2,000 | **Pressure** — peak season |
| 7 | 192 | 2,000 | **Relief** (scaled ×1.5) — top SLO |
| 8 | 192 | — | **Nightly ETL** (write-only) |

Two takeaways to point out while clicking through:

1. **Latency consistency** — every *relief* phase returns to roughly the same low latency
   regardless of user count. *Users never notice the scaling.*
2. **Throughput scaling** — 32 → 64 → 128 is near-linear (2× vCores ≈ 2× throughput);
   128 → 192 (+50% vCores) still absorbs a doubling of users.

For a panel-by-panel walkthrough — the vCore dial, concurrent-users tiles, CPU heatmap,
per-query latency, log throughput, and columnstore engine indicators — see
[scale-dashboard/README.md](scale-dashboard/README.md).

---

## How this connects to the other acts

- **From Act 1 (Migrate):** this is the same *fictional* `ZavaLendingDB`, now imagined at
  launch — a **hypothetical** continuation, not a literal one. Act 1 lands the database on a
  small (~8-vCore) tier; this scenario simply picks a representative 32-vCore starting point
  to tell the scaling story, so there's no need to carry state over from Act 1.
- **Into Act 3 (AI):** the **named read replica** concept above is what lets Act 3 optionally
  offload vector search to an Analytics replica while AI scoring and writes stay on the primary.

