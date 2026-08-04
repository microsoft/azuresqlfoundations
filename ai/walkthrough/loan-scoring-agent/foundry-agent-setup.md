# Foundry Agent Setup — ZavaFin Loan Scoring

> Step-by-step guide to connect the deployed SQL MCP Server to Azure AI Foundry  
> and create an agent that can query and score loan applications.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **SQL MCP Server deployed** | Run `deploy-sql-mcp-server.ps1` first. You need the MCP endpoint URL (e.g., `https://zava-loan-mcp.azurecontainerapps.io/mcp`) |
| **Azure AI Foundry project** | Access to [ai.azure.com](https://ai.azure.com) with an existing project |
| **Chat model** | GPT-5-mini or equivalent deployed in your Foundry project |

---

## Step 1: Access Azure AI Foundry

1. Navigate to [https://ai.azure.com](https://ai.azure.com/)
2. In the header, select the **new Foundry experience** (preview toggle)
3. Select your Foundry project
4. In the left navigation, select **Playground**

---

## Step 2: Create the Loan Scoring Agent

1. Select **Create new agent** (or open an existing one)
2. Name it: **ZavaFin Loan Scoring Agent**
3. In the **Instructions** section, paste the contents of `agent-instructions.txt`

---

## Step 3: Add the SQL MCP Server as a Tool

1. In the **Tools** section (left panel), select **Add** → **Add a new tool**
2. The "Select a tool" dialog opens with three tabs: **Configured**, **Catalog**, **Custom**
3. Select the **Custom** tab
4. Select **Model Context Protocol (MCP)**
5. Select **Create** to proceed

---

## Step 4: Configure the MCP Connection

Fill in the "Add Model Context Protocol tool" dialog:

| Field | Value |
|-------|-------|
| **Name** | `zava-loan-scoring-mcp` |
| **Remote MCP Server endpoint** | `https://<your-container-app-url>/mcp` |
| **Authentication** | `Unauthenticated` |

> **Note:** The deployment uses anonymous permissions. For production, configure Microsoft Entra ID authentication on both the Container App and the MCP tool.

Select **Connect** to add the tool.

### Verify Tool Discovery

After connecting, the agent should discover **6 MCP tools**:
- `describe_entities`
- `read_records`
- `execute_entity`
- ~~`create_record`~~ (disabled globally)
- ~~`update_record`~~ (disabled globally)
- ~~`delete_record`~~ (disabled globally)

Only the first three are functional per our DAB configuration.

---

## Step 5: Test the Agent

Try these prompts in the Chat Playground:

### Test 1: Schema Discovery
```
What entities are available in the loan scoring database?
```
**Expected:** Agent calls `describe_entities`, returns LoanApplications, Applicants, LoanDecisions, LoanHistory, and ScoreLoan.

### Test 2: List Pending Applications
```
Show me all pending loan applications
```
**Expected:** Agent calls `read_records` on LoanApplications with filter `Status eq 'Pending'`.

### Test 3: Applicant Details
```
What are the financial details for the applicant on application #1?
```
**Expected:** Agent calls `read_records` on LoanApplications to get the ApplicantId, then `read_records` on Applicants with the ApplicantId filter.

### Test 4: Score a Loan (The Key Test)
```
Score loan application #1
```
**Expected:** Agent calls `execute_entity` on ScoreLoan with parameter `ApplicationId=1`. This triggers the full scoring pipeline:
1. Vector search finds 10 similar historical loans from 12M+ embeddings
2. Phi-4 generates a risk narrative and recommendation
3. Decision is stored in LoanDecisions with tamper-detection hash
4. Agent receives: risk score, decision, narrative, processing time

### Test 5: Review the Decision
```
Show me the scoring decision for application #1
```
**Expected:** Agent calls `read_records` on LoanDecisions with filter `ApplicationId eq 1`.

### Test 6: Full Workflow (Chained)
```
Find a pending loan application, show me the applicant's profile, score the loan, and then show me the decision with the AI narrative.
```
**Expected:** Agent chains multiple tool calls:
1. `read_records` on LoanApplications (filter: Status = Pending)
2. `read_records` on Applicants (filter: ApplicantId from step 1)
3. `execute_entity` on ScoreLoan (ApplicationId from step 1)
4. `read_records` on LoanDecisions (ApplicationId from step 1)

---

## Step 6: View Tool Calls

In the Chat Playground, expand the tool call details to see:

| Detail | What to Look For |
|--------|-----------------|
| **Tool called** | `describe_entities`, `read_records`, or `execute_entity` |
| **Arguments** | Entity name, filters, parameters passed |
| **Response** | Data returned from ZavaLendingDB via SQL MCP Server |

The `execute_entity` call for scoring is the most interesting — you'll see the full result set from `usp_ScoreLoanApplication` including the AI-generated narrative.

---

## Step 7: Configure Tool Approval (Optional)

For the demo, set **Require approval** to `Never` on the MCP tool so the agent can call tools automatically without user confirmation. In production, you'd want approval for `execute_entity` calls since they trigger scoring.

---

## Bonus exercise — publish the agent to Microsoft Teams (optional)

Once the agent works in the Foundry Playground, you can publish it as a **Microsoft Teams app**
so colleagues can score loans right from a Teams chat. This is an **optional** extension — the
agent is fully functional in the Playground without it.

Two supported paths:

- **Portal (fastest):** In the Foundry portal, open your agent → **Publish** →
  **Teams and Microsoft 365 Copilot**. Foundry auto-provisions an Azure Bot Service resource
  and a Microsoft Entra registration, builds the Teams app package, and enables the activity
  protocol for you. Fill in the app metadata (name, version, description, developer) and
  publish. Full steps:
  [Publish agents to Microsoft 365 Copilot and Microsoft Teams (Foundry portal)](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot).
- **Pro-code (customizable):** Use the **Microsoft 365 Agents Toolkit** in VS Code to wrap the
  agent as a custom engine agent — better for SSO, custom logic, and multi-environment
  deployment. Start here:
  [Integrate a Foundry agent with Microsoft 365 using the Agents Toolkit](https://aka.ms/aif2m365-procode)
  and the [Agents Toolkit overview](https://learn.microsoft.com/microsoftteams/platform/toolkit/overview-agents-toolkit).

Background on the two approaches:
[Custom engine agents for Microsoft 365 overview](https://learn.microsoft.com/microsoft-365/copilot/extensibility/overview-custom-engine-agent).

> A Microsoft 365 admin may need to approve the published agent before it appears in Teams.
> Content safety still comes from Azure AI Foundry's built-in content filters — publishing to
> Teams does not require the APIM gateway.

---

## Troubleshooting

### Tool not appearing
- Verify the MCP URL is correct: `https://<app>.azurecontainerapps.io/mcp`
- Check Container App is running: `az containerapp show --name zava-loan-mcp --resource-group rg-zava-loan-mcp --query "properties.runningStatus"`
- Test health: `curl https://<app>.azurecontainerapps.io/health`

### Agent not using the tool
- Ensure the system instructions reference the tool name `zava-loan-scoring-mcp`
- Try more specific questions: "Use the loan scoring tool to find pending applications"

### execute_entity fails
- Verify `usp_ScoreLoanApplication` exists in `zavalending` database
- Check the connection string in Container App secrets
- Check Azure AI Services credential is configured in the database
- Review Container App logs: `az containerapp logs show --name zava-loan-mcp --resource-group rg-zava-loan-mcp --follow`

### No data returned
- Verify Act 2 setup is complete (tables populated)
- Verify Act 3 setup is complete (stored procedure created)
- Check RBAC permissions in dab-config.json

---

## Demo Narrative

> *"We built a loan scoring engine inside SQL Server — vector search, AI reasoning, auditable decisions. Now we need to make it accessible. Not by writing an API. Not by building middleware. We configure a JSON file, deploy a container, and connect it to a Foundry Agent. The agent discovers our schema, queries our data, and executes our scoring procedure — all through MCP. Zero application code."*

---

## Clean Up

```powershell
# Remove all Azure resources
az group delete --name rg-zava-loan-mcp --yes --no-wait
```
