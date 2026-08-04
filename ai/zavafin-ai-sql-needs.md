# ZavaFin Lending — AI + SQL Needs

ZavaFin Lending has outgrown traditional search and scoring approaches. As the loan portfolio scales, underwriters need smarter tools to find similar loans, filter results by business criteria, and score applications — all without leaving the database.

---

## 1. A Better Search Than Full-Text

Full-text search can't handle the way loan officers actually think. When an underwriter searches for *"business struggling financially with declining revenue and risk of closure,"* `FREETEXT` returns zero rows — because none of the loan narratives contain those exact words. The narratives describe the *same situations* using completely different language: "revenue declined 45%," "depleted reserves," "foot traffic has not fully returned."

**What ZavaFin needs:** Semantic search that understands *meaning*, not just keywords. Vector embeddings capture the intent behind a query and match it against the intent behind every loan narrative — regardless of the specific words used.

## 2. Vector Search with Proper Iterative Filtering

Finding semantically similar loans isn't enough. Underwriters need results filtered by business criteria: loan type, credit score range, outcome, date range. The legacy approach — find the *k* nearest vectors first, then apply filters — fails badly. When a loan officer searches for distressed SmallBusiness loans with CreditScore ≥ 700, the 5 nearest vectors are all below 700 or the wrong loan type. After filtering, the officer gets **zero useful results**.

**What ZavaFin needs:** `TOP (N) WITH APPROXIMATE` — filtering *during* the DiskANN graph traversal, not after. The engine keeps walking the graph until it finds *N* rows that satisfy both the semantic similarity and all relational predicates. The underwriter always gets the number of results they asked for.

## 3. DML on Tables with Vector Indexes

New loans come in every day. Previously, tables with vector indexes didn't support INSERT, UPDATE, or DELETE — you had to drop the index, modify data, and rebuild. That's not viable for a lending operation where new applications arrive continuously and need to be searchable immediately.

**What ZavaFin needs:** Native DML support on vector-indexed tables. Insert a new loan, generate its embedding, and it's instantly searchable — no index rebuild, no downtime. The engine handles the DiskANN index maintenance automatically.

## 4. Faster Vector Index Creation

ZavaFin's loan portfolio is growing. Building a DiskANN index on a million 3072-dimensional embeddings takes real time. As the portfolio scales to tens of millions of loans, index build time becomes a bottleneck — especially when deploying to new environments or recovering from failures.

**What ZavaFin needs:** Faster vector index creation, including parallel build with MAXDOP. On Azure SQL Hyperscale, MAXDOP 16 reduced index build time from ~50 minutes to ~32 minutes on 1M rows — a 1.57× speedup. As the data grows, this gap widens.

## 5. In-Database AI Loan Scoring with Cost-Effective Models

ZavaFin wants to explore AI-powered loan scoring without routing sensitive financial data outside the database. Using `sp_invoke_external_rest_endpoint`, the database can call an LLM directly — no middleware, no data exfiltration, no external application tier.

**What ZavaFin wants to explore:**
- **Phi-4** as a cost-effective scoring model — smaller, cheaper, and faster than GPT-4, while still capable of structured risk assessment
- Combine vector search (find similar historical loans) with LLM scoring (assess the new application in context) in a single stored procedure
- Keep all PII and financial data inside the database boundary — the model sees only what the proc sends
- Rule-based fallback when the model is unavailable, so loan processing never stops
- Database-scoped credentials manage API keys, not application code

This approach puts AI scoring where the data already lives, reduces latency, and gives DBAs control over model access through familiar SQL Server security primitives.
