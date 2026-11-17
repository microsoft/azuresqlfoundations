-- ============================================================
-- Loan Application — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Trade-Order
-- Multi-step stored procedure: reads applicant profile,
-- scans LoanTransactions CCI for similar-loan risk analysis
-- (~3.5M rows batch mode), then INSERTs application + decision
-- and UPDATEs applicant record.
-- Must run on PRIMARY — writes prevent read-replica offload.
-- CPU profile: MEDIUM-HEAVY
-- ============================================================

DECLARE @id INT = (ABS(CHECKSUM(NEWID())) % (SELECT MAX(ApplicantId) FROM dbo.Applicants)) + 1;
EXEC dbo.usp_LoanApplication @ApplicantId = @id;
