# Zava Lending applications

> 📺 Part of the [Azure SQL Foundations video series & workshop](../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

The three original mockups are now live Node.js applications backed by `ZavaLendingDB`:

| App | `APP_KIND` | Live behavior |
| --- | --- | --- |
| `loan-platform-customer` | `customer` | Rate estimate from comparable historical loans |
| `loan-platform-internal` | `internal` | Portfolio dashboard, account lookup, risk, branch, and payment data |
| `loan-platform-internal-ai` | `internal-ai` | Internal app plus hybrid narrative search and AI loan scoring |

One deployable artifact serves all three applications. Each Azure App Service sets a different
`APP_KIND` and has its own system-assigned managed identity. The browser never receives a SQL
credential or access token.

## Configuration

Copy `.env.example` to `.env` and fill in the values. `AZURE_SQL_SERVER` is the logical server
name only, without `.database.windows.net`.

```powershell
Copy-Item .env.example .env
```

For local development, `DefaultAzureCredential` uses your Azure CLI identity:

```powershell
az login
npm install
npm test
npm start
```

Set `APP_KIND` in `.env` to `customer`, `internal`, or `internal-ai`, then open
`http://localhost:3000`. Your signed-in identity must exist as a contained database user with
the required permissions.

## Deploy to three App Services

Prerequisites:

- Azure CLI authenticated with `az login`
- Permission to create App Service and Storage resources and assign roles in the target resource group
- Azure SQL Microsoft Entra administrator access for the database permission step
- `sqlcmd` for configuring contained database users

After completing `.env`, provision and deploy all three apps:

```powershell
./deploy-apps.ps1
```

Then grant their managed identities access to the database:

```powershell
./configure-database-access.ps1
```

The infrastructure template is in `infra/main.bicep`. It creates one Linux App Service plan,
three HTTPS-only Node 20 App Services with health checks at `/api/health`, and a private
Standard LRS storage account for the application package. Shared-key access is disabled. Each
app reads the package with its managed identity and the `Storage Blob Data Reader` role.

## Deploy the database

These apps run against `ZavaLendingDB`. The database is a **prerequisite** — deploy it
**before** running `deploy-apps.ps1`. This is separate from the App Service deployment above,
and there are two ways to get the database depending on whether you did the Act 1 migration:

- **You already ran Act 1 (Migrate).** `ZavaLendingDB` already exists on Hyperscale with its
  data — nothing else to build for the operational apps. **Do not** run the `cloudborn/`
  scripts; they DROP/TRUNCATE and would wipe the migrated data. For the AI app, additionally
  run the objects in [`../ai/build/sql/`](../ai/build/sql/).
- **Starting cloud-born (no migration).** Build the database fresh on Hyperscale from
  [`../cloudborn/`](../cloudborn/) (base + scale schema and data). See
  [../cloudborn/README.md](../cloudborn/README.md). For the AI app, then run
  [`../ai/build/sql/`](../ai/build/sql/).

Schema each app expects:

| App | Requires |
| --- | --- |
| `loan-platform-customer` | Base + scale schemas |
| `loan-platform-internal` | Base + scale schemas |
| `loan-platform-internal-ai` | The above **plus** `ai/build/sql/` objects, including `dbo.usp_HybridLoanSearch` and `dbo.usp_ScoreLoanApplication` |

After the database exists and the apps are deployed, run `configure-database-access.ps1` to
create the contained database users. The customer and internal identities receive
`db_datareader`. The AI identity receives `db_datareader` plus execute permission only on the
two AI stored procedures.
