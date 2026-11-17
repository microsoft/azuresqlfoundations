-- ============================================================
-- TPC-E Style Workload Stored Procedures — Zava Lending Scale Demo
-- ============================================================
-- Creates 6 stored procedures that simulate realistic lending
-- transactions. Five mix reads AND writes so they MUST run
-- on the primary replica. One (LoanEligibility) is pure read-only.
--
-- Modeled after TPC-E transaction types:
--   1. usp_LoanApplication    (Trade-Order)   — submit application
--   2. usp_PaymentProcessing   (Trade-Result)  — process payment
--   3. usp_AccountReview       (Customer-Position) — full account pull
--   4. usp_RiskExposure        (Market-Watch)  — portfolio analytics
--   5. usp_BranchActivity      (Broker-Volume) — daily activity summary
--   6. usp_LoanEligibility     (Trade-Lookup)  — eligibility check (pure read)
--
-- Run this script ONCE before running the workload phases.
-- ============================================================

-- ============================================================
-- CLEANUP: Remove workload-generated rows from prior runs
-- ============================================================
DELETE d FROM dbo.LoanDecisions d WHERE d.DecidedBy = 'ScaleWorkload';
DELETE a FROM dbo.LoanApplications a WHERE a.LoanPurpose = 'Scale workload test';
TRUNCATE TABLE dbo.PaymentProcessingBatch;

-- Reset LoanTransactions to pre-loaded baseline (5,797,985 rows)
-- Workload procs INSERT payment/disbursement rows during each run;
-- this removes them so the demo is repeatable.
DECLARE @Baseline BIGINT = 5797985;
DECLARE @CurrentMax BIGINT = (SELECT MAX(TransactionId) FROM dbo.LoanTransactions);
IF @CurrentMax > @Baseline
BEGIN
    DELETE FROM dbo.LoanTransactions WHERE TransactionId > @Baseline;
    ALTER INDEX CCI_LoanTransactions ON dbo.LoanTransactions REORGANIZE;
    DBCC CHECKIDENT('dbo.LoanTransactions', RESEED, @Baseline);
    PRINT CONCAT('Reset LoanTransactions: deleted ', @CurrentMax - @Baseline, ' workload rows, reseeded to ', @Baseline);
END
ELSE
    PRINT CONCAT('LoanTransactions already at baseline (', ISNULL(@CurrentMax, 0), ' rows).');

-- ============================================================
-- CLUSTERED INDEX RESTRUCTURE: Distribute inserts across pages
-- ============================================================
-- Leading with ApplicantId (10,000 values) distributes inserts across ~10,000 pages
-- instead of converging on a single last page (sequential identity key).
-- PK becomes the CI itself — no separate NC PK on the identity column.
-- FK_LoanDecisions_Applications must be dropped/recreated as a composite FK
-- referencing the new composite PK.

-- Pre-req: LoanDecisions needs ApplicantId column for composite PK/FK
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LoanDecisions') AND name = 'ApplicantId')
BEGIN
    ALTER TABLE dbo.LoanDecisions ADD ApplicantId INT NOT NULL DEFAULT 0;
    PRINT 'LoanDecisions: Added ApplicantId column';
END
ELSE IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LoanDecisions') AND name = 'ApplicantId' AND is_nullable = 1)
BEGIN
    -- Fix up if previously added as NULL (needed for PK)
    UPDATE dbo.LoanDecisions SET ApplicantId = 0 WHERE ApplicantId IS NULL;
    ALTER TABLE dbo.LoanDecisions ALTER COLUMN ApplicantId INT NOT NULL;
    PRINT 'LoanDecisions: Fixed ApplicantId to NOT NULL';
END
GO

-- Step 1: LoanApplications — PK CLUSTERED (ApplicantId, ApplicationId)
-- Check if PK already leads with ApplicantId (our target state)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    WHERE i.object_id = OBJECT_ID('dbo.LoanApplications')
      AND i.is_primary_key = 1 AND i.type_desc = 'CLUSTERED'
      AND ic.key_ordinal = 1 AND COL_NAME(ic.object_id, ic.column_id) = 'ApplicantId'
)
BEGIN
    -- Drop ALL FKs from LoanDecisions that reference LoanApplications (may have system-generated names)
    DECLARE @fkDrop NVARCHAR(MAX) = '';
    SELECT @fkDrop = @fkDrop + 'ALTER TABLE dbo.LoanDecisions DROP CONSTRAINT ' + QUOTENAME(fk.name) + '; '
    FROM sys.foreign_keys fk
    WHERE fk.parent_object_id = OBJECT_ID('dbo.LoanDecisions')
      AND fk.referenced_object_id = OBJECT_ID('dbo.LoanApplications');
    IF LEN(@fkDrop) > 0 EXEC(@fkDrop);
    -- Drop existing PK (may have system-generated or explicit name)
    DECLARE @pkApp NVARCHAR(256) = (SELECT name FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID('dbo.LoanApplications') AND type = 'PK');
    IF @pkApp IS NOT NULL
        EXEC('ALTER TABLE dbo.LoanApplications DROP CONSTRAINT ' + @pkApp);
    -- Drop old CI if it exists
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'CX_LoanApplications'
               AND object_id = OBJECT_ID('dbo.LoanApplications'))
        DROP INDEX CX_LoanApplications ON dbo.LoanApplications;
    -- Create PK as clustered
    ALTER TABLE dbo.LoanApplications
        ADD CONSTRAINT PK_LoanApplications PRIMARY KEY CLUSTERED (ApplicantId, ApplicationId);
    PRINT 'LoanApplications: PK CLUSTERED (ApplicantId, ApplicationId)';
END
ELSE
    PRINT 'LoanApplications: PK already clustered on (ApplicantId, ...) — no change';
GO

-- Step 2: LoanDecisions — PK CLUSTERED (ApplicantId, DecisionId)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    WHERE i.object_id = OBJECT_ID('dbo.LoanDecisions')
      AND i.is_primary_key = 1 AND i.type_desc = 'CLUSTERED'
      AND ic.key_ordinal = 1 AND COL_NAME(ic.object_id, ic.column_id) = 'ApplicantId'
)
BEGIN
    DECLARE @pkDec NVARCHAR(256) = (SELECT name FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID('dbo.LoanDecisions') AND type = 'PK');
    IF @pkDec IS NOT NULL
        EXEC('ALTER TABLE dbo.LoanDecisions DROP CONSTRAINT ' + @pkDec);
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'CX_LoanDecisions'
               AND object_id = OBJECT_ID('dbo.LoanDecisions'))
        DROP INDEX CX_LoanDecisions ON dbo.LoanDecisions;
    ALTER TABLE dbo.LoanDecisions
        ADD CONSTRAINT PK_LoanDecisions PRIMARY KEY CLUSTERED (ApplicantId, DecisionId);
    PRINT 'LoanDecisions: PK CLUSTERED (ApplicantId, DecisionId)';
END
ELSE
    PRINT 'LoanDecisions: PK already clustered on (ApplicantId, ...) — no change';
GO

-- Step 3: Recreate FK as composite (ApplicantId, ApplicationId) → PK_LoanApplications
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LoanDecisions_Applications')
BEGIN
    ALTER TABLE dbo.LoanDecisions
        ADD CONSTRAINT FK_LoanDecisions_Applications
        FOREIGN KEY (ApplicantId, ApplicationId)
        REFERENCES dbo.LoanApplications (ApplicantId, ApplicationId);
    PRINT 'FK_LoanDecisions_Applications recreated as composite FK';
END
ELSE
    PRINT 'FK_LoanDecisions_Applications already exists — no change';
GO

-- ============================================================
-- NONCLUSTERED INDEXES: Support query patterns
-- ============================================================

-- Ensure covering NC index on LoanHistoryExpanded for LoanApplication risk lookup
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanHistoryExpanded_TypeScore'
               AND object_id = OBJECT_ID('dbo.LoanHistoryExpanded'))
    CREATE NONCLUSTERED INDEX IX_LoanHistoryExpanded_TypeScore
        ON dbo.LoanHistoryExpanded (LoanType, CreditScore)
        INCLUDE (DefaultRate, LoanOutcome, ApprovedAmount);
GO

-- DROPPED: IX_LoanApplications_ApplicantId is no longer used by any query.
-- AccountReview Step 2 and LoanApplication Step 2 now use PK_LoanApplications (CI)
-- due to the (ApplicantId, ApplicationId) join predicate + 90-day date filter.
-- LoanEligibility no longer queries LoanApplications at all.
-- The NC index was pure overhead: EX latches on every INSERT (109K waits / 476K ms
-- in Phase 5 at 128v/600u) with zero read benefit.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanApplications_ApplicantId'
           AND object_id = OBJECT_ID('dbo.LoanApplications'))
    DROP INDEX IX_LoanApplications_ApplicantId ON dbo.LoanApplications;
GO

-- DROPPED: IX_LoanApplications_AppDate caused last-page latch contention
-- (ApplicationDate is monotonically increasing → 250K latch waits / 5.2M ms).
-- BranchActivity Step 3 now does a CI scan (acceptable at 4 fixed threads).
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanApplications_AppDate'
           AND object_id = OBJECT_ID('dbo.LoanApplications'))
    DROP INDEX IX_LoanApplications_AppDate ON dbo.LoanApplications;
GO

-- DROPPED: IX_LoanDecisions_ApplicationId caused PAGELATCH_EX contention.
-- ApplicationId is monotonically increasing (identity) → last-page hot spot on every INSERT
-- (270K latch waits / 2.68M ms in Phase 5 at 128v/600u).
-- The two LEFT JOINs that used it (usp_LoanApplication Step 2, usp_AccountReview Step 2)
-- now join on (ApplicantId, ApplicationId) → CI seek on PK_LoanDecisions (27.6x cheaper).
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanDecisions_ApplicationId'
           AND object_id = OBJECT_ID('dbo.LoanDecisions'))
    DROP INDEX IX_LoanDecisions_ApplicationId ON dbo.LoanDecisions;
GO

-- NC index for usp_LoanEligibility Step 2 and usp_LoanApplication Step 3.
-- Eliminates 103-row CI scan per call (7.7M execs/phase) → ~2 read seeks.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanHistory_ApplicantId'
               AND object_id = OBJECT_ID('dbo.LoanHistory'))
    CREATE NONCLUSTERED INDEX IX_LoanHistory_ApplicantId
        ON dbo.LoanHistory (ApplicantId)
        INCLUDE (ApprovedAmount, InterestRate);
GO

-- ============================================================
-- Pre-aggregate LoanHistoryExpanded → LoanRiskSummary (16 rows)
-- Eliminates 31K-row scan per usp_LoanApplication call.
-- LoanHistoryExpanded is static (loaded once, never written to
-- during workload), so these aggregates are constants.
-- 4 LoanTypes × 4 CreditBands = 16 rows.
-- ============================================================
DROP TABLE IF EXISTS dbo.LoanRiskSummary;
GO

CREATE TABLE dbo.LoanRiskSummary (
    LoanType        NVARCHAR(30)    NOT NULL,
    CreditBand      NVARCHAR(20)    NOT NULL,
    AvgDefaultRate   DECIMAL(5,4)   NOT NULL,
    LoanCount        INT            NOT NULL,
    AvgDaysPastDue   FLOAT          NOT NULL,
    AtRiskBalance    DECIMAL(18,2)  NOT NULL,
    CONSTRAINT PK_LoanRiskSummary PRIMARY KEY CLUSTERED (LoanType, CreditBand)
);
GO

INSERT INTO dbo.LoanRiskSummary (LoanType, CreditBand, AvgDefaultRate, LoanCount, AvgDaysPastDue, AtRiskBalance)
SELECT 
    LoanType,
    CASE WHEN CreditScore >= 750 THEN 'Excellent'
         WHEN CreditScore >= 700 THEN 'Good'
         WHEN CreditScore >= 650 THEN 'Fair'
         ELSE 'Poor' END AS CreditBand,
    AVG(DefaultRate),
    COUNT(*),
    AVG(CASE WHEN LoanOutcome = 'Default' THEN 90.0
             WHEN DefaultRate > 0.05 THEN 30.0
             ELSE 0.0 END),
    SUM(CASE WHEN LoanOutcome = 'Default' THEN ISNULL(ApprovedAmount, 0) ELSE 0 END)
FROM dbo.LoanHistoryExpanded
GROUP BY LoanType,
    CASE WHEN CreditScore >= 750 THEN 'Excellent'
         WHEN CreditScore >= 700 THEN 'Good'
         WHEN CreditScore >= 650 THEN 'Fair'
         ELSE 'Poor' END;
GO

DECLARE @SummaryCount INT = (SELECT COUNT(*) FROM dbo.LoanRiskSummary);
PRINT CONCAT('=== Created LoanRiskSummary: ', @SummaryCount, ' pre-aggregated rows (from 500K LoanHistoryExpanded). ===');
GO

-- ============================================================
-- Credit Scoring Scorecard Rules (3,000 rows)
-- ============================================================
-- Table-driven scoring model used by usp_LoanEligibility.
-- Each call scans the full table with conditional math per row.
-- Serial plan, ~5ms CPU per call — scales by running more
-- concurrent calls across more schedulers.
-- ============================================================
IF OBJECT_ID('dbo.ScoreCardRules', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ScoreCardRules (
        RuleId INT IDENTITY(1,1) PRIMARY KEY,
        Category NVARCHAR(30) NOT NULL,
        SubCategory NVARCHAR(30) NOT NULL,
        MinValue DECIMAL(18,2) NOT NULL,
        MaxValue DECIMAL(18,2) NOT NULL,
        Weight DECIMAL(10,4) NOT NULL,
        Multiplier DECIMAL(10,4) NOT NULL DEFAULT 1.0,
        MathFunction NVARCHAR(20) NOT NULL DEFAULT 'LINEAR'
    );

    -- Populate base rules: 10 categories × 50 bands = 500 rows
    DECLARE @i INT = 1;
    WHILE @i <= 50
    BEGIN
        INSERT INTO dbo.ScoreCardRules (Category, SubCategory, MinValue, MaxValue, Weight, Multiplier, MathFunction)
        VALUES
        ('CreditScore', 'Band' + CAST(@i AS VARCHAR), 500 + (@i-1)*8, 500 + @i*8, CAST((@i - 25) * 1.2 AS DECIMAL(10,4)), 1.0 + @i * 0.02, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' WHEN 2 THEN 'POWER' ELSE 'LINEAR' END),
        ('Income', 'Band' + CAST(@i AS VARCHAR), (@i-1)*5000, @i*5000, CAST((@i - 25) * 0.8 AS DECIMAL(10,4)), 1.0 + @i * 0.015, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' WHEN 2 THEN 'POWER' ELSE 'LINEAR' END),
        ('DTI', 'Band' + CAST(@i AS VARCHAR), (@i-1)*2, @i*2, CAST((25 - @i) * 1.5 AS DECIMAL(10,4)), 1.0 + @i * 0.01, CASE @i % 3 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' ELSE 'POWER' END),
        ('LoanAmount', 'Band' + CAST(@i AS VARCHAR), (@i-1)*4000, @i*4000, CAST((25 - @i) * 0.9 AS DECIMAL(10,4)), 1.0 + @i * 0.012, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' WHEN 2 THEN 'POWER' ELSE 'LINEAR' END),
        ('Rate', 'Band' + CAST(@i AS VARCHAR), (@i-1)*0.5, @i*0.5, CAST((15 - @i) * 0.6 AS DECIMAL(10,4)), 1.0 + @i * 0.008, CASE @i % 3 WHEN 0 THEN 'SQRT' WHEN 1 THEN 'POWER' ELSE 'LINEAR' END),
        ('Exposure', 'Band' + CAST(@i AS VARCHAR), (@i-1)*10000, @i*10000, CAST((25 - @i) * 1.1 AS DECIMAL(10,4)), 1.0 + @i * 0.018, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' WHEN 2 THEN 'POWER' ELSE 'LINEAR' END),
        ('ExistingLoans', 'Band' + CAST(@i AS VARCHAR), (@i-1)*1, @i*1, CAST((10 - @i) * 2.0 AS DECIMAL(10,4)), 1.0 + @i * 0.025, CASE @i % 3 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' ELSE 'LINEAR' END),
        ('InteractionCreditDTI', 'Band' + CAST(@i AS VARCHAR), (@i-1)*200, @i*200, CAST((@i - 25) * 0.5 AS DECIMAL(10,4)), 1.0, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'SQRT' WHEN 2 THEN 'POWER' ELSE 'LINEAR' END),
        ('RegionalRisk', 'Band' + CAST(@i AS VARCHAR), @i, @i, CAST(ABS(CHECKSUM(NEWID()) % 20 - 10) AS DECIMAL(10,4)), 1.0 + ABS(CHECKSUM(NEWID()) % 50) * 0.001, CASE @i % 3 WHEN 0 THEN 'SQRT' WHEN 1 THEN 'LOG' ELSE 'LINEAR' END),
        ('StabilityScore', 'Band' + CAST(@i AS VARCHAR), (@i-1)*3, @i*3, CAST((@i - 25) * 0.7 AS DECIMAL(10,4)), 1.0 + @i * 0.01, CASE @i % 4 WHEN 0 THEN 'LOG' WHEN 1 THEN 'POWER' WHEN 2 THEN 'SQRT' ELSE 'LINEAR' END);
        SET @i = @i + 1;
    END;

    -- Expand to ~3,000 rows by duplicating with variations
    INSERT INTO dbo.ScoreCardRules (Category, SubCategory, MinValue, MaxValue, Weight, Multiplier, MathFunction)
    SELECT Category, SubCategory + '_v' + CAST(v.n AS VARCHAR),
           MinValue + v.n * 0.01, MaxValue + v.n * 0.01,
           Weight * (1.0 + v.n * 0.001), Multiplier * (1.0 + v.n * 0.0005),
           MathFunction
    FROM dbo.ScoreCardRules
    CROSS JOIN (VALUES (1),(2),(3),(4),(5)) v(n)
    WHERE RuleId <= 500;

    DECLARE @ScoreCardCount INT = (SELECT COUNT(*) FROM dbo.ScoreCardRules);
    PRINT CONCAT('=== Created ScoreCardRules: ', @ScoreCardCount, ' scoring rules. ===');
END
ELSE
BEGIN
    DECLARE @ExistingCount INT = (SELECT COUNT(*) FROM dbo.ScoreCardRules);
    PRINT CONCAT('=== ScoreCardRules already exists: ', @ExistingCount, ' rows. ===');
END
GO

PRINT '=== Cleaned up prior workload data ==='
GO

-- ============================================================
-- 1. usp_LoanApplication — Submit a Loan Application
-- ============================================================
-- TPC-E analog: Trade-Order
-- Steps:
--   1. Read applicant profile (B-tree seek, 1 row)
--   2. Duplicate application check — count recent apps for same applicant
--      (clustered index range scan + aggregation — CPU work)
--   3. Income verification — aggregate payment history across applicant's
--      existing loans (multi-table join + CCI aggregation — CPU-heavy)
--   4. Look up LoanRiskSummary (16 rows, PK seek) for pre-aggregated risk metrics
--   5. Compute risk score from aggregated metrics + verification results
--   6. INSERT new LoanApplication (single auto-commit — no explicit txn needed)
--
-- Note: LoanDecision is a separate internal process that runs after AI scoring.
-- The decision proc would be called asynchronously after reviewing scoring results.
--
-- CPU profile: MEDIUM (CCI scan + joins + aggregation + 1 write)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_LoanApplication
    @ApplicantId INT
AS
SET NOCOUNT ON;
DECLARE @CreditScore INT, @Income DECIMAL(18,2), @DTI DECIMAL(5,2), @Region NVARCHAR(50);

-- Step 1: Read applicant profile (index seek)
SELECT @CreditScore = CreditScore, @Income = AnnualIncome,
       @DTI = DebtToIncomeRatio, @Region = Region
FROM dbo.Applicants
WHERE ApplicantId = @ApplicantId;

-- Step 2: Duplicate application check — count recent apps for this applicant
-- Scans LoanApplications CI range (CPU work)
DECLARE @RecentAppCount INT;
SELECT @RecentAppCount = COUNT(*)
FROM dbo.LoanApplications
WHERE ApplicantId = @ApplicantId
  AND ApplicationDate >= DATEADD(DAY, -90, GETDATE());

-- Step 3: Income verification — aggregate payment history across borrower's loans
-- Multi-table join: LoanHistory → LoanTransactions CCI aggregation (CPU-heavy)
DECLARE @TotalPaid DECIMAL(18,2), @TotalOutstanding DECIMAL(18,2),
        @MaxDPD INT, @LoanCount INT;
SELECT @TotalPaid = SUM(CASE WHEN t.TransactionType = 'Payment' THEN t.Amount ELSE 0 END),
       @TotalOutstanding = SUM(t.RunningBalance),
       @MaxDPD = MAX(t.DaysPastDue),
       @LoanCount = COUNT(DISTINCT h.LoanId)
FROM dbo.LoanHistory h
INNER JOIN dbo.LoanTransactions t ON t.LoanId = h.LoanId
WHERE h.ApplicantId = @ApplicantId;

-- Determine credit band for score range lookup
DECLARE @Band NVARCHAR(20) = CASE
    WHEN @CreditScore >= 750 THEN 'Excellent'
    WHEN @CreditScore >= 700 THEN 'Good'
    WHEN @CreditScore >= 650 THEN 'Fair'
    ELSE 'Poor'
END;

-- Random loan parameters (use CASE not CHOOSE — CHOOSE can return NULL under concurrency)
DECLARE @rndType INT = ABS(CHECKSUM(NEWID()) % 4);
DECLARE @LoanType NVARCHAR(30) = CASE @rndType
    WHEN 0 THEN 'Auto' WHEN 1 THEN 'Personal'
    WHEN 2 THEN 'SmallBusiness' ELSE 'HomeImprovement' END;
DECLARE @Amount DECIMAL(18,2) = CAST(5000 + ABS(CHECKSUM(NEWID()) % 195000) AS DECIMAL(18,2));
DECLARE @rndTerm INT = ABS(CHECKSUM(NEWID()) % 5);
DECLARE @Term INT = CASE @rndTerm
    WHEN 0 THEN 12 WHEN 1 THEN 24 WHEN 2 THEN 36
    WHEN 3 THEN 48 ELSE 60 END;

-- Step 4: Look up pre-aggregated risk metrics from LoanRiskSummary
-- (16 rows, PK seek by LoanType + CreditBand — zero parallelism, zero contention)
DECLARE @SimDefaultRate DECIMAL(5,4), @SimCount INT, @AvgDPD FLOAT, @AtRiskBal DECIMAL(18,2);

SELECT @SimDefaultRate = AvgDefaultRate,
       @SimCount = LoanCount,
       @AvgDPD = AvgDaysPastDue,
       @AtRiskBal = AtRiskBalance
FROM dbo.LoanRiskSummary
WHERE LoanType = @LoanType
  AND CreditBand = @Band;

-- Step 5: Compute risk score (blended from credit score + verification results)
-- Factor in existing loan exposure and recent application velocity
DECLARE @ExposureFactor DECIMAL(5,2) = CASE
    WHEN ISNULL(@TotalOutstanding, 0) > 500000 THEN 15.0
    WHEN ISNULL(@TotalOutstanding, 0) > 200000 THEN 10.0
    WHEN ISNULL(@TotalOutstanding, 0) > 100000 THEN 5.0
    ELSE 0.0 END;
DECLARE @VelocityFactor DECIMAL(5,2) = CASE
    WHEN ISNULL(@RecentAppCount, 0) > 5 THEN 20.0
    WHEN ISNULL(@RecentAppCount, 0) > 3 THEN 10.0
    ELSE 0.0 END;

DECLARE @Risk DECIMAL(5,2) = CAST(
    CASE WHEN @CreditScore >= 750 THEN 10 + ABS(CHECKSUM(NEWID()) % 20)
         WHEN @CreditScore >= 700 THEN 30 + ABS(CHECKSUM(NEWID()) % 25)
         WHEN @CreditScore >= 650 THEN 55 + ABS(CHECKSUM(NEWID()) % 20)
         ELSE 75 + ABS(CHECKSUM(NEWID()) % 25)
    END AS DECIMAL(5,2));
-- Cap at 99 after adding exposure/velocity factors
SET @Risk = CASE WHEN @Risk + @ExposureFactor + @VelocityFactor > 99 THEN 99
                 ELSE @Risk + @ExposureFactor + @VelocityFactor END;

-- Step 6: INSERT new loan application (auto-commit, no explicit txn needed)
DECLARE @rndCh INT = ABS(CHECKSUM(NEWID()) % 4);
DECLARE @Channel NVARCHAR(20) = CASE @rndCh
    WHEN 0 THEN 'Web' WHEN 1 THEN 'Mobile'
    WHEN 2 THEN 'Branch' ELSE 'PartnerAPI' END;

INSERT INTO dbo.LoanApplications
    (ApplicantId, LoanType, RequestedAmount, TermMonths, LoanPurpose, Channel, Status)
VALUES
    (@ApplicantId, @LoanType, @Amount, @Term, 'Scale workload test',
     @Channel, 'Submitted');

-- Note: LoanTransactions CCI is read-only during OLTP workload.
-- Bulk transactions are consolidated in Phase 8 (nightly batch ETL).
-- This avoids CCI delta store latch contention under high concurrency.
GO

PRINT '=== Created usp_LoanApplication ==='
GO

-- ============================================================
-- 2. usp_PaymentProcessing — Process a Loan Payment
-- ============================================================
-- TPC-E analog: Trade-Result
-- Steps:
--   1. Read current loan balance (NC index seek on LoanTransactions)
--   2. Read loan terms from LoanHistory (B-tree seek)
--   3. Fraud velocity check — scan recent transactions for suspicious frequency
--      (CCI range scan with date filter + aggregation — CPU-heavy)
--   4. Amortization recalc — compute remaining balance from full payment history
--      (CCI aggregation scan — CPU-heavy)
--   5. Calculate interest/principal split
--   6. INSERT audit row into PaymentProcessingBatch
--
-- Note: LoanTransactions CCI is read-only during OLTP workload.
-- Bulk transactions are consolidated in Phase 8 (nightly batch ETL).
-- This avoids CCI delta store latch contention under high concurrency.
--
-- CPU profile: MEDIUM (CCI scans + aggregations + one write)
-- High concurrency — many threads running this simultaneously
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_PaymentProcessing
AS
SET NOCOUNT ON;

-- Pick random loan
DECLARE @LoanId BIGINT = (ABS(CHECKSUM(NEWID()) % 50000)) + 1;
DECLARE @Balance DECIMAL(18,2), @DPD INT, @LoanType NVARCHAR(30), @Region NVARCHAR(50);

-- Step 1: Read current balance (NC index seek on IX_LoanTransactions_LoanId)
SELECT TOP 1 @Balance = RunningBalance, @DPD = DaysPastDue,
             @LoanType = LoanType, @Region = Region
FROM dbo.LoanTransactions
WHERE LoanId = @LoanId
ORDER BY TransactionDate DESC;

-- Step 2: Read loan terms from LoanHistory (B-tree seek)
DECLARE @Rate DECIMAL(5,2), @TermMonths INT;
DECLARE @ApplicantId INT;
SELECT TOP 1 @Rate = InterestRate, @TermMonths = TermMonths,
             @ApplicantId = ApplicantId
FROM dbo.LoanHistory
WHERE LoanId = @LoanId;

-- Step 3: Fraud velocity check — count recent transactions for this loan
-- Scans CCI with date filter (segment elimination) + aggregation = CPU work
DECLARE @RecentTxnCount INT, @RecentTxnTotal DECIMAL(18,2), @FraudFlag BIT = 0;
SELECT @RecentTxnCount = COUNT(*),
       @RecentTxnTotal = SUM(Amount)
FROM dbo.LoanTransactions
WHERE LoanId = @LoanId
  AND TransactionDate >= DATEADD(DAY, -30, GETDATE());

-- Flag suspicious velocity (>5 payments in 30 days or >$50K total)
IF @RecentTxnCount > 5 OR ISNULL(@RecentTxnTotal, 0) > 50000
    SET @FraudFlag = 1;

-- Step 4: Amortization recalc — compute actual vs expected balance
-- Full history aggregation across all transactions for this loan (CCI scan + aggregation)
DECLARE @TotalPaid DECIMAL(18,2), @TotalInterest DECIMAL(18,2), @PaymentCount INT;
SELECT @TotalPaid = SUM(CASE WHEN TransactionType = 'Payment' THEN Amount ELSE 0 END),
       @TotalInterest = SUM(CASE WHEN TransactionType = 'Interest' THEN Amount ELSE 0 END),
       @PaymentCount = COUNT(*)
FROM dbo.LoanTransactions
WHERE LoanId = @LoanId;

-- Step 5: Calculate payment components
DECLARE @PayAmt DECIMAL(18,2) = CAST(100 + ABS(CHECKSUM(NEWID()) % 2000) AS DECIMAL(18,2));
DECLARE @IntPart DECIMAL(18,2) = @PayAmt * ISNULL(@Rate, 6.0) / 100.0;
DECLARE @PrinPart DECIMAL(18,2) = @PayAmt - @IntPart;

-- Step 6: INSERT into PaymentProcessingBatch (audit trail for payment)
DECLARE @NewBalance DECIMAL(18,2) = ISNULL(@Balance, 10000) - @PrinPart;

INSERT INTO dbo.PaymentProcessingBatch
    (LoanId, TransactionType, BatchAmount, PrincipalApplied,
     InterestApplied, FeesApplied, NewBalance, AuditTrail)
VALUES
    (@LoanId, 'Payment', @PayAmt, @PrinPart, @IntPart, 0,
     @NewBalance,
     CONCAT('LoanType=', ISNULL(@LoanType, '?'), ' Region=', ISNULL(@Region, '?'),
            ' DPD=', ISNULL(@DPD, 0), ' Rate=', ISNULL(@Rate, 0),
            ' Fraud=', @FraudFlag,
            ' TotalPaid=$', CAST(ISNULL(@TotalPaid, 0) AS INT),
            ' Payments=', ISNULL(@PaymentCount, 0)));
GO

PRINT '=== Created usp_PaymentProcessing ==='
GO

-- ============================================================
-- 3. usp_AccountReview — Full Account Review (Customer Position)
-- ============================================================
-- TPC-E analog: Customer-Position
-- Steps:
--   1. Read applicant profile
--   2. Read all loan applications + decisions for this applicant
--   3. Aggregate transaction history across applicant's loans
--      (NC index range scans on LoanTransactions)
--   4. Compute account summary statistics
--
-- LastReviewDate UPDATE removed — it took EX page latches on the tiny
-- Applicants table (2-3 pages / 1,000 rows) 265K times per run, blocking
-- SH readers in LoanEligibility (359 threads) and LoanApplication (60 threads).
-- Review timestamps belong in an activity log, not the customer master row.
--
-- CPU profile: MEDIUM-HIGH (multi-join + CCI aggregation + trend analysis, pure read)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_AccountReview
    @ApplicantId INT
AS
SET NOCOUNT ON;
DECLARE @Name NVARCHAR(200), @CreditScore INT, @Income DECIMAL(18,2), @Region NVARCHAR(50);

-- Step 1: Read applicant profile
SELECT @Name = FirstName + ' ' + LastName,
       @CreditScore = CreditScore,
       @Income = AnnualIncome,
       @Region = Region
FROM dbo.Applicants
WHERE ApplicantId = @ApplicantId;

-- Step 2: Read recent applications + decisions (90-day window, matches LoanApplication)
-- Full history is a back-office report; website dashboard shows recent activity only.
-- The date filter keeps row estimates low → stable Nested Loops plan under concurrency.
DECLARE @AppCount INT, @ApprovedCount INT, @TotalRequested DECIMAL(18,2), @TotalApproved DECIMAL(18,2);

SELECT @AppCount = COUNT(*),
       @ApprovedCount = SUM(CASE WHEN d.Decision IN ('Approved', 'ConditionallyApproved') THEN 1 ELSE 0 END),
       @TotalRequested = SUM(a.RequestedAmount),
       @TotalApproved = SUM(ISNULL(d.ApprovedAmount, 0))
FROM dbo.LoanApplications a
LEFT JOIN dbo.LoanDecisions d ON d.ApplicantId = a.ApplicantId AND d.ApplicationId = a.ApplicationId
WHERE a.ApplicantId = @ApplicantId
  AND a.ApplicationDate >= DATEADD(DAY, -90, GETDATE());

-- Step 3: Aggregate transaction history for this applicant's loans
-- Joins LoanHistory to get applicant's loan IDs, then aggregates from LoanTransactions
-- CCI ordered on TransactionDate, not LoanId → no segment elimination → CPU-bound scan
DECLARE @TotalPaid DECIMAL(18,2), @TotalOutstanding DECIMAL(18,2), @MaxDPD INT, @TxnCount INT;
DECLARE @AvgPaymentAmt DECIMAL(18,2), @PaymentStdDev FLOAT,
        @OnTimePct DECIMAL(5,2), @AvgDPD FLOAT,
        @EarlyPayPct DECIMAL(5,2), @LatePayPct DECIMAL(5,2);

SELECT @TotalPaid = SUM(CASE WHEN t.TransactionType = 'Payment' THEN t.Amount ELSE 0 END),
       @TotalOutstanding = SUM(CASE WHEN t.TransactionType != 'Payment' THEN t.RunningBalance ELSE 0 END),
       @MaxDPD = MAX(t.DaysPastDue),
       @TxnCount = COUNT(*),
       @AvgPaymentAmt = AVG(CASE WHEN t.TransactionType = 'Payment' THEN t.Amount END),
       @PaymentStdDev = STDEVP(CASE WHEN t.TransactionType = 'Payment' THEN t.Amount END),
       @OnTimePct = CAST(SUM(CASE WHEN t.DaysPastDue = 0 THEN 1.0 ELSE 0.0 END)
                        / NULLIF(COUNT(*), 0) * 100.0 AS DECIMAL(5,2)),
       @AvgDPD = AVG(CAST(t.DaysPastDue AS FLOAT)),
       @EarlyPayPct = CAST(SUM(CASE WHEN t.TransactionType = 'Payment' AND t.DaysPastDue = 0
                                     AND t.Amount > 0 THEN 1.0 ELSE 0.0 END)
                          / NULLIF(SUM(CASE WHEN t.TransactionType = 'Payment' THEN 1.0 ELSE 0.0 END), 0)
                          * 100.0 AS DECIMAL(5,2)),
       @LatePayPct = CAST(SUM(CASE WHEN t.DaysPastDue > 30 THEN 1.0 ELSE 0.0 END)
                         / NULLIF(COUNT(*), 0) * 100.0 AS DECIMAL(5,2))
FROM dbo.LoanHistory h
INNER JOIN dbo.LoanTransactions t ON t.LoanId = h.LoanId
WHERE h.ApplicantId = @ApplicantId
  AND t.TransactionDate >= DATEADD(DAY, -30, '2026-02-28');

-- Step 4: Compute account health score from payment trends
DECLARE @AccountHealth NVARCHAR(20) = CASE
    WHEN ISNULL(@OnTimePct, 50) >= 95 AND ISNULL(@AvgDPD, 30) < 5 THEN 'Excellent'
    WHEN ISNULL(@OnTimePct, 50) >= 80 AND ISNULL(@AvgDPD, 30) < 15 THEN 'Good'
    WHEN ISNULL(@OnTimePct, 50) >= 60 THEN 'Fair'
    ELSE 'AtRisk' END;

-- Step 5: Read loan history summary
DECLARE @HistCount INT, @HistDefaults INT;

SELECT @HistCount = COUNT(*),
       @HistDefaults = SUM(CASE WHEN LoanOutcome = 'Default' THEN 1 ELSE 0 END)
FROM dbo.LoanHistory
WHERE ApplicantId = @ApplicantId;
GO

PRINT '=== Created usp_AccountReview ==='
GO

-- ============================================================
-- 4. usp_RiskExposure — Portfolio Risk Snapshot
-- ============================================================
-- TPC-E analog: Market-Watch
-- Steps:
--   1. Query MonthlyPortfolioSnapshot (12.8K rows, rowstore-sized CCI)
--      for portfolio-wide risk aggregation — lightweight serial scan
--   2. Regional breakdown from same pre-aggregated snapshot
--   3. Cross-reference with LoanHistory credit score distribution
--
-- CPU profile: LIGHT (small table scans — pure read, no writes)
-- Uses pre-aggregated MonthlyPortfolioSnapshot instead of scanning
-- 18M+ row LoanTransactions CCI. Only BranchActivity uses CCI.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RiskExposure
AS
SET NOCOUNT ON;

-- Step 1: Portfolio-wide aggregation from MonthlyPortfolioSnapshot (12.8K rows)
-- Pre-aggregated by Month/LoanType/Region/Channel/CreditScoreBand
DECLARE @TotalOutstanding DECIMAL(18,2), @TotalDefaults INT,
        @AtRiskBalance DECIMAL(18,2), @AvgDPD FLOAT, @ActiveLoans INT;

SELECT @TotalOutstanding = SUM(TotalOutstanding),
       @TotalDefaults = SUM(TotalDefaults),
       @AtRiskBalance = SUM(PortfolioAtRisk),
       @AvgDPD = AVG(AvgDaysPastDue),
       @ActiveLoans = SUM(ActiveLoanCount)
FROM dbo.MonthlyPortfolioSnapshot;

-- Step 2: Regional breakdown from snapshot
DECLARE @RegionCount INT;

SELECT @RegionCount = COUNT(*)
FROM (
    SELECT Region,
           SUM(ActiveLoanCount)   AS Loans,
           SUM(TotalOutstanding)  AS Volume,
           SUM(TotalDefaults)     AS Defaults,
           SUM(PortfolioAtRisk)   AS AtRisk,
           AVG(AvgDaysPastDue)    AS AvgDPD,
           AVG(DefaultRate)       AS DefaultRate
    FROM dbo.MonthlyPortfolioSnapshot
    GROUP BY Region
) sub;

-- Step 3: Credit score distribution from LoanHistory
DECLARE @HistAvgScore INT, @HistCount INT;

SELECT @HistAvgScore = AVG(CreditScore), @HistCount = COUNT(*)
FROM dbo.LoanHistory;

-- Return snapshot (pure read — no write needed for analytics)
SELECT @TotalOutstanding AS TotalOutstanding, @TotalDefaults AS TotalDefaults,
       @ActiveLoans AS ActiveLoans, @RegionCount AS Regions,
       @AtRiskBalance AS AtRiskBalance, @AvgDPD AS AvgDPD,
       @HistAvgScore AS AvgCreditScore, @HistCount AS HistoricalLoans;
GO

PRINT '=== Created usp_RiskExposure ==='
GO

-- ============================================================
-- 5. usp_BranchActivity — Daily Activity Summary
-- ============================================================
-- TPC-E analog: Broker-Volume
-- Steps:
--   1. Scan recent LoanTransactions by channel/region (CCI with
--      date filter — segment elimination on TransactionDate)
--   2. Count recent loan applications by channel
--   3. Compute channel-level summaries
--
-- CPU profile: MEDIUM (filtered CCI scan + rowstore scan — pure read)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_BranchActivity
AS
SET NOCOUNT ON;

-- Anchor to the known max transaction date (LoanTransactions is static during workload)
-- Avoids a full 5.8M-row CCI scan just to find MAX(TransactionDate)
DECLARE @MaxDate DATE = '2026-02-28';
DECLARE @DaysBack INT = 7 + ABS(CHECKSUM(NEWID()) % 24);
DECLARE @StartDate DATE = DATEADD(DAY, -@DaysBack, @MaxDate);

-- Steps 1+2 combined: Single CCI scan computes totals AND per-channel breakdown
-- One scan instead of two — halves the CCI work
DECLARE @TxnCount INT, @PaymentVol DECIMAL(18,2), @DefaultVol DECIMAL(18,2),
        @ChannelCount INT, @TopChannel NVARCHAR(20), @TopChannelVol DECIMAL(18,2);

SELECT TOP 1
       @TopChannel = Channel,
       @TopChannelVol = TotalVol,
       @TxnCount = SUM(Cnt) OVER (),
       @PaymentVol = SUM(PayVol) OVER (),
       @DefaultVol = SUM(DefVol) OVER (),
       @ChannelCount = COUNT(*) OVER ()
FROM (
    SELECT Channel,
           COUNT(*) AS Cnt,
           SUM(CASE WHEN TransactionType = 'Payment' THEN Amount ELSE 0 END) AS PayVol,
           SUM(CASE WHEN TransactionType = 'Default' THEN Amount ELSE 0 END) AS DefVol,
           SUM(Amount) AS TotalVol
    FROM dbo.LoanTransactions
    WHERE TransactionDate >= @StartDate
    GROUP BY Channel
) ca
ORDER BY TotalVol DESC;

-- Step 3: Count loan applications for a random branch portfolio (~20% of applicants)
-- Filter by ApplicantId range (CI seek) since ApplicationDate is always "now" from workload runs
DECLARE @RecentApps INT, @RecentApproved INT;
DECLARE @BranchStart INT = 1 + ABS(CHECKSUM(NEWID()) % 800);

SELECT @RecentApps = COUNT(*),
       @RecentApproved = SUM(CASE WHEN Status = 'Decided' THEN 1 ELSE 0 END)
FROM dbo.LoanApplications
WHERE ApplicantId BETWEEN @BranchStart AND @BranchStart + 199;

-- Return summary (pure read — report query, no write needed)
SELECT @DaysBack AS DaysBack, @TxnCount AS TransactionCount,
       @PaymentVol AS PaymentVolume, @DefaultVol AS DefaultVolume,
       @TopChannel AS TopChannel, @TopChannelVol AS TopChannelVolume,
       @RecentApps AS RecentApplications, @RecentApproved AS RecentApproved;
GO

PRINT '=== Created usp_BranchActivity ==='
GO

-- ============================================================
-- 6. usp_LoanEligibility — Eligibility Check (Pure Read)
-- ============================================================
-- TPC-E analog: Trade-Lookup
-- The most common operation on a lending website — visitors check
-- "do I qualify?" without submitting an application.
-- Steps:
--   1. Read applicant profile (B-tree seek)
--   2. Count existing loans + total outstanding (LoanHistory seek)
--   3. Compute DTI ratio, estimated payment, risk tier (CPU math)
--
-- Application velocity check ("applied too many times") is a fraud/abuse
-- control that belongs in usp_LoanApplication at submission time, not here.
--
-- CPU profile: MEDIUM per-call (CCI scan for payment behavior + CPU math, zero writes)
-- No INSERT, no LoanApplications access — zero latch pressure. More vCores directly helps.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_LoanEligibility
    @ApplicantId INT
AS
SET NOCOUNT ON;
DECLARE @CreditScore INT, @Income DECIMAL(18,2), @DTI DECIMAL(5,2), @Region NVARCHAR(50);

-- Step 1: Read applicant profile (index seek)
SELECT @CreditScore = CreditScore, @Income = AnnualIncome,
       @DTI = DebtToIncomeRatio, @Region = Region
FROM dbo.Applicants
WHERE ApplicantId = @ApplicantId;

-- Step 2: Existing loan exposure (LoanHistory seek + aggregation)
DECLARE @ExistingLoans INT, @TotalOutstanding DECIMAL(18,2), @AvgRate DECIMAL(5,2);
SELECT @ExistingLoans = COUNT(*),
       @TotalOutstanding = SUM(ApprovedAmount),
       @AvgRate = AVG(InterestRate)
FROM dbo.LoanHistory
WHERE ApplicantId = @ApplicantId;

-- Step 3: Credit scoring model — table-driven scorecard (10K rules)
-- Scans ScoreCardRules rowstore table, applies conditional math per rule.
-- Serial plan (~5ms per call), pure CPU work that scales by running more
-- concurrent calls across more schedulers.
DECLARE @ScoreAdjustment FLOAT = 0;
SELECT @ScoreAdjustment = SUM(
    CASE
        WHEN r.Category = 'CreditScore' AND @CreditScore BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * CASE r.MathFunction WHEN 'LOG' THEN LOG(ABS(r.Multiplier * @CreditScore) + 1) WHEN 'SQRT' THEN SQRT(ABS(r.Multiplier * @CreditScore)) WHEN 'POWER' THEN POWER(ABS(r.Multiplier), 1.5) ELSE r.Multiplier END
        WHEN r.Category = 'Income' AND @Income BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * CASE r.MathFunction WHEN 'LOG' THEN LOG10(ABS(r.Multiplier * @Income) + 1) WHEN 'SQRT' THEN SQRT(ABS(r.Multiplier * @Income)) WHEN 'POWER' THEN POWER(ABS(r.Multiplier), 0.8) ELSE r.Multiplier END
        WHEN r.Category = 'DTI' AND @DTI BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * CASE r.MathFunction WHEN 'LOG' THEN LOG(ABS(r.Multiplier * @DTI) + 1) WHEN 'SQRT' THEN SQRT(ABS(r.Multiplier * @DTI)) WHEN 'POWER' THEN POWER(ABS(r.Multiplier * @DTI / 100.0), 1.5) ELSE r.Multiplier END
        WHEN r.Category = 'Exposure' AND ISNULL(@TotalOutstanding,0) BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * CASE r.MathFunction WHEN 'LOG' THEN LOG(ABS(r.Multiplier * ISNULL(@TotalOutstanding,1)) + 1) WHEN 'SQRT' THEN SQRT(ABS(r.Multiplier)) WHEN 'POWER' THEN POWER(ABS(r.Multiplier), 1.2) ELSE r.Multiplier END
        WHEN r.Category = 'ExistingLoans' AND @ExistingLoans BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * CASE r.MathFunction WHEN 'LOG' THEN LOG(ABS(r.Multiplier * @ExistingLoans) + 1) WHEN 'SQRT' THEN SQRT(ABS(r.Multiplier)) ELSE r.Multiplier END
        WHEN r.Category = 'InteractionCreditDTI' AND (@CreditScore * @DTI) BETWEEN r.MinValue AND r.MaxValue
            THEN r.Weight * r.Multiplier
        ELSE 0
    END)
FROM dbo.ScoreCardRules r;

-- Step 4: Compute eligibility (CPU math + scorecard adjustment — no writes)
DECLARE @RequestedAmount DECIMAL(18,2) = CAST(5000 + ABS(CHECKSUM(NEWID()) % 95000) AS DECIMAL(18,2));
DECLARE @EstMonthlyPayment DECIMAL(18,2) = @RequestedAmount * (ISNULL(@AvgRate, 6.0) / 100.0 / 12.0) /
    (1.0 - POWER(1.0 + (ISNULL(@AvgRate, 6.0) / 100.0 / 12.0), -60));
DECLARE @NewDTI DECIMAL(5,2) = CASE WHEN ISNULL(@Income, 50000) > 0
    THEN (ISNULL(@DTI, 30) * ISNULL(@Income, 50000) / 100.0 + @EstMonthlyPayment * 12) / ISNULL(@Income, 50000) * 100.0
    ELSE 99.0 END;
-- Apply scorecard adjustment (positive = higher risk, negative = lower risk)
SET @NewDTI = @NewDTI + ISNULL(@ScoreAdjustment, 0) / 100.0;
IF @NewDTI < 0 SET @NewDTI = 0;
IF @NewDTI > 99 SET @NewDTI = 99;

DECLARE @RiskTier NVARCHAR(20) = CASE
    WHEN ISNULL(@CreditScore, 650) >= 750 AND @NewDTI < 36 THEN 'Excellent'
    WHEN ISNULL(@CreditScore, 650) >= 700 AND @NewDTI < 43 THEN 'Good'
    WHEN ISNULL(@CreditScore, 650) >= 650 AND @NewDTI < 50 THEN 'Fair'
    ELSE 'Poor' END;
DECLARE @Eligible BIT = CASE
    WHEN @NewDTI < 50 AND ISNULL(@CreditScore, 650) >= 620 THEN 1
    ELSE 0 END;

-- Return result (SELECT — no write, CPU only)
SELECT @ApplicantId AS ApplicantId, @CreditScore AS CreditScore,
       @Income AS Income, @ExistingLoans AS ExistingLoans,
       @TotalOutstanding AS TotalOutstanding, @RequestedAmount AS RequestedAmount,
       @EstMonthlyPayment AS EstMonthlyPayment, @NewDTI AS NewDTI,
       @RiskTier AS RiskTier, @Eligible AS Eligible;
GO

PRINT '=== Created usp_LoanEligibility ==='
GO

PRINT ''
PRINT '=== All 6 workload procedures created successfully ==='
PRINT ''
PRINT 'Procedures:'
PRINT '  1. usp_LoanApplication    — Submit application (reads + 1 write)'
PRINT '  2. usp_PaymentProcessing  — Process payment (index seeks + ledger write)'
PRINT '  3. usp_AccountReview      — Full account review (multi-join + update)'
PRINT '  4. usp_RiskExposure       — Portfolio risk snapshot (pre-aggregated rowstore)'
PRINT '  5. usp_BranchActivity     — Daily activity summary (filtered CCI scan)'
PRINT '  6. usp_LoanEligibility    — Eligibility check (pure read, CPU math)'
PRINT ''
PRINT 'Key design: 5 procs mix reads+writes (primary only), 1 is pure read.'
PRINT 'LoanEligibility is the highest volume — most visitors check before applying.'
PRINT ''
PRINT 'Next: run the workload with step7-run-workload.ps1'
GO
