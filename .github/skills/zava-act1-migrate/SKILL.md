---
name: zava-act1-migrate
description: 'Act 1 of the Zava Lending Hyperscale workshop — Migrate & Modernize — and the standalone, approve-each-step runbook to migrate ANY on-prem / IaaS SQL Server database to Azure SQL Database Hyperscale using the local `az datamigration` CLI. USE WHEN the user wants to run "Act 1" / "the migrate act", stand up the SQL Server 2019 source, migrate ZavaLendingDB to Hyperscale, or modernize after migrating (compatibility level 170 / intelligent query processing, rowstore → clustered columnstore, automatic index compaction); OR for any SQL Server → Hyperscale migration: verifying migration prerequisites / "make sure the pre-reqs are installed", assessing a SQL Server instance for Azure SQL readiness, finding migration blockers/issues, provisioning a Hyperscale target (the create-time-only zone-redundancy decision), creating a Database Migration Service (DMS) + Self-Hosted Integration Runtime (SHIR), migrating schema then data offline, validating row counts, running any of the scripts/ files (00-setup, 01-assess, 02-provision, 03-dms-shir, 04-migrate, 05-validate, 99-teardown, verify-service-broker, validate-migration), or tearing down / resetting the migration to run it again.'
---

# Act 1 — Migrate & Modernize (Zava Lending)

Migrate ZavaFin's on-prem **SQL Server 2019** `ZavaLendingDB` to **Azure SQL Database
Hyperscale** (offline, via DMS), then modernize it on the new platform. Narrative:
[migrate/README.md](../../../migrate/README.md).

Act 1 has **three steps** — do them in order:

1. **Stand up the source** (below).
2. **Migrate to Hyperscale with DMS** — the approve-each-step runbook that forms the
   bulk of this skill (from *The runbook* through *Minimal-downtime alternatives*).
3. **Modernize on Hyperscale** (compat 170, columnstore, automatic index compaction).

> Step 2's runbook is also usable **standalone** for any SQL Server → Hyperscale
> migration, not just Zava — every environment value is a parameter.

## Step 1 — Stand up the source (SQL Server 2019 stand-in)

Folder: [migrate/scripts/01-source-sql2019/](../../../migrate/scripts/01-source-sql2019/).
Provision + seed a SQL Server 2019 instance (a VM stand-in for "on-prem") holding
`ZavaLendingDB` — the database Step 2 migrates. Skip this if you're migrating your own
existing SQL Server.

## Step 2 — Migrate to Hyperscale with DMS

A parameter-driven runbook for moving a single user database from an
on-prem / Azure VM SQL Server instance to **Azure SQL Database Hyperscale** using
the local **`az datamigration`** CLI (the same engine as the portal DMS wizard).

The runnable scripts live in **`migrate/scripts/02-migrate-dms/`** in this workspace.
Drive them with this skill, or run the individual `*.ps1` / `*.sql` files by hand. The
T-SQL files (`verify-service-broker.sql`, `validate-migration.sql`) also run directly
in SSMS or the VS Code MSSQL extension.

> All scripts live in `migrate/scripts/02-migrate-dms/`. The `.\NN-*.ps1` launch path
> is **relative**, so every phase command must run from that folder. Don't assume the
> active terminal is already there — a prior step may have left it elsewhere.
> **Always `cd` into the scripts folder in the same command** before invoking a phase
> script:
>
> ```powershell
> Set-Location 'C:\azuresqlfoundations\migrate\scripts\02-migrate-dms'
> .\04-migrate.ps1 ...
> ```
>
> The scripts themselves are location-independent once launched (they resolve helpers
> via `$PSScriptRoot`); only the launch token needs the right cwd.

> **Every phase script logs to a file.** Each run tees its full console output to
> `C:\dms\logs\<phase>-<timestamp>.log` (override the dir with `$env:DMS_LOG_DIR`),
> mirrors the latest to `C:\dms\logs\<phase>-latest.log`, and records the active
> path in `C:\dms\logs\last-run.txt`. Read those files to check a run's result
> reliably instead of scraping the live terminal — the transcript is flushed
> continuously, so the log is complete even if the script throws. No secrets are
> written (masked password prompts aren't echoed; scripts never print connection
> strings). Implemented by `_log.ps1` (`Start-PhaseLog` / `Stop-PhaseLog`).

## Five phases (plus Phase 0 and teardown)

| Phase | Script | What it does |
|-------|--------|--------------|
| **0** Setup | `00-setup.ps1` | Install the `datamigration` CLI extension; optionally register providers |
| **1** Assess | `01-assess.ps1` | List migration issues/blockers; verify Service Broker usage |
| **2** Provision Hyperscale | `02-provision.ps1` | Logical server + empty Hyperscale DB + firewall (+ Entra admin, ZR decision) |
| **3** DMS + SHIR | `03-dms-shir.ps1` | Create the DMS and register the SHIR on this machine |
| **4** Migrate | `04-migrate.ps1` | **4pre** DMS limitation check, **4a** deploy schema, **4b** copy data, then wait |
| **5** Validate | `05-validate.ps1` | Compare object counts + per-table row counts, source vs target |
| Teardown | `99-teardown.ps1` | Delete the DB/DMS/server to reset for a repeat run |

## Single-box assumption

This runbook assumes **DMS and the SHIR run on this machine**, and that the source
SQL Server is reachable as `localhost` here. That keeps the source connection on
`localhost` and means you run every phase from one place. (If your SHIR must live on
a separate host with line-of-sight to the source, register it there in Phase 3 and
use the SQL Server's hostname instead of `localhost`.)

## Scope and hard truths (read first)

- **Source:** SQL Server 2008 or later (on-prem, Azure VM, EC2, RDS, GCE).
- **Target:** Azure SQL Database, Hyperscale service tier (e.g. `HS_Gen5_2`).
  Hyperscale is a target like any other Azure SQL DB — pick a Hyperscale SKU on the
  target database; there is no special "Hyperscale migration" path.
- **DMS to Azure SQL Database is OFFLINE ONLY.** The data copy reads a point-in-time
  snapshot of the source; changes made on the source after the copy starts are not
  carried over. Online/continuous-sync DMS exists only for SQL Managed Instance and
  SQL VM targets — not Azure SQL Database.
- For near-zero downtime to Azure SQL Database, DMS is not the tool — see
  [Minimal-downtime alternatives](#minimal-downtime-alternatives).
- **Zone redundancy is a CREATE-TIME-ONLY decision for Hyperscale** — it cannot be
  changed after the database is created. See [Zone redundancy](#zone-redundancy).
- **Reverse migration is NOT available** for a SQL-Server-sourced migration. Going
  back means another data movement, not a tier flip.

## How the agent must run this (approve-each-step)

This runbook performs irreversible and billable actions (creating Azure resources).
Follow these rules:

1. **One phase at a time.** Present the phase, show the **exact command** you will
   run (with the user's real values filled in), and state what it changes —
   especially whether it **creates Azure resources or costs money**.
2. **Wait for explicit approval** before executing each phase. Never chain phases.
3. **Never invent identity values.** The scripts have **no defaults** — collect
   every value from the user first (see *Values you must collect*). If a value is
   missing, ask; do not guess subscription IDs, server names, etc.
4. **Run PowerShell synchronously** and report the exit code. Stop on any non-zero
   exit and diagnose before continuing.
5. **Secrets:** target/admin passwords are entered directly into the terminal as
   masked prompts. Never ask for a password through chat, and never echo one.

## Prerequisites

- Azure CLI with the `datamigration` extension (Phase 0 installs it).
- An Azure subscription where you can create a DMS, a logical server, and a DB.
- The **source SQL Server** reachable as `localhost` from this machine.
- Network: the target logical server firewall must allow this machine's egress.

## Values you must collect (no defaults exist)

Ask the user for these before starting; pass them as parameters every phase.

| Value | Used by | Notes |
|-------|---------|-------|
| Subscription ID | 0, 2, 3, 4 | `az login` first |
| Resource group | 2, 3, 4 | created if missing by Phase 2 |
| Location / region | 2, 3 | e.g. `eastus2` |
| Source connection string | 1 | ADO.NET; point at `master`; Win or SQL auth |
| Source server / database | 1, 4, 5 | `localhost` + the user DB name |
| Target server name + FQDN | 2, 4, 5 | globally unique; `<name>.database.windows.net` |
| Target database name | 2, 4, 5 | the Hyperscale DB |
| Target admin/SQL user | 2, 4, 5 | password entered at the masked prompt |
| Hyperscale shape | 2 | compute model, vCores, (HA replicas / ZR — see below) |
| Entra admin (optional) | 2 | display name + object ID (mixed-mode) |
| DMS name | 3, 4 | the SQL Migration Service |

## The runbook

Each step lists the command and **what to approve**. Substitute `<...>`
placeholders with the collected values. All paths are relative to
`migrate/scripts/02-migrate-dms/`.

### Phase 0 — Setup (verify prerequisites)
Use this for prompts like *"make sure the pre-reqs are installed."* The script
checks the Azure CLI is present and **installs/updates** the `datamigration`
extension. Pass `-SubscriptionId` to ALSO confirm sign-in and **register** the
providers; omit it to just install the extension. Idempotent.
```powershell
.\00-setup.ps1                          # just install the CLI extension
.\00-setup.ps1 -SubscriptionId <sub>    # extension + register providers
```
*Approve:* installs a CLI extension; with `-SubscriptionId`, also registers
`Microsoft.DataMigration` / `Microsoft.Sql`. It does **not** install the base
Azure CLI or the SHIR MSI — it tells you if those are missing.

### Phase 1 — Assess  *(read-only)*
The **only** thing this phase determines is **compatibility**: whether any source
feature or configuration conflicts with the Hyperscale (Azure SQL Database) target.
It lists those incompatibilities/blockers and auto-verifies any Service Broker
finding (enabled vs. actually used). It does **not** judge whether Hyperscale is
the right tier, and it does **not** size compute — SKU sizing and performance-data
collection are out of scope (use `az datamigration performance-data-collection` +
`get-sku-recommendation` separately if you want that).
```powershell
.\01-assess.ps1 -SourceConnectionString 'Data Source=localhost;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True'
```
*Approve:* none needed — read-only, creates no Azure resources. **Review the
findings together before continuing.** SSMS alternative for the broker check:
`verify-service-broker.sql` against the user DB. If the assessment flags Service
Broker as **ENABLED BUT UNUSED**, disable it on the source before migrating:
`ALTER DATABASE [<db>] SET DISABLE_BROKER WITH ROLLBACK IMMEDIATE;`

### Phase 2 — Provision Hyperscale (interactive)
Creates the logical server, an empty Hyperscale DB, and firewall rule(s); optionally
sets a mixed-mode **Entra ID admin**. The script has **no identity defaults** — pass
every environment value; you are prompted for the admin password as a masked
SecureString. It also **prompts for the zone-redundancy decision** (see below).

> **Detect an existing logical server first.** Once the user gives the **resource
> group**, list the logical servers already in it before asking for a server name:
> ```powershell
> az sql server list -g <rg> --query "[].name" -o tsv
> ```
> - If one or more exist, **show them and ask whether to reuse one** (e.g. "Found
>   logical server `zavafinlogicalserver` in `<rg>` — reuse it, or create a new
>   one?"). If the user reuses it, pass that name as `-ServerName`; creating the DB
>   on an existing server is idempotent and the firewall rule re-add is a no-op, so
>   the admin user/password must match the existing server's. Skipping a needless
>   new server is the common case for a repeat run where teardown kept the server.
> - If none exist (or the user wants a fresh one), collect a **globally unique**
>   server name as before.
>
> Do not silently pick a server — always confirm reuse-vs-create with the user.

```powershell
.\02-provision.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
    -Location <region> -ServerName <unique-server> -DatabaseName <db> `
    -AdminUser <user> -Capacity <vcores> -ClientIpAddress <your-ip>
```
Optional Entra admin (mixed-mode; keeps the SQL admin that DMS writes with):
`-EntraAdminName <upn-or-group>` — the object ID is resolved automatically (pass
`-EntraAdminObjectId <guid>` too only if you want to skip the lookup). With no
Entra parameter and no `-NonInteractive`, the script prompts whether to add one.
*Approve:* **creates billable Azure resources** (logical server + Hyperscale DB).

#### Zone redundancy
For Hyperscale, zone redundancy can **only** be set at create time and cannot be
changed later in place — adding it afterward means redeploying the database
(copy / point-in-time restore / geo-replica) and repointing the connection string.
`02-provision.ps1` therefore **prompts** you to decide unless you pass
`-ZoneRedundant` or `-NonInteractive`. Choosing yes auto-sets the two prerequisites
Hyperscale requires: **one HA replica** (`-HaReplicas 1`) and **zone-redundant
backup storage** (`-BackupStorageRedundancy Zone`). There is no extra compute cost
for ZR beyond the HA replica it requires. Default is no replicas, no ZR.

> **Explain ZR to the user — don't assume they know it.** Most users won't know
> what zone redundancy is or that it's a one-way, create-time-only choice. When you
> reach the provision step, **proactively raise it** and explain in plain language
> before asking them to decide:
> - It spreads the database across availability zones so it survives a datacenter-
>   zone failure.
> - It can **only** be turned on **now, at create time** — you cannot add it later
>   without redeploying the database, so decide up front.
> - Turning it on **requires one HA replica** (and zone-redundant backup storage),
>   which the script adds automatically. The replica is the only added cost; there's
>   no extra ZR surcharge beyond it.
>
> Then ask: "Do you want zone redundancy? (yes adds 1 HA replica + zone-redundant
> backup)". Only after the user answers do you pass `-ZoneRedundant` (or omit it).

### Phase 3 — DMS + SHIR
Creates the DMS, reads its auth key, and registers the SHIR on this machine in one
step. Add `-IrPath <IntegrationRuntime.msi>` to install the runtime first
(download: https://aka.ms/sql-migration-shir-download), or `-InstalledIrPath` if
it's installed but not auto-detected.
```powershell
.\03-dms-shir.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -Location <region> -DmsName <dms-name>
```
*Approve:* **creates a billable DMS resource** and installs/registers the SHIR
locally.

### Phase 4 — Migrate (4pre check, 4a schema, then 4b data)

> **Discover the DMS name from Azure — never guess it.** Phase 4 needs `-DmsName`,
> and the right value is whatever Database Migration Service already exists in the
> resource group. **Do not** carry a DMS name over from memory, a prior chat, or a
> hard-coded example. Once the resource group is known, list the services first:
> `az datamigration sql-service list -g <rg> --query "[].name" -o tsv`.
> If exactly **one** is returned, use it as `-DmsName`. If **more than one** is
> returned, show the list and ask the operator which to use. If **none** is returned,
> Phase 3 has not run — create the DMS + SHIR first. This grounds the name in live
> Azure truth and prevents the "wrong DMS name" failure (4b is the only step that
> actually uses the DMS, so a stale name silently passes 4a then fails 4b).

One phase, three steps. **4pre** scans the *source* for DMS data-copy limitations
that the Phase 1 compatibility assessment does **not** catch (they are migration-
*tool* limits, not target incompatibilities): >100k tables, double-byte table
names, reserved-word/semicolon DB names (all **BLOCKERS**), plus computed columns,
large LOB/blob columns, and NULL default constraints (**WARNINGS**). A BLOCKER
verdict stops the migration before the cutover window; warnings print and proceed.
Then **4a** deploys the schema first (the data copy does not create tables), and
**4b** starts the offline data copy and **waits for it to finish** (polls
`az datamigration sql-db show` until Succeeded/Failed/Canceled). You are prompted
once for the target password; it is reused for both sub-steps.

> **Per-table copy progress (`-ShowCopyProgress`).** By default the 4b poll prints
> only the coarse `migrationStatus` / `migrationState`. Add **`-ShowCopyProgress`** to
> also print the per-table detail on each poll (table, status, rows read/copied,
> MB) from the status payload's `listOfCopyProgressDetails`. Note: for an **Azure SQL
> Database** target that list is **empty until the copy phase actually starts
> streaming tables** (states `StartSqlDataCopy` → early `MonitorMigration` show no
> rows), then fills in per table — so an empty list early on is expected, not a bug.
> For an exact live row count you can also query the target directly
> (`sys.dm_db_partition_stats`).

> **The SHIR needs SQL auth on the source.** The SHIR runs as the virtual account
> `NT SERVICE\DIAHostService`, which cannot be passed as a credential, and there is
> **no working Windows-auth recipe** for the SHIR's source connection — every
> documented DMS data-copy example authenticates the source with **SQL auth**. So
> the *local* schema step (4a) uses Windows auth, but the *SHIR* data copy (4b)
> needs a SQL login. Put the source in **mixed mode** and create a dedicated
> read-only login (the runbook used `db_datareader` + `VIEW DATABASE STATE` +
> `VIEW DEFINITION`), then pass `-SourceSqlUser <login>` — Phase 4 prompts for its
> password and uses SQL auth only for 4b.

```powershell
.\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
    -SourceServer localhost -SourceDatabase <db> `
    -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
    -TargetDatabase <db> -TargetSqlUser <user> -SourceSqlUser <source-login>
```
Options: `-SchemaAction GenerateScript` to review/edit the DDL before deploying
(then re-run with `-SchemaAction DeploySchema -InputScriptFilePath <file>`);
`-TableList '[dbo].[A]','[dbo].[B]'` to copy specific tables;
`-SkipDmsLimitationCheck` to skip 4pre; `-Force` to proceed past a BLOCKER verdict;
`-SkipSchema` to skip 4a (e.g. the schema was already deployed by a prior run);
`-SchemaOnly` to deploy the schema and **stop before the data copy**;
`-SourceSqlUser <login>` to use SQL auth for the SHIR data copy (see note above).
You can also run the pre-check standalone:
`sqlcmd -S localhost -E -d <db> -i migrate\scripts\02-migrate-dms\check-dms-limitations.sql`.

**Staged "migrate the schema, let me verify, then migrate the data" flow.** When the
operator wants to deploy the schema, check it with **Schema Compare** (VS Code MSSQL
extension or SSMS), and only then copy the data, run Phase 4 as **two** invocations —
map their natural-language prompts to these commands:

- Prompt like *"migrate the schema first and let me verify it"* → **schema only**,
  stop before the data copy (deploys straight to the target, no script file):
  ```powershell
  .\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
      -SourceServer localhost -SourceDatabase <db> `
      -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
      -TargetDatabase <db> -TargetSqlUser <user> -SchemaOnly
  ```
  Prompts only for the **target** password (4a is local Windows auth — no source
  login needed yet). Then the operator verifies the schema (see below).
- Prompt like *"the schema checks out — now migrate the data"* → **data only**,
  skip re-deploying schema, copy via the SHIR with SQL auth:
  ```powershell
  .\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
      -SourceServer localhost -SourceDatabase <db> `
      -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
      -TargetDatabase <db> -TargetSqlUser <user> -SkipSchema -SourceSqlUser <source-login>
  ```
  Prompts for the **target** then the **source** (`dms_reader`) password, then polls
  the data copy to completion. Add **`-ShowCopyProgress`** to print per-table rows on
  each poll.

**Verify the schema in VS Code (no SSMS needed).** At the schema-only checkpoint, use
the **MSSQL extension's Schema Compare** — Command Palette → **MSSQL: Schema Compare**
(or right-click the source database in the MSSQL **Object Explorer** → **Schema
Compare**). Set **source** = `localhost` / `<SourceDatabase>` and **target** =
`<server>.database.windows.net` / `<TargetDatabase>` (both live connections), tune
**Options** if needed, then **Compare**. Same DacFx engine and options as SSMS Schema
Compare, all inside VS Code. (Database-to-database is built into the MSSQL extension;
the richer database-vs-SQL-project compare additionally needs the SQL Database Projects
extension + .NET 8 SDK.) SSMS Schema Compare remains a valid alternative if you prefer it.

> **Bonus: the staged flow yields a cleaner Schema Compare.** The schema tool's
> `__migration_status` bookkeeping table is created by the **data copy** (4b), not the
> schema deploy (4a). So when you run Schema Compare at the schema-only checkpoint
> (after 4a, before 4b), `__migration_status` does not exist yet and is **not** flagged
> — the only difference is the source-only migration login (e.g. `dms_reader`). Verify
> here for the cleanest comparison; if you compare *after* the data copy, expect
> `__migration_status` to show as a droppable target-only object.

**Schema errors are surfaced, not swallowed.** After 4a, the runbook reads *this
run's* object-level deploy errors from the schema tool's event log
(`%LOCALAPPDATA%\Microsoft\SqlSchemaMigration\Logs\SchemaMigrationEvent-*.log`),
prints them as numbered **warnings**, and **prompts before the data copy**
(`Proceed to DATA COPY anyway? [y/N]`). Many are benign — e.g. the dedicated source
*migration login* gets scripted onto the target where it collides with the admin
(`The login already has an account with the user name 'dbo'`). Review, then answer
`y` to continue or Enter/`N` to stop. Pass `-ContinueOnSchemaError` (or `-Force`) to
skip the prompt in non-interactive runs.

*Approve:* writes schema + data into the target DB. The data copy is an offline,
read-only snapshot of the source — it never writes to the source.


### Phase 5 — Validate  *(read-only)*
Runs `validate-migration.sql` against the source and the target, then compares
object counts + per-table row counts and reports PASS/FAIL. The comparison
**excludes** the schema tool's `__migration_status` bookkeeping table (it is
created only on the target), so a clean migration reports PASS without manual
cleanup — don't drop that table to make counts line up.
```powershell
.\05-validate.ps1 -SourceDatabase <db> `
    -TargetServerFqdn <server>.database.windows.net -TargetDatabase <db> -TargetSqlUser <user>
```
SSMS alternative: run `validate-migration.sql` by hand on both sides and compare.
*Approve:* read-only. Counts should match table-for-table.

### Teardown / reset for a repeat run
Delete the Azure resources this runbook created so you can run it again from a
clean slate. Idempotent. **Destructive:** the script confirms (type `delete`)
unless `-Force`.
```powershell
# Full clean slate — drop the DB, the DMS, and the logical server:
.\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
    -ServerName <server> -DatabaseName <db> -DmsName <dms-name>

# Keep the server, only drop the migrated DB + DMS:
.\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
    -ServerName <server> -DatabaseName <db> -DmsName <dms-name> -KeepServer

# Nuke the whole resource group (only if it holds nothing else):
.\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DeleteResourceGroup
```
*Approve:* destructive ARM deletes, in dependency order (DB → DMS → server). An
**in-progress migration must finish or be cancelled** before its DMS can be deleted.
After teardown, re-run from Phase 2.

## Abort / rollback

- **Before Phase 4:** safe to stop anytime. To undo Azure spend, run
  `99-teardown.ps1` (see *Teardown / reset*).
- **After the data copy:** the source is untouched (offline copy reads it, never
  writes). To roll back, keep using the source and drop the target resources.

## Limitations

DMS Azure SQL Database offline migration uses Azure Data Factory pipelines under the
hood and inherits these constraints:

- **Online migration to Azure SQL Database is not supported** (offline only).
- 100,000 tables per database limit; scales poorly with very high table counts.
- Table names with **double-byte characters** are not supported (rename, migrate, rename back).
- Tables with large blob columns may time out.
- Database names with **SQL Server reserved words** or **semicolons** are not supported.
- **Computed columns are not migrated.**
- Source columns with default constraints containing `NULL` are migrated with the
  **defined default value** on the target, not the original `NULL`.

## Minimal-downtime alternatives

DMS has **no first-party online path to Azure SQL Database**. For minimal downtime:

- Third-party CDC-based replication (e.g. Qlik Replicate, Striim, Cloudamize).
- Application-coordinated cutover patterns.
- Accept the offline window after testing it against the real database size.

## Step 3 — Modernize on Hyperscale (optional but recommended)

With `ZavaLendingDB` now on Hyperscale, modernize it on the new platform. Run in order
from [migrate/scripts/03-optimize/](../../../migrate/scripts/03-optimize/):

1. `01-compatibility-level.sql` — raise the database compatibility level to **170**
   (intelligent query processing).
2. `02-columnstore.sql` — convert rowstore → **clustered columnstore**.
3. `03-auto-index-compaction.sql` — enable **automatic index compaction** (preview).

See [migrate/scripts/03-optimize/README.md](../../../migrate/scripts/03-optimize/README.md).

## Step 4 — Review the app (exercise)

Now that `ZavaLendingDB` is on Hyperscale, open the platform's front-ends to see what the
migrated database powers — this is the **first** time in the workshop the app is shown:

- **Customer site** — [application/loan-platform-customer/index.html](../../../application/loan-platform-customer/index.html): the borrower-facing experience.
- **Internal operations console** — [application/loan-platform-internal/index.html](../../../application/loan-platform-internal/index.html): the staff-facing console.

Both are **static UI mockups** (mocked data, no server) — they illustrate the UX, not live
data. The same apps reappear in **Act 2** (same console on the scaled database), and **Act 3**
adds an AI menu. Overview: [application/README.md](../../../application/README.md).

## Result & next act

`ZavaLendingDB` is now on Hyperscale and modernized — the database **Act 3 (AI)** builds
on. Continue to **Act 2 (Scale)** via the `zava-act2-scale` skill, or jump to **Act 3
(AI)** via `zava-act3-ai` (Act 2 is not required for Act 3).

## Hyperscale notes

- **Log rate** on Hyperscale is a flat **100 MB/s** regardless of service objective.
  Do not apply the General Purpose / Business Critical log-rate scaling guidance to
  a Hyperscale target.
- Scale the target **up** during ingestion to relieve CPU, then scale back after —
  Hyperscale compute scaling is fast and does not move data.
- **HA replicas and zone redundancy** are independent of the migration. You can
  start with 0 replicas and add them later as a separate optimization — but zone
  redundancy itself is create-time-only (see [Zone redundancy](#zone-redundancy)).

## Key facts

- **Offline only.** DMS → Azure SQL Database (incl. Hyperscale) has no online mode;
  the data copy is a point-in-time snapshot of the source.
- **Schema before data.** Phase 4 does 4a (schema) before 4b (data) for you.
- **Zone redundancy is create-time-only** for Hyperscale and requires 1 HA replica
  + zone backup storage. Phase 2 prompts you to decide.
- **SHIR always required**, even Azure-to-Azure; this runbook registers it on this
  machine so the source connection stays `localhost`.
- **SHIR source auth = SQL auth.** The SHIR runs as `NT SERVICE\DIAHostService` and
  has no working Windows-auth recipe for the source data copy. Put the source in
  mixed mode, create a read-only SQL login (`db_datareader` + `VIEW DATABASE STATE`
  + `VIEW DEFINITION`), and pass `-SourceSqlUser`. The local schema step still uses
  Windows auth.
- **Schema deploy errors are reviewable, not fatal.** Phase 4 lists this run's
  object-level schema errors as warnings and prompts before the data copy; a
  source-only migration login colliding with the target admin is the common benign
  case. The validator ignores the tool's `__migration_status` table — don't drop it
  to force a PASS.
- **Service Broker enabled ≠ used.** SQL Server enables it by default at
  `CREATE DATABASE`; DMS flags the option regardless. `verify-service-broker.sql`
  proves whether any user broker objects exist.
- **No defaults** are baked into any script — every environment value is mandatory.

## File inventory

All files live in `migrate/scripts/02-migrate-dms/`.

| File | Phase | Notes |
|------|-------|-------|
| `00-setup.ps1` | 0 setup | install extension / register providers |
| `01-assess.ps1` | 1 assess | read-only assessment |
| `verify-service-broker.sql` | 1 (broker proof) | SSMS / source |
| `02-provision.ps1` | 2 provision Hyperscale | server + DB + firewall + Entra + ZR prompt |
| `03-dms-shir.ps1` | 3 DMS + SHIR | create DMS, register SHIR locally |
| `04-migrate.ps1` | 4 migrate | 4pre DMS check + 4a schema + 4b data + wait |
| `check-dms-limitations.sql` | 4 migrate | source scan for DMS data-copy limitations |
| `05-validate.ps1` | 5 validate | row-count compare |
| `validate-migration.sql` | 5 validate | SSMS / both sides |
| `99-teardown.ps1` | teardown / reset | delete DB/DMS/server |
| `_resolve-az.ps1` | helper | puts `az` on PATH for the session |
| `prompts.md` | ready-to-paste prompts | — |
| `README.md` | human reference for the scripts | — |

## Command reference

| Task | Script | Azure CLI (az) |
| --- | --- | --- |
| Setup | `00-setup.ps1` | `az extension add datamigration` |
| Assess source | `01-assess.ps1` | `az datamigration get-assessment` |
| Provision Hyperscale | `02-provision.ps1` | `az sql db create --edition Hyperscale` |
| Create DMS + SHIR | `03-dms-shir.ps1` | `az datamigration sql-service create` / `register-integration-runtime` |
| Migrate schema (4a) | `04-migrate.ps1` | `az datamigration sql-server-schema` |
| Migrate data (4b) + wait | `04-migrate.ps1` | `az datamigration sql-db create` / `sql-db show` |
| Validate | `05-validate.ps1` | `sqlcmd -i validate-migration.sql` (both sides) |
| Teardown / reset | `99-teardown.ps1` | `az sql db delete` / `az datamigration sql-service delete` / `az sql server delete` |

## Verified against

`az datamigration` extension and `az sql db create -e Hyperscale`
(`--family Gen5`, `--capacity`, `--compute-model Provisioned|Serverless`,
`--ha-replicas`, `--backup-storage-redundancy`, `--zone-redundant`,
`--min-capacity`) per Microsoft Learn (2026-06). Zone-redundancy create-time-only
behavior per the Azure SQL reliability and enable-zone-redundancy docs.

## References

- Tutorial: Migrate SQL Server to Azure SQL Database (offline) —
  https://learn.microsoft.com/data-migration/sql-server/database/database-migration-service
- Migrate databases at scale using automation (PowerShell / CLI) —
  https://learn.microsoft.com/azure/dms/migration-dms-powershell-cli
- DMS supported scenarios —
  https://learn.microsoft.com/azure/dms/resource-scenario-status
- Create a Hyperscale database —
  https://learn.microsoft.com/azure/azure-sql/database/hyperscale-database-create
- Create a zone-redundant Hyperscale database —
  https://learn.microsoft.com/azure/azure-sql/database/hyperscale-create-zone-redundant-database
- Enable zone redundancy (create-time-only for Hyperscale) —
  https://learn.microsoft.com/azure/azure-sql/database/enable-zone-redundancy
- Hyperscale service tier —
  https://learn.microsoft.com/azure/azure-sql/database/service-tier-hyperscale
