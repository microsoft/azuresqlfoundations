/*
    Step 3a — Modernize #1: Compatibility Level 150 → 170
    Migrate & Modernize: On-Prem SQL Server 2019 → Hyperscale

    The database migrated from on-prem SQL Server 2019, so it landed on
    Hyperscale at compatibility level 150. Bumping it to 170 lights up the
    full SQL Server 2022 (160) intelligent query processing suite PLUS the
    2025 (170) additions — none of which is active at 150:

        - Parameter Sensitive Plan (PSP) optimization   (160)
        - Cardinality Estimation (CE) feedback          (160)
        - Degree of Parallelism (DOP) feedback          (160)
        - Memory Grant Feedback persistence + percentile (160)
        - plus 170 engine/optimizer behaviors

    Run order: this is Step 3a (after migration + validation).

    NOTE: Replace [ZavaLendingDB] with your actual database name. Never
    hardcode server/database names in committed runs.
*/

SET NOCOUNT ON;
GO

-- ============================================
-- BEFORE: confirm we landed at 150
-- ============================================
SELECT
    name                AS database_name,
    compatibility_level
FROM sys.databases
WHERE name = N'ZavaLendingDB';   -- expect 150 immediately after migration
GO

/*
    BEFORE query (concrete): run the same parameterized statement with a highly
    common LoanType and a less common LoanType. This gives a practical PSP demo.
*/
SET STATISTICS IO, TIME ON;
GO

DECLARE @q NVARCHAR(MAX) = N'
SELECT
    COUNT_BIG(*)                AS loan_count,
    AVG(InterestRate)           AS avg_rate,
    AVG(DefaultRate)            AS avg_default_rate
FROM dbo.LoanHistory
WHERE LoanType = @LoanType
  AND ApplicationDate >= DATEADD(YEAR, -2, SYSUTCDATETIME())
  AND CreditScore BETWEEN 620 AND 760;';

EXEC sys.sp_executesql @q, N'@LoanType NVARCHAR(30)', @LoanType = N'Auto';
EXEC sys.sp_executesql @q, N'@LoanType NVARCHAR(30)', @LoanType = N'HomeImprovement';
GO

SET STATISTICS IO, TIME OFF;
GO

-- ============================================
-- THE OPTIMIZATION: bump to 170
-- ============================================
ALTER DATABASE [ZavaLendingDB] SET COMPATIBILITY_LEVEL = 170;
GO

-- ============================================
-- AFTER: confirm 170 and re-run the query
-- ============================================
SELECT
    name                AS database_name,
    compatibility_level
FROM sys.databases
WHERE name = N'ZavaLendingDB';   -- now 170
GO

/*
    AFTER query (same statement, same parameters).
    At 170, PSP can keep multiple plan variants for the skewed parameter values.
*/
SET STATISTICS IO, TIME ON;
GO

DECLARE @q2 NVARCHAR(MAX) = N'
SELECT
    COUNT_BIG(*)                AS loan_count,
    AVG(InterestRate)           AS avg_rate,
    AVG(DefaultRate)            AS avg_default_rate
FROM dbo.LoanHistory
WHERE LoanType = @LoanType
  AND ApplicationDate >= DATEADD(YEAR, -2, SYSUTCDATETIME())
  AND CreditScore BETWEEN 620 AND 760;';

EXEC sys.sp_executesql @q2, N'@LoanType NVARCHAR(30)', @LoanType = N'Auto';
EXEC sys.sp_executesql @q2, N'@LoanType NVARCHAR(30)', @LoanType = N'HomeImprovement';
GO

SET STATISTICS IO, TIME OFF;
GO

/*
    Inspect IQP/feedback artifacts:
*/

-- Dispatcher / PSP plan variants for queries in cache
SELECT
    qsq.query_id,
    qsq.query_hash,
    COUNT(DISTINCT qsp.plan_id) AS plan_variants
FROM sys.query_store_query AS qsq
JOIN sys.query_store_plan  AS qsp ON qsp.query_id = qsq.query_id
GROUP BY qsq.query_id, qsq.query_hash
HAVING COUNT(DISTINCT qsp.plan_id) > 1
ORDER BY plan_variants DESC;
GO

-- Memory grant / CE / DOP feedback surfaced via Query Store plan feedback
SELECT
    plan_id,
    feature_desc,
    feedback_data,
    state_desc
FROM sys.query_store_plan_feedback
ORDER BY plan_id;
GO
