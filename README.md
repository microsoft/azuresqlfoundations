# Azure SQL Foundations — Hyperscale Video Series & Workshop

A complete, end-to-end story for **Azure SQL Database Hyperscale**, built as both a
**video series** and a hands-on **workshop**. Everything centers on one fictional
customer — **ZavaFin / Zava Lending** — and one database, **`ZavaLendingDB`**, followed
across its entire lifecycle: migrate it onto Hyperscale, scale it for launch, and make it
intelligent with native vector search and AI scoring.

> Same database. Three acts. One platform.

> 📺 **This workshop is a companion to the Azure SQL Foundations video series:**
> **<https://aka.ms/azuresqlfoundationseries>**. Watch the videos to see the story,
> then use this repo to run the same three acts hands-on.

> ▶ **Using GitHub Copilot?** Open Copilot Chat in **Agent mode** and say
> *"Let's go through the workshop examples"* — the repo's skills drive the whole thing.
> See [Run it with GitHub Copilot](#run-it-with-github-copilot-skills--prompts).

---

## Why Hyperscale?

Azure SQL Database Hyperscale is a cost-efficient, high-performance cloud database and is suitable for all workload types.

Azure SQL Database is based on the [SQL Database Engine](https://learn.microsoft.com/en-us/sql/database-engine/sql-database-engine). Users can start small and grow to their needs with Hyperscale:

- A default Hyperscale database can consist of only 2 vCores and 10GB of storage. You never define a maximum. Storage just grows per your needs up to 128TB. You can also scale your database with minimal downtime up to 192 vCores.

- Hyperscale is competitively priced compared to other high-performance cloud database options using open-source pricing. In addition, you can save costs using serverless or elastic pools.

- While Hyperscale uses the power SQL Server engine, it's distributed architecture is what makes it unique. It separates compute, log, and storage layers, allowing for rapid scaling and high availability without impacting ongoing operations.
 
- Hyperscale supports powerful HA options including built-in high-availability replicas with zone redundancy and configurable geo-replicas around the globe.
 
- Hyperscale's architecture allows for nearly instantaneous backups and fast restores, ensuring minimal disruption to ongoing operations.

- Read scale-out strategies are easy, with up to 30 named replicas with independent configurable compute, plus built-in high-availability replicas and configurable geo-replicas around the globe.

---

## The Story

ZavaFin runs a digital lending platform on an aging on-prem **SQL Server 2019** box. They
are launching a new product and have hit the ceiling — storage, compute, and weekend
maintenance jobs. They move to **Azure SQL Hyperscale**, and that move is only the
starting line. The payoff is everything they can do *next* that they never could on-prem.

Every demo uses the **same `ZavaLendingDB`**, so the workshop tells one continuous narrative
rather than three disconnected labs.

---

## Why Zava Lending Chose Hyperscale

ZavaFin evaluated every major cloud database for their lending platform — 50M+ applications a
year, 800 GB growing toward multi-terabyte, and the need to scale compute in seconds without
downtime. They chose **Azure SQL Hyperscale** because no other platform delivered *all* of the
following in one database, behind one SQL surface:

| # | What sealed the decision | Proof point from the demo |
|---|--------------------------|---------------------------|
| 1 | **Up to 192 vCores** in a single database | Peak season (850 users) scaled 128 → 192 vCores in seconds — no downtime, no re-architecture |
| 2 | **Named replicas** — independent endpoints + independent compute over shared storage | Primary (192) writes, Analytics (80→128) vector search, Reporting (40) dashboards — no contention, zero data copies |
| 3 | **100 TB** storage with no performance cliff | Distributed page servers + RBPEX SSD cache that grows with compute (≈499 GB → 2.5 TB) |
| 4 | **Log-based architecture** for batch at scale | 5M-row nightly ETL: 8.4 GB of log at 108.6 MB/s, done in ~79 seconds |
| 5 | **Native columnstore** + batch-mode execution | OLTP and 55M-row analytical scans on the *same* tables, same SQL |
| 6 | **Built-in AI** — no external pipeline | `AI_GENERATE_EMBEDDINGS`, DiskANN `VECTOR_SEARCH`, LLM scoring via `sp_invoke_external_rest_endpoint`, native `vector` type |
| 7 | **Full T-SQL engine** — not a compatibility subset | Stored procs, window functions, `MERGE`, Query Store; SSMS/ADS/sqlcmd tooling unchanged |
| 8 | **Elastic scale in seconds** | 8-phase 32 → 192 vCore progression — no sharding, no connection drops, no maintenance windows |
| 9 | **Built-in monitoring** — no third-party stack | Query Store, Intelligent Insights, automatic tuning, Azure Monitor — zero config |
| 10 | **99.995% SLA** — zone-redundant HA | Automatic failover across availability zones, no clustering to configure |

> "We evaluated every cloud database on the market. Only one gave us 192 vCores, named
> replicas, columnstore, vector search, AI scoring, built-in monitoring, and a 99.995% SLA —
> all in the same database, all with the same SQL. That's why we're on Hyperscale."

---

## The Three Acts (plus a portable runbook)

```
  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
  │   MIGRATE   │ ──► │    SCALE    │ ──► │     AI      │
  │  (Act 1)   │     │  (Act 2)   │     │  (Act 3)   │
  │  migrate/   │     │   scale/    │     │    ai/      │
  └─────────────┘     └─────────────┘     └─────────────┘
        │
        └── Workshop skills: .github/skills/  (zava-hyperscale-workshop + zava-act1-migrate / zava-act2-scale / zava-act3-ai)
            Act 1's zava-act1-migrate drives scripts in migrate/scripts/02-migrate-dms/
```

| Folder | Act | Theme | What it proves |
|--------|-----|-------|----------------|
| [migrate/](migrate/) | **Act 1** | Migrate & Modernize | On-prem SQL Server 2019 → Hyperscale via DMS (offline), then modernize in place: compat 150→170 (intelligent query processing), rowstore→clustered columnstore, automatic index compaction. |
| [migrate/scripts/02-migrate-dms/](migrate/scripts/02-migrate-dms/) | Act 1 (scripted) | Migrate & Modernize | An approve-each-step runbook that drives the same migration with the local `az datamigration` CLI, invoked by the [zava-act1-migrate](.github/skills/zava-act1-migrate/SKILL.md) VS Code skill. Recorded as a 5-video Copilot Agent series. |
| [scale/](scale/) | **Act 2** | The Destination | Scale the migrated database for launch — vCore changes as a minimal-downtime control-plane operation, serverless, and named read replicas for read-only scale-out. Ships as a self-contained, interactive **scale dashboard** you can play. |
| [ai/](ai/) | **Act 3** | The Engine Knows | Native `VECTOR_DISTANCE` + DiskANN vector search over millions of loans, AI risk scoring via `sp_invoke_external_rest_endpoint`, hybrid search, and workload isolation across named replicas. |

---

## The app — front-ends you can open

The database powers a lending platform with self-contained web front-ends (static HTML — open
directly in a browser, mocked data, no server — these are **UI mockups**, not the live app;
overview: [application/README.md](application/README.md)):

- **Customer site** — [application/loan-platform-customer/index.html](application/loan-platform-customer/index.html): the borrower-facing application experience (first reviewed in Act 1).
- **Internal operations console** — [application/loan-platform-internal/index.html](application/loan-platform-internal/index.html) (first reviewed in Act 1, reused in Act 2), and its AI-enhanced version [application/loan-platform-internal-ai/index.html](application/loan-platform-internal-ai/index.html) (Act 3), whose **AI Intelligence** menu (**Narrative Search** + **AI Loan Scoring**) is the visual anchor for the AI act.

---

## Folder Guide

### `migrate/` — Act 1: Migrate & Modernize
The front door to the session. Migrates ZavaFin's on-prem SQL Server 2019 `ZavaLendingDB`
to Hyperscale using Azure Database Migration Service (offline), then modernizes it on the
new platform. Scripts are grouped by phase:

- **Narrative:** [migrate/README.md](migrate/README.md)
- **`scripts/01-source-sql2019/`** — stand up + seed the SQL Server 2019 source (VM stand-in).
- **`scripts/02-migrate-dms/`** — the complete `az datamigration` CLI migration (setup →
  assess → provision → DMS/SHIR → migrate → validate → teardown), driven by the skill below.
- **`scripts/03-optimize/`** — optional post-migrate modernization (compatibility level,
  columnstore, automatic index compaction).

### `.github/skills/zava-act1-migrate/` — Act 1 migration skill (VS Code)
The **skill** that VS Code discovers and invokes to run Act 1 as a guided,
approve-each-step runbook (stand up source → DMS migration → modernize). The `SKILL.md`
lives here; the runnable scripts and the plain-language prompts it drives live in
[migrate/scripts/02-migrate-dms/](migrate/scripts/02-migrate-dms/).

- **Runbook:** [.github/skills/zava-act1-migrate/SKILL.md](.github/skills/zava-act1-migrate/SKILL.md)
- **Prompts to run it:** [migrate/scripts/02-migrate-dms/prompts.md](migrate/scripts/02-migrate-dms/prompts.md)
- **Phases:** 0 Setup → 1 Assess → 2 Provision Hyperscale → 3 DMS + SHIR →
  4 Migrate (schema, then data) → 5 Validate → 99 Teardown.
- Migration to Azure SQL Database (including Hyperscale) via DMS is **offline only**.

### `scale/` — Act 2: The Destination
Picks up the *same* migrated `ZavaLendingDB` and shows how you scale it for launch on
Hyperscale — vCore changes as a minimal-downtime control-plane operation, serverless, and
named read replicas for read-only scale-out. **This act ships as a self-contained, interactive
scale dashboard** (no Azure account needed) that replays a real 8-phase scale-up.

- **Concepts + how to use the dashboard:** [scale/README.md](scale/README.md)
- **Why Hyperscale for Zava:** see [Why Zava Lending Chose Hyperscale](#why-zava-lending-chose-hyperscale) above.
- **Dashboard:** [scale/scale-dashboard/dashboard.html](scale/scale-dashboard/dashboard.html)
  (guide: [scale/scale-dashboard/README.md](scale/scale-dashboard/README.md)). Front-end
  mockups (customer + internal consoles) live under [application/](application/).

### `ai/` — Act 3: The Engine Knows
Adds AI to the *existing* Hyperscale database — natively in Azure SQL. Semantic **Narrative
Search** and in-database **AI Loan Scoring** run on the same `ZavaLendingDB`, built on the
**Act 1 (Migrate)** database (no Act 2 scale required). Vector reads can *optionally* offload
to an Analytics named replica; AI scoring and writes run on the primary.

- **Narrative:** [ai/README.md](ai/README.md)
- **Requirements:** [ai/zavafin-ai-sql-needs.md](ai/zavafin-ai-sql-needs.md) — the scenario /
  spec for this act: the five things ZavaFin's underwriters need (semantic search, iterative
  `WITH APPROXIMATE` filtering, DML on vector-indexed tables, faster index builds, and
  in-database AI scoring with Phi-4) that the `build/` + `walkthrough/` scripts deliver.
- **Build:** [ai/build/](ai/build/) — deploy the AI objects (narratives, embeddings, DiskANN
  index, search + scoring procedures). See [ai/build/README.md](ai/build/README.md).
- **Walkthrough:** [ai/walkthrough/](ai/walkthrough/) — execute the T-SQL behind Narrative
  Search and AI Loan Scoring. See [ai/walkthrough/README.md](ai/walkthrough/README.md).
- **Optional exercise — loan-scoring agent (DAB + MCP + Foundry):** expose the same
  `usp_ScoreLoanApplication` as an MCP tool via Data API Builder and drive it from a Microsoft
  Foundry agent. **Not required** to complete the AI act — deploy from
  [ai/build/loan-scoring-agent/](ai/build/loan-scoring-agent/), use it via
  [ai/walkthrough/loan-scoring-agent/](ai/walkthrough/loan-scoring-agent/).

---

## Capabilities Demonstrated

| Capability | Act | Where |
|-----------|-----|-------|
| DMS migration to Hyperscale (offline) | Migrate | `migrate/`, `.github/skills/zava-act1-migrate/` |
| Compatibility level 170 + intelligent query processing | Migrate | `migrate/scripts/03-optimize/01-compatibility-level.sql` |
| Clustered columnstore on Hyperscale | Migrate / Scale | `migrate/scripts/03-optimize/02-columnstore.sql`, `scale/` |
| Automatic index compaction (preview) | Migrate | `migrate/scripts/03-optimize/03-auto-index-compaction.sql` |
| 192 vCore SLO — scale in seconds, zero downtime | Scale | `scale/` |
| Named replicas (independent compute + endpoints) | Scale / AI | `scale/`, `ai/walkthrough/sql/03-vector-search-replica.sql` |
| **Narrative Search** — natural-language semantic search over loan narratives | AI | `application/loan-platform-internal-ai/`, `ai/build/sql/03-hybrid-search-procedure.sql` |
| **AI Loan Scoring** — in-database Phi-4 risk decisioning with auditable results | AI | `application/loan-platform-internal-ai/`, `ai/build/sql/04-loan-scoring.sql` |
| Native `VECTOR_DISTANCE` + `VECTOR(n)` type | AI | `ai/build/`, `ai/walkthrough/sql/` |
| DiskANN vector index + `TOP (N) WITH APPROXIMATE` | AI | `ai/build/sql/02-vector-index.sql`, `ai/walkthrough/sql/05-legacy-vs-new.sql` |
| DML on vector-indexed tables | AI | `ai/walkthrough/sql/04-dml-insert-search.sql` |
| In-database AI scoring via `sp_invoke_external_rest_endpoint` | AI | `ai/build/sql/04-loan-scoring.sql` |

---

## Using This Repo

### As a video series
Each act pairs with a video. Follow the acts in order — **Migrate → Scale → AI** — and
use each folder's `README.md` and numbered `scripts/` to reproduce what the video shows,
step by step, at your own pace.

### As a workshop
Each folder is a self-contained module with numbered scripts and a pre-demo checklist.
Because every act operates on the same `ZavaLendingDB`, the recommended path is to run
them in sequence so attendees carry one database through its full lifecycle. Individual
folders can also be run standalone for shorter sessions.

---

## Run it with GitHub Copilot (skills & prompts)

Every act can be run **two ways**: **by hand** (numbered scripts + folder READMEs — see
[How to run each act](#how-to-run-each-act)) or driven by **GitHub Copilot** using the
**skills** this repo ships under [.github/skills/](.github/skills/). In Copilot Chat you
don't hunt through folders — you just ask, and the skill walks you through its scripts
**one approved step at a time** (it never runs anything without your go-ahead).

### Supported AI tooling

| Tool | How it uses this repo |
|------|-----------------------|
| **GitHub Copilot in VS Code — Agent mode** *(recommended)* | Auto-discovers the four skills in `.github/skills/` and runs each act as a guided, approve-each-step workflow. Requires the GitHub Copilot extension, signed in, switched to **Agent** mode. |
| Other agentic coding assistants | The migration is also driven by plain-language prompts in [migrate/scripts/02-migrate-dms/prompts.md](migrate/scripts/02-migrate-dms/prompts.md) — paste them into any AI assistant you prefer. |

### Prompts to get started

Type any of these in **Copilot Chat (Agent mode)**:

| Say this | What happens | Skill |
|----------|--------------|-------|
| *"Let's go through the workshop examples"* | Lays out the three acts, prerequisites, and recommended order, then routes you | [`zava-hyperscale-workshop`](.github/skills/zava-hyperscale-workshop/SKILL.md) |
| *"Run Act 1"* / *"migrate SQL Server to Hyperscale"* | Stand up the SQL 2019 source → DMS migration → modernize | [`zava-act1-migrate`](.github/skills/zava-act1-migrate/SKILL.md) |
| *"Run Act 2"* / *"the scale act"* | Explains Hyperscale scaling and drives the scale dashboard | [`zava-act2-scale`](.github/skills/zava-act2-scale/SKILL.md) |
| *"Run Act 3"* / *"the AI act"* | Embeddings → DiskANN vector index → Narrative Search → AI Loan Scoring | [`zava-act3-ai`](.github/skills/zava-act3-ai/SKILL.md) |

The orchestrator skill knows the whole story; each act skill is also self-contained, so
you can jump straight to any act.

---

## Prerequisites

High-level summary — **detailed, per-act prerequisites live in each folder's README** (see
[How to run each act](#how-to-run-each-act) for the links).

- An **Azure subscription** that can create a logical server + Hyperscale database (and, for
  Act 1, a DMS and a source SQL Server VM).
- **Azure SQL Database Hyperscale** for Acts 1 and 3. *(Act 2 requires no Azure — it ships as a
  self-contained dashboard you open in a browser.)*
- **Azure AI (Azure OpenAI)** endpoint with `text-embedding-3-large` and **Phi-4** deployed,
  for Act 3. Act 3 builds on the **Act 1** database and does **not** require the Act 2 scale.
- Tooling: **SSMS 22** or the **VS Code MSSQL extension**, **Azure CLI** with the
  `datamigration` extension, and **VS Code + Copilot (Agent mode)** for the scripted
  migration.

---

## How to run each act

Each act is a self-contained module you can run **by hand** (below) — or let **GitHub
Copilot** drive it via the **Copilot:** prompt shown under each act (see
[Run it with GitHub Copilot](#run-it-with-github-copilot-skills--prompts)). **Detailed
prerequisites and step-by-step instructions live in the folder READMEs linked below** —
this is just the high-level path.

### Act 1 — Migrate → [migrate/README.md](migrate/README.md)
- **Prerequisites:** [migrate/README.md](migrate/README.md#prerequisites) — Azure subscription, a SQL Server 2019 source (VM stand-in), DMS.
- **Build / run:** stand up the SQL 2019 source (`migrate/scripts/01-source-sql2019/`) → run the DMS migration (`migrate/scripts/02-migrate-dms/`, or the VS Code skill) → *(optional)* modernize (`migrate/scripts/03-optimize/`).
- **Result:** `ZavaLendingDB` on Hyperscale, modernized (compat 170, columnstore, automatic index compaction).
- **Review the app:** open the [customer](application/loan-platform-customer/index.html) + [internal](application/loan-platform-internal/index.html) front-ends (UI mockups) to see what the migrated database powers — overview [application/README.md](application/README.md).
- **Copilot:** *"Run Act 1"* — skill [`zava-act1-migrate`](.github/skills/zava-act1-migrate/SKILL.md).

### Act 2 — Scale → [scale/README.md](scale/README.md)
- **Prerequisites:** none — this act ships as a self-contained dashboard; a modern browser is all you need.
- **Walkthrough:** read the scaling concepts (vCore scaling, serverless, named read replicas) → open the customer + internal front-ends → open the scale dashboard and step/play through its 8 phases (32 → 192 vCores).
- **Result:** see how online vCore scaling and read replicas absorb launch-day growth.
- **Copilot:** *"Run Act 2"* — skill [`zava-act2-scale`](.github/skills/zava-act2-scale/SKILL.md).

### Act 3 — AI → [ai/README.md](ai/README.md)
- **Prerequisites:** a populated `ZavaLendingDB` from **Act 1** (Act 2 not required) + an Azure AI resource with `text-embedding-3-large` and Phi-4. Detail: [ai/build/README.md](ai/build/README.md#prerequisites).
- **Build:** run `ai/build/sql/00`→`04` — narratives → embeddings → vector index → search procedure → scoring procedure. See [ai/build/README.md](ai/build/README.md).
- **Walkthrough:** run `ai/walkthrough/sql/` (Narrative Search, DML, `WITH APPROXIMATE`, execute scoring), then *(optional)* the loan-scoring agent (DAB/MCP/Foundry). See [ai/walkthrough/README.md](ai/walkthrough/README.md).
- **Copilot:** *"Run Act 3"* — skill [`zava-act3-ai`](.github/skills/zava-act3-ai/SKILL.md).

---

## Conventions

- **Fictional customer:** ZavaFin / Zava Lending — any resemblance to real entities is
  coincidental. All data is synthetic.
- **Database:** `ZavaLendingDB` throughout.
- **Secrets:** passwords are entered only at masked terminal prompts — never in chat and
  never committed.

---

## Repository Layout

```
azuresqlfoundations/
├── .github/
│   └── skills/
│       ├── zava-hyperscale-workshop/ # orchestrator skill ("go through the workshop")
│       ├── zava-act1-migrate/        # Act 1 — DMS migration + modernize runbook
│       ├── zava-act2-scale/          # Act 2 — scale dashboard guide
│       └── zava-act3-ai/             # Act 3 — vector search + AI scoring guide
├── migrate/                          # Act 1 — Migrate & Modernize
│   └── scripts/
│       ├── 01-source-sql2019/        #   stand up + seed the SQL 2019 source
│       ├── 02-migrate-dms/           #   the complete az datamigration CLI migration
│       └── 03-optimize/              #   optional post-migrate modernization
├── scale/                            # Act 2 — Scale on Hyperscale (interactive scale dashboard + apps)
└── ai/                               # Act 3 — Vector search + AI scoring (scripts, agent, MCP)
```

---

## Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft
trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.

---