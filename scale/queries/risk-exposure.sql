-- ============================================================
-- Risk Exposure — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Market-Watch
-- Portfolio-level risk computation: full CCI scan of
-- LoanTransactions (55M rows!) with multi-dimensional
-- aggregation by Region + LoanType. Batch mode parallelism
-- across all available vCores. Then INSERTs a risk snapshot.
-- Must run on PRIMARY — writes prevent read-replica offload.
-- CPU profile: VERY HEAVY (run with 1-2 threads only)
-- ============================================================

EXEC dbo.usp_RiskExposure;
