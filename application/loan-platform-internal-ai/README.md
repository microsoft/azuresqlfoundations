# Zava Lending — Internal Operations Console

The live internal staff application for **Act 3 (AI)**. Its **AI Intelligence** screens call
the hybrid search and loan scoring procedures in `ZavaLendingDB`.

## Run

From the parent `application` directory, set `APP_KIND=internal-ai` in `.env`, run `npm start`,
and open `http://localhost:3000`. See the parent README for Azure App Service deployment,
managed identity permissions, and required Act 3 database objects.

## The menu

The dark left sidebar groups the console into sections:

| Section | Items |
| --- | --- |
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
