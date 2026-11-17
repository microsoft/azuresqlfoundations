-- ============================================================
-- Payment Processing — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Trade-Result
-- Reads current loan balance via NC index seek, reads loan
-- terms from LoanHistory, computes interest/principal split,
-- then INSERTs a wide payment record into PaymentProcessingBatch.
-- Must run on PRIMARY — writes prevent read-replica offload.
-- CPU profile: LIGHT (high concurrency)
-- ============================================================

EXEC dbo.usp_PaymentProcessing;
