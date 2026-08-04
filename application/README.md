# Zava Lending — Application Front-Ends (UI mockups)

Static, self-contained web pages that stand in for Zava Lending's apps. They are the
**visual anchor** for the workshop — open them to *see* what the `ZavaLendingDB` database
powers at each act.

> ⚠️ **These are mockups, not the real application.** Every page is a single `index.html`
> with **all data hard-coded in the page**. There is **no server, no build step, and no
> connection to any database or Azure resource** — nothing you do in these pages runs a
> query or calls an API. They illustrate the **UX**, not live data. The actual data and AI
> work happens in the SQL scripts under [migrate/](../migrate/), [scale/](../scale/), and
> [ai/](../ai/).

## How to open

Double-click any `index.html` (or open it in a browser). That's it — no install, no server.

## The three front-ends — and when to look at them

You **first review the customer and internal apps in Act 1**, right after the database is
migrated — an exercise to see the app the new Hyperscale database powers. They reappear in
**Act 2** (same console, now on the scaled database), and **Act 3** adds the AI version.

| App | Open it during | What it shows |
|-----|----------------|---------------|
| [loan-platform-customer/](loan-platform-customer/) | **Act 1** (review after migrating) · also in Act 2 | The **borrower-facing** website — the public "Check Your Rate" application experience. |
| [loan-platform-internal/](loan-platform-internal/) | **Act 1** (review after migrating) · also in Act 2 | The **internal staff** operations console the migrated database powers. |
| [loan-platform-internal-ai/](loan-platform-internal-ai/) | **Act 3 — AI** | The same console **plus an 🟣 AI Intelligence menu** (🔍 Narrative Search + 🤖 AI Loan Scoring) — the visual anchor for the AI act. |

All three represent the same fictional platform on the same `ZavaLendingDB`. Each subfolder
has its own README with the detail:

- **Customer site:** [loan-platform-customer/README.md](loan-platform-customer/README.md)
- **Internal console (Act 2):** [loan-platform-internal/README.md](loan-platform-internal/README.md)
- **Internal console + AI (Act 3):** [loan-platform-internal-ai/README.md](loan-platform-internal-ai/README.md)

## Where these fit

The **🔍 Narrative Search** and **🤖 AI Loan Scoring** screens in the AI console are the UX
over the real T-SQL objects built in Act 3 —
[ai/build/sql/03-hybrid-search-procedure.sql](../ai/build/sql/03-hybrid-search-procedure.sql)
(`usp_HybridLoanSearch`) and
[ai/build/sql/04-loan-scoring.sql](../ai/build/sql/04-loan-scoring.sql)
(`usp_ScoreLoanApplication`). The mockups show what those procedures *feel like* to an
underwriter; run the scripts to see them actually execute.

See the parent [../README.md](../README.md) for the full three-act story.
