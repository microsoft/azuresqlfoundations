# Prompts — migrating SQL Server to Azure SQL Hyperscale with GitHub Copilot

Plain-language prompts that say what you want to do, one step at a time. Copilot does
the work and stops for your approval before each step, so you stay in control.

> Tip: substitute the `<...>` placeholders with your real values. Passwords are
> entered directly at the terminal's masked prompt — never type them into chat.

## 0. Get oriented ("what are the steps?")

Start here if you just want to understand the path before doing anything:

> I have a local SQL Server instance and want to migrate my database to Azure SQL Hyperscale. What are the steps?

You'll get the five phases (plus setup): check prerequisites, assess the source,
provision the Hyperscale target, set up the migration service, migrate (schema then
data), and validate — plus the up-front decisions (target name/region, Hyperscale
sizing, and the create-time-only zone-redundancy choice).

## 1. Kickoff

> Migrate my local SQL Server database to Azure SQL Hyperscale. Do it one step at a time, and stop for my approval before you start each step. Ask me for whatever details you need as we go.

Copilot asks for what it needs when it needs it — subscription and resource group,
source database, target server and database names, region, and the Hyperscale
sizing (it shows the cost before creating anything). You don't supply anything up
front.

## 2. Per-phase prompts

| Phase | Prompt |
|-------|--------|
| 0 — Setup | `Make sure the pre-reqs are installed and register any providers needed. Ask me for my Azure subscription before registering.` |
| 1 — Assess | `Run the assessment against my source and show me the findings.` |
| 2 — Provision Hyperscale | `I'm ready to create my Hyperscale database. Please ask me any details I need to know to deploy it.` |
| 3 — DMS + SHIR | `Create the migration service and register the SHIR on this machine.` |
| 4 — Migrate | `Migrate the database: deploy the schema, then copy the data, and wait until it finishes.` |
| 5 — Validate | `Validate the migration — compare object and row counts between source and target.` |
| Teardown | `Tear down everything so I can run the migration again.` |

> **Phase 4 — verify the schema before copying data (staged).** If you want to
> deploy the schema, check it with the **VS Code MSSQL extension's Schema Compare**
> (SSMS optional), and only then copy the data, split Phase 4 into two prompts:
>
> 1. **Migrate the schema, then stop so you can verify it:**
>    > `Migrate the schema first and let me verify it before we copy any data.`
>
>    (Copilot deploys the schema straight to the target — no script file — and stops.
>    Verify with the VS Code MSSQL extension's Schema Compare.)
>
> 2. **After you've verified, migrate the data:**
>    > `The schema checks out — now migrate the data and wait until it finishes.`
>
>    (Copilot copies the data via the SHIR without re-deploying the schema, and polls
>    to completion.)

## 3. Zone redundancy (Phase 2)

Zone redundancy for Hyperscale is a **create-time-only** decision — it can't be
enabled in place after the database exists; adding it later means redeploying the
database. Copilot (and `02-provision.ps1`) prompts you to decide before creating the
DB. Saying yes auto-sets the two prerequisites: one HA replica and zone-redundant
backup storage. The default is no replicas, no ZR.

> Provision with zone redundancy now — I understand it can't be added later.

> Don't enable zone redundancy yet — provision with no HA replicas; we'll handle that as a separate optimization later.

## 4. SHIR options (Phase 3)

The Self-Hosted Integration Runtime is the agent that reads your source database, so
it must run on a machine that can reach the source. This runbook assumes it runs on
**this machine** (source = `localhost`).

| Option | When to use | What it means |
|--------|-------------|---------------|
| **A. On this machine (default)** | Source SQL is reachable here as `localhost` | `03-dms-shir.ps1` installs/registers the SHIR locally. |
| **B. On a separate host with line-of-sight** | You don't want the SHIR on this box, or SQL is locked down | Run `03-dms-shir.ps1` on that host and set the source connection to the SQL Server's hostname, not `localhost`. |
| **C. Reuse an existing SHIR** | A SHIR is already installed/registered | Skip the MSI install; the script registers with the new auth key. |

Install behavior of `03-dms-shir.ps1`:
- Add `-IrPath <IntegrationRuntime.msi>` to **install** the runtime first, then
  register (download: https://aka.ms/sql-migration-shir-download).
- Add `-InstalledIrPath '<version folder>'` if it's installed but not auto-detected.
- With neither, it registers against an already-installed, auto-detected runtime.

## 5. Control prompts (use any time)

- `What's the next step and what will it change?`
- `Show me the exact command before you run it.`
- `Don't run anything yet — just explain this phase.`
- `Abort — what do I delete to undo the Azure spend?`
- `Tear down everything so I can run the migration again.` *(deletes DB/DMS/server)*

## 6. Notes

- **Run from the scripts folder.** The phase scripts are launched by a relative path
  (`.\04-migrate.ps1`), so the terminal's current directory must be the `scripts/`
  folder. If a prior step left you elsewhere (e.g. the repo root), `cd` back first —
  Copilot should prepend `Set-Location '<...>\scripts'` in the same command so the
  launch is cwd-proof. Symptom of a wrong cwd: *"the term '.\NN-*.ps1' is not
  recognized."*
- **Single box:** all phases run from this machine, with `az login` for the
  control-plane scripts (0 setup w/ subscription, 2 provision, 3 DMS+SHIR, 4
  migrate, teardown). The source is `localhost` here.
- **Offline copy:** the data migration reads a point-in-time snapshot of the source
  and never writes to it.
- The T-SQL helpers run by hand in **SSMS** too: `verify-service-broker.sql`
  (Phase 1 broker check) and `validate-migration.sql` (Phase 5 validate).
