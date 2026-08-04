/* ============================================================================
   reset-target-schema.sql
   Empty a migration TARGET database in place: drop ALL user objects (schema +
   data) without dropping the database itself. Used by 99-teardown.ps1
   -ResetTargetSchema so Phase 4 can be re-run against the same Hyperscale DB
   (keeps the create-time-only zone-redundancy setting intact).

   Drops, in dependency order: foreign keys, views, procedures, functions,
   tables (incl. the __migration_status artifact), sequences, synonyms, and
   user-defined types. Schemas, users, logins, and roles are left untouched.
   Idempotent and safe to re-run.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(MAX);

-- 1) Foreign keys (drop first so table drop order is irrelevant)
SET @sql = N'';
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
             + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(13)
FROM sys.foreign_keys fk
JOIN sys.tables  t ON fk.parent_object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 2) Views (drop before tables to clear schema-bound dependencies)
SET @sql = N'';
SELECT @sql += N'DROP VIEW ' + QUOTENAME(s.name) + N'.' + QUOTENAME(v.name) + N';' + CHAR(13)
FROM sys.views v
JOIN sys.schemas s ON v.schema_id = s.schema_id
WHERE v.is_ms_shipped = 0;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 3) Stored procedures
SET @sql = N'';
SELECT @sql += N'DROP PROCEDURE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) + N';' + CHAR(13)
FROM sys.procedures p
JOIN sys.schemas s ON p.schema_id = s.schema_id
WHERE p.is_ms_shipped = 0;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 4) Functions (scalar, inline TVF, multi-statement TVF, CLR)
SET @sql = N'';
SELECT @sql += N'DROP FUNCTION ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) + N';' + CHAR(13)
FROM sys.objects o
JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE o.type IN ('FN','IF','TF','FS','FT') AND o.is_ms_shipped = 0;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 5) Tables (includes the DMS __migration_status artifact); defaults/checks/PKs
--    drop with the table
SET @sql = N'';
SELECT @sql += N'DROP TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';' + CHAR(13)
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.is_ms_shipped = 0;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 6) Sequences
SET @sql = N'';
SELECT @sql += N'DROP SEQUENCE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(seq.name) + N';' + CHAR(13)
FROM sys.sequences seq
JOIN sys.schemas s ON seq.schema_id = s.schema_id;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 7) Synonyms
SET @sql = N'';
SELECT @sql += N'DROP SYNONYM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(syn.name) + N';' + CHAR(13)
FROM sys.synonyms syn
JOIN sys.schemas s ON syn.schema_id = s.schema_id;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

-- 8) User-defined types (drop last; tables that used them are already gone)
SET @sql = N'';
SELECT @sql += N'DROP TYPE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tp.name) + N';' + CHAR(13)
FROM sys.types tp
JOIN sys.schemas s ON tp.schema_id = s.schema_id
WHERE tp.is_user_defined = 1;
IF @sql <> N'' EXEC sys.sp_executesql @sql;

PRINT 'reset-target-schema: all user objects dropped (schema + data cleared).';
GO
