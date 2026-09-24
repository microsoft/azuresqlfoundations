SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(CustomerIdentityName)')
    CREATE USER [$(CustomerIdentityName)] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$(CustomerPrincipalId)';
GO
ALTER ROLE db_datareader ADD MEMBER [$(CustomerIdentityName)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(InternalIdentityName)')
    CREATE USER [$(InternalIdentityName)] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$(InternalPrincipalId)';
GO
ALTER ROLE db_datareader ADD MEMBER [$(InternalIdentityName)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(InternalAiIdentityName)')
    CREATE USER [$(InternalAiIdentityName)] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$(InternalAiPrincipalId)';
GO
ALTER ROLE db_datareader ADD MEMBER [$(InternalAiIdentityName)];
GO
GRANT EXECUTE ON OBJECT::dbo.usp_HybridLoanSearch TO [$(InternalAiIdentityName)];
GRANT EXECUTE ON OBJECT::dbo.usp_ScoreLoanApplication TO [$(InternalAiIdentityName)];
GRANT EXECUTE ON EXTERNAL MODEL::FoundryEmbeddingModel TO [$(InternalAiIdentityName)];
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [$(InternalAiIdentityName)];

DECLARE @EmbeddingCredentialName sysname = (
    SELECT credential.name
    FROM sys.external_models AS model
    JOIN sys.database_scoped_credentials AS credential
        ON credential.credential_id = model.credential_id
    WHERE model.name = N'FoundryEmbeddingModel'
);

IF @EmbeddingCredentialName IS NOT NULL
BEGIN
    DECLARE @GrantCredentialSql nvarchar(max) =
        N'GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::' + QUOTENAME(@EmbeddingCredentialName) +
        N' TO ' + QUOTENAME(N'$(InternalAiIdentityName)') + N';';
    EXEC sys.sp_executesql @GrantCredentialSql;
END;

DECLARE @GatewayCredentialName sysname = (
    SELECT name
    FROM sys.database_scoped_credentials
    WHERE name = N'https://zavafin-ai-gateway.azure-api.net/'
);

IF @GatewayCredentialName IS NOT NULL
BEGIN
    DECLARE @GrantGatewayCredentialSql nvarchar(max) =
        N'GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::' + QUOTENAME(@GatewayCredentialName) +
        N' TO ' + QUOTENAME(N'$(InternalAiIdentityName)') + N';';
    EXEC sys.sp_executesql @GrantGatewayCredentialSql;
END;
GO