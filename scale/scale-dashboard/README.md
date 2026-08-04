# Scale Dashboard — how to use it

`dashboard.html` is a **self-contained, offline** web page that lets you "play" the Zava
Lending scaling story. Everything (styles, charts, and the captured phase data) is inlined —
there's no server, no database, and no build step.

## Run it

Just **double-click `dashboard.html`** (or open it in any modern browser). Nothing to install.

## The idea in one line

A lending platform grows from a few hundred to a few thousand concurrent users. At each
growth stage, CPU pressure builds → you **scale up vCores online** → latency recovers and
throughput climbs. The dashboard replays real captured metrics for each stage so you can see
the pattern without provisioning anything.

## How to drive it

The **control bar** at the bottom is where you click:

| Button | What it loads |
|--------|---------------|
| **1 – 8** | Jump straight to a specific phase (see the phase table below). |
| **▶ Play Progression** | Auto-steps through phases 1 → 8 with a pause on each, so it animates the whole story hands-free. |
| **Restart** | Reset back to Phase 1. |

The **phase strip** across the top bar shows where you are in the journey. Each marker is a
`vCores` value with a status icon:

- **✓ (healthy)** — CPU comfortable, latency low.
- **⚠ (pressure)** — the same vCores now under heavier user load; CPU saturates, latency spikes.
- **⇒ N** — a **scale-up** happened here (e.g. `⇒ 64` = scaled to 64 vCores).
- **✍ (log writer)** — the nightly batch/ETL phase.

## The 8 phases

The story alternates **pressure** (load grows on fixed vCores) and **relief** (scale up →
recovery), then finishes with a write-only batch:

| Phase | vCores | Users | Role | What you should see |
|-------|--------|-------|------|---------------------|
| 1 | 32 | 250 | Launch day (baseline) | Healthy — low CPU, ~low latency. |
| 2 | 32 | 500 | **Pressure** | CPU pegs, latency spikes — the box is out of headroom. |
| 3 | 64 | 500 | **Relief** (scaled ×2) | Same users, double the vCores — CPU drops, latency recovers. |
| 4 | 64 | 1,000 | **Pressure** | Load doubles again — CPU pegs. |
| 5 | 128 | 1,000 | **Relief** (scaled ×2) | Pressure gone again. |
| 6 | 128 | 2,000 | **Pressure** | Peak-season load — CPU pegs. |
| 7 | 192 | 2,000 | **Relief** (scaled ×1.5) | Headroom restored at the top SLO. |
| 8 | 192 | — | **Nightly ETL** (write-only) | Log throughput dominates; a bulk load + columnstore build. |

**The two takeaways to point out:**
1. **Latency consistency** — every *relief* phase returns to roughly the same low average
   latency, regardless of user count. *"Users never notice the scaling."*
2. **Throughput scaling** — 32 → 64 → 128 is near-linear (2× vCores ≈ 2× throughput);
   128 → 192 (only +50% vCores) still absorbs a doubling of users. *"Even sub-linear scaling
   keeps the business running."*

## The panels (what each visual means)

| Panel | Shows | What to look for |
|-------|-------|------------------|
| **vCore Count** | A dial with the current compute tier (32 / 64 / 128 / 192). | Jumps up on each *relief* phase. |
| **Concurrent Users** | Active sessions, plus **QPS/User**, **Txns/User**, and **Avg Elapsed** (with deltas vs. the prior phase). | On pressure phases, per-user throughput drops and latency rises; scaling reverses it. |
| **Business Transactions** | Total transactions completed, broken down by Payments, Account Reviews, Loan Applications, Eligibility Checks. | Total climbs as vCores and users grow. |
| **CPU Utilization** | A per-scheduler heatmap + **Avg CPU** and scheduler count. | Turns hot/red on pressure phases; cools after a scale-up. Scheduler count tracks vCores. |
| **Query Performance (avg elapsed)** | Per-procedure latency bars for the six workload procs (Loan Application, Payment Processing, Account Review, Risk Exposure, Branch Activity, Loan Eligibility). Hover a name for the proc's steps. | Bars grow under pressure, shrink after scaling. Risk Exposure (55M-row CCI scan) is the heaviest. |
| **Log Throughput** | Sustained MB/sec + total log written. In **Phase 8** it expands to show Batch ETL detail (rows loaded, rows/sec, heap INSERT time, CCI build time). | Phase 8 pushes log write rate toward the Hyperscale cap. |
| **Columnstore Engine** | Indicator lights for **Batch Mode** and **Segment Elimination**, plus compressed %, CCI size, and compression ratio. | Lights active when the analytic procs run columnstore scans. |

## Notes

- All numbers are **captured from a real run** and inlined into the page — the dashboard is a
  faithful replay, not a live query tool.
- The executable harness that produced these metrics has been removed from the repo; you
  don't need it to use this dashboard.
