-- ============================================================
-- Account Review — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Customer-Position
-- Full account pull: reads applicant profile, joins
-- LoanApplications with LoanDecisions, aggregates transaction
-- history from LoanTransactions (NC index range scans),
-- then INSERTs an audit record.
-- Must run on PRIMARY — writes prevent read-replica offload.
-- CPU profile: MEDIUM
-- ============================================================

DECLARE @id INT = (ABS(CHECKSUM(NEWID())) % (SELECT MAX(ApplicantId) FROM dbo.Applicants)) + 1;
EXEC dbo.usp_AccountReview @ApplicantId = @id;
