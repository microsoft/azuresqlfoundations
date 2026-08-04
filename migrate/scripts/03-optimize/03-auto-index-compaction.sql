/*
    Step 3c — Modernize #3: Automatic Index Compaction (PREVIEW)
    Migrate & Modernize: On-Prem SQL Server 2019 → Hyperscale

    On-prem, the DBA team ran weekend index rebuild jobs to fight page bloat
    from the OLTP write workload. On Azure SQL Hyperscale, automatic index
    compaction keeps B-tree leaf pages dense CONTINUOUSLY, with low overhead,
    and NO maintenance jobs.

    This is Step 3c (hands-off index maintenance).

    PREVIEW: Automatic index compaction is in preview for Azure SQL Database,
    Azure SQL Managed Instance (Always-up-to-date update policy), and SQL
    database in Fabric. It acts on B-tree leaf pages in IN_ROW_DATA only —
    NOT heaps, NOT compressed columnstore rowgroups — so it complements the
    Step 3b columnstore conversion rather than overlapping it.
    Docs: https://learn.microsoft.com/sql/relational-databases/indexes/automatic-index-compaction

    NOTE: Replace [ZavaLendingDB] with your actual database name.
*/

SET NOCOUNT ON;
GO

USE [ZavaLendingDB];
GO

-- ============================================
-- BEFORE: is it on? + page-density baseline
-- ============================================
SELECT
    database_id,
    name,
    is_automatic_index_compaction_on
FROM sys.databases
WHERE name = N'ZavaLendingDB';   -- expect 0 (off by default)
GO

-- Page density for the B-tree indexes most affected by the OLTP write
-- workload (e.g. LoanApplications / LoanDecisions). Low
-- avg_page_space_used_in_percent = bloated pages that compaction will fix.
SELECT
    OBJECT_NAME(ips.object_id)              AS table_name,
    i.name                                  AS index_name,
    ips.index_type_desc,
    ips.page_count,
    CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,2)) AS avg_page_density_pct,
    CAST(ips.avg_fragmentation_in_percent   AS DECIMAL(5,2)) AS avg_fragmentation_pct
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ips
JOIN sys.indexes AS i
    ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.index_level = 0                  -- leaf level
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
  AND ips.index_type_desc IN ('CLUSTERED INDEX', 'NONCLUSTERED INDEX')
ORDER BY avg_page_density_pct ASC;
GO

-- ============================================
-- THE OPTIMIZATION: enable automatic index compaction
-- ============================================
ALTER DATABASE [ZavaLendingDB] SET AUTOMATIC_INDEX_COMPACTION = ON;
GO

-- ============================================
-- AFTER: confirm enabled
-- ============================================
SELECT
    name,
    is_automatic_index_compaction_on
FROM sys.databases
WHERE name = N'ZavaLendingDB';   -- now 1
GO

SELECT DATABASEPROPERTYEX(N'ZavaLendingDB', 'IsAutomaticIndexCompactionOn') AS IsAutoCompactionOn;
GO

/*
    OPTIONAL — ongoing visibility:

    Automatic compaction acts only on pages modified AFTER it's enabled. To
    show an immediate density win for a pre-bloated index, run a one-time
    reorg/rebuild once; from then on compaction maintains density hands-off.

    The auto_index_compaction_stats Extended Event fires every 10 minutes with
    cumulative rows-moved / pages-deallocated / skipped-attempt counters:

        CREATE EVENT SESSION [auto_index_compaction] ON DATABASE
        ADD EVENT sqlserver.auto_index_compaction_stats
        ADD TARGET package0.ring_buffer;
        ALTER EVENT SESSION [auto_index_compaction] ON DATABASE STATE = START;

    Re-run the page-density query above after the workload has modified pages
    to show avg_page_space_used_in_percent trending up with no maintenance jobs.
*/
