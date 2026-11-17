-- ============================================================
-- Loan Eligibility Check — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Trade-Lookup
-- Pure read-only eligibility check: reads applicant profile,
-- checks existing loans, computes DTI and risk tier.
-- No writes — zero latch pressure. CPU-bound at volume.
-- CPU profile: LIGHT per-call, HIGH at volume
-- ============================================================

DECLARE @id INT = (ABS(CHECKSUM(NEWID())) % (SELECT MAX(ApplicantId) FROM dbo.Applicants)) + 1;
EXEC dbo.usp_LoanEligibility @ApplicantId = @id;
