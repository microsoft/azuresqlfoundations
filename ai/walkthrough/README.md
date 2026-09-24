# Act 3 walkthrough — run Narrative Search + AI Loan Scoring

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

Execute the T-SQL behind the two AI capabilities, then see the same scoring engine driven by
a Microsoft Foundry agent through DAB/MCP.

**Prerequisite:** the objects from [../build/](../build/) are deployed against your
`ZavaLendingDB` (narratives, embeddings, vector index, and the two stored procedures). See
[../build/README.md](../build/README.md).

---

## Part 1 — the T-SQL ([`sql/`](sql/))

Run these in order. Connect where noted (primary vs. the optional Analytics named replica).

| Step | Script | Connect to | What you see |
|------|--------|-----------|--------------|
| 1 | [sql/00-reset.sql](sql/00-reset.sql) | **primary** | Resets demo state — clears rows from prior runs so the walkthrough starts clean. |
| 2 | [sql/03-vector-search-replica.sql](sql/03-vector-search-replica.sql) | **Analytics replica** (`zavalending_Analytics`), or primary | **Narrative Search.** `usp_HybridLoanSearch` turns a plain-English prompt into an embedding and returns the most semantically similar loans — no keywords. |
| 3 | [sql/04-dml-insert-search.sql](sql/04-dml-insert-search.sql) | **primary** | **DML on a vector-indexed table.** Inserts three new loans, generates their embeddings, and they're immediately searchable — no index rebuild. |
| 4 | [sql/05-legacy-vs-new.sql](sql/05-legacy-vs-new.sql) | primary or replica | **Filtering that works.** Legacy post-filter (`usp_HybridLoanSearchLegacy`) returns too few rows; `TOP (N) WITH APPROXIMATE` filters *during* the DiskANN traversal and returns the N you asked for. |
| 5 | [sql/07-execute-scoring.sql](sql/07-execute-scoring.sql) | **primary** | **AI Loan Scoring.** `usp_ScoreLoanApplication` runs vector search → Phi-4 → an auditable, tamper-evident decision, all in T-SQL. |

> Step 2 runs the vector read on the **optional** Analytics named replica for workload
> isolation. If you don't have a named replica, run it on the primary — the result is
> identical.

---

## Part 2 — the same engine, driven by an agent ([`loan-scoring-agent/`](loan-scoring-agent/))

Step 5 called `usp_ScoreLoanApplication` directly. This part exposes that *same* procedure as
an MCP tool via **Data API Builder (DAB)** and drives it from a **Microsoft Foundry agent** —
"one engine, two surfaces."

1. **Deploy the pieces first** (from [../build/loan-scoring-agent/](../build/loan-scoring-agent/)):
   the DAB SQL MCP server (Container Apps) and the Foundry agent.
2. **Wire up and use the agent** — follow
   [loan-scoring-agent/foundry-agent-setup.md](loan-scoring-agent/foundry-agent-setup.md):
   add the MCP server as a Custom → MCP tool in [ai.azure.com](https://ai.azure.com), then
   chat with it:
   - *"Show me all pending loan applications"* → `read_records` on `LoanApplications`
   - *"Score loan application #1"* → `execute_entity` on `ScoreLoan` (fires
     `usp_ScoreLoanApplication`)
   - *"What was the decision?"* → `read_records` on `LoanDecisions`
3. **Exercise it programmatically** — run
   [loan-scoring-agent/test-foundry-agent.ps1](loan-scoring-agent/test-foundry-agent.ps1) to
   drive the agent with sample prompts.

The agent never writes SQL — it calls typed CRUD + the stored procedure (NL2DAB), with RBAC
limiting it to read + execute. The vector search, Phi-4 call, and audit hash stay in the
database.
