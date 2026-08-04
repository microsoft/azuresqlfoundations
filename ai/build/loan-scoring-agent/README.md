# Loan Scoring Agent — SQL MCP Server + Azure AI Foundry

> **Parent Demo:** Act 3 — "The Engine Knows: Vector Search + AI Scoring"  
> **Purpose:** Expose ZavaFin's loan scoring stored procedure as an MCP tool via SQL MCP Server (Data API Builder), deploy it to Azure Container Apps, and connect it to a Microsoft Foundry Agent that automates the entire loan decisioning workflow.

---

## Architecture

```
  ┌──────────────────────────────┐
  │     Azure AI Foundry         │
  │     (Foundry Agent)          │
  │                              │
  │  "Score loan application     │
  │   #42 for ZavaFin"           │
  │                              │
  │  Agent uses MCP tools:       │
  │  ① describe_entities         │
  │  ② read_records              │
  │  ③ execute_entity            │
  └──────────┬───────────────────┘
             │ MCP Protocol (Streamable HTTP)
             │
  ┌──────────▼───────────────────┐
  │  Azure Container Apps        │
  │  SQL MCP Server (DAB 1.7+)   │
  │                              │
  │  Entities exposed:           │
  │  • LoanApplications (read)  │
  │  • Applicants (read)        │
  │  • LoanDecisions (read)     │
  │  • LoanHistory (read)       │
  │  • ScoreLoan (execute)      │
  │                              │
  │  Port 5000 / /mcp endpoint  │
  └──────────┬───────────────────┘
             │ T-SQL (ODBC)
             │
  ┌──────────▼───────────────────┐
  │  Azure SQL Hyperscale        │
  │  <your-server>.database.        │
  │  windows.net / zavalending   │
  │                              │
  │  usp_ScoreLoanApplication:   │
  │  • Vector search (DiskANN)   │
  │  • Phi-4 via REST endpoint   │
  │  • Auditable decision store  │
  └──────────────────────────────┘
```

---

## What the Agent Can Do

The Foundry Agent connects to the SQL MCP Server and gets access to these **six DML tools**:

| Tool | What It Does in This Demo |
|------|---------------------------|
| `describe_entities` | Agent discovers the schema — LoanApplications, Applicants, LoanDecisions, LoanHistory, and the ScoreLoan stored procedure |
| `read_records` | Agent queries pending applications, applicant profiles, historical loans, and previous scoring decisions |
| `execute_entity` | Agent calls `usp_ScoreLoanApplication` to trigger AI scoring — vector search + Phi-4 + auditable decision storage |
| `create_record` | Not used (locked down via RBAC — agent is read-only + execute) |
| `update_record` | Not used (locked down via RBAC) |
| `delete_record` | Not used (disabled globally) |

### Agent Workflow

A typical conversation with the Loan Scoring Agent:

1. **"Show me all pending loan applications"** → Agent calls `read_records` on `LoanApplications` with filter `Status eq 'Pending'`
2. **"What are the details for applicant #1?"** → Agent calls `read_records` on `Applicants` with filter `ApplicantId eq 1`
3. **"Score loan application #1"** → Agent calls `execute_entity` on `ScoreLoan` with parameter `ApplicationId=1`
4. **"What was the decision?"** → Agent calls `read_records` on `LoanDecisions` with filter `ApplicationId eq 1`
5. **"Show me the similar historical loans used"** → Agent calls `read_records` on `LoanHistory` to look up the similar loan IDs

---

## Components

**This folder deploys the agent.** To *use* the deployed agent (portal setup + example
conversation + a test script), see
[../../walkthrough/loan-scoring-agent/](../../walkthrough/loan-scoring-agent/).

| File | Purpose |
|------|---------|
| `README.md` | This file — architecture + deploy overview |
| `dab-config.json` | DAB configuration: entities, permissions, MCP settings |
| `Dockerfile` | Container image based on DAB 1.7.83-rc prerelease |
| `deploy-sql-mcp-server.ps1` | Deploy the SQL MCP server to Azure Container Apps |
| `deploy-dab-existing-rg.ps1` | Deploy variant targeting an existing resource group |
| `run-dab-local.ps1` | Run the SQL MCP server locally for testing |
| `deploy-foundry-agent.ps1` | Provision the Foundry agent against the MCP endpoint |
| `agent-instructions.txt`, `basic-agent-instructions.txt` | Foundry agent system prompts |
| `mcp-endpoint.json` | Saved MCP endpoint config |

---

## Key Design Decisions

### Why SQL MCP Server (Not NL2SQL)?

SQL MCP Server uses an **NL2DAB** approach — not NL2SQL. The agent never writes raw SQL. Instead:

- **Typed CRUD**: `read_records` builds deterministic T-SQL via DAB's Query Builder
- **Stored procedures**: `execute_entity` calls `usp_ScoreLoanApplication` — the complex logic (vector search + Phi-4 + audit hash) stays in the database engine
- **RBAC enforcement**: The agent's role (`loan-scorer`) only permits read + execute — no create/update/delete

This is safer, more predictable, and auditable compared to letting an LLM generate arbitrary SQL.

### Why Azure Container Apps?

- **Serverless scaling**: 1-3 replicas, 0.5 CPU / 1 GB memory per replica
- **Secrets management**: Connection string stored as Container Apps secret
- **Health checks**: DAB provides `/health` endpoint for monitoring
- **External ingress**: MCP endpoint accessible from Azure AI Foundry

### Why the Stored Procedure Stays in the Database?

The `usp_ScoreLoanApplication` procedure does **four things** that must happen inside the engine:

1. **Vector search** — DiskANN index scan over 12M narrative embeddings (can't move this to the app tier)
2. **Phi-4 invocation** — `sp_invoke_external_rest_endpoint` using database-scoped credentials (secure, no key in config)
3. **Decision storage** — INSERT into `LoanDecisions` with `HASHBYTES` tamper detection
4. **Transaction atomicity** — All steps run in a single connection context

The agent doesn't need to understand any of this. It just calls `execute_entity` with an `ApplicationId`.

---

## Prerequisites

- Azure SQL Hyperscale database (`<your-server>.database.windows.net / zavalending`) with Act 2 + Act 3 setup complete
- Azure AI Services account (`<your-ai-account>`) with Phi-4 and embedding models deployed
- Azure Container Registry (will be created by deployment script)
- Azure Container Apps environment (will be created by deployment script)
- Azure AI Foundry project with access to a chat model (GPT-5-mini or equivalent)
- .NET 9+ SDK (for DAB CLI)
- Azure CLI

---

## Quick Start

```powershell
# 1. Deploy SQL MCP Server to Azure Container Apps
.\deploy-sql-mcp-server.ps1

# 2. Test the MCP endpoint
curl "https://<your-app>.azurecontainerapps.io/health"

# 3. Configure the Foundry Agent (see ../../walkthrough/loan-scoring-agent/foundry-agent-setup.md)

# 4. Test in Azure AI Foundry Playground
#    "Show me all pending loan applications"
#    "Score loan application #1"
```

---

## Demo Story

> **"We built the engine — vector search, AI scoring, auditable decisions, all in T-SQL. Now we make it accessible to any AI agent. No custom API code. No middleware. Just a config file and a container."**

The Loan Scoring Agent demonstrates the **full stack**:
- **SQL Server 2025**: Vector search + AI scoring (the engine)
- **Data API Builder**: Entity abstraction + RBAC + MCP tools (the surface)
- **Azure Container Apps**: Scalable hosting (the infrastructure)
- **Azure AI Foundry**: Agent orchestration (the consumer)

From stored procedure to agent tool — zero application code required.

---

## Using it through MCP — the tool-call sequence

> **One engine. One SQL. Any surface.** The same `usp_ScoreLoanApplication` you can run in
> T-SQL is reachable through the standard **Model Context Protocol** — the protocol GitHub
> Copilot, VS Code, and AI agents use to call tools. Below is the exact call sequence an MCP
> client makes against the deployed DAB server.

**The story:** Art Vandelay of Vandelay Industries applies for a $150,000 small-business loan
to expand his import/export operation. The engine scores it — vector search to find similar
historical loans, then Phi-4 for a human-readable risk narrative — all surfaced through MCP.

### Step 0 — Discover the tools (MCP handshake)

Tool: `describe_entities` (no parameters). The server returns its five tools — four read-only
entities (`Applicants`, `LoanApplications`, `LoanDecisions`, `LoanHistory`) and one executable
action (`ScoreLoan`), each with a rich, AI-readable description and typed parameters.

> **How does an MCP client know to use this server?** One entry pointing at the endpoint:
> ```json
> {
>   "servers": {
>     "zavalending-sql-mcp": {
>       "type": "http",
>       "url": "https://<your-app>.<region>.azurecontainerapps.io/mcp"
>     }
>   }
> }
> ```
> On startup the client calls `describe_entities`, registers the returned tools (names,
> descriptions, parameters), and from then on matches your natural-language prompt to the
> right tool by reading those descriptions — no routing code, no SDK, no API gateway.
>
> **Implication for database developers:** the quality of your entity descriptions in the DAB
> config *is* your API documentation, your SDK, and your routing logic. Write them for an AI
> reader.

### Step 1 — Read the pending application

`read_records` → `LoanApplications`, filter `ApplicationId eq 1`:
```json
{ "ApplicationId": 1, "LoanType": "SmallBusiness", "RequestedAmount": 150000.00,
  "LoanPurpose": "Import/export business expansion - Vandelay Industries", "Status": "Pending" }
```

### Step 2 — Confirm no prior decision

`read_records` → `LoanDecisions`, filter `ApplicationId eq 1` → `{ "value": [] }` (clean slate).

### Step 3 — Score the loan (vector search + Phi-4)

`execute_entity` → `ScoreLoan`, body `{ "ApplicationId": 1 }`:
```json
{ "Applicant": "Art Vandelay", "RiskScore": 25.00, "RiskCategory": "Low",
  "Decision": "Approved", "ApprovedAmount": "$150,000.00", "InterestRate": 5.99,
  "AIRiskNarrative": "...strong financial profile, credit score 780, DTI 0.15... approval recommended.",
  "SimilarLoansAnalyzed": 10, "ProcessingTimeMs": 6899 }
```
Inside the engine: read app + applicant → `AI_GENERATE_EMBEDDINGS` → `VECTOR_SEARCH` (DiskANN,
cosine, top 10) → aggregate metrics → `sp_invoke_external_rest_endpoint` → Phi-4 → `INSERT`
`LoanDecisions` with a SHA-256 tamper-detection hash → `UPDATE` status.

### Step 4 — Read the stored decision

`read_records` → `LoanDecisions`, filter `ApplicationId eq 1` → the persisted, explainable,
auditable decision (risk score, category, narrative, model version).

### Step 5 — Verify status

`read_records` → `LoanApplications` → `Status` has moved `Pending → Scoring → Decided`
automatically.

### The "one engine" proof

The same `usp_ScoreLoanApplication` powers every surface: run it directly in T-SQL (see
[../../walkthrough/sql/07-execute-scoring.sql](../../walkthrough/sql/07-execute-scoring.sql)),
call it from GitHub Copilot / VS Code / any MCP client through DAB, or drive it from the Azure
AI Foundry agent. **One engine. One SQL. Any surface.**
