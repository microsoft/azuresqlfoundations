/*
    ZavaLendingDB — Setup Script
    SQLCon 2026 — Demo 2: "The Destination: Built for Hyperscale"
    
    Creates the ZavaLendingDB schema on Azure SQL Database Hyperscale
    with loan history, vector embeddings, and AI decisioning tables.
    
    This is the ZavaLendingDB schema as it runs on Hyperscale after the
    Demo 1 migration from on-prem SQL Server 2019 (then modernized).
    
    This database is used by both Demo 2 (Hyperscale infrastructure)
    and Demo 3 (vector search + AI scoring).
    
    Prerequisites:
      - Azure SQL Database Hyperscale (40+ vCores recommended)
      - Azure OpenAI resource with gpt-4o and text-embedding-3-small deployments
      - Database-scoped credential for Azure OpenAI endpoint
*/

-- ============================================
-- DROP EXISTING OBJECTS (for idempotent re-runs)
-- ============================================

-- Drop full-text index on LoanHistory if it exists (blocks DROP TABLE)
IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.LoanHistory'))
    DROP FULLTEXT INDEX ON dbo.LoanHistory;

-- Drop demo3 table that has FK to LoanHistory
DROP TABLE IF EXISTS dbo.LoanNarrativeEmbeddings;

-- Drop ledger audit table (append-only ledger requires explicit drop)
-- Note: sys.database_ledger_transactions history is lost on drop
DROP TABLE IF EXISTS dbo.LoanDecisionAudit;

-- Drop in reverse dependency order
DROP TABLE IF EXISTS dbo.LoanDecisions;
DROP TABLE IF EXISTS dbo.LoanApplications;
DROP TABLE IF EXISTS dbo.LoanHistory;
DROP TABLE IF EXISTS dbo.Applicants;
GO

-- ============================================
-- TABLES
-- ============================================

-- Applicants: loan applicants (customers and prospects)
CREATE TABLE dbo.Applicants (
    ApplicantId         INT IDENTITY(1,1) PRIMARY KEY,
    FirstName           NVARCHAR(100)   NOT NULL,
    LastName            NVARCHAR(100)   NOT NULL,
    Email               NVARCHAR(256)   NOT NULL,
    PhoneNumber         NVARCHAR(20)    NULL,
    DateOfBirth         DATE            NULL,
    AnnualIncome        DECIMAL(18,2)   NOT NULL,
    EmploymentStatus    NVARCHAR(30)    NOT NULL DEFAULT 'Employed',  -- Employed, Self-Employed, Retired, Unemployed
    EmploymentYears     DECIMAL(4,1)    NULL,
    CreditScore         INT             NOT NULL,
    DebtToIncomeRatio   DECIMAL(5,2)    NULL,
    Region              NVARCHAR(50)    NOT NULL DEFAULT 'US-West',
    CreatedDate         DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    IsExistingCustomer  BIT             NOT NULL DEFAULT 0,
    LastReviewDate      DATETIME2       NULL
);
GO

-- LoanHistory: historical loan applications with outcomes
CREATE TABLE dbo.LoanHistory (
    LoanId              BIGINT IDENTITY(1,1) NOT NULL,
    CONSTRAINT PK_LoanHistory PRIMARY KEY (LoanId),
    ApplicantId         INT             NULL REFERENCES dbo.Applicants(ApplicantId),
    LoanType            NVARCHAR(30)    NOT NULL,   -- Auto, Personal, SmallBusiness, HomeImprovement
    RequestedAmount     DECIMAL(18,2)   NOT NULL,
    ApprovedAmount      DECIMAL(18,2)   NULL,
    InterestRate        DECIMAL(5,2)    NULL,
    TermMonths          INT             NOT NULL,
    ApplicantIncome     DECIMAL(18,2)   NOT NULL,
    CreditScore         INT             NOT NULL,
    DebtToIncomeRatio   DECIMAL(5,2)    NULL,
    EmploymentYears     DECIMAL(4,1)    NULL,
    LoanPurpose         NVARCHAR(200)   NULL,
    LoanOutcome         NVARCHAR(20)    NOT NULL,   -- Approved, Denied, Default, PaidInFull, Active
    DefaultRate         DECIMAL(5,4)    NULL,        -- Probability of default at time of decision
    ApplicationDate     DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    DecisionDate        DATETIME2       NULL
);
GO

-- LoanApplications: incoming applications (the real-time pipeline)
CREATE TABLE dbo.LoanApplications (
    ApplicationId       BIGINT IDENTITY(1,1) PRIMARY KEY,
    ApplicantId         INT             NOT NULL REFERENCES dbo.Applicants(ApplicantId),
    LoanType            NVARCHAR(30)    NOT NULL,
    RequestedAmount     DECIMAL(18,2)   NOT NULL,
    TermMonths          INT             NOT NULL,
    LoanPurpose         NVARCHAR(200)   NULL,
    Channel             NVARCHAR(20)    NOT NULL DEFAULT 'Web',  -- Web, Mobile, PartnerAPI, Branch
    ApplicationDate     DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    Status              NVARCHAR(20)    NOT NULL DEFAULT 'Pending'  -- Pending, Scoring, Decided, Expired
);
GO

-- LoanDecisions: AI-generated decisions with explainable narratives
CREATE TABLE dbo.LoanDecisions (
    DecisionId          BIGINT IDENTITY(1,1) PRIMARY KEY,
    ApplicationId       BIGINT          NOT NULL REFERENCES dbo.LoanApplications(ApplicationId),
    RiskScore           DECIMAL(5,2)    NOT NULL,  -- 0.00 (lowest risk) to 100.00 (highest risk)
    RiskCategory        NVARCHAR(20)    NOT NULL,  -- Low, Medium, High, Critical
    Decision            NVARCHAR(30)    NOT NULL,  -- Approved, ConditionallyApproved, Denied, ManualReview
    ApprovedAmount      DECIMAL(18,2)   NULL,
    ApprovedRate        DECIMAL(5,2)    NULL,
    Narrative           NVARCHAR(MAX)   NOT NULL,  -- AI-generated human-readable risk explanation
    SimilarLoanIds      NVARCHAR(MAX)   NULL,      -- JSON array of LoanHistory IDs used for comparison
    SimilarLoanCount    INT             NULL,
    SimilarApprovalRate DECIMAL(5,2)    NULL,       -- % of similar loans that were approved
    SimilarDefaultRate  DECIMAL(5,4)    NULL,       -- Average default rate of similar loans
    ModelVersion        NVARCHAR(30)    NOT NULL DEFAULT 'gpt-4o-2025-08',
    ProcessingTimeMs    INT             NULL,        -- End-to-end scoring time in milliseconds
    DecidedAt           DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    DecidedBy           NVARCHAR(50)    NOT NULL DEFAULT 'AI-AutoScore',  -- AI-AutoScore, ManualReview, Override
    AuditHash           VARBINARY(32)   NULL         -- SHA2_256 hash of inputs for tamper detection
);
GO

-- LoanDecisionAudit: append-only ledger table for regulatory compliance
-- Every loan decision is immutably recorded. Regulators (CFPB, ECOA/fair lending)
-- can verify no decision was retroactively altered — the blockchain-anchored hash
-- chain proves tamper evidence. Append-only = no UPDATE or DELETE allowed.
CREATE TABLE dbo.LoanDecisionAudit (
    AuditId         BIGINT IDENTITY(1,1) NOT NULL,
    LoanId          BIGINT          NOT NULL,
    Decision        NVARCHAR(20)    NOT NULL,   -- Approved, Denied
    ReasonCode      NVARCHAR(50)    NOT NULL,   -- EXCELLENT_CREDIT, HIGH_RISK_SCORE, etc.
    RiskScore       DECIMAL(5,2)    NOT NULL,   -- 0.00–100.00
    DecisionMaker   NVARCHAR(100)   NOT NULL,   -- AI-AutoScore, ManualReview, analyst name
    DecisionDate    DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME()
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
GO

-- ============================================
-- INDEXES
-- ============================================

CREATE INDEX IX_LoanHistory_LoanType ON dbo.LoanHistory(LoanType, ApplicationDate);
CREATE INDEX IX_LoanHistory_CreditScore ON dbo.LoanHistory(CreditScore);
CREATE INDEX IX_LoanHistory_Outcome ON dbo.LoanHistory(LoanOutcome);
CREATE INDEX IX_LoanHistory_ApplicationDate ON dbo.LoanHistory(ApplicationDate DESC);

-- Covering index for usp_LoanEligibility Step 2 and usp_LoanApplication Step 3.
-- Eliminates 103-row CI scan per call (7.7M execs/phase) → ~2 read seeks.
CREATE INDEX IX_LoanHistory_ApplicantId ON dbo.LoanHistory(ApplicantId)
    INCLUDE (ApprovedAmount, InterestRate);

-- REMOVED: IX_LoanApplications_Status caused PAGELATCH_EX contention.
-- All inserts write Status='Decided' → single-value monotonic last-page hot spot.
-- Not used by any workload procedure. Revert script: revert-dropped-indexes.sql
-- CREATE INDEX IX_LoanApplications_Status ON dbo.LoanApplications(Status, ApplicationDate);

-- Covering index: key on (ApplicantId, ApplicationDate) eliminates key lookups
-- to the CI for the top latch-producing queries (usp_LoanEligibility Step 3,
-- usp_LoanApplication Step 2, usp_AccountReview Step 2).
-- Without ApplicationDate in the key, readers do key lookups to CI leaf pages
-- where usp_LoanApplication concurrently INSERTs — causing PAGELATCH_SH convoys.
-- See: latch-contention-analysis.md (March 2026)
CREATE INDEX IX_LoanApplications_ApplicantId ON dbo.LoanApplications(ApplicantId, ApplicationDate)
    INCLUDE (ApplicationId, RequestedAmount, Status);

-- Covering index for usp_BranchActivity Step 3 date-range filter.
-- Eliminates full CI scan (706 reads → ~5-20 reads per call).
CREATE INDEX IX_LoanApplications_AppDate ON dbo.LoanApplications(ApplicationDate)
    INCLUDE (Status);

-- REMOVED: IX_LoanDecisions_ApplicationId caused PAGELATCH_EX contention.
-- ApplicationId is monotonically increasing (identity) → last-page hot spot on every INSERT.
-- 270K latch waits / 2.68M ms in Phase 5. The two LEFT JOINs that used it
-- (usp_LoanApplication Step 2, usp_AccountReview Step 2) now join on
-- (ApplicantId, ApplicationId) → CI seek on PK_LoanDecisions.
-- Dropped in setup-workload-procs.sql.

-- REMOVED: IX_LoanDecisions_RiskCategory and IX_LoanDecisions_DecidedAt caused
-- PAGELATCH_EX contention. Neither is used by any workload procedure.
-- DecidedAt (monotonic datetime) was a last-page hot spot on every insert.
-- Revert script: revert-dropped-indexes.sql
-- CREATE INDEX IX_LoanDecisions_RiskCategory ON dbo.LoanDecisions(RiskCategory);
-- CREATE INDEX IX_LoanDecisions_DecidedAt ON dbo.LoanDecisions(DecidedAt DESC);
GO

-- NOTE: Vector index (DiskANN) is created in demo3/07-vector-embeddings-setup.sql
--       after embeddings are generated (requires 100+ non-null vectors).
GO

-- ============================================
-- SAMPLE DATA — Applicants
-- ============================================

INSERT INTO dbo.Applicants (FirstName, LastName, Email, PhoneNumber, DateOfBirth, AnnualIncome, EmploymentStatus, EmploymentYears, CreditScore, DebtToIncomeRatio, Region, IsExistingCustomer)
VALUES
    ('Jerry',   'Seinfeld',   'jerry.seinfeld@email.com',     '555-2001', '1992-03-15', 95000.00,  'Employed',      6.5,  740, 0.28, 'US-West',    1),
    ('George',  'Costanza',   'george.costanza@email.com',    '555-2002', '1985-07-22', 62000.00,  'Employed',      12.0, 680, 0.35, 'US-East',    1),
    ('Elaine',  'Benes',      'elaine.benes@email.com',       '555-2003', '1990-11-08', 78000.00,  'Employed',      4.2,  710, 0.22, 'US-West',    0),
    ('Cosmo',   'Kramer',     'cosmo.kramer@email.com',       '555-2004', '1978-01-30', 120000.00, 'Self-Employed', 15.0, 760, 0.18, 'US-Central', 1),
    ('Susan',   'Ross',       'susan.ross@email.com',         '555-2005', '1995-06-12', 55000.00,  'Employed',      2.8,  650, 0.42, 'US-East',    0),
    ('Frank',   'Costanza',   'frank.costanza@email.com',     '555-2006', '1988-09-25', 85000.00,  'Employed',      8.3,  720, 0.30, 'US-West',    1),
    ('Estelle', 'Costanza',   'estelle.costanza@email.com',   '555-2007', '1993-04-18', 72000.00,  'Employed',      5.0,  695, 0.33, 'EU-West',    0),
    ('Art',     'Vandelay',   'art.vandelay@email.com',       '555-2008', '1980-12-03', 145000.00, 'Self-Employed', 20.0, 780, 0.15, 'US-East',    1),
    ('Jackie',  'Chiles',     'jackie.chiles@email.com',      '555-2009', '1997-08-21', 48000.00,  'Employed',      1.5,  620, 0.48, 'US-Central', 0),
    ('David',   'Puddy',      'david.puddy@email.com',        '555-2010', '1983-05-09', 110000.00, 'Employed',      14.0, 750, 0.20, 'US-West',    1),
    ('Kenny',   'Bania',      'kenny.bania@email.com',        '555-2011', '1991-02-14', 68000.00,  'Employed',      7.0,  700, 0.31, 'EU-West',    0),
    ('Lloyd',   'Braun',      'lloyd.braun@email.com',        '555-2012', '1976-10-27', 92000.00,  'Employed',      22.0, 735, 0.25, 'US-East',    1);
GO

-- Generate 988 additional applicants for Phase 1 baseline.
-- The original 12 are named characters with LoanHistory ties;
-- the rest are typical customers. grow-data.ps1 adds more
-- at pressure phases (2→3K, 4→6K, 6→10K).
DECLARE @i INT = 13;
WHILE @i <= 1000
BEGIN
    INSERT INTO dbo.Applicants
        (FirstName, LastName, Email, PhoneNumber, DateOfBirth,
         AnnualIncome, EmploymentStatus, EmploymentYears,
         CreditScore, DebtToIncomeRatio, Region, IsExistingCustomer)
    VALUES (
        CONCAT('Applicant', @i),
        CONCAT('Customer', @i),
        CONCAT('applicant', @i, '@zavalending.com'),
        CONCAT('555-', RIGHT('0000' + CAST(@i AS VARCHAR(10)), 4)),
        DATEADD(YEAR, -(20 + ABS(CHECKSUM(NEWID()) % 40)), GETDATE()),
        CAST(35000 + ABS(CHECKSUM(NEWID()) % 165000) AS DECIMAL(18,2)),
        CASE ABS(CHECKSUM(NEWID()) % 4)
            WHEN 0 THEN 'Employed' WHEN 1 THEN 'Self-Employed'
            WHEN 2 THEN 'Retired' ELSE 'Employed' END,
        CAST(0.5 + ABS(CHECKSUM(NEWID()) % 250) / 10.0 AS DECIMAL(4,1)),
        600 + ABS(CHECKSUM(NEWID()) % 200),
        CAST(0.10 + ABS(CHECKSUM(NEWID()) % 45) / 100.0 AS DECIMAL(5,2)),
        CASE ABS(CHECKSUM(NEWID()) % 4)
            WHEN 0 THEN 'US-West' WHEN 1 THEN 'US-East'
            WHEN 2 THEN 'US-Central' ELSE 'EU-West' END,
        0);
    SET @i = @i + 1;
END
GO
PRINT '=== Seeded 1,000 applicants (12 named + 988 generated). ===';
GO

-- ============================================
-- SAMPLE DATA — LoanHistory (historical loans with outcomes)
-- NOTE: In production demo, load 50K-12M+ rows with pre-computed embeddings
--       using bcp or BULK INSERT from Azure Blob Storage.
--       These sample rows use NULL embeddings as placeholders.
-- ============================================

-- Auto Loans — mixed outcomes
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('Auto', 35000.00, 35000.00, 5.49, 60, 72000.00, 710, 0.28, 5.0, 'New vehicle purchase - SUV',           'PaidInFull', 0.0420, '2024-02-15', '2024-02-15'),
    ('Auto', 28000.00, 28000.00, 6.99, 48, 58000.00, 665, 0.38, 3.2, 'Used vehicle purchase - sedan',        'PaidInFull', 0.0810, '2024-03-22', '2024-03-22'),
    ('Auto', 42000.00, 38000.00, 5.99, 72, 95000.00, 740, 0.22, 8.0, 'New vehicle purchase - truck',         'Active',     0.0310, '2024-06-10', '2024-06-10'),
    ('Auto', 32000.00, 32000.00, 7.49, 60, 61000.00, 680, 0.35, 4.5, 'Used vehicle purchase - SUV',          'Default',    0.1250, '2024-01-08', '2024-01-08'),
    ('Auto', 25000.00, 25000.00, 4.99, 48, 88000.00, 755, 0.20, 10.0,'New vehicle purchase - electric',      'PaidInFull', 0.0220, '2024-04-30', '2024-04-30'),
    ('Auto', 38000.00, NULL,     NULL,  60, 45000.00, 610, 0.52, 1.0, 'New vehicle purchase - luxury sedan',  'Denied',     NULL,   '2024-05-18', '2024-05-18'),
    ('Auto', 30000.00, 30000.00, 6.49, 60, 70000.00, 700, 0.30, 6.0, 'Certified pre-owned vehicle',          'PaidInFull', 0.0550, '2024-07-01', '2024-07-01'),
    ('Auto', 34000.00, 34000.00, 7.99, 72, 63000.00, 670, 0.40, 3.0, 'New vehicle purchase - midsize',       'Default',    0.1450, '2024-08-14', '2024-08-14'),
    ('Auto', 22000.00, 22000.00, 5.29, 36, 80000.00, 730, 0.19, 9.0, 'Used vehicle purchase - compact',      'PaidInFull', 0.0280, '2024-09-05', '2024-09-05'),
    ('Auto', 40000.00, 40000.00, 5.79, 60, 105000.00,745, 0.24, 7.5, 'New vehicle purchase - hybrid SUV',    'Active',     0.0350, '2025-01-12', '2025-01-12');
GO

-- Personal Loans — mixed outcomes
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('Personal', 15000.00, 15000.00, 8.99,  36, 65000.00, 700, 0.30, 5.0, 'Debt consolidation',              'PaidInFull', 0.0650, '2024-01-20', '2024-01-20'),
    ('Personal', 25000.00, 20000.00, 10.49, 48, 52000.00, 660, 0.38, 2.5, 'Home renovation',                 'Active',     0.0980, '2024-04-12', '2024-04-12'),
    ('Personal', 10000.00, 10000.00, 7.49,  24, 78000.00, 735, 0.22, 8.0, 'Medical expenses',                'PaidInFull', 0.0320, '2024-06-28', '2024-06-28'),
    ('Personal', 30000.00, NULL,     NULL,   60, 40000.00, 590, 0.55, 0.5, 'Vacation and lifestyle',          'Denied',     NULL,   '2024-07-15', '2024-07-15'),
    ('Personal', 20000.00, 20000.00, 9.49,  36, 70000.00, 710, 0.28, 6.0, 'Wedding expenses',                'PaidInFull', 0.0480, '2024-09-01', '2024-09-01');
GO

-- Small Business Loans — mixed outcomes
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('SmallBusiness', 75000.00,  75000.00,  7.99,  60, 120000.00, 750, 0.20, 12.0, 'Equipment purchase - restaurant',  'PaidInFull', 0.0580, '2024-02-10', '2024-02-10'),
    ('SmallBusiness', 150000.00, 125000.00, 8.49,  84, 180000.00, 720, 0.28, 8.0,  'Business expansion - retail',     'Active',     0.0720, '2024-05-22', '2024-05-22'),
    ('SmallBusiness', 50000.00,  50000.00,  9.99,  48, 85000.00,  690, 0.35, 5.0,  'Inventory financing',             'Default',    0.1380, '2024-03-15', '2024-03-15'),
    ('SmallBusiness', 100000.00, NULL,      NULL,   60, 60000.00,  640, 0.48, 2.0,  'Startup launch - tech',           'Denied',     NULL,   '2024-08-30', '2024-08-30'),
    ('SmallBusiness', 200000.00, 200000.00, 6.99,  120,250000.00, 780, 0.15, 20.0, 'Commercial property renovation',  'Active',     0.0280, '2025-01-05', '2025-01-05');
GO

-- ============================================
-- ADDITIONAL SAMPLE DATA — LoanHistory (80 more rows for DiskANN vector index minimum of 100)
-- DiskANN requires at least 100 non-null vectors to build the index.
-- ============================================

-- HomeImprovement Loans (rows 21-30)
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('HomeImprovement', 45000.00, 45000.00, 7.99, 60, 82000.00, 720, 0.26, 7.0, 'Kitchen remodel - full renovation',        'PaidInFull', 0.0380, '2024-01-10', '2024-01-10'),
    ('HomeImprovement', 30000.00, 30000.00, 8.49, 48, 65000.00, 690, 0.33, 4.0, 'Bathroom addition - master suite',          'Active',     0.0650, '2024-03-05', '2024-03-05'),
    ('HomeImprovement', 60000.00, 55000.00, 9.29, 84, 95000.00, 710, 0.29, 10.0,'Basement finishing - recreation room',      'Active',     0.0520, '2024-04-18', '2024-04-18'),
    ('HomeImprovement', 25000.00, 25000.00, 7.49, 36, 78000.00, 745, 0.20, 8.5, 'Energy efficiency - solar panels',          'PaidInFull', 0.0250, '2024-05-22', '2024-05-22'),
    ('HomeImprovement', 80000.00, NULL,     NULL,  120,55000.00, 620, 0.47, 2.0, 'Full home renovation - inherited property', 'Denied',     NULL,   '2024-06-15', '2024-06-15'),
    ('HomeImprovement', 35000.00, 35000.00, 8.99, 60, 70000.00, 700, 0.31, 5.5, 'Deck and outdoor living space',             'PaidInFull', 0.0480, '2024-07-08', '2024-07-08'),
    ('HomeImprovement', 50000.00, 50000.00, 7.29, 60, 110000.00,760, 0.18, 12.0,'Roof replacement and insulation',           'Active',     0.0200, '2024-08-20', '2024-08-20'),
    ('HomeImprovement', 40000.00, 40000.00, 8.79, 48, 73000.00, 680, 0.36, 3.5, 'HVAC system replacement',                   'Default',    0.1100, '2024-09-12', '2024-09-12'),
    ('HomeImprovement', 55000.00, 55000.00, 7.99, 72, 88000.00, 730, 0.24, 9.0, 'Garage conversion - home office',           'Active',     0.0350, '2024-10-01', '2024-10-01'),
    ('HomeImprovement', 70000.00, 65000.00, 8.29, 84, 105000.00,715, 0.30, 6.0, 'Landscaping and pool installation',         'Active',     0.0580, '2024-11-15', '2024-11-15');
GO

-- More Auto Loans (rows 31-45)
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('Auto', 29000.00, 29000.00, 5.99, 48, 68000.00, 715, 0.27, 6.0, 'Certified pre-owned SUV',                  'PaidInFull', 0.0400, '2024-02-08', '2024-02-08'),
    ('Auto', 55000.00, 50000.00, 6.49, 72, 120000.00,750, 0.21, 11.0,'New luxury sedan - executive',              'Active',     0.0280, '2024-03-15', '2024-03-15'),
    ('Auto', 18000.00, 18000.00, 7.99, 36, 45000.00, 655, 0.39, 2.0, 'Used economy car - commuter',              'PaidInFull', 0.0880, '2024-04-22', '2024-04-22'),
    ('Auto', 45000.00, NULL,     NULL,  72, 52000.00, 600, 0.55, 1.5, 'New sports car - recreation',              'Denied',     NULL,   '2024-05-30', '2024-05-30'),
    ('Auto', 36000.00, 36000.00, 5.49, 60, 92000.00, 740, 0.23, 8.0, 'New minivan - family vehicle',             'Active',     0.0300, '2024-06-18', '2024-06-18'),
    ('Auto', 27000.00, 27000.00, 6.99, 48, 62000.00, 695, 0.32, 4.5, 'Used pickup truck - work vehicle',         'Default',    0.0950, '2024-07-25', '2024-07-25'),
    ('Auto', 33000.00, 33000.00, 5.79, 60, 85000.00, 725, 0.25, 7.0, 'New compact SUV - daily driver',           'PaidInFull', 0.0350, '2024-08-10', '2024-08-10'),
    ('Auto', 48000.00, 45000.00, 6.29, 72, 130000.00,770, 0.17, 15.0,'New electric SUV - premium',               'Active',     0.0180, '2024-09-22', '2024-09-22'),
    ('Auto', 22000.00, 22000.00, 8.49, 48, 50000.00, 645, 0.41, 2.5, 'Used sedan - first car after bankruptcy',  'Default',    0.1300, '2024-10-05', '2024-10-05'),
    ('Auto', 31000.00, 31000.00, 5.99, 60, 75000.00, 710, 0.28, 5.0, 'New hatchback - fuel efficient',           'PaidInFull', 0.0420, '2024-11-18', '2024-11-18'),
    ('Auto', 40000.00, 38000.00, 6.79, 60, 98000.00, 735, 0.22, 9.0, 'New midsize SUV - towing package',         'Active',     0.0320, '2024-12-01', '2024-12-01'),
    ('Auto', 15000.00, 15000.00, 9.49, 36, 42000.00, 630, 0.44, 1.0, 'Used compact - budget transportation',     'Default',    0.1450, '2025-01-08', '2025-01-08'),
    ('Auto', 38000.00, 38000.00, 5.29, 60, 105000.00,755, 0.19, 10.0,'New hybrid sedan - commuter',              'Active',     0.0220, '2025-02-14', '2025-02-14'),
    ('Auto', 52000.00, NULL,     NULL,  84, 60000.00, 615, 0.50, 1.5, 'New luxury SUV - aspirational purchase',   'Denied',     NULL,   '2025-03-01', '2025-03-01'),
    ('Auto', 26000.00, 26000.00, 6.49, 48, 70000.00, 705, 0.30, 5.5, 'Certified pre-owned wagon - family',       'PaidInFull', 0.0450, '2025-03-20', '2025-03-20');
GO

-- More Personal Loans (rows 46-60)
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('Personal', 12000.00, 12000.00, 8.49, 24, 58000.00, 710, 0.27, 5.0, 'Emergency home repair - plumbing',           'PaidInFull', 0.0380, '2024-01-15', '2024-01-15'),
    ('Personal',  8000.00,  8000.00, 9.99, 24, 45000.00, 675, 0.34, 3.0, 'Dental surgery - out of pocket',             'PaidInFull', 0.0650, '2024-02-20', '2024-02-20'),
    ('Personal', 35000.00, 30000.00, 10.99, 48, 70000.00, 660, 0.37, 4.0,'Debt consolidation - credit cards',          'Active',     0.0920, '2024-03-28', '2024-03-28'),
    ('Personal', 50000.00, NULL,     NULL,   60, 48000.00, 580, 0.58, 0.5,'Investment in cryptocurrency venture',       'Denied',     NULL,   '2024-04-10', '2024-04-10'),
    ('Personal', 18000.00, 18000.00, 7.99, 36, 82000.00, 730, 0.22, 8.0, 'Adoption expenses - international',          'PaidInFull', 0.0300, '2024-05-15', '2024-05-15'),
    ('Personal',  5000.00,  5000.00, 11.49, 12, 38000.00, 640, 0.42, 1.5,'Moving expenses - job relocation',           'PaidInFull', 0.0780, '2024-06-22', '2024-06-22'),
    ('Personal', 25000.00, 25000.00, 8.99, 36, 90000.00, 745, 0.20, 10.0,'Home furnishing - new house',               'Active',     0.0250, '2024-07-18', '2024-07-18'),
    ('Personal', 40000.00, 35000.00, 9.49, 48, 75000.00, 690, 0.33, 5.0, 'Graduate school tuition - MBA program',      'Active',     0.0680, '2024-08-30', '2024-08-30'),
    ('Personal', 15000.00, NULL,     NULL,   36, 35000.00, 595, 0.52, 1.0,'Personal travel - extended sabbatical',      'Denied',     NULL,   '2024-09-15', '2024-09-15'),
    ('Personal', 20000.00, 20000.00, 8.29, 36, 68000.00, 720, 0.26, 6.5, 'Family emergency - medical bills',           'PaidInFull', 0.0350, '2024-10-08', '2024-10-08'),
    ('Personal', 10000.00, 10000.00, 10.49, 24, 52000.00, 665, 0.36, 3.5,'Car repair and maintenance backlog',         'Default',    0.0980, '2024-11-20', '2024-11-20'),
    ('Personal', 30000.00, 30000.00, 7.49, 48, 95000.00, 760, 0.16, 12.0,'Backyard pool installation',                'Active',     0.0200, '2024-12-05', '2024-12-05'),
    ('Personal', 22000.00, 22000.00, 9.29, 36, 60000.00, 700, 0.30, 4.5, 'IVF fertility treatment - second round',     'Active',     0.0520, '2025-01-22', '2025-01-22'),
    ('Personal', 45000.00, NULL,     NULL,   60, 55000.00, 610, 0.48, 2.0,'Business startup - food truck',              'Denied',     NULL,   '2025-02-10', '2025-02-10'),
    ('Personal', 16000.00, 16000.00, 8.79, 36, 72000.00, 715, 0.28, 7.0, 'Musical instrument - professional piano',    'PaidInFull', 0.0420, '2025-03-05', '2025-03-05');
GO

-- More SmallBusiness Loans (rows 61-80)
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('SmallBusiness',  60000.00,  60000.00, 8.49, 48, 100000.00, 730, 0.24, 10.0,'Bakery expansion - second oven and seating', 'PaidInFull', 0.0450, '2024-01-25', '2024-01-25'),
    ('SmallBusiness', 120000.00, 100000.00, 9.29, 72, 140000.00, 700, 0.30, 6.0, 'Auto repair shop - equipment upgrade',       'Active',     0.0750, '2024-02-18', '2024-02-18'),
    ('SmallBusiness',  40000.00,  40000.00, 10.49, 36, 75000.00, 680, 0.35, 4.0, 'Food truck startup - kitchen build-out',     'Default',    0.1200, '2024-03-22', '2024-03-22'),
    ('SmallBusiness', 300000.00, 300000.00, 6.49, 120,350000.00, 790, 0.12, 22.0,'Commercial real estate - office building',   'Active',     0.0150, '2024-04-15', '2024-04-15'),
    ('SmallBusiness',  80000.00, NULL,      NULL,  60, 50000.00, 610, 0.52, 1.5, 'E-commerce startup - inventory',             'Denied',     NULL,   '2024-05-28', '2024-05-28'),
    ('SmallBusiness',  95000.00,  95000.00, 8.99, 60, 130000.00, 740, 0.22, 14.0,'Dental practice - new equipment',            'PaidInFull', 0.0320, '2024-06-10', '2024-06-10'),
    ('SmallBusiness', 175000.00, 150000.00, 7.79, 84, 200000.00, 755, 0.18, 16.0,'Franchise acquisition - coffee shop',        'Active',     0.0400, '2024-07-20', '2024-07-20'),
    ('SmallBusiness',  55000.00,  55000.00, 9.99, 48, 80000.00, 670, 0.38, 5.0, 'Landscaping company - vehicle fleet',         'Default',    0.1350, '2024-08-05', '2024-08-05'),
    ('SmallBusiness', 225000.00, 225000.00, 7.29, 96, 280000.00, 775, 0.15, 18.0,'Manufacturing - CNC machine purchase',       'Active',     0.0200, '2024-09-18', '2024-09-18'),
    ('SmallBusiness',  35000.00,  35000.00, 10.99, 36, 60000.00, 650, 0.40, 3.0, 'Pet grooming salon - startup costs',         'Default',    0.1400, '2024-10-12', '2024-10-12'),
    ('SmallBusiness', 500000.00, 450000.00, 6.99, 120,400000.00, 800, 0.10, 25.0,'Hotel renovation - boutique property',       'Active',     0.0100, '2024-11-05', '2024-11-05'),
    ('SmallBusiness',  70000.00,  70000.00, 8.79, 48, 90000.00, 710, 0.28, 7.0, 'Gym and fitness studio - equipment',          'PaidInFull', 0.0550, '2024-12-20', '2024-12-20'),
    ('SmallBusiness', 180000.00, NULL,      NULL,  84, 65000.00, 625, 0.50, 2.0, 'Restaurant chain - third location',          'Denied',     NULL,   '2025-01-15', '2025-01-15'),
    ('SmallBusiness', 110000.00, 110000.00, 8.29, 60, 150000.00, 745, 0.20, 12.0,'Veterinary clinic - X-ray equipment',        'Active',     0.0350, '2025-02-08', '2025-02-08'),
    ('SmallBusiness',  45000.00,  45000.00, 9.49, 36, 70000.00, 685, 0.34, 5.0, 'Tutoring center - classroom build-out',       'PaidInFull', 0.0620, '2025-02-25', '2025-02-25'),
    ('SmallBusiness', 400000.00, 380000.00, 7.49, 120,320000.00, 785, 0.13, 20.0,'Winery expansion - barrel room and tasting', 'Active',     0.0180, '2025-03-12', '2025-03-12'),
    ('SmallBusiness',  90000.00,  90000.00, 9.79, 60, 110000.00, 695, 0.32, 8.0, 'Dry cleaning chain - new location',          'Active',     0.0700, '2025-03-28', '2025-03-28'),
    ('SmallBusiness',  65000.00, NULL,      NULL,  48, 55000.00, 635, 0.46, 2.5, 'Mobile car wash franchise - startup',         'Denied',     NULL,   '2024-06-30', '2024-06-30'),
    ('SmallBusiness', 140000.00, 140000.00, 8.49, 72, 160000.00, 735, 0.23, 11.0,'IT consulting firm - office and staff',      'PaidInFull', 0.0380, '2024-08-15', '2024-08-15'),
    ('SmallBusiness',  85000.00,  85000.00, 9.29, 48, 95000.00, 705, 0.30, 6.0, 'Brewery taproom - renovation and permits',    'Active',     0.0600, '2024-10-28', '2024-10-28');
GO

-- Additional Auto + Personal mix (rows 81-100)
INSERT INTO dbo.LoanHistory (LoanType, RequestedAmount, ApprovedAmount, InterestRate, TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio, EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate, ApplicationDate, DecisionDate)
VALUES
    ('Auto',     35000.00, 35000.00, 5.69, 60, 88000.00, 725, 0.24, 7.5, 'New crossover SUV - AWD',                   'Active',     0.0330, '2024-01-20', '2024-01-20'),
    ('Auto',     20000.00, 20000.00, 8.99, 36, 48000.00, 650, 0.40, 2.0, 'Used minivan - growing family',             'Default',    0.1150, '2024-02-28', '2024-02-28'),
    ('Auto',     44000.00, 44000.00, 5.49, 72, 115000.00,760, 0.18, 13.0,'New electric truck - work and personal',    'Active',     0.0190, '2024-04-05', '2024-04-05'),
    ('Personal', 28000.00, 28000.00, 8.99, 48, 76000.00, 705, 0.29, 6.0, 'Basement renovation - home theater',        'Active',     0.0500, '2024-05-12', '2024-05-12'),
    ('Personal',  7000.00,  7000.00, 10.99, 12, 42000.00, 660, 0.37, 2.5,'Emergency veterinary surgery - pet',        'PaidInFull', 0.0700, '2024-06-08', '2024-06-08'),
    ('Auto',     30000.00, NULL,     NULL,  60, 40000.00, 605, 0.53, 1.0, 'New SUV - single income household',         'Denied',     NULL,   '2024-07-15', '2024-07-15'),
    ('Personal', 13000.00, 13000.00, 9.49, 24, 55000.00, 695, 0.31, 4.0, 'Professional certification - pilot license', 'PaidInFull', 0.0480, '2024-08-22', '2024-08-22'),
    ('Auto',     27000.00, 27000.00, 6.79, 48, 72000.00, 710, 0.28, 6.0, 'Certified pre-owned EV - commuter',         'PaidInFull', 0.0400, '2024-09-30', '2024-09-30'),
    ('Personal', 20000.00, 18000.00, 9.99, 36, 60000.00, 680, 0.35, 3.5, 'Wedding venue deposit and catering',        'Active',     0.0750, '2024-10-18', '2024-10-18'),
    ('Auto',     50000.00, 48000.00, 6.29, 72, 135000.00,765, 0.17, 14.0,'New performance sedan - enthusiast',        'Active',     0.0210, '2024-11-25', '2024-11-25'),
    ('Personal', 35000.00, NULL,     NULL,  48, 50000.00, 615, 0.49, 1.5, 'Cosmetic surgery - elective procedures',    'Denied',     NULL,   '2024-12-10', '2024-12-10'),
    ('Auto',     23000.00, 23000.00, 7.49, 48, 58000.00, 685, 0.33, 4.0, 'Used luxury sedan - off-lease deal',        'PaidInFull', 0.0650, '2025-01-05', '2025-01-05'),
    ('Personal', 11000.00, 11000.00, 8.49, 24, 65000.00, 725, 0.22, 8.0, 'LASIK eye surgery - both eyes',             'PaidInFull', 0.0300, '2025-01-28', '2025-01-28'),
    ('Auto',     42000.00, 42000.00, 5.99, 60, 100000.00,740, 0.21, 9.0, 'New plug-in hybrid SUV',                    'Active',     0.0280, '2025-02-15', '2025-02-15'),
    ('Personal', 18000.00, 18000.00, 9.79, 36, 62000.00, 690, 0.32, 5.0, 'Accessibility modifications - aging parent', 'Active',     0.0580, '2025-03-08', '2025-03-08'),
    ('Auto',     32000.00, 32000.00, 6.49, 60, 80000.00, 720, 0.26, 7.0, 'New sedan - replacing totaled vehicle',     'Active',     0.0380, '2025-03-22', '2025-03-22'),
    ('Personal', 25000.00, 25000.00, 8.29, 36, 85000.00, 735, 0.20, 9.5, 'Home security and smart home upgrade',      'PaidInFull', 0.0280, '2024-03-10', '2024-03-10'),
    ('Auto',     19000.00, 19000.00, 7.99, 36, 52000.00, 670, 0.36, 3.0, 'Used hatchback - college graduate first car','PaidInFull', 0.0750, '2024-05-25', '2024-05-25'),
    ('Personal', 40000.00, 38000.00, 9.49, 48, 90000.00, 715, 0.25, 8.0, 'Home gym and wellness room build-out',      'Active',     0.0420, '2024-07-12', '2024-07-12'),
    ('Auto',     37000.00, 37000.00, 5.79, 60, 95000.00, 745, 0.22, 10.0,'New AWD sedan - winter climate driver',     'Active',     0.0260, '2024-09-08', '2024-09-08');
GO

-- ============================================
-- Assign ApplicantId to seed rows + grow to 1,000 rows
-- Phase 1 baseline: 1,000 applicants, 1,000 loans (~1 loan/applicant)
-- grow-data.ps1 scales both tables at pressure phases.
-- ============================================

-- Assign ApplicantId to the 100 seed rows (LoanId 1-100 → ApplicantId 1-100)
UPDATE dbo.LoanHistory SET ApplicantId = CAST(LoanId AS INT) WHERE ApplicantId IS NULL;
GO

-- Generate 900 more rows (ApplicantId 101-1000)
DECLARE @i INT = 101;
DECLARE @denied BIT;
WHILE @i <= 1000
BEGIN
    SET @denied = CASE WHEN ABS(CHECKSUM(NEWID()) % 5) = 0 THEN 1 ELSE 0 END;
    INSERT INTO dbo.LoanHistory
        (ApplicantId, LoanType, RequestedAmount, ApprovedAmount, InterestRate,
         TermMonths, ApplicantIncome, CreditScore, DebtToIncomeRatio,
         EmploymentYears, LoanPurpose, LoanOutcome, DefaultRate,
         ApplicationDate, DecisionDate)
    VALUES (
        @i,
        CASE ABS(CHECKSUM(NEWID()) % 4)
            WHEN 0 THEN 'Auto' WHEN 1 THEN 'Personal'
            WHEN 2 THEN 'SmallBusiness' ELSE 'HomeImprovement' END,
        CAST(5000 + ABS(CHECKSUM(NEWID()) % 195000) AS DECIMAL(18,2)),
        CASE WHEN @denied = 1 THEN NULL
             ELSE CAST(5000 + ABS(CHECKSUM(NEWID()) % 195000) AS DECIMAL(18,2)) END,
        CASE WHEN @denied = 1 THEN NULL
             ELSE CAST(4.0 + ABS(CHECKSUM(NEWID()) % 800) / 100.0 AS DECIMAL(5,2)) END,
        CASE ABS(CHECKSUM(NEWID()) % 5)
            WHEN 0 THEN 12 WHEN 1 THEN 24 WHEN 2 THEN 36 WHEN 3 THEN 48 ELSE 60 END,
        CAST(35000 + ABS(CHECKSUM(NEWID()) % 165000) AS DECIMAL(18,2)),
        600 + ABS(CHECKSUM(NEWID()) % 200),
        CAST(0.10 + ABS(CHECKSUM(NEWID()) % 50) / 100.0 AS DECIMAL(5,2)),
        CAST(0.5 + ABS(CHECKSUM(NEWID()) % 250) / 10.0 AS DECIMAL(4,1)),
        'Generated loan ' + CAST(@i AS VARCHAR(10)),
        CASE WHEN @denied = 1 THEN 'Denied'
             WHEN ABS(CHECKSUM(NEWID()) % 4) = 0 THEN 'Default'
             WHEN ABS(CHECKSUM(NEWID()) % 3) = 0 THEN 'Active'
             ELSE 'PaidInFull' END,
        CASE WHEN @denied = 1 THEN NULL
             ELSE CAST(ABS(CHECKSUM(NEWID()) % 1500) / 10000.0 AS DECIMAL(5,4)) END,
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID()) % 365)), '2025-03-31'),
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID()) % 365)), '2025-03-31')
    );
    SET @i = @i + 1;
END
GO
PRINT '=== LoanHistory: 100 seed + 900 generated = 1,000 rows, all with ApplicantId. ===';
GO

-- ============================================
-- SAMPLE DATA — A pending loan application (for the live demo)
-- ============================================

INSERT INTO dbo.LoanApplications (ApplicantId, LoanType, RequestedAmount, TermMonths, LoanPurpose, Channel, Status)
VALUES
    (8, 'SmallBusiness', 150000.00, 60, 'Import/export business expansion - Vandelay Industries specializes in importing and exporting fine latex products and long matches', 'Web', 'Pending');
GO

-- ============================================
-- DATABASE-SCOPED CREDENTIAL for Azure OpenAI
-- ============================================
-- NOTE: Replace with your actual Azure OpenAI endpoint and API key
--       In production, use Managed Identity instead of API key

-- CREATE DATABASE SCOPED CREDENTIAL [AzureOpenAI]
-- WITH IDENTITY = 'HTTPEndpointHeaders',
--      SECRET = '{"api-key": "<YOUR-AZURE-OPENAI-API-KEY>"}';
--
-- -- Verify connectivity (optional test)
-- DECLARE @response NVARCHAR(MAX);
-- EXEC sp_invoke_external_rest_endpoint
--     @url = 'https://<YOUR-RESOURCE>.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-08-01-preview',
--     @method = 'POST',
--     @credential = [AzureOpenAI],
--     @payload = N'{"messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}',
--     @response = @response OUTPUT;
-- SELECT @response;

PRINT 'ZavaLendingDB schema and sample data created successfully.';
PRINT 'Next steps:';
PRINT '  1. Configure database-scoped credential for Azure OpenAI (see comments above)';
PRINT '  2. Create named replica: zavalending_NamedReplica';
PRINT '  3. Deploy vector search procedure: ../demo3-vector-ai/scripts/02-usp-find-similar-loans.sql';
PRINT '  4. Deploy scoring procedure: ../demo3-vector-ai/scripts/03-usp-score-loan-application.sql';
PRINT '  5. For full demo scale: bulk load 50K+ rows into LoanHistory with pre-computed embeddings';
GO
