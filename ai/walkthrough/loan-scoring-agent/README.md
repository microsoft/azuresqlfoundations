# Loan Scoring Agent — Walkthrough (optional exercise)

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

> **Optional.** This exercise is **not required** to complete Act 3. Narrative Search and AI
> Loan Scoring both run end-to-end in T-SQL without it. This folder shows how to *use* the
> loan-scoring agent once it's deployed.

The agent exposes the same `usp_ScoreLoanApplication` procedure — vector search + Phi-4 scoring
— as an MCP tool through Data API Builder (DAB), then drives it from a Microsoft Foundry agent.
**One engine, two surfaces.**

## Before you start

Deploy the pieces from [../../build/loan-scoring-agent/](../../build/loan-scoring-agent/):

1. `deploy-sql-mcp-server.ps1` — deploy the DAB SQL MCP server to Azure Container Apps.
2. `deploy-foundry-agent.ps1` — provision the Foundry agent against the MCP endpoint.

See the build [README.md](../../build/loan-scoring-agent/README.md) for architecture, the tool
list, and the MCP call sequence.

## What's here

| File | Purpose |
|------|---------|
| [foundry-agent-setup.md](foundry-agent-setup.md) | Step-by-step portal guide: connect the SQL MCP server to Azure AI Foundry, create the agent, add the MCP tool, and run example prompts (schema discovery → list pending → score a loan → review the decision). |
| [test-foundry-agent.ps1](test-foundry-agent.ps1) | Scripted test that exercises the deployed agent end-to-end. |

## Bonus exercise (optional) — publish to Microsoft Teams

After the agent works in the Foundry Playground, you can publish it as a **Microsoft Teams app**
so colleagues can score loans from a Teams chat. Two paths — the Foundry portal **Publish →
Teams and Microsoft 365 Copilot** flow (auto-provisions Azure Bot Service + Entra + the Teams
app package), or the pro-code **Microsoft 365 Agents Toolkit**. Full steps are in the **Bonus
exercise** section of [foundry-agent-setup.md](foundry-agent-setup.md).

## Clean up

When you're done, remove the Azure resources you created — see the **Clean Up** section at the
end of [foundry-agent-setup.md](foundry-agent-setup.md).
