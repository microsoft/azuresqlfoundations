# cloudborn — "Start from Hyperscale" build scripts

> 📺 Part of the [Azure SQL Foundations video series & workshop](../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

> ⚠️ **Use these scripts ONLY when starting cloud-born** — i.e. you are building
> ZavaLendingDB **fresh on Azure SQL Hyperscale** from scratch.
>
> **Do NOT run these after a Demo 1 migration.** If the database arrived via the
> on-prem **SQL Server 2019 → Hyperscale migration** (Demo 1), the data already
> exists. These scripts **DROP / TRUNCATE / regenerate** the core tables and will
> **wipe the migrated data**.

## What's in here

These are the from-scratch data-build scripts. They create the schema and load
the full baseline data volumes that Demo 2 Phase 1 expects.

| Script | Purpose |
|--------|---------|
| `01-setup-zava-lending-db.sql` | Create base schema + seed sample data |
| `03-add-loan-narratives.sql` | Add loan narratives + full-text index |
| `04-scale-schema.sql` | **DROPs** + recreates scale tables (CCI) |
| `step1-setup-db.ps1` | Runs `01` |
| `step2-replica-queries.ps1` | Named replica reporting setup |
| `step3-add-narratives.ps1` | Runs `03` |
| `step4-scale-schema.ps1` | Runs `04` |
| `step5-generate-data.ps1` | Generates CSV data (`./data`) |
| `step6-load-data.ps1` | **TRUNCATE + bcp load** CSVs, then create workload procs |

## Migration path (Demo 1) — what to run instead

After migrating the SQL 2019 source into Hyperscale, the data is already present.
**Skip everything in this folder.** Run only the shared steps from the parent
`scripts/` + `workload/` folders:

1. `../workload/setup-workload-procs.sql` — self-healing; adds the few columns /
   indexes the workload needs (idempotent, non-destructive).
2. The workload phases / `step7-run-workload.ps1`.
3. Monitoring & analysis tooling (`05-monitoring-queries.sql`, `compare-*`, `show-*`).

## Orchestrators

`../run-scale-demo.ps1` and `../run-demo2.ps1` invoke these scripts via the
`cloudborn\` path and are themselves part of the **cloud-born** flow.
