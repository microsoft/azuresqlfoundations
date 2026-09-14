/*
    ZavaLendingDB — Scale Demo Schema
    SQLCon 2026 — Demo 2: "The Destination: Built for Hyperscale"
    
    Creates columnstore tables for the vCore scale-up demonstration.
    
    SAFE: Does NOT touch existing tables (Applicants, LoanHistory,
    LoanApplications, LoanDecisions). Those are used by Demo 3.
    
    RE-RUNNABLE: Uses DROP IF EXISTS for all new objects.
    
    Target: zavafinsql.database.windows.net / zavalending
    Auth:   Access token (-T)
    
    Run with sqlsim:
      sqlsim.exe -S zavafinsql.database.windows.net -d zavalending -T <token> -i 04-scale-schema.sql -v
*/

-- ============================================
-- SAFETY CHECK: Verify demo tables exist
-- ============================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LoanHistory')
BEGIN
    RAISERROR('ERROR: LoanHistory table not found. Run 01-setup-zava-lending-db.sql first.', 16, 1);
    RETURN;
END
PRINT '=== Existing demo tables verified (not touching them). ==='
GO

-- ============================================
-- DROP EXISTING SCALE OBJECTS (for re-runs)
-- ============================================
DROP TABLE IF EXISTS dbo.LoanTransactions;
DROP TABLE IF EXISTS dbo.MonthlyPortfolioSnapshot;
DROP TABLE IF EXISTS dbo.LoanHistoryExpanded;
DROP TABLE IF EXISTS dbo.PaymentProcessingBatch;
GO
PRINT '=== Dropped any previous scale demo tables. ==='
GO

-- ============================================
-- LoanHistoryExpanded — Extended loan universe
-- for scale workload (500K loans)
-- 
-- This is a SEPARATE table from LoanHistory.
-- LoanHistory (100 rows) stays untouched for Demo 3.
-- LoanTransactions references BOTH tables via UNION views.
-- ============================================
CREATE TABLE dbo.LoanHistoryExpanded (
    LoanId              BIGINT          NOT NULL,
    CONSTRAINT PK_LoanHistoryExpanded PRIMARY KEY CLUSTERED (LoanId),
    ApplicantId         INT             NOT NULL,
    LoanType            NVARCHAR(30)    NOT NULL,
    RequestedAmount     DECIMAL(18,2)   NOT NULL,
    ApprovedAmount      DECIMAL(18,2)   NULL,
    InterestRate        DECIMAL(5,2)    NULL,
    TermMonths          INT             NOT NULL,
    ApplicantIncome     DECIMAL(18,2)   NOT NULL,
    CreditScore         INT             NOT NULL,
    DebtToIncomeRatio   DECIMAL(5,2)    NULL,
    EmploymentYears     DECIMAL(4,1)    NULL,
    LoanPurpose         NVARCHAR(200)   NULL,
    LoanOutcome         NVARCHAR(20)    NOT NULL,
    DefaultRate         DECIMAL(5,4)    NULL,
    ApplicationDate     DATETIME2       NOT NULL,
    DecisionDate        DATETIME2       NULL,
    Region              NVARCHAR(50)    NOT NULL DEFAULT 'US-West',
    Channel             NVARCHAR(20)    NOT NULL DEFAULT 'Web'
);
GO
PRINT '=== Created LoanHistoryExpanded (will hold rows 101-500000). ==='
GO

-- NC index for workload procs to seek by ApplicantId into LoanHistoryExpanded
-- Each of 10,000 applicants has ~50 loans → seek + nested loop to LoanTransactions CCI
CREATE NONCLUSTERED INDEX IX_LoanHistoryExpanded_ApplicantId
    ON dbo.LoanHistoryExpanded (ApplicantId)
    INCLUDE (LoanId, LoanOutcome, ApprovedAmount, InterestRate, DefaultRate);
GO

-- ============================================
-- VIEW: All loans (original 100 + expanded)
-- Queries use this view for joins so both 
-- demo tables are covered.
-- ============================================
IF OBJECT_ID('dbo.vw_AllLoans', 'V') IS NOT NULL
    DROP VIEW dbo.vw_AllLoans;
GO

CREATE VIEW dbo.vw_AllLoans AS
SELECT 
    LoanId, LoanType, RequestedAmount, ApprovedAmount,
    InterestRate, TermMonths, ApplicantIncome, CreditScore,
    DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome,
    DefaultRate, ApplicationDate, DecisionDate
FROM dbo.LoanHistory
UNION ALL
SELECT 
    LoanId, LoanType, RequestedAmount, ApprovedAmount,
    InterestRate, TermMonths, ApplicantIncome, CreditScore,
    DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome,
    DefaultRate, ApplicationDate, DecisionDate
FROM dbo.LoanHistoryExpanded;
GO
PRINT '=== Created vw_AllLoans (UNION of LoanHistory + LoanHistoryExpanded). ==='
GO

-- ============================================
-- LoanTransactions — Columnstore fact table
-- THE STAR OF THE SCALE DEMO
-- ============================================
CREATE TABLE dbo.LoanTransactions (
    TransactionId       BIGINT IDENTITY(1,1) NOT NULL,
    LoanId              BIGINT          NOT NULL,
    TransactionDate     DATE            NOT NULL,
    TransactionType     NVARCHAR(20)    NOT NULL,   -- Payment, Disbursement, InterestAccrual, Fee, Adjustment, Default
    Amount              DECIMAL(18,2)   NOT NULL,
    RunningBalance      DECIMAL(18,2)   NOT NULL,
    InterestComponent   DECIMAL(18,2)   NULL,
    PrincipalComponent  DECIMAL(18,2)   NULL,
    DaysPastDue         INT             NOT NULL DEFAULT 0,
    LoanType            NVARCHAR(30)    NOT NULL,   -- Denormalized for columnstore scan performance
    Region              NVARCHAR(50)    NOT NULL,
    Channel             NVARCHAR(20)    NOT NULL,
    CreditScoreBand     NVARCHAR(20)    NOT NULL,   -- Excellent, Good, Fair, Poor
    ProcessedBy         NVARCHAR(50)    NOT NULL DEFAULT 'AutoPay',
    CreatedAt           DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- CLUSTERED COLUMNSTORE INDEX — the demo centerpiece
-- ORDER(TransactionDate) with MAXDOP 1 ensures non-overlapping segments
-- so date-filtered queries (e.g., usp_BranchActivity) get proper segment elimination.
-- With random insertion order + no ORDER hint, every segment spans the full date range
-- and segment elimination is impossible — all segments get scanned regardless of filter.
CREATE CLUSTERED COLUMNSTORE INDEX CCI_LoanTransactions
    ON dbo.LoanTransactions
    ORDER (TransactionDate)
    WITH (MAXDOP = 1);
GO

-- Nonclustered rowstore for OLTP point lookups during mixed workload
CREATE NONCLUSTERED INDEX IX_LoanTransactions_LoanId 
    ON dbo.LoanTransactions(LoanId, TransactionDate DESC)
    INCLUDE (TransactionType, Amount, RunningBalance, Region, Channel);
GO

PRINT '=== Created LoanTransactions with clustered columnstore index. ==='
GO

-- ============================================
-- MonthlyPortfolioSnapshot — Columnstore summary
-- ============================================
CREATE TABLE dbo.MonthlyPortfolioSnapshot (
    SnapshotMonth       DATE            NOT NULL,
    LoanType            NVARCHAR(30)    NOT NULL,
    Region              NVARCHAR(50)    NOT NULL,
    Channel             NVARCHAR(20)    NOT NULL,
    CreditScoreBand     NVARCHAR(20)    NOT NULL,
    ActiveLoanCount     INT             NOT NULL,
    TotalOutstanding    DECIMAL(18,2)   NOT NULL,
    TotalPayments       DECIMAL(18,2)   NOT NULL,
    TotalDefaults       INT             NOT NULL,
    AvgDaysPastDue      DECIMAL(8,2)    NOT NULL,
    DefaultRate         DECIMAL(5,4)    NOT NULL,
    WeightedAvgRate     DECIMAL(5,2)    NOT NULL,
    PortfolioAtRisk     DECIMAL(18,2)   NOT NULL,
    ProvisionAmount     DECIMAL(18,2)   NOT NULL
);
GO

CREATE CLUSTERED COLUMNSTORE INDEX CCI_MonthlyPortfolioSnapshot ON dbo.MonthlyPortfolioSnapshot;
GO

PRINT '=== Created MonthlyPortfolioSnapshot with clustered columnstore index. ==='
GO

-- ============================================
-- PaymentProcessingBatch — Audit-trail sink for all workload procs
-- Clustered on LoanId to distribute inserts randomly across B-tree pages.
-- LoanId is randomly generated (ABS(CHECKSUM(NEWID())) % 50000 + 1) in each
-- proc, so inserts scatter across the B-tree — no last-page hotspot.
-- Previous design was a heap, which caused PFS allocation page latch contention
-- at 156+ concurrent insert threads. IDENTITY CI was rejected because it creates
-- last-page insert contention. OPTIMIZE_FOR_SEQUENTIAL_KEY was tested and did
-- not help (BTREE_INSERT_FLOW_CONTROL waits).
-- See: latch-contention-analysis.md (March 2026)
-- ============================================
CREATE TABLE dbo.PaymentProcessingBatch (
    BatchRowId       BIGINT IDENTITY(1,1) NOT NULL,
    LoanId           BIGINT          NOT NULL,
    ProcessedDate    DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    TransactionType  NVARCHAR(20)    NOT NULL,
    BatchAmount      DECIMAL(18,2)   NOT NULL,
    PrincipalApplied DECIMAL(18,2)   NOT NULL,
    InterestApplied  DECIMAL(18,2)   NOT NULL,
    FeesApplied      DECIMAL(18,2)   NOT NULL,
    NewBalance       DECIMAL(18,2)   NOT NULL,
    ProcessingStatus NVARCHAR(20)    NOT NULL DEFAULT N'Processed',
    AuditTrail       NVARCHAR(800)   NOT NULL
);
GO
CREATE CLUSTERED INDEX CIX_PaymentProcessingBatch_LoanId ON dbo.PaymentProcessingBatch(LoanId);
GO
PRINT '=== Created PaymentProcessingBatch (clustered on LoanId — random insert distribution). ==='
GO

PRINT ''
PRINT '=== Scale demo schema created successfully. ==='
PRINT 'Next steps:'
PRINT '  1. Generate CSV data: .\05-generate-scale-data.ps1'
PRINT '  2. Load data with bcp: .\06-load-scale-data.ps1'
PRINT '  3. Run workload: .\run-scale-workload.ps1'
GO
