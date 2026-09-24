# Zava Lending — Customer Site

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

A borrower-facing application for Zava Lending. Its rate checker calls the shared Node API,
which estimates a rate from comparable loans in `ZavaLendingDB`.

## Run

From the parent `application` directory, set `APP_KIND=customer` in `.env`, run `npm start`,
and open `http://localhost:3000`. See the parent README for Azure App Service deployment and
managed identity configuration.

## What it shows

A modern lending landing page for **ZavaFin / Zava Lending**:

- **Hero + "Check Your Rate"** — pre-qualification call-to-action (personal, auto, and
  business loans, $2,000–$500,000).
- **Loan Types** — the product lineup.
- **How It Works** — the application flow.
- **Reviews** + trust stats (loans funded, borrowers, rating, funding time).

This is the customer end of the story; the staff-facing side is the
[loan-platform-internal/](../loan-platform-internal/) operations console. You **first review both
in Act 1** (right after the database is migrated); they sit on top of the same `ZavaLendingDB`
that Act 2 scales. See the parent [../../README.md](../../README.md).
