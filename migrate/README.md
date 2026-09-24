# Act 1 — Migrate & Modernize: SQL Server 2019 → Azure SQL Hyperscale

> 📺 Part of the [Azure SQL Foundations video series & workshop](../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

Migrate the fictional **ZavaFin** lending database (`ZavaLendingDB`) from an on-prem **SQL
Server 2019** instance to **Azure SQL Database Hyperscale**, then modernize it in place.
This is the companion to the Act 1 video — watch along or work straight through at your own
pace.

By the end you will have:

1. A SQL Server 2019 source database (compatibility level 150) to migrate from.
2. That database running on Azure SQL Hyperscale via Azure Database Migration Service (DMS).
3. A modernized Hyperscale database: compat 170, a columnstore fact table, and automatic
   index compaction.

The same `ZavaLendingDB` is carried forward into **Act 2 (Scale)** and **Act 3 (AI)**.

---

## What you'll build

```
   ON-PREMISES (VM stand-in)             AZURE
  ┌────────────────────┐               ┌──────────────────────────────────────┐
  │ SQL Server 2019    │   Azure DMS   │  Azure SQL Database — Hyperscale      │
  │ ZavaLendingDB      │  (offline)    │  ZavaLendingDB                        │
  │ Compat level 150   │  ──────────►  │  Lands at compat 150, then modernized │
  │ Rowstore tables    │   scheduled   │  Step 3a: compat 150 → 170 (IQP)      │
  │ Manual index jobs  │    window     │  Step 3b: rowstore → columnstore      │
  │ SAN nearly full    │               │  Step 3c: automatic index compaction  │
  └────────────────────┘               └──────────────────────────────────────┘
                                                        │
                                            Act 2: scale to 192 vCores
                                            Act 3: vector search + AI scoring
```

**Why offline migration?** DMS migrations to **Azure SQL Database targets (including
Hyperscale) are offline only** — the data copy is a point-in-time snapshot, so writes on
the source during the copy are not carried over. Online/continuous-sync migration exists
only for Azure SQL Managed Instance and SQL Server on Azure VM, not Azure SQL Database.
Plan a cutover window. *(Reference: [DMS offline tutorial](https://learn.microsoft.com/data-migration/sql-server/database/database-migration-service).)*

---

## Prerequisites

- An **Azure subscription** where you can create a VM, a logical server + Hyperscale
  database, and a Database Migration Service.
- **Azure CLI** with the `datamigration` extension (Step 2 installs it).
- **SSMS 22** or the **VS Code MSSQL extension** to run T-SQL and compare schemas.
- **VS Code + GitHub Copilot (Agent mode)** if you want the guided, prompt-driven
  migration (recommended).
- A Windows host that can reach the source as `localhost` — the source VM itself works well
  and doubles as the SHIR host.

---

## The steps

Each step has its own detailed runbook next to the scripts. Work through them in order.

### Step 1 — Stand up the SQL Server 2019 source

Provision the VM stand-in, initialize its disks, and build + seed `ZavaLendingDB` at
compatibility level 150 (rowstore `LoanTransactions`). Skip if you already have a SQL Server
source.

➡️ **[scripts/01-source-sql2019/README.md](scripts/01-source-sql2019/README.md)**

### Step 2 — Migrate to Hyperscale with DMS (offline)

Assess the source, provision the Hyperscale target, stand up the DMS + SHIR, then migrate
schema-first and copy the data. The database lands on Hyperscale **still at compat 150** —
migration is faithful. Two ways to run it:

- **Guided (recommended)** — open [scripts/02-migrate-dms/prompts.md](scripts/02-migrate-dms/prompts.md)
  and drive it with GitHub Copilot in **Agent mode**; it runs one approved phase at a time.
- **CLI yourself** — run the numbered `az datamigration` scripts directly.

➡️ **[scripts/02-migrate-dms/README.md](scripts/02-migrate-dms/README.md)** ·
skill: [SKILL.md](../.github/skills/zava-act1-migrate/SKILL.md)

**Validate:** point a query window at the Hyperscale endpoint, confirm the database is
present and still at compat 150, and spot-check row counts table-for-table.

```sql
SELECT compatibility_level FROM sys.databases WHERE name = 'zavalending';  -- 150
```

### Step 3 — Modernize on Hyperscale (optional)

Now do what you never could on-prem: compat 150 → 170 (intelligent query processing),
rowstore → clustered columnstore, and hands-off automatic index compaction.

➡️ **[scripts/03-optimize/README.md](scripts/03-optimize/README.md)**

**Next:** continue to **Act 2 (`scale/`)** to scale the database to 192 vCores.

---

## Things to know (so it holds up under questioning)

- **DMS to Azure SQL Database (incl. Hyperscale) is offline only.** Don't expect near-zero
  downtime via DMS for this target — that's Managed Instance / SQL on Azure VM only. Frame
  it as a scheduled cutover window.
- **Schema must exist first.** The data copy won't create tables on an Azure SQL Database
  target — deploy the schema before the data.
- **A SHIR is always required**, even Azure-to-Azure. Hosting it on the source VM keeps the
  source connection on `localhost`.
- **Never hardcode connection-string passwords.** Type them at the prompt or use a secret.
- **Automatic index compaction is in preview.** It acts on B-tree leaf pages only, so it
  complements — doesn't overlap — the columnstore conversion.

---

## Folder map

| Folder | Step | Detailed runbook |
|--------|------|------------------|
| [scripts/01-source-sql2019/](scripts/01-source-sql2019/) | 1 — Source | Stand up + seed the SQL 2019 source (VM stand-in) |
| [scripts/02-migrate-dms/](scripts/02-migrate-dms/) | 2 — Migrate | The `az datamigration` CLI migration + `prompts.md`, driven by the skill |
| [scripts/03-optimize/](scripts/03-optimize/) | 3 — Modernize | compat 170 → columnstore → automatic index compaction |
