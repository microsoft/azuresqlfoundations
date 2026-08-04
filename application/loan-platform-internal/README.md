# Zava Lending — Internal Operations Console (Acts 1–2)

A self-contained static web page ([index.html](index.html)) that stands in for Zava Lending's
**internal staff app** — the operations console the platform database powers.

## How to open

Open [index.html](index.html) directly in any browser — no server, no build, no data
connection. All content is mocked in the page; it illustrates the UX, not live data.

## The menu

The dark left sidebar groups the console into sections:

| Section | Items |
|---------|-------|
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
