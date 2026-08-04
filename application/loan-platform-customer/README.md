# Zava Lending — Customer Site

A self-contained static web page ([index.html](index.html)) that stands in for Zava Lending's
**borrower-facing** website — the public application experience the platform database powers.

## How to open

Open [index.html](index.html) directly in any browser — no server, no build, no data
connection. All content is mocked in the page; it illustrates the UX, not live data.

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
