-- ============================================================
-- Branch Activity — Zava Lending Scale Demo
-- ============================================================
-- TPC-E analog: Broker-Volume
-- Daily activity summary: scans recent LoanTransactions via
-- CCI with date filter (segment elimination), aggregates by
-- Channel + Region, counts recent applications from rowstore,
-- then INSERTs a daily summary record.
-- Must run on PRIMARY — writes prevent read-replica offload.
-- CPU profile: MEDIUM (filtered CCI scan + rowstore scan)
-- ============================================================

EXEC dbo.usp_BranchActivity;
