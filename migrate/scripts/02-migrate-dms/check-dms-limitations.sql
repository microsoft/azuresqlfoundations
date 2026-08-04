-- =============================================================================
-- check-dms-limitations.sql
-- Phase 4 pre-flight: scan the SOURCE database for things the DMS (Azure SQL
-- Database, offline) data-copy pipeline cannot handle. These are NOT caught by
-- the Phase 1 compatibility assessment, because they are limitations of the
-- migration TOOL, not feature incompatibilities with the Azure SQL Database
-- target. Run against the source USER database (sqlcmd: -d <SourceDatabase>).
--
-- Severity:
--   BLOCKER  = DMS will not migrate this correctly; fix before migrating.
--   WARNING  = migrates with caveats; verify on the target after Phase 4.
--
-- Limitations checked (per DMS Azure SQL Database offline docs):
--   * > 100,000 tables per database                         (BLOCKER)
--   * table names with double-byte / non-ASCII characters   (BLOCKER)
--   * database name with reserved words or semicolons       (BLOCKER)
--   * computed columns (values not copied)                  (WARNING)
--   * large LOB/blob columns (may time out)                 (WARNING)
--   * default constraints defining NULL                     (WARNING)
-- =============================================================================
SET NOCOUNT ON;

DECLARE @blockers int = 0, @warnings int = 0;

PRINT '==================================================================';
PRINT ' DMS limitation pre-check for database [' + DB_NAME() + ']';
PRINT '==================================================================';

-- 1) Table count vs the 100,000-table limit ---------------------------------
DECLARE @tableCount int =
    (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0);
PRINT '';
PRINT '[1] User table count: ' + CAST(@tableCount AS varchar(20)) + ' (limit 100000)';
IF @tableCount > 100000
BEGIN
    SET @blockers += 1;
    PRINT '    BLOCKER: exceeds the 100,000-table DMS limit.';
END

-- 2) Double-byte / non-ASCII characters in table names ----------------------
PRINT '';
PRINT '[2] Tables with non-ASCII / double-byte names:';
IF EXISTS (SELECT 1 FROM sys.tables
           WHERE is_ms_shipped = 0
             AND name COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%')
BEGIN
    SET @blockers += 1;
    SELECT CAST(SCHEMA_NAME(schema_id) AS varchar(40)) AS [schema],
           CAST(name AS varchar(60)) AS [table], 'BLOCKER' AS severity
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND name COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'
    ORDER BY [schema], [table];
END
ELSE PRINT '    none.';

-- 3) Database name: reserved words or semicolons ----------------------------
PRINT '';
PRINT '[3] Database name compatibility:';
DECLARE @db sysname = DB_NAME();
IF CHARINDEX(';', @db) > 0
BEGIN
    SET @blockers += 1;
    PRINT '    BLOCKER: database name contains a semicolon.';
END
IF UPPER(@db) IN (
    'ADD','ALL','ALTER','AND','ANY','AS','ASC','AUTHORIZATION','BACKUP','BEGIN',
    'BETWEEN','BREAK','BROWSE','BULK','BY','CASCADE','CASE','CHECK','CHECKPOINT',
    'CLOSE','CLUSTERED','COALESCE','COLLATE','COLUMN','COMMIT','COMPUTE','CONSTRAINT',
    'CONTAINS','CONTINUE','CONVERT','CREATE','CROSS','CURRENT','CURSOR','DATABASE',
    'DEFAULT','DELETE','DENY','DESC','DISTINCT','DROP','ELSE','END','ESCAPE','EXCEPT',
    'EXEC','EXECUTE','EXISTS','EXIT','EXTERNAL','FETCH','FILE','FOR','FOREIGN','FROM',
    'FULL','FUNCTION','GOTO','GRANT','GROUP','HAVING','IDENTITY','IF','IN','INDEX',
    'INNER','INSERT','INTERSECT','INTO','IS','JOIN','KEY','KILL','LEFT','LIKE','MERGE',
    'NATIONAL','NOCHECK','NOT','NULL','OF','OFF','ON','OPEN','OPTION','OR','ORDER',
    'OUTER','OVER','PIVOT','PLAN','PRIMARY','PRINT','PROC','PROCEDURE','PUBLIC','RAISERROR',
    'READ','RECONFIGURE','REFERENCES','REPLICATION','RESTORE','RESTRICT','RETURN','REVERT',
    'REVOKE','RIGHT','ROLLBACK','ROWCOUNT','RULE','SAVE','SCHEMA','SELECT','SESSION_USER',
    'SET','SETUSER','SHUTDOWN','SOME','STATISTICS','SYSTEM_USER','TABLE','THEN','TO','TOP',
    'TRAN','TRANSACTION','TRIGGER','TRUNCATE','UNION','UNIQUE','UNPIVOT','UPDATE','USE',
    'USER','VALUES','VARYING','VIEW','WAITFOR','WHEN','WHERE','WHILE','WITH','WRITETEXT')
BEGIN
    SET @blockers += 1;
    PRINT '    BLOCKER: database name [' + @db + '] is a T-SQL reserved word.';
END
IF @blockers = 0 OR (CHARINDEX(';', @db) = 0)
    PRINT '    name = [' + @db + ']';

-- 4) Computed columns (definitions migrate via schema; values not copied) ----
PRINT '';
PRINT '[4] Computed columns (values are not copied; recomputed by target):';
IF EXISTS (SELECT 1 FROM sys.computed_columns)
BEGIN
    SET @warnings += 1;
    SELECT CAST(SCHEMA_NAME(t.schema_id) AS varchar(40)) AS [schema],
           CAST(t.name AS varchar(60)) AS [table],
           CAST(cc.name AS varchar(60)) AS [column], cc.is_persisted, 'WARNING' AS severity
    FROM sys.computed_columns cc
    JOIN sys.tables t ON cc.object_id = t.object_id
    ORDER BY [schema], [table], [column];
END
ELSE PRINT '    none.';

-- 5) Large LOB / blob columns (may time out during copy) --------------------
PRINT '';
PRINT '[5] Large LOB / blob columns (may time out on very large rows):';
IF EXISTS (
    SELECT 1 FROM sys.columns c
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id AND t.is_ms_shipped = 0
    WHERE ty.name IN ('text','ntext','image','xml')
       OR (ty.name IN ('varchar','nvarchar','varbinary') AND c.max_length = -1))
BEGIN
    SET @warnings += 1;
    SELECT CAST(SCHEMA_NAME(t.schema_id) AS varchar(40)) AS [schema],
           CAST(t.name AS varchar(60)) AS [table],
           CAST(c.name AS varchar(60)) AS [column],
           CAST(ty.name AS varchar(20)) AS data_type, 'WARNING' AS severity
    FROM sys.columns c
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id AND t.is_ms_shipped = 0
    WHERE ty.name IN ('text','ntext','image','xml')
       OR (ty.name IN ('varchar','nvarchar','varbinary') AND c.max_length = -1)
    ORDER BY [schema], [table], [column];
END
ELSE PRINT '    none.';

-- 6) Default constraints defining NULL --------------------------------------
PRINT '';
PRINT '[6] Default constraints defining NULL (migrate as the defined default):';
IF EXISTS (SELECT 1 FROM sys.default_constraints
           WHERE REPLACE(REPLACE(UPPER(definition),'(',''),')','') = 'NULL')
BEGIN
    SET @warnings += 1;
    SELECT CAST(SCHEMA_NAME(t.schema_id) AS varchar(40)) AS [schema],
           CAST(t.name AS varchar(60)) AS [table],
           CAST(c.name AS varchar(60)) AS [column],
           CAST(dc.definition AS varchar(60)) AS definition, 'WARNING' AS severity
    FROM sys.default_constraints dc
    JOIN sys.tables t ON dc.parent_object_id = t.object_id
    JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE REPLACE(REPLACE(UPPER(dc.definition),'(',''),')','') = 'NULL'
    ORDER BY [schema], [table], [column];
END
ELSE PRINT '    none.';

-- Verdict -------------------------------------------------------------------
PRINT '';
PRINT '==================================================================';
IF @blockers > 0
    PRINT ' DMS PRE-CHECK VERDICT: BLOCKERS FOUND (' + CAST(@blockers AS varchar(10)) + ') -- fix before migrating';
ELSE IF @warnings > 0
    PRINT ' DMS PRE-CHECK VERDICT: PASS WITH WARNINGS (' + CAST(@warnings AS varchar(10)) + ') -- review then proceed';
ELSE
    PRINT ' DMS PRE-CHECK VERDICT: PASS -- no DMS limitations found';
PRINT '==================================================================';
