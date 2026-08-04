-- =============================================================================
-- validate-migration.sql
-- Post-migration validation: object counts + per-table row counts.
--
-- Run this script on BOTH the source database and the migrated target
-- (e.g. in SSMS, connected to each in turn), then compare the two outputs.
-- A successful offline migration should produce identical object counts and
-- identical row counts for every user table.
--
--   Source: sqlcmd -S localhost -E -C -d <SourceDb> -i validate-migration.sql
--   Target: sqlcmd -S <server>.database.windows.net -U <user> -P <pwd> -d <TargetDb> -i validate-migration.sql
-- =============================================================================
SET NOCOUNT ON;

PRINT 'Validation snapshot for [' + DB_NAME() + '] at '
    + CONVERT(varchar(30), SYSUTCDATETIME(), 126) + 'Z';

-- 1) User object counts by type (tables, views, procs, functions, etc.)
-- Exclude the DMS schema-migration bookkeeping table(s) (__migration_status)
-- that the tool creates only on the target, so source/target counts align.
SELECT type_desc, object_count = COUNT(*)
FROM sys.objects
WHERE is_ms_shipped = 0
  AND name NOT LIKE '\_\_migration%' ESCAPE '\'
GROUP BY type_desc
ORDER BY type_desc;

-- 2) Per-table row counts (heap or clustered index => index_id 0 or 1)
SELECT [schema] = s.name,
       [table]  = t.name,
       [rows]   = SUM(p.rows)
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.name NOT LIKE '\_\_migration%' ESCAPE '\'
GROUP BY s.name, t.name
ORDER BY s.name, t.name;

-- 3) Totals — quick single-line comparison between source and target
SELECT total_tables = COUNT(DISTINCT t.object_id),
       total_rows   = ISNULL(SUM(p.rows), 0)
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.name NOT LIKE '\_\_migration%' ESCAPE '\';
