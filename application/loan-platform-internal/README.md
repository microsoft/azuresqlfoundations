# Zava Lending — Internal Operations Console (Acts 1–2)

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

The internal staff operations console backed by live data from `ZavaLendingDB`.

## Run

From the parent `application` directory, set `APP_KIND=internal` in `.env`, run `npm start`,
and open `http://localhost:3000`. See the parent README for Azure App Service deployment and
managed identity configuration.

## The menu

The dark left sidebar groups the console into sections:

| Section | Items |
| --- | --- |
| **Overview** | Dashboard |
| **Operations** | Account Review, Risk Exposure, Branch Activity, Payment Processing |
| **System** | Settings |

## Relationship to the other acts

You **first open this console in Act 1**, to review the app after `ZavaLendingDB` is migrated.
It's the same staff app running on the scaled Hyperscale database in **Act 2**. **Act 3 (AI)**
takes this same console and adds an **AI Intelligence** section (🔍 Narrative Search + 🤖 AI Loan
Scoring) — see [../loan-platform-internal-ai/](../loan-platform-internal-ai/).

The customer-facing side is [../loan-platform-customer/](../loan-platform-customer/). Both sit on
top of the same `ZavaLendingDB`. See the parent [../../README.md](../../README.md).
