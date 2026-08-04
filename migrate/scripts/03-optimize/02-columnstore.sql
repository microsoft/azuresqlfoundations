/*
    Step 3b — Modernize #2: Rowstore → Clustered Columnstore
    Migrate & Modernize: On-Prem SQL Server 2019 → Hyperscale

    LoanTransactions (~5.8M rows of loan financial events) migrated from on-prem
    as a ROWSTORE table. Converting it to a clustered columnstore index (CCI)
    delivers heavy compression and batch-mode execution for the analytic
    aggregation queries — the same storage format Act 2 (scale) relies on.

    This is Step 3b (after the compat 150 → 170 bump).

    sqlcmd / scripting note: columnstore + index DDL is sensitive to SET options.
    These are set explicitly so the script behaves the same under sqlcmd as it
    does in SSMS / the MSSQL extension.

    NOTE: Replace [ZavaLendingDB] with your actual database name.
*/

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
GO

USE [ZavaLendingDB];
GO

-- ============================================
-- BEFORE: storage footprint as rowstore
-- ============================================
SELECT
    OBJECT_NAME(p.object_id)                    AS table_name,
    i.type_desc                                 AS index_type,
    SUM(p.rows)                                 AS row_count,
    CAST(SUM(a.used_pages) * 8.0 / 1024 AS DECIMAL(18,2)) AS used_mb
FROM sys.partitions AS p
JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE p.object_id = OBJECT_ID(N'dbo.LoanTransactions')
GROUP BY OBJECT_NAME(p.object_id), i.type_desc;
GO

-- BEFORE query (rowstore baseline)
SET STATISTICS IO, TIME ON;
GO

SELECT
    LoanType,
    Region,
    COUNT_BIG(*)                              AS txn_count,
    SUM(Amount)                               AS total_amount,
    AVG(CAST(DaysPastDue AS DECIMAL(10,2)))   AS avg_dpd
FROM dbo.LoanTransactions
WHERE TransactionDate >= DATEADD(YEAR, -1, CAST(SYSUTCDATETIME() AS DATE))
GROUP BY LoanType, Region
ORDER BY LoanType, Region;
GO

SET STATISTICS IO, TIME OFF;
GO

-- ============================================
-- THE OPTIMIZATION: convert rowstore → clustered columnstore
-- ORDER (TransactionDate) + MAXDOP 1 builds non-overlapping segments so
-- date-filtered queries get rowgroup (segment) elimination.
-- DROP_EXISTING = ON converts an existing rowstore clustered index in place.
-- (If the source table is a heap, remove DROP_EXISTING = ON.)
-- ============================================
CREATE CLUSTERED COLUMNSTORE INDEX CCI_LoanTransactions
    ON dbo.LoanTransactions
    ORDER (TransactionDate)
    WITH (DROP_EXISTING = ON, MAXDOP = 1);
GO

-- Keep a nonclustered rowstore index for OLTP point lookups by loan
CREATE NONCLUSTERED INDEX IX_LoanTransactions_LoanId
    ON dbo.LoanTransactions (LoanId, TransactionDate DESC)
    INCLUDE (TransactionType, Amount, RunningBalance, Region, Channel)
    WITH (DROP_EXISTING = ON);
GO

-- ============================================
-- AFTER: storage footprint as columnstore (compression win)
-- ============================================
SELECT
    OBJECT_NAME(p.object_id)                    AS table_name,
    i.type_desc                                 AS index_type,
    SUM(p.rows)                                 AS row_count,
    CAST(SUM(a.used_pages) * 8.0 / 1024 AS DECIMAL(18,2)) AS used_mb
FROM sys.partitions AS p
JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE p.object_id = OBJECT_ID(N'dbo.LoanTransactions')
GROUP BY OBJECT_NAME(p.object_id), i.type_desc;
GO

-- Rowgroup health (all should be COMPRESSED, ~1M rows each)
SELECT
    state_desc,
    COUNT(*)        AS rowgroup_count,
    SUM(total_rows) AS total_rows,
    AVG(total_rows) AS avg_rows_per_rowgroup
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID(N'dbo.LoanTransactions')
GROUP BY state_desc;
GO

-- AFTER query (same statement after CCI conversion)
SET STATISTICS IO, TIME ON;
GO

SELECT
    LoanType,
    Region,
    COUNT_BIG(*)                              AS txn_count,
    SUM(Amount)                               AS total_amount,
    AVG(CAST(DaysPastDue AS DECIMAL(10,2)))   AS avg_dpd
FROM dbo.LoanTransactions
WHERE TransactionDate >= DATEADD(YEAR, -1, CAST(SYSUTCDATETIME() AS DATE))
GROUP BY LoanType, Region
ORDER BY LoanType, Region;
GO

SET STATISTICS IO, TIME OFF;
GO

/*
    Compare logical reads and elapsed time against the rowstore baseline.
*/
