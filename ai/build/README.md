# `ai/build/` — Deploy the AI capabilities

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

These scripts add **Narrative Search** (semantic vector search) and **AI Loan Scoring** to
an existing `ZavaLendingDB`. Run them in order against the primary database. They are
additive and non-destructive — they add columns, tables, an index, and stored procedures
on top of data that already exists.

The AI act is built on the **Act 1 (Migrate)** database plus these additions — it does
**not** require the Act 2 (Scale) 192-vCore build.

---

## Prerequisites

1. **A populated `ZavaLendingDB` from [Act 1 (Migrate)](../../migrate/).**
   The migrated database already has everything the AI layer needs:
   - `Applicants`, `LoanHistory` (the ~100-row representative set, `LoanId` 1–100),
     `LoanApplications`, and an empty `LoanDecisions` table — which Act 1 leaves empty
     *on purpose* for Act 3 to fill.
   - No large data volume is required. Vector search here runs over ~100 richly-written
     loan narratives, so it works on any service tier.

2. **An Azure AI (Azure OpenAI) resource** with two model deployments:
   - `text-embedding-3-large` — for generating embeddings (step `01`).
   - `Phi-4` — for loan risk scoring (step `04`).

3. **Your endpoint + key wired into the scripts.** The scripts use placeholders
   (`<your-ai-account>`, `<your-azure-ai-api-key>`). Replace them with your own Azure AI
   endpoint and key before running — the credential and external model are defined in
   `sql/01-embeddings-setup.sql`.

---

## Run order

| Step | Script | Creates |
|------|--------|---------|
| 0 | `sql/00-add-loan-narratives.sql` | `LoanHistory.LoanNarrative` column + text (rows 1–100) + a full-text catalog/index. This is the one bridge step — the narrative text Narrative Search will embed and search. |
| 1 | `sql/01-embeddings-setup.sql` | Master key, database-scoped credential, `CREATE EXTERNAL MODEL` (embeddings), the `LoanNarrativeEmbeddings` table, and the embeddings themselves via `AI_GENERATE_EMBEDDINGS`. |
| 2 | `sql/02-vector-index.sql` | The DiskANN `CREATE VECTOR INDEX` on the embedding column. |
| 3 | `sql/03-hybrid-search-procedure.sql` | `usp_HybridLoanSearch` — semantic search with `TOP (N) WITH APPROXIMATE` relational filtering. Powers **Narrative Search**. |
| 4 | `sql/04-loan-scoring.sql` | `AIOperationsLedger` (append-only ledger) + `usp_ScoreLoanApplication` — vector search + Phi-4 scoring via `sp_invoke_external_rest_endpoint`. Calls Azure AI **directly by default**; `@UseGateway = 1` routes through the optional APIM gateway. Powers **AI Loan Scoring**. |

After these run, work through [../walkthrough/](../walkthrough/) to execute the T-SQL behind
the two capabilities.

---

## `APIM/` — optional AI gateway (off by default)

The AI gateway is **completely optional.** `usp_ScoreLoanApplication` (step `04`)
**defaults to calling Phi-4 directly** on your Azure AI Services / Foundry endpoint
(`@UseGateway = 0`), reusing the credential created in step `01`. **No APIM is required to run
either capability** — Narrative Search and AI Loan Scoring both work end-to-end against the
model directly.

**If you don't want APIM (the default):** just substitute your own Foundry model endpoint in
the direct URL. In `sql/04-loan-scoring.sql`, the `@UseGateway = 0` branch points at:

```text
https://<your-ai-account>.cognitiveservices.azure.com/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview
```

Replace `<your-ai-account>` with your endpoint (and set the matching credential in step `01`).
That's the whole substitution — no gateway, no extra resources.

**If you do want APIM:** set `@UseGateway = 1`, which routes the same call through an Azure API
Management AI gateway instead. The [APIM/](APIM/) subfolder holds the scripts that stand the
gateway up (subscription-key policy, optional content safety) and the T-SQL that creates the
gateway credential (`setup-gateway-demo.sql`, `10-ai-gateway-switch.sql`). Use it when you want
centralized key management, token metering, throttling, or content-safety filtering in front
of the model.

> All values in `APIM/` (subscription IDs, resource groups, subscription keys) are
> **placeholders** (`<your-...>`) — fill in your own when you provision the gateway. No live
> secrets are committed.

