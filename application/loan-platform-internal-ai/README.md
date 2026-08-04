# Zava Lending — Internal Operations Console

A self-contained static web page ([index.html](index.html)) that stands in for Zava Lending's
internal staff app. It's the visual anchor for **Act 3 (AI)**: open it and click the two
**AI Intelligence** menu items to see the capabilities the AI act adds to a dashboard the
company already runs on Hyperscale.

## How to open

Open [index.html](index.html) directly in any browser — no server, no build, no data
connection. All content is mocked in the page; it illustrates the UX, not live data.

## The menu

The dark left sidebar groups the console into sections:

| Section | Items |
|---------|-------|
| **Overview** | Dashboard |
| **Operations** | Account Review, Risk Exposure, Branch Activity, Payment Processing |
| **🟣 AI Intelligence** | **🔍 Narrative Search**, **🤖 AI Loan Scoring** |
| **System** | Settings |

## The two AI additions (the point of Act 3)

- **🔍 Narrative Search** — search millions of loan narratives in plain English, ranked by
  semantic similarity (not keyword match). This is the UX over `usp_HybridLoanSearch` from
  [../../ai/build/sql/03-hybrid-search-procedure.sql](../../ai/build/sql/03-hybrid-search-procedure.sql).
- **🤖 AI Loan Scoring** — score a new application against similar historical loans, with a
  risk gauge and an LLM-generated risk narrative. This is the UX over
  `usp_ScoreLoanApplication` from [../../ai/build/sql/04-loan-scoring.sql](../../ai/build/sql/04-loan-scoring.sql).

The Operations pages (Account Review, Risk Exposure, Branch Activity, Payment Processing) are
the existing app; the **AI Intelligence** section is what Act 3 layers on top. See the parent
[../../ai/README.md](../../ai/README.md) for how this fits the build + walkthrough.
