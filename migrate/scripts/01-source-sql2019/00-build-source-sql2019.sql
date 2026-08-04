/*
    Act 1 — SQL Server 2019 Source Build Script (Pre-Migration)
    "Migrate & Modernize: On-Prem SQL Server 2019 -> Hyperscale"

    PURPOSE
      Build the on-prem SQL Server 2019 source database so that, after migration
      to Azure SQL Hyperscale and the Act 1 modernization steps, it lands EXACTLY
      at the Act 2 (scale) "Phase 1 @ 32 vCores" baseline.

      This mirrors the Act 2 (scale) schema — the modernizations Act 1 adds AFTER migration are:
        1. dbo.LoanTransactions  : ROWSTORE here  -> CLUSTERED COLUMNSTORE (Step 3b)
        2. COMPATIBILITY_LEVEL   : 150 here       -> 170 (Step 3a)
        3. Auto index compaction : off here       -> on (Step 3c)

      MIGRATION DATA SHAPING (differs from Act 2 (scale) on purpose):
        - LoanTransactions carries a REALISTIC ~36 txns per non-denied loan (~3 yrs of
          servicing history) instead of ~100, so the per-customer ratio is believable.
        - A fixed-width clearing/settlement column (RawSettlementRecord CHAR(500)) pads
          each row so the database still lands at a realistic ~11 GB migration size
          WITHOUT an inflated row count. Fixed-width settlement records are normal in
          lending/payments, so this reads as real data, not filler.

    SCHEMA PARITY WITH ACT 2 (SCALE) — PHASE 1 BASELINE (mirror, rowstore form)
      Applicants ............ 1,000    (12 named + 988 generated — Phase-1 baseline;
                                        grow-data.ps1 grows to 3K/6K/10K at pressure
                                        phases 2/4/6 during the scale demo)
      LoanHistory ........... 100      (named/representative loans, LoanId 1-100)
      LoanHistoryExpanded ... 500,000  (the loan book, LoanId 101-500100)
      vw_AllLoans ........... UNION ALL view (LoanHistory + LoanHistoryExpanded)
      LoanTransactions ...... ~15.4M   (ROWSTORE; ~36 txns/non-denied loan; padded to
                                        ~11 GB via fixed-width RawSettlementRecord CHAR(500))
      MonthlyPortfolioSnapshot  rollup (rowstore)
      LoanApplications ...... 1        (single Vandelay 'Pending' demo row — the scale
                                        workload generates the live pipeline)
      LoanDecisions ......... EMPTY    (AI-generated at Hyperscale — Act 3 (AI))

    NOT BUILT HERE (Act 2 (scale) workload-setup creates these at scale time, idempotently):
      PaymentProcessingBatch, LoanRiskSummary, ScoreCardRules,
      LoanDecisions.ApplicantId column, LoanApplications composite PK reshape.

    NOTES
      - SQL Server 2019 compatible only. No ledger, no vector type, no columnstore.
      - Safe to re-run: drops and recreates the demo objects.
      - Bulk generation is set-based and batched; recovery is set to SIMPLE for
        the load to keep the transaction log bounded.
*/

SET NOCOUNT ON;
GO

IF DB_ID(N'ZavaLendingDB') IS NULL
BEGIN
    CREATE DATABASE [ZavaLendingDB];
END;
GO

ALTER DATABASE [ZavaLendingDB] SET COMPATIBILITY_LEVEL = 150;
GO

-- Keep the transaction log bounded during the bulk build.
ALTER DATABASE [ZavaLendingDB] SET RECOVERY SIMPLE;
GO

USE [ZavaLendingDB];
GO

PRINT '=== Act 1 source build starting (Act 2 (scale) baseline, rowstore / compat 150) ===';
GO

-- ============================================================
-- DROP (reverse dependency order)
-- ============================================================
IF OBJECT_ID(N'dbo.vw_AllLoans', N'V') IS NOT NULL DROP VIEW dbo.vw_AllLoans;
GO
DROP TABLE IF EXISTS dbo.LoanTransactions;
DROP TABLE IF EXISTS dbo.MonthlyPortfolioSnapshot;
DROP TABLE IF EXISTS dbo.LoanDecisions;
DROP TABLE IF EXISTS dbo.LoanApplications;
DROP TABLE IF EXISTS dbo.LoanHistoryExpanded;
DROP TABLE IF EXISTS dbo.LoanHistory;
DROP TABLE IF EXISTS dbo.Applicants;
GO

-- ============================================================
-- TABLES (mirror Act 2 (scale) schema, rowstore)
-- ============================================================

-- Applicants — mirrors the Act 2 (scale) setup schema (rich schema)
CREATE TABLE dbo.Applicants (
    ApplicantId         INT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_Applicants PRIMARY KEY CLUSTERED (ApplicantId),
    FirstName           NVARCHAR(100)   NOT NULL,
    LastName            NVARCHAR(100)   NOT NULL,
    Email               NVARCHAR(256)   NOT NULL,
    PhoneNumber         NVARCHAR(20)    NULL,
    DateOfBirth         DATE            NULL,
    AnnualIncome        DECIMAL(18,2)   NOT NULL,
    EmploymentStatus    NVARCHAR(30)    NOT NULL CONSTRAINT DF_Applicants_EmploymentStatus DEFAULT 'Employed',
    EmploymentYears     DECIMAL(4,1)    NULL,
    CreditScore         INT             NOT NULL,
    DebtToIncomeRatio   DECIMAL(5,2)    NULL,
    Region              NVARCHAR(50)    NOT NULL CONSTRAINT DF_Applicants_Region DEFAULT 'US-West',
    CreatedDate         DATETIME2       NOT NULL CONSTRAINT DF_Applicants_CreatedDate DEFAULT SYSUTCDATETIME(),
    IsExistingCustomer  BIT             NOT NULL CONSTRAINT DF_Applicants_IsExistingCustomer DEFAULT 0,
    LastReviewDate      DATETIME2       NULL
);
GO

-- LoanHistory — the small named/representative set (LoanId 1-100)
CREATE TABLE dbo.LoanHistory (
    LoanId              BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_LoanHistory PRIMARY KEY CLUSTERED (LoanId),
    ApplicantId         INT             NULL CONSTRAINT FK_LoanHistory_Applicants REFERENCES dbo.Applicants(ApplicantId),
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
    ApplicationDate     DATETIME2       NOT NULL CONSTRAINT DF_LoanHistory_ApplicationDate DEFAULT SYSUTCDATETIME(),
    DecisionDate        DATETIME2       NULL
);
GO

-- LoanHistoryExpanded — the loan book (LoanId 101-500100), mirrors the Act 2 (scale) loan book
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
    Region              NVARCHAR(50)    NOT NULL CONSTRAINT DF_LoanHistoryExpanded_Region DEFAULT 'US-West',
    Channel             NVARCHAR(20)    NOT NULL CONSTRAINT DF_LoanHistoryExpanded_Channel DEFAULT 'Web'
);
GO

-- LoanApplications — live application pipeline
CREATE TABLE dbo.LoanApplications (
    ApplicationId       BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_LoanApplications PRIMARY KEY CLUSTERED (ApplicationId),
    ApplicantId         INT             NOT NULL CONSTRAINT FK_LoanApplications_Applicants REFERENCES dbo.Applicants(ApplicantId),
    LoanType            NVARCHAR(30)    NOT NULL,
    RequestedAmount     DECIMAL(18,2)   NOT NULL,
    TermMonths          INT             NOT NULL,
    LoanPurpose         NVARCHAR(200)   NULL,
    Channel             NVARCHAR(20)    NOT NULL CONSTRAINT DF_LoanApplications_Channel DEFAULT 'Web',
    ApplicationDate     DATETIME2       NOT NULL CONSTRAINT DF_LoanApplications_ApplicationDate DEFAULT SYSUTCDATETIME(),
    Status              NVARCHAR(20)    NOT NULL CONSTRAINT DF_LoanApplications_Status DEFAULT 'Pending'
);
GO

-- LoanDecisions — empty on 2019 (AI decisions generated at Hyperscale).
-- NOTE: Act 2 (scale) workload-setup adds the ApplicantId column idempotently at scale time.
CREATE TABLE dbo.LoanDecisions (
    DecisionId          BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_LoanDecisions PRIMARY KEY CLUSTERED (DecisionId),
    ApplicationId       BIGINT          NOT NULL CONSTRAINT FK_LoanDecisions_LoanApplications REFERENCES dbo.LoanApplications(ApplicationId),
    RiskScore           DECIMAL(5,2)    NOT NULL,
    RiskCategory        NVARCHAR(20)    NOT NULL,
    Decision            NVARCHAR(30)    NOT NULL,
    ApprovedAmount      DECIMAL(18,2)   NULL,
    ApprovedRate        DECIMAL(5,2)    NULL,
    Narrative           NVARCHAR(MAX)   NOT NULL,
    SimilarLoanIds      NVARCHAR(MAX)   NULL,
    SimilarLoanCount    INT             NULL,
    SimilarApprovalRate DECIMAL(5,2)    NULL,
    SimilarDefaultRate  DECIMAL(5,4)    NULL,
    ModelVersion        NVARCHAR(30)    NOT NULL CONSTRAINT DF_LoanDecisions_ModelVersion DEFAULT 'gpt-4o-2025-08',
    ProcessingTimeMs    INT             NULL,
    DecidedAt           DATETIME2       NOT NULL CONSTRAINT DF_LoanDecisions_DecidedAt DEFAULT SYSUTCDATETIME(),
    DecidedBy           NVARCHAR(50)    NOT NULL CONSTRAINT DF_LoanDecisions_DecidedBy DEFAULT 'AI-AutoScore',
    AuditHash           VARBINARY(32)   NULL
);
GO

-- LoanTransactions — ROWSTORE on the 2019 source.
-- Step 3b converts this to a CLUSTERED COLUMNSTORE after migration.
CREATE TABLE dbo.LoanTransactions (
    TransactionId       BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_LoanTransactions PRIMARY KEY CLUSTERED (TransactionId),
    LoanId              BIGINT          NOT NULL,
    TransactionDate     DATE            NOT NULL,
    TransactionType     NVARCHAR(20)    NOT NULL,
    Amount              DECIMAL(18,2)   NOT NULL,
    RunningBalance      DECIMAL(18,2)   NOT NULL,
    InterestComponent   DECIMAL(18,2)   NULL,
    PrincipalComponent  DECIMAL(18,2)   NULL,
    DaysPastDue         INT             NOT NULL CONSTRAINT DF_LoanTransactions_DaysPastDue DEFAULT 0,
    LoanType            NVARCHAR(30)    NOT NULL,
    Region              NVARCHAR(50)    NOT NULL,
    Channel             NVARCHAR(20)    NOT NULL,
    CreditScoreBand     NVARCHAR(20)    NOT NULL,
    ProcessedBy         NVARCHAR(50)    NOT NULL CONSTRAINT DF_LoanTransactions_ProcessedBy DEFAULT 'AutoPay',
    CreatedAt           DATETIME2       NOT NULL CONSTRAINT DF_LoanTransactions_CreatedAt DEFAULT SYSUTCDATETIME(),
    -- Fixed-width clearing/settlement record (ACH-style). Migration-demo only: pads each
    -- row so a realistic ~15.4M-row table reaches ~11 GB without inflating the row count.
    RawSettlementRecord CHAR(500)       NOT NULL CONSTRAINT DF_LoanTransactions_RawSettlementRecord DEFAULT ''
);
GO

-- MonthlyPortfolioSnapshot — portfolio rollup (rowstore on 2019)
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
    ProvisionAmount     DECIMAL(18,2)   NOT NULL,
    CONSTRAINT PK_MonthlyPortfolioSnapshot PRIMARY KEY CLUSTERED
        (SnapshotMonth, LoanType, Region, Channel, CreditScoreBand)
);
GO

-- ============================================================
-- SUPPORTING INDEXES (rowstore; match Act 2 (scale) expectations)
-- ============================================================
CREATE NONCLUSTERED INDEX IX_LoanHistoryExpanded_ApplicantId
    ON dbo.LoanHistoryExpanded (ApplicantId)
    INCLUDE (LoanId, LoanOutcome, ApprovedAmount, InterestRate, DefaultRate);

CREATE NONCLUSTERED INDEX IX_LoanTransactions_LoanId
    ON dbo.LoanTransactions (LoanId, TransactionDate DESC)
    INCLUDE (TransactionType, Amount, RunningBalance, Region, Channel);

CREATE NONCLUSTERED INDEX IX_LoanApplications_ApplicantId
    ON dbo.LoanApplications (ApplicantId, ApplicationDate)
    INCLUDE (LoanType, RequestedAmount, Status);
GO

-- ============================================================
-- VIEW: vw_AllLoans (UNION ALL — mirrors the Act 2 (scale) loan book)
-- ============================================================
GO
CREATE VIEW dbo.vw_AllLoans AS
SELECT LoanId, LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths,
       ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose,
       LoanOutcome, DefaultRate, ApplicationDate, DecisionDate
FROM dbo.LoanHistory
UNION ALL
SELECT LoanId, LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths,
       ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose,
       LoanOutcome, DefaultRate, ApplicationDate, DecisionDate
FROM dbo.LoanHistoryExpanded;
GO

-- ============================================================
-- SEED: Applicants (12 named + grow to 1,000 — Phase-1 baseline)
-- ============================================================
INSERT INTO dbo.Applicants (FirstName, LastName, Email, PhoneNumber, DateOfBirth, AnnualIncome, EmploymentStatus, EmploymentYears, CreditScore, DebtToIncomeRatio, Region, IsExistingCustomer)
VALUES
    ('Jerry','Seinfeld','jerry.seinfeld@email.com','555-2001','1992-03-15',95000,'Employed',6.5,740,0.28,'US-West',1),
    ('George','Costanza','george.costanza@email.com','555-2002','1985-07-22',62000,'Employed',12.0,680,0.35,'US-East',1),
    ('Elaine','Benes','elaine.benes@email.com','555-2003','1990-11-08',78000,'Employed',4.2,710,0.22,'US-West',0),
    ('Cosmo','Kramer','cosmo.kramer@email.com','555-2004','1978-01-30',120000,'Self-Employed',15.0,760,0.18,'US-Central',1),
    ('Susan','Ross','susan.ross@email.com','555-2005','1995-06-12',55000,'Employed',2.8,650,0.42,'US-East',0),
    ('Frank','Costanza','frank.costanza@email.com','555-2006','1988-09-25',85000,'Employed',8.3,720,0.30,'US-West',1),
    ('Estelle','Costanza','estelle.costanza@email.com','555-2007','1993-04-18',72000,'Employed',5.0,695,0.33,'EU-West',0),
    ('Art','Vandelay','art.vandelay@email.com','555-2008','1980-12-03',145000,'Self-Employed',20.0,780,0.15,'US-East',1),
    ('Jackie','Chiles','jackie.chiles@email.com','555-2009','1997-08-21',48000,'Employed',1.5,620,0.48,'US-Central',0),
    ('David','Puddy','david.puddy@email.com','555-2010','1983-05-09',110000,'Employed',14.0,750,0.20,'US-West',1),
    ('Kenny','Bania','kenny.bania@email.com','555-2011','1991-02-14',68000,'Employed',7.0,700,0.31,'EU-West',0),
    ('Lloyd','Braun','lloyd.braun@email.com','555-2012','1976-10-27',92000,'Employed',22.0,735,0.25,'US-East',1);
GO

DECLARE @ApplicantCount INT = 1000;
DECLARE @ExtraApplicants INT = CASE WHEN @ApplicantCount > 12 THEN @ApplicantCount - 12 ELSE 0 END;
;WITH N AS (
    SELECT TOP (@ExtraApplicants) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.Applicants (FirstName, LastName, Email, PhoneNumber, DateOfBirth, AnnualIncome, EmploymentStatus, EmploymentYears, CreditScore, DebtToIncomeRatio, Region, IsExistingCustomer)
SELECT
    CONCAT(N'Applicant', n),
    CONCAT(N'Demo', n),
    CONCAT(N'applicant', n, N'@zavafin.local'),
    CONCAT(N'555-', RIGHT(CONCAT(N'0000', n), 4)),
    DATEADD(YEAR, -(20 + (n % 40)), CAST('2026-01-01' AS DATE)),
    CAST(35000 + (n % 180000) AS DECIMAL(18,2)),
    CASE n % 4 WHEN 0 THEN N'Employed' WHEN 1 THEN N'Self-Employed' WHEN 2 THEN N'Retired' ELSE N'Employed' END,
    CAST((n % 300) / 10.0 AS DECIMAL(4,1)),
    580 + (n % 251),
    CAST((18 + (n % 48)) / 100.0 AS DECIMAL(5,2)),
    CASE n % 4 WHEN 0 THEN N'US-West' WHEN 1 THEN N'US-East' WHEN 2 THEN N'US-Central' ELSE N'EU-West' END,
    CASE WHEN n % 3 = 0 THEN 1 ELSE 0 END
FROM N;
GO
PRINT '=== Applicants seeded: 1,000 (12 named + 988 generated) — Phase-1 baseline. ===';
GO

-- ============================================================
-- SEED: LoanHistory (100 representative loans, LoanId 1-100)
-- ============================================================
;WITH N AS (
    SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects
)
INSERT INTO dbo.LoanHistory (
    ApplicantId, LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths,
    ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears,
    LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate
)
SELECT
    n,
    CASE WHEN n % 100 < 60 THEN N'Auto' WHEN n % 100 < 80 THEN N'Personal'
         WHEN n % 100 < 92 THEN N'SmallBusiness' ELSE N'HomeImprovement' END,
    CAST(2000 + (n % 120000) AS DECIMAL(18,2)),
    CAST(1800 + (n % 100000) AS DECIMAL(18,2)),
    CAST(4.50 + ((n % 950) / 100.0) AS DECIMAL(5,2)),
    CASE n % 4 WHEN 0 THEN 24 WHEN 1 THEN 36 WHEN 2 THEN 48 ELSE 60 END,
    CAST(30000 + (n % 170000) AS DECIMAL(18,2)),
    580 + (n % 251),
    CAST((18 + (n % 48)) / 100.0 AS DECIMAL(5,2)),
    CAST((n % 300) / 10.0 AS DECIMAL(4,1)),
    CASE n % 5 WHEN 0 THEN N'Debt consolidation' WHEN 1 THEN N'Car purchase'
         WHEN 2 THEN N'Working capital' WHEN 3 THEN N'Home repairs' ELSE N'Emergency expense' END,
    CASE WHEN n % 17 = 0 THEN N'Default' WHEN n % 13 = 0 THEN N'Denied'
         WHEN n % 2 = 0 THEN N'Active' ELSE N'PaidInFull' END,
    CAST((n % 1200) / 10000.0 AS DECIMAL(5,4)),
    DATEADD(DAY, -(n % 1460), SYSUTCDATETIME()),
    DATEADD(DAY, -((n % 1460) - 2), SYSUTCDATETIME())
FROM N;
GO
PRINT '=== LoanHistory seeded: 100 representative loans. ===';
GO

-- ============================================================
-- SEED: LoanHistoryExpanded (500,000 loans, LoanId 101-500100)
-- ============================================================
DECLARE @ExpandedCount INT = 500000;
DECLARE @StartId BIGINT = 101;
;WITH N AS (
    SELECT TOP (@ExpandedCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.LoanHistoryExpanded (
    LoanId, ApplicantId, LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths,
    ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears,
    LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate, Region, Channel
)
SELECT
    @StartId + (rn - 1)                                   AS LoanId,
    CAST(((@StartId + (rn - 1)) % 10000) + 1 AS INT)      AS ApplicantId,
    CASE WHEN rn % 100 < 60 THEN N'Auto' WHEN rn % 100 < 80 THEN N'Personal'
         WHEN rn % 100 < 92 THEN N'SmallBusiness' ELSE N'HomeImprovement' END,
    CAST(2000 + (rn % 120000) AS DECIMAL(18,2)),
    CASE WHEN rn % 7 = 0 THEN NULL ELSE CAST(1800 + (rn % 100000) AS DECIMAL(18,2)) END,
    CASE WHEN rn % 7 = 0 THEN NULL ELSE CAST(4.50 + ((rn % 950) / 100.0) AS DECIMAL(5,2)) END,
    CASE rn % 4 WHEN 0 THEN 24 WHEN 1 THEN 36 WHEN 2 THEN 48 ELSE 60 END,
    CAST(30000 + (rn % 170000) AS DECIMAL(18,2)),
    550 + (rn % 270),
    CAST((10 + (rn % 50)) / 100.0 AS DECIMAL(5,2)),
    CAST((5 + (rn % 245)) / 10.0 AS DECIMAL(4,1)),
    CASE rn % 5 WHEN 0 THEN N'Debt consolidation' WHEN 1 THEN N'Car purchase'
         WHEN 2 THEN N'Working capital' WHEN 3 THEN N'Home repairs' ELSE N'Emergency expense' END,
    CASE WHEN rn % 7 = 0 THEN N'Denied'
         WHEN rn % 100 < 45 THEN N'PaidInFull'
         WHEN rn % 100 < 70 THEN N'Active'
         ELSE N'Default' END,
    CASE WHEN rn % 7 = 0 THEN NULL ELSE CAST((rn % 1500) / 10000.0 AS DECIMAL(5,4)) END,
    DATEADD(DAY, -(rn % 420), CAST('2026-02-28' AS DATETIME2)),
    DATEADD(DAY, -((rn % 420)) + 1, CAST('2026-02-28' AS DATETIME2)),
    CASE rn % 4 WHEN 0 THEN N'US-West' WHEN 1 THEN N'US-East' WHEN 2 THEN N'US-Central' ELSE N'EU-West' END,
    CASE WHEN rn % 10 < 4 THEN N'Web' WHEN rn % 10 < 7 THEN N'Mobile'
         WHEN rn % 10 < 9 THEN N'PartnerAPI' ELSE N'Branch' END
FROM N;
GO
PRINT '=== LoanHistoryExpanded seeded: 500,000 loans (LoanId 101-500100). ===';
GO

-- ============================================================
-- SEED: LoanTransactions (~36 txns per non-denied loan, ~15.4M rows)
-- Padded with RawSettlementRecord CHAR(500) to land the DB at ~11 GB.
-- Batched by LoanId range to keep the log bounded.
-- ============================================================
DECLARE @TxnsPerLoan INT = 36;             -- ~3 yrs servicing history per loan (realistic)
DECLARE @BatchSize   INT = 20000;          -- loans per batch (~720K txn rows)
DECLARE @MinLoan BIGINT = 101;
DECLARE @MaxLoan BIGINT = (SELECT MAX(LoanId) FROM dbo.LoanHistoryExpanded);
DECLARE @BatchStart BIGINT = @MinLoan;
DECLARE @BatchEnd   BIGINT;

WHILE @BatchStart <= @MaxLoan
BEGIN
    SET @BatchEnd = @BatchStart + @BatchSize - 1;

    ;WITH Seq AS (
        SELECT TOP (@TxnsPerLoan) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS seq
        FROM sys.all_objects
    )
    INSERT INTO dbo.LoanTransactions (
        LoanId, TransactionDate, TransactionType, Amount, RunningBalance,
        InterestComponent, PrincipalComponent, DaysPastDue,
        LoanType, Region, Channel, CreditScoreBand, ProcessedBy, CreatedAt,
        RawSettlementRecord
    )
    SELECT
        lh.LoanId,
        DATEADD(DAY, s.seq * 7, CAST(lh.ApplicationDate AS DATE)),
        CASE WHEN s.seq = 1 THEN N'Disbursement'
             WHEN s.seq = @TxnsPerLoan THEN N'Adjustment'
             ELSE N'Payment' END,
        CASE WHEN s.seq = 1 THEN ISNULL(lh.ApprovedAmount, lh.RequestedAmount)
             ELSE -1.0 * CAST(ISNULL(lh.ApprovedAmount, lh.RequestedAmount) / @TxnsPerLoan AS DECIMAL(18,2)) END,
        CAST(ISNULL(lh.ApprovedAmount, lh.RequestedAmount)
             - ((s.seq - 1) * (ISNULL(lh.ApprovedAmount, lh.RequestedAmount) / @TxnsPerLoan)) AS DECIMAL(18,2)),
        CAST(CASE WHEN s.seq = 1 THEN 0
             ELSE ISNULL(lh.ApprovedAmount, lh.RequestedAmount) * (ISNULL(lh.InterestRate, 6.0) / 100.0) / 12.0 END AS DECIMAL(18,2)),
        CAST(ISNULL(lh.ApprovedAmount, lh.RequestedAmount) / @TxnsPerLoan AS DECIMAL(18,2)),
        CASE WHEN s.seq % 11 = 0 THEN (s.seq % 30) ELSE 0 END,
        lh.LoanType,
        lh.Region,
        lh.Channel,
        CASE WHEN lh.CreditScore >= 750 THEN N'Excellent'
             WHEN lh.CreditScore >= 700 THEN N'Good'
             WHEN lh.CreditScore >= 650 THEN N'Fair' ELSE N'Poor' END,
        N'BatchLoad',
        SYSUTCDATETIME(),
        -- Fixed-width ACH/clearing settlement record; varied content (NEWID) so it is
        -- high-cardinality real-looking data, CHAR(500) pads the remainder to 500 bytes.
        CONCAT(
            'STLREC|', RIGHT(REPLICATE('0',12) + CAST(lh.LoanId AS VARCHAR(20)), 12),
            '|SEQ', RIGHT('0000' + CAST(s.seq AS VARCHAR(10)), 4),
            '|', CONVERT(CHAR(8), DATEADD(DAY, s.seq * 7, CAST(lh.ApplicationDate AS DATE)), 112),
            '|REF', REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''),
            '|CLRHOUSE-ACH'
        )
    FROM dbo.LoanHistoryExpanded lh
    CROSS APPLY Seq s
    WHERE lh.LoanId BETWEEN @BatchStart AND @BatchEnd
      AND lh.LoanOutcome <> N'Denied';   -- denied loans never disbursed

    SET @BatchStart = @BatchEnd + 1;
    CHECKPOINT;
END
GO
PRINT '=== LoanTransactions generated (rowstore). ===';
GO

-- ============================================================
-- SEED: MonthlyPortfolioSnapshot (portfolio rollup from transactions)
-- ============================================================
INSERT INTO dbo.MonthlyPortfolioSnapshot (
    SnapshotMonth, LoanType, Region, Channel, CreditScoreBand,
    ActiveLoanCount, TotalOutstanding, TotalPayments, TotalDefaults,
    AvgDaysPastDue, DefaultRate, WeightedAvgRate, PortfolioAtRisk, ProvisionAmount
)
SELECT
    DATEFROMPARTS(YEAR(t.TransactionDate), MONTH(t.TransactionDate), 1) AS SnapshotMonth,
    t.LoanType, t.Region, t.Channel, t.CreditScoreBand,
    COUNT(DISTINCT t.LoanId)                                          AS ActiveLoanCount,
    CAST(SUM(t.RunningBalance) AS DECIMAL(18,2))                      AS TotalOutstanding,
    CAST(SUM(CASE WHEN t.Amount < 0 THEN -t.Amount ELSE 0 END) AS DECIMAL(18,2)) AS TotalPayments,
    SUM(CASE WHEN t.DaysPastDue > 0 THEN 1 ELSE 0 END)               AS TotalDefaults,
    CAST(AVG(CAST(t.DaysPastDue AS DECIMAL(8,2))) AS DECIMAL(8,2))    AS AvgDaysPastDue,
    CAST(0.05 AS DECIMAL(5,4))                                        AS DefaultRate,
    CAST(6.50 AS DECIMAL(5,2))                                        AS WeightedAvgRate,
    CAST(SUM(CASE WHEN t.DaysPastDue > 0 THEN t.RunningBalance ELSE 0 END) AS DECIMAL(18,2)) AS PortfolioAtRisk,
    CAST(SUM(CASE WHEN t.DaysPastDue > 0 THEN t.RunningBalance ELSE 0 END) * 0.10 AS DECIMAL(18,2)) AS ProvisionAmount
FROM dbo.LoanTransactions t
GROUP BY
    DATEFROMPARTS(YEAR(t.TransactionDate), MONTH(t.TransactionDate), 1),
    t.LoanType, t.Region, t.Channel, t.CreditScoreBand;
GO
PRINT '=== MonthlyPortfolioSnapshot rollup created. ===';
GO

-- ============================================================
-- SEED: LoanApplications (single named 'Pending' demo row)
-- Mirrors the Act 2 (scale) setup exactly: just the Art Vandelay application.
-- The scale workload generates the live pipeline; reset-data cleans it.
-- ============================================================
INSERT INTO dbo.LoanApplications (ApplicantId, LoanType, RequestedAmount, TermMonths, LoanPurpose, Channel, ApplicationDate, Status)
VALUES
    (8, N'SmallBusiness', 150000.00, 60, N'Import/export business expansion - Vandelay Industries specializes in importing and exporting fine latex products and long matches', N'Web', SYSUTCDATETIME(), N'Pending');
GO
PRINT '=== LoanApplications seeded: 1 (named Vandelay pending). ===';
GO

-- ============================================================
-- Final shape check
-- ============================================================
SELECT
    (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) AS compatibility_level,
    (SELECT COUNT_BIG(*) FROM dbo.Applicants)               AS applicants,
    (SELECT COUNT_BIG(*) FROM dbo.LoanHistory)              AS loan_history,
    (SELECT COUNT_BIG(*) FROM dbo.LoanHistoryExpanded)      AS loan_history_expanded,
    (SELECT COUNT_BIG(*) FROM dbo.LoanTransactions)         AS loan_transactions,
    (SELECT COUNT_BIG(*) FROM dbo.MonthlyPortfolioSnapshot) AS monthly_snapshots,
    (SELECT COUNT_BIG(*) FROM dbo.LoanApplications)         AS loan_applications,
    (SELECT COUNT_BIG(*) FROM dbo.LoanDecisions)            AS loan_decisions,
    (SELECT i.type_desc FROM sys.indexes i
       WHERE i.object_id = OBJECT_ID(N'dbo.LoanTransactions') AND i.index_id = 1) AS loan_transactions_storage;
GO

-- Size sanity check (expect LoanTransactions ~11 GB; total DB ~11+ GB)
SELECT
    CAST(SUM(CASE WHEN p.object_id = OBJECT_ID(N'dbo.LoanTransactions')
                  THEN a.used_pages ELSE 0 END) * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) AS loan_transactions_gb,
    CAST(SUM(a.used_pages) * 8.0 / 1024 / 1024 AS DECIMAL(10,2))                       AS all_objects_used_gb
FROM sys.partitions p
JOIN sys.allocation_units a ON a.container_id = p.partition_id;
GO

PRINT '=== Act 1 source build complete (Act 2 (scale) baseline, rowstore / compat 150). ===';
PRINT 'Ready for source assessment and offline DMS migration to Hyperscale.';
GO
