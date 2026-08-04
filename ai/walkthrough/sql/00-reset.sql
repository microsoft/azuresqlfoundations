-- Pre-demo reset: run on PRIMARY before Act 3
-- Cleans up rows from previous demo runs

DELETE FROM dbo.LoanNarrativeEmbeddings WHERE LoanId > 100;
DELETE FROM dbo.LoanHistory WHERE LoanId > 100;
GO

DELETE FROM dbo.LoanDecisions WHERE ApplicationId = 1;
UPDATE dbo.LoanApplications SET Status = 'Pending' WHERE ApplicationId = 1;
GO

SELECT COUNT(*) AS Embeddings FROM dbo.LoanNarrativeEmbeddings;
SELECT COUNT(*) AS LoanHistory FROM dbo.LoanHistory;
GO
