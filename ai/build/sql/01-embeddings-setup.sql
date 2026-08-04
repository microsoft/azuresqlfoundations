/*
    Act 3, Step 2 — Vector Embeddings: From Text to Meaning
    Act 3: "The Engine Knows: Vector Search + AI Scoring"
    
    After showing Full-Text Search can't handle natural language prompts,
    we create vector embeddings from the loan narratives using:
      1. CREATE EXTERNAL MODEL — register a Microsoft Foundry embedding model
      2. AI_GENERATE_EMBEDDINGS — generate vectors from LoanNarrative text
    
    The embeddings go into a separate table (LoanNarrativeEmbeddings) that
    pairs each LoanId with its vector representation.
    The DiskANN vector index is built in Step 3 (separate script).
    
    Target: <your-server>.database.windows.net / zavalending
    Auth:   Microsoft Entra ID (sqlcmd -G)
    
    Run with sqlcmd (Azure AD auth):
      sqlcmd -S <your-server>.database.windows.net -d zavalending -G -i <this-file>
*/

-- ============================================
-- STEP 2a: Create the external model
-- ============================================
PRINT '=== Creating External Model for text-embedding-3-large ==='
GO

-- "Full-Text couldn't understand meaning. But we can teach the engine
--  to understand meaning — by converting text into vectors.
--  First, I register an embedding model from Microsoft Foundry."

-- Master key is required for database-scoped credentials
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<your-master-key-password>';
    PRINT '  Master key created.'
END
ELSE
    PRINT '  Master key already exists.'
GO

-- Credential setup (will switch to managed identity for production)
-- NOTE: Credential name MUST be a valid URL matching the endpoint per docs
-- Clean up old objects from previous runs (old endpoint, old credential names)
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = 'FoundryEmbeddingModel')
    DROP EXTERNAL MODEL [FoundryEmbeddingModel];
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'FoundryEmbeddings')
    DROP DATABASE SCOPED CREDENTIAL [FoundryEmbeddings];
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'https://<your-ai-account>.cognitiveservices.azure.com/')
    DROP DATABASE SCOPED CREDENTIAL [https://<your-ai-account>.cognitiveservices.azure.com/];
GO

-- This credential serves BOTH the embedding model below AND direct Phi-4 loan scoring
-- (04-loan-scoring.sql). Both models are deployed in the same Azure AI Services account,
-- so this one account-scoped credential (matched by URL prefix) covers both calls.
CREATE DATABASE SCOPED CREDENTIAL [https://<your-ai-account>.cognitiveservices.azure.com/]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET = '{"api-key": "<your-azure-ai-api-key>"}';
PRINT '  Credential created.'
GO

CREATE EXTERNAL MODEL [FoundryEmbeddingModel]
WITH (
    LOCATION = 'https://<your-ai-account>.cognitiveservices.azure.com/openai/deployments/text-embedding-3-large/embeddings?api-version=2023-05-15',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL = 'text-embedding-3-large',
    CREDENTIAL = [https://<your-ai-account>.cognitiveservices.azure.com/]
);
PRINT '  External model registered.'
GO

-- ============================================
-- STEP 2b: Create the embeddings table
-- ============================================
PRINT '=== Creating LoanNarrativeEmbeddings table ==='
GO

-- "Now I create a table to store the vector embeddings.
--  Each row links a LoanId to its 3072-dimension vector stored in half-precision (float16).
--  float16 uses 2 bytes per dimension instead of 4, allowing the full native output."

IF OBJECT_ID('dbo.LoanNarrativeEmbeddings', 'U') IS NOT NULL
    DROP TABLE dbo.LoanNarrativeEmbeddings;
GO

CREATE TABLE dbo.LoanNarrativeEmbeddings
(
    LoanId              BIGINT          NOT NULL PRIMARY KEY,
    NarrativeEmbedding  VECTOR(3072, float16) NOT NULL,
    GeneratedAt         DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_LoanNarrativeEmbeddings_LoanHistory 
        FOREIGN KEY (LoanId) REFERENCES dbo.LoanHistory(LoanId)
);
GO

PRINT '  Table created.'
GO

-- ============================================
-- STEP 2c: Generate embeddings from LoanNarrative text
-- ============================================
PRINT '=== Generating embeddings using AI_GENERATE_EMBEDDINGS ==='
GO

-- "Now the magic. I generate embeddings for every loan narrative.
--  AI_GENERATE_EMBEDDINGS takes the text and produces a 3072-dimension
--  vector that captures the MEANING — not just the words."

-- Batch in groups of 5 to stay within API rate limits (capacity=1 deployment)
-- 60-second delay between batches allows the per-minute token quota to reset
-- Rows 1-20 (original loan data)
INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 1 AND 5;
PRINT '  Rows 1-5 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 6 AND 10;
PRINT '  Rows 6-10 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 11 AND 15;
PRINT '  Rows 11-15 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 16 AND 20;
PRINT '  Rows 16-20 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

-- Rows 21-40 (HomeImprovement + additional Auto loans)
INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 21 AND 25;
PRINT '  Rows 21-25 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 26 AND 30;
PRINT '  Rows 26-30 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 31 AND 35;
PRINT '  Rows 31-35 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 36 AND 40;
PRINT '  Rows 36-40 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

-- Rows 41-60 (more Auto + Personal loans)
INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 41 AND 45;
PRINT '  Rows 41-45 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 46 AND 50;
PRINT '  Rows 46-50 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 51 AND 55;
PRINT '  Rows 51-55 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 56 AND 60;
PRINT '  Rows 56-60 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

-- Rows 61-80 (SmallBusiness loans)
INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 61 AND 65;
PRINT '  Rows 61-65 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 66 AND 70;
PRINT '  Rows 66-70 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 71 AND 75;
PRINT '  Rows 71-75 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 76 AND 80;
PRINT '  Rows 76-80 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

-- Rows 81-100 (mixed Auto + Personal)
INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 81 AND 85;
PRINT '  Rows 81-85 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 86 AND 90;
PRINT '  Rows 86-90 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 91 AND 95;
PRINT '  Rows 91-95 done. Waiting 60s for rate limit reset...'
WAITFOR DELAY '00:01:00';
GO

INSERT INTO dbo.LoanNarrativeEmbeddings (LoanId, NarrativeEmbedding)
SELECT lh.LoanId, AI_GENERATE_EMBEDDINGS(lh.LoanNarrative USE MODEL FoundryEmbeddingModel)
FROM dbo.LoanHistory lh
WHERE lh.LoanNarrative IS NOT NULL AND lh.LoanId BETWEEN 96 AND 100;
PRINT '  Rows 96-100 done.'
GO

-- Show what we generated
SELECT 
    e.LoanId,
    lh.LoanType,
    LEFT(lh.LoanNarrative, 60) + '...' AS NarrativePreview,
    DATALENGTH(e.NarrativeEmbedding) AS EmbeddingBytes,
    e.GeneratedAt
FROM dbo.LoanNarrativeEmbeddings e
JOIN dbo.LoanHistory lh ON e.LoanId = lh.LoanId
ORDER BY e.LoanId;
GO

-- "Every narrative is now a 3072-dimension vector stored in float16.
--  Each vector captures the semantic meaning of the text — risk factors,
--  borrower situation, financial stability, everything.
--  Next step: build a DiskANN index for fast similarity search."

PRINT '=== Embeddings generated. Next: build the DiskANN vector index (Step 3). ==='
GO
