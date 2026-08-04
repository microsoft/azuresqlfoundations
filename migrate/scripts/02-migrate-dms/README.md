# DMS CLI Migration Scripts — SQL Server → Azure SQL Database Hyperscale

> For a guided, approve-each-step walkthrough (setup → assess → provision →
> DMS+SHIR → migrate → validate), see [SKILL.md](../SKILL.md). Ready-to-paste
> prompts are in [prompts.md](prompts.md). This README is the human reference for
> the individual scripts.

Scripted equivalent of the portal **Migrate to Azure SQL** / DMS wizard, using the
`az datamigration` extension. Same engine, driven by API/CLI.

## Five phases (plus Phase 0 and teardown)

| Phase | Script | What it does |
|-------|--------|--------------|
| **0** Setup | `00-setup.ps1` | Install the `datamigration` CLI extension; optionally register providers |
| **1** Assess | `01-assess.ps1` | List migration issues/blockers; verify Service Broker usage |
| **2** Provision Hyperscale | `02-provision.ps1` | Logical server + empty Hyperscale DB + firewall (+ Entra admin, ZR prompt) |
| **3** DMS + SHIR | `03-dms-shir.ps1` | Create the DMS and register the SHIR on this machine |
| **4** Migrate | `04-migrate.ps1` | **4pre** scan the source for DMS data-copy limitations, **4a** deploy schema, then **4b** copy data, then wait to completion |
| **5** Validate | `05-validate.ps1` | Compare object counts + per-table row counts, source vs target |
| Teardown | `99-teardown.ps1` | Delete the DB/DMS/server to reset for a repeat run |

## Single-box assumption

These scripts assume **DMS and the SHIR run on this machine** and the source SQL
Server is reachable here as `localhost`. You run every phase from one place. (If the
SHIR must live on a separate host, register it there in Phase 3 with
`03-dms-shir.ps1` and use the SQL Server's hostname instead of `localhost`.)

## Resource mapping (you supply ALL of these — no defaults are baked in)

Every environment/identity parameter is **mandatory**; the scripts ship with no
defaults so anyone can use them against their own instance.

| Role | Value (substitute your own) |
|------|-------|
| Subscription | `<subscription-guid>` |
| Resource group | `<resource-group>` |
| Source instance / DB | this machine (`localhost`) / `<SourceDatabase>` |
| Target server / DB | `<server-name>.database.windows.net` / `<TargetDatabase>` (Hyperscale) |
| DMS (SQL Migration Service) | `<dms-name>` (`<region>`) |
| SHIR host | this machine |

If you omit a mandatory parameter, PowerShell prompts you for it.

## Authentication — `az login`

All control-plane scripts (`00-setup` with `-SubscriptionId`, `02-provision`,
`03-dms-shir`, `04-migrate`, `99-teardown`) call ARM and need an authenticated
context. Each dot-sources `_resolve-az.ps1` (to put `az` on PATH) and runs
`az account set --subscription <sub>` for you. Sign in once first:

```powershell
az login            # device code if needed: az login --use-device-code
az account show     # confirm the right subscription/tenant
```

The SHIR registered in Phase 3 authenticates to the DMS with an **auth key** (read
by the script from the DMS), not Azure creds — so the data read works without any
extra sign-in.

## Order of operations

```powershell
cd migrate\scripts\02-migrate-dms

# Phase 0 — setup
.\00-setup.ps1                                # install the DMS CLI extension (no sub needed)
.\00-setup.ps1 -SubscriptionId <sub>          # + register providers (needs az login)

# Phase 1 — assess (read-only)
.\01-assess.ps1 -SourceConnectionString 'Data Source=localhost;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True'

# Phase 2 — provision Hyperscale (prompts for ZR decision + admin password)
.\02-provision.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -Location <region> `
    -ServerName <server> -DatabaseName <db> -AdminUser <user> `
    -Capacity 2 -ClientIpAddress <your-ip>

# Phase 3 — DMS + SHIR (one step; add -IrPath <msi> to install the runtime first)
.\03-dms-shir.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -Location <region> -DmsName <dms-name>

# Phase 4 — migrate: 4a schema, then 4b data, then wait (prompts for target password once)
.\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
    -SourceServer localhost -SourceDatabase <db> `
    -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
    -TargetDatabase <db> -TargetSqlUser <user>

# Phase 5 — validate (read-only; prompts for target password)
.\05-validate.ps1 -SourceDatabase <db> `
    -TargetServerFqdn <server>.database.windows.net -TargetDatabase <db> -TargetSqlUser <user>
```

### Phase 4 staged — deploy schema, verify, then copy data

To verify the target schema (e.g. with **SSMS Schema Compare**) before committing to
the data copy, split Phase 4 into two runs:

```powershell
# 4a only — deploy the schema and STOP before the data copy.
.\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
    -SourceServer localhost -SourceDatabase <db> `
    -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
    -TargetDatabase <db> -TargetSqlUser <user> -SchemaOnly
#   -> verify with SSMS Schema Compare here (cleanest point — see Key facts)

# 4b only — skip re-deploying schema; copy data via the SHIR using a source SQL login.
.\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
    -SourceServer localhost -SourceDatabase <db> `
    -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
    -TargetDatabase <db> -TargetSqlUser <user> -SkipSchema -SourceSqlUser <source-login>
```

### Zone redundancy (Phase 2 — decide now, can't add later)

For Hyperscale, zone redundancy is **create-time-only** — it cannot be enabled in
place after the database exists (adding it later means a full redeploy). So
`02-provision.ps1` **prompts** you unless you pass `-ZoneRedundant` or
`-NonInteractive`. Saying yes auto-sets the two prerequisites: one HA replica
(`-HaReplicas 1`) and zone-redundant backup storage (`-BackupStorageRedundancy
Zone`). The default is **no replicas, no ZR** — HA replicas can be added later as a
separate optimization, but ZR cannot.

### Run again (teardown / reset)

```powershell
.\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
    -ServerName <server> -DatabaseName <db> -DmsName <dms-name>   # type 'delete' to confirm
```
Idempotent (skips what's already gone) and destructive. Use `-KeepServer` to keep
the logical server, `-DeleteResourceGroup` to nuke the whole group, `-Force` to
skip the prompt. To keep the Hyperscale DB but empty it in place (so Phase 4 can
re-run while preserving the create-time-only zone redundancy), use
`-ResetTargetSchema -TargetSqlUser <login>` — this runs `reset-target-schema.sql`
against the target instead of dropping it. An in-progress migration must
finish/cancel before its DMS can be deleted. After teardown, re-run from
`02-provision.ps1` (Phase 2).

## Key facts (why the order matters)

- **Offline only.** DMS → Azure SQL Database (incl. Hyperscale) has no online mode;
  the data copy is a point-in-time snapshot of the source.
- **Schema first.** The data-copy step does **not** create tables; `04-migrate.ps1`
  runs schema (4a) before data (4b) for you. Use `-SchemaOnly` to deploy 4a and stop
  (verify with SSMS Schema Compare), then `-SkipSchema -SourceSqlUser <login>` to copy.
- **Cleaner compare at the schema-only checkpoint.** The schema tool's
  `__migration_status` bookkeeping table is created by the **data copy** (4b), not the
  schema deploy (4a) — so comparing after `-SchemaOnly` (before 4b) won't flag it.
- **Data copy needs SQL auth on the source.** The SHIR runs as a service account, so
  4b authenticates to the source with a SQL login passed via `-SourceSqlUser` (a
  dedicated least-privilege read login such as `dms_reader` is recommended).
- **Zone redundancy is create-time-only** for Hyperscale and requires 1 HA replica
  + zone-redundant backup storage; `02-provision.ps1` prompts you to decide.
- **SHIR always required**, even Azure-to-Azure. Registering it on this machine keeps
  the source connection on `localhost`.
- **Passwords** are prompted as masked SecureStrings; the target password is passed
  to the CLI as a process argument (inherent to the tool). Use a least-privileged
  login and treat it accordingly.
- **Firewall.** The target server must allow this machine. `02-provision.ps1` adds a
  rule via `-ClientIpAddress` / `-AllowAzureServices`.

## Verified against

`az datamigration` extension CLI reference — commands `get-assessment`,
`sql-service create`, `sql-service list-auth-key`, `register-integration-runtime`,
`sql-server-schema`, `sql-db create`, `sql-db show`, plus `az sql server create` /
`az sql db create -e Hyperscale` / `az sql server ad-admin create`.

## Files

| File | Purpose |
|------|---------|
| `00-setup.ps1` | Phase 0 — install the `datamigration` CLI extension; optionally register providers |
| `01-assess.ps1` | Phase 1 — list migration issues/blockers; verify Service Broker usage (read-only) |
| `02-provision.ps1` | Phase 2 — logical server + empty Hyperscale DB + firewall (+ Entra admin, ZR prompt) |
| `03-dms-shir.ps1` | Phase 3 — create the DMS and register the SHIR on this machine |
| `04-migrate.ps1` | Phase 4 — 4pre limitation check, 4a schema, 4b data copy, then wait |
| `05-validate.ps1` | Phase 5 — compare object + per-table row counts, source vs target |
| `99-teardown.ps1` | Teardown / reset — delete or reset the DB/DMS/server |
| `check-dms-limitations.sql` | Source scan for DMS data-copy limitations (run by 4pre; also standalone) |
| `verify-service-broker.sql` | Prove whether Service Broker is actually *used* vs merely enabled (Phase 1) |
| `validate-migration.sql` | Object + row-count snapshot to run on source and target and compare (Phase 5) |
| `reset-target-schema.sql` | Empty the target DB in place — used by `99-teardown.ps1 -ResetTargetSchema` |
| `_resolve-az.ps1` | Helper: ensure `az` is on PATH for the session (dot-sourced by the phase scripts) |
| `_log.ps1` | Helper: tee each phase's output to a timestamped log under `C:\dms\logs` |
| `prompts.md` | Paste-into-Copilot prompts to drive the migration one approved phase at a time |
