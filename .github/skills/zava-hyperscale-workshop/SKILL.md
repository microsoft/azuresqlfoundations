---
name: zava-hyperscale-workshop
description: 'Orchestrator for the Azure SQL Foundations Hyperscale workshop (fictional customer ZavaFin / Zava Lending, one database ZavaLendingDB) — a three-act "Migrate → Scale → AI" story. USE WHEN the user says "let''s go through the workshop examples", "run the Azure SQL Foundations workshop", "start the Zava Lending / ZavaFin demo", "walk me through the three acts", "do the Hyperscale workshop", or asks which act or step to run next. Explains the acts, prerequisites, and recommended order, then hands off to the per-act skills: zava-act1-migrate, zava-act2-scale, and zava-act3-ai.'
---

# Azure SQL Foundations — Hyperscale Workshop (orchestrator)

One fictional customer — **ZavaFin / Zava Lending** — and one database, **`ZavaLendingDB`**,
followed across its whole lifecycle in three acts. This skill is the front door: it explains
the story, checks where the user wants to start, and routes to the right per-act skill.

> Same database. Three acts. One platform. **Migrate → Scale → AI.**

## The three acts

| Act | Folder | Theme | Per-act skill | What it proves |
|-----|--------|-------|---------------|----------------|
| **1 — Migrate** | [migrate/](../../../migrate/) | Migrate & Modernize | `zava-act1-migrate` | On-prem SQL Server 2019 → Azure SQL Hyperscale via DMS (offline), then modernize (compat 170, clustered columnstore, automatic index compaction). |
| **2 — Scale** | [scale/](../../../scale/) | The Destination | `zava-act2-scale` | How Hyperscale scales: vCore change as a minimal-downtime control-plane operation, serverless, and named read replicas. Ships as a self-contained interactive dashboard. |
| **3 — AI** | [ai/](../../../ai/) | The Engine Knows | `zava-act3-ai` | Native vector search (DiskANN) + in-database AI loan scoring (Phi-4), plus an optional DAB / SQL MCP / Foundry agent. |

## How to guide the user

1. **Ask where they want to start.** The recommended path is **in order (1 → 2 → 3)** so one
   database carries through its whole lifecycle, but **each act is self-contained** and can be
   run standalone for a shorter session. Act 3 builds on the **Act 1** database; **Act 2 is not
   required for Act 3**.
2. **Route to the per-act skill** for step-by-step guidance:
   - Act 1 → the `zava-act1-migrate` skill (source setup → DMS migration runbook → modernize).
   - Act 2 → the `zava-act2-scale` skill.
   - Act 3 → the `zava-act3-ai` skill.
3. **Point to the narrative READMEs** as you go: root [README.md](../../../README.md),
   [migrate/README.md](../../../migrate/README.md), [scale/README.md](../../../scale/README.md),
   [ai/README.md](../../../ai/README.md).

## Prerequisites (high level — per-act READMEs have the detail)

- An **Azure subscription** that can create a logical server + Hyperscale database (Act 1 also
  needs a DMS and a source SQL Server VM stand-in). **Act 2 needs no Azure** — it's a browser
  dashboard.
- **Azure SQL Database Hyperscale** for Acts 1 and 3.
- **Azure AI (Azure OpenAI)** with `text-embedding-3-large` and **Phi-4** deployed, for Act 3.
- Tooling: **SSMS** or the **VS Code MSSQL extension**, **Azure CLI** with the `datamigration`
  extension, and **VS Code + Copilot (Agent mode)** for the scripted migration.

## The app (optional visual anchor)

Static, self-contained front-ends you can open in a browser (mocked data, no server):
[application/loan-platform-customer/index.html](../../../application/loan-platform-customer/index.html),
[application/loan-platform-internal/index.html](../../../application/loan-platform-internal/index.html) (Act 2),
and [application/loan-platform-internal-ai/index.html](../../../application/loan-platform-internal-ai/index.html) (Act 3).

## Conventions

- **Fictional customer:** ZavaFin / Zava Lending — all data is synthetic; any resemblance to
  real entities is coincidental.
- **Database:** `ZavaLendingDB` throughout.
- **Secrets:** passwords are entered only at masked terminal prompts — never in chat, never
  committed. Scripts use placeholders (`<your-server>`, `<your-resource-group>`,
  `<your-ai-account>`, …) the user replaces with their own values.
