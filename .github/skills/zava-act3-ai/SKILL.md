---
name: zava-act3-ai
description: 'Act 3 of the Zava Lending Hyperscale workshop — The Engine Knows: native vector search + in-database AI loan scoring. USE WHEN the user wants to run "Act 3", "the AI act", build embeddings / DiskANN vector index / hybrid Narrative Search / Phi-4 AI Loan Scoring, run the ai/build and ai/walkthrough scripts, or do the OPTIONAL loan-scoring agent (Data API Builder + SQL MCP server + Microsoft Foundry agent, plus the bonus publish-to-Teams exercise) and the OPTIONAL APIM AI gateway. Guides ai/build/sql 00→04 then ai/walkthrough.'
---

# Act 3 — The Engine Knows (Vector Search + AI Scoring)

Add AI to the existing Hyperscale `ZavaLendingDB` — natively in Azure SQL. Built on the **Act 1**
database; **Act 2 scale is not required**. Narrative: [ai/README.md](../../../ai/README.md).

## Prerequisites

- A populated `ZavaLendingDB` on Hyperscale (from Act 1).
- An **Azure AI (Azure OpenAI)** resource with **`text-embedding-3-large`** and **`Phi-4`**
  deployed. Scripts use placeholders (`<your-ai-account>`, `<your-azure-ai-api-key>`) — replace
  with your own; the credential + external model are defined in `sql/01-embeddings-setup.sql`.
- Detail: [ai/build/README.md](../../../ai/build/README.md).

## Step 1 — Build the AI objects (run in order)

Folder: [ai/build/sql/](../../../ai/build/sql/).

1. `00-add-loan-narratives.sql` — narrative text + full-text catalog (the bridge step).
2. `01-embeddings-setup.sql` — master key, credential, `CREATE EXTERNAL MODEL`, embeddings via `AI_GENERATE_EMBEDDINGS`.
3. `02-vector-index.sql` — the DiskANN `CREATE VECTOR INDEX`.
4. `03-hybrid-search-procedure.sql` — `usp_HybridLoanSearch` (powers **Narrative Search**).
5. `04-loan-scoring.sql` — `usp_ScoreLoanApplication`: vector search + Phi-4 scoring via `sp_invoke_external_rest_endpoint` (powers **AI Loan Scoring**). Calls Azure AI **directly by default** (`@UseGateway = 0`).

## Step 2 — Walk through the capabilities

Folder: [ai/walkthrough/sql/](../../../ai/walkthrough/sql/). See
[ai/walkthrough/README.md](../../../ai/walkthrough/README.md).

- `00-reset.sql` — reset to a clean demo state.
- `03-vector-search-replica.sql` — run Narrative Search, optionally on the Analytics named replica.
- `04-dml-insert-search.sql` — DML on vector-indexed tables.
- `05-legacy-vs-new.sql` — legacy `VECTOR_DISTANCE` vs `TOP (N) WITH APPROXIMATE`.
- `07-execute-scoring.sql` — execute `usp_ScoreLoanApplication`.

## Optional — APIM AI gateway (off by default)

Not required. Default is direct-to-Foundry (`@UseGateway = 0`). To route the scoring call
through an APIM gateway (token metering, content safety, throttling), set `@UseGateway = 1` and
use [ai/build/APIM/](../../../ai/build/APIM/). To skip it, substitute your own Foundry model URL
in the direct branch. Content safety on the *agent* path comes from Azure AI Foundry's built-in
filters — it does **not** require APIM.

## Optional — loan-scoring agent (DAB + SQL MCP server + Foundry agent)

Not required to complete Act 3. Expose the same `usp_ScoreLoanApplication` as an MCP tool via
**Data API Builder**, host it on **Azure Container Apps**, and drive it from a **Microsoft
Foundry agent**. Deploy from
[ai/build/loan-scoring-agent/](../../../ai/build/loan-scoring-agent/); set up and use it via
[ai/walkthrough/loan-scoring-agent/](../../../ai/walkthrough/loan-scoring-agent/)
([foundry-agent-setup.md](../../../ai/walkthrough/loan-scoring-agent/foundry-agent-setup.md)).

**Bonus exercise:** publish the deployed Foundry agent as a **Microsoft Teams app** — see the
*Bonus exercise* section of `foundry-agent-setup.md`.

## Result

`ZavaLendingDB` now does semantic **Narrative Search** and in-database **AI Loan Scoring** in
T-SQL — the same engine, one SQL surface, optionally reachable by any AI agent through MCP.
