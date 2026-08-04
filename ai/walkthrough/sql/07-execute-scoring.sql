-- Connection: zavalending (PRIMARY)
-- Execute the AI scoring engine in pure T-SQL.
-- usp_ScoreLoanApplication: vector search (V3) -> Phi-4 risk assessment -> auditable decision.
-- This is the SAME proc the Foundry Agent calls via the SQL MCP Server — "one engine, two surfaces."

EXEC dbo.usp_ScoreLoanApplication @ApplicationId = 1;
GO

-- Inspect the stored, tamper-evident decision
SELECT TOP (1)
    ApplicationId,
    Decision,
    RiskScore,
    RiskCategory,
    SimilarLoanCount,
    SimilarApprovalRate,
    ModelVersion,
    ProcessingTimeMs,
    Narrative
FROM dbo.LoanDecisions
WHERE ApplicationId = 1
ORDER BY DecisionId DESC;
GO
