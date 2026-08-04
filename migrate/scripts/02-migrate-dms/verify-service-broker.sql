-- =============================================================================
-- verify-service-broker.sql
-- Substantiates the DMS "ServiceBroker" assessment finding for Azure SQL Database.
--
-- SQL Server enables Service Broker by default at CREATE DATABASE
-- (is_broker_enabled = 1), so DMS flags the *option* regardless of whether the
-- feature is actually used. This script distinguishes "enabled" from "used" by
-- counting USER-defined broker objects (system/default objects are excluded).
--
-- Run against the user database, e.g.:
--   sqlcmd -S localhost -E -C -d <YourDatabase> -i verify-service-broker.sql
-- =============================================================================
SET NOCOUNT ON;

DECLARE @is_enabled bit =
    (SELECT is_broker_enabled FROM sys.databases WHERE database_id = DB_ID());

-- Queues are schema objects -> use is_ms_shipped to exclude the 3 system queues.
DECLARE @user_queues int =
    (SELECT COUNT(*) FROM sys.service_queues q
     JOIN sys.objects o ON o.object_id = q.object_id
     WHERE o.is_ms_shipped = 0);

-- Services/contracts/message types: system objects are 'DEFAULT' or the
-- 'http://schemas.microsoft.com/...' namespace; anything else is user-defined.
DECLARE @user_services int =
    (SELECT COUNT(*) FROM sys.services
     WHERE name NOT LIKE 'http://schemas.microsoft.com/%');

DECLARE @user_contracts int =
    (SELECT COUNT(*) FROM sys.service_contracts
     WHERE name <> 'DEFAULT' AND name NOT LIKE 'http://schemas.microsoft.com/%');

DECLARE @user_msgtypes int =
    (SELECT COUNT(*) FROM sys.service_message_types
     WHERE name <> 'DEFAULT' AND name NOT LIKE 'http://schemas.microsoft.com/%');

DECLARE @user_routes int =
    (SELECT COUNT(*) FROM sys.routes WHERE name <> 'AutoCreatedLocal');

DECLARE @remote_bindings int = (SELECT COUNT(*) FROM sys.remote_service_bindings);
DECLARE @conversations   int = (SELECT COUNT(*) FROM sys.conversation_endpoints);
DECLARE @event_notif     int = (SELECT COUNT(*) FROM sys.event_notifications);

DECLARE @user_total int =
    @user_queues + @user_services + @user_contracts + @user_msgtypes
    + @user_routes + @remote_bindings + @conversations + @event_notif;

DECLARE @verdict varchar(200) =
    CASE
        WHEN @user_total = 0 AND @is_enabled = 1
            THEN 'ENABLED BUT UNUSED -- safe to SET DISABLE_BROKER; finding is informational'
        WHEN @user_total = 0 AND @is_enabled = 0
            THEN 'DISABLED AND UNUSED -- no action needed'
        ELSE 'IN USE -- user Service Broker objects exist; review before migrating'
    END;

PRINT 'Service Broker verification for database [' + DB_NAME() + ']';
PRINT '  is_broker_enabled    : ' + CAST(@is_enabled AS varchar(1));
PRINT '  user queues          : ' + CAST(@user_queues AS varchar(11));
PRINT '  user services        : ' + CAST(@user_services AS varchar(11));
PRINT '  user contracts       : ' + CAST(@user_contracts AS varchar(11));
PRINT '  user message types   : ' + CAST(@user_msgtypes AS varchar(11));
PRINT '  user routes          : ' + CAST(@user_routes AS varchar(11));
PRINT '  remote bindings      : ' + CAST(@remote_bindings AS varchar(11));
PRINT '  active conversations : ' + CAST(@conversations AS varchar(11));
PRINT '  event notifications  : ' + CAST(@event_notif AS varchar(11));
PRINT '  user broker objects  : ' + CAST(@user_total AS varchar(11));
PRINT '  VERDICT              : ' + @verdict;
