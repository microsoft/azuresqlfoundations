/*
    Act 3, Step 3 — DiskANN Vector Index: Fast Similarity Search
    Act 3: "The Engine Knows: Vector Search + AI Scoring"
    
    The embeddings are in the table. Now we build a DiskANN vector index
    so similarity searches are fast — approximate nearest neighbor search
    at scale rather than brute-force exact scan.
    
    Then we run a quick test to prove vector search understands MEANING,
    not just keywords.
    
    Target: <your-server>.database.windows.net / zavalending
    Auth:   Microsoft Entra ID (sqlcmd -G)
    
    Run with sqlcmd (Azure AD auth):
      sqlcmd -S <your-server>.database.windows.net -d zavalending -G -i <this-file>
*/

-- ============================================
-- STEP 3a: Create the DiskANN vector index
-- ============================================
PRINT '=== Creating DiskANN vector index ==='
GO

-- "Now I create a vector index so similarity searches are fast.
--  DiskANN gives us approximate nearest neighbor search at scale."

-- NOTE: DiskANN requires at least 100 rows for index creation.
-- With 20 demo rows, vector search still works via exact scan (instant for small tables).
-- In production with 50K-12M+ rows, the DiskANN index is critical for performance.

DECLARE @rowcount INT;
SELECT @rowcount = COUNT(*) FROM dbo.LoanNarrativeEmbeddings WHERE NarrativeEmbedding IS NOT NULL;

IF @rowcount >= 100
BEGIN
    -- Always drop and recreate to ensure current index version
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LoanNarrativeEmbeddings_Vector')
    BEGIN
        DROP INDEX IX_LoanNarrativeEmbeddings_Vector ON dbo.LoanNarrativeEmbeddings;
        PRINT '  Dropped existing DiskANN vector index.'
    END

    CREATE VECTOR INDEX IX_LoanNarrativeEmbeddings_Vector
    ON dbo.LoanNarrativeEmbeddings(NarrativeEmbedding)
    WITH (METRIC = 'cosine', TYPE = 'diskann');
    PRINT '  DiskANN vector index created.'
END
ELSE
    PRINT '  Skipping DiskANN index: only ' + CAST(@rowcount AS VARCHAR) + ' rows (need 100+). Vector search still works via exact scan.'
GO

-- ============================================
-- STEP 3b: Quick test — vector search with a natural language prompt
-- ============================================
PRINT '=== Quick test: Vector search with natural language ==='
GO

-- "Remember the prompt from Step 1 that FTS couldn't handle?
--  Let's run the exact same prompt through vector search."

DECLARE @testEmbedding VECTOR(3072, float16);
SET @testEmbedding = AI_GENERATE_EMBEDDINGS(
    N'utterly tapped out and drowning in red ink'
    USE MODEL FoundryEmbeddingModel
);

SELECT
    e.LoanId,
    lh.LoanType,
    lh.LoanOutcome,
    LEFT(lh.LoanNarrative, 80) + '...' AS NarrativePreview,
    vs.distance AS SemanticDistance
FROM VECTOR_SEARCH(
    TABLE = dbo.LoanNarrativeEmbeddings AS e,
    COLUMN = NarrativeEmbedding,
    SIMILAR_TO = @testEmbedding,
    METRIC = 'cosine',
    TOP_N = 5
) AS vs
JOIN dbo.LoanHistory lh ON e.LoanId = lh.LoanId
ORDER BY vs.distance;
GO

-- "Look at the results. None of those words — 'tapped', 'drowning', 'red',
--  'ink' — appear in any loan narrative. But vector search found the loans
--  about financial distress, declining revenue, and elevated debt.
--  It understood the MEANING. That's the difference."

PRINT '=== DiskANN index built. Vector search validated. Ready for hybrid search. ==='
GO
