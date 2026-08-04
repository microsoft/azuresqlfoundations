/*
    Act 3, Step 4 — Hybrid Search: Vector + Relational in One Query
    
    Build a stored procedure that takes a natural language prompt and
    performs hybrid search — combining TOP (N) WITH APPROXIMATE for
    semantic similarity with traditional WHERE clauses for relational
    filtering DURING DiskANN graph traversal (pre-filtering).
    
    This is the payoff: a loan officer types a question in plain English,
    and the engine returns semantically similar loans filtered by 
    business criteria (loan type, date range, credit score, etc.).
    
    Target: <your-server>.database.windows.net / zavalending
    Auth:   Microsoft Entra ID (sqlcmd -G)
    
    Run with sqlcmd (Azure AD auth):
      sqlcmd -S <your-server>.database.windows.net -d zavalending -G -i <this-file>
*/

-- ============================================
-- CREATE the hybrid search procedure
-- ============================================
PRINT '=== Creating usp_HybridLoanSearch ==='
GO

CREATE OR ALTER PROCEDURE dbo.usp_HybridLoanSearch
    @Prompt             NVARCHAR(1000),     -- Natural language search prompt
    @LoanType           NVARCHAR(30)  = NULL, -- Optional: Auto, Personal, SmallBusiness
    @MinCreditScore     INT           = NULL, -- Optional: minimum credit score filter
    @MaxCreditScore     INT           = NULL, -- Optional: maximum credit score filter
    @LoanOutcome        NVARCHAR(20)  = NULL, -- Optional: Approved, Denied, Default, PaidInFull, Active
    @MinAmount          DECIMAL(18,2) = NULL, -- Optional: minimum requested amount
    @MaxAmount          DECIMAL(18,2) = NULL, -- Optional: maximum requested amount
    @DateFrom           DATE          = NULL, -- Optional: application date range start
    @DateTo             DATE          = NULL, -- Optional: application date range end
    @TopN               INT           = 10    -- Number of results (default 10)
AS
BEGIN
    SET NOCOUNT ON;

    -- Generate the embedding for the user's prompt
    DECLARE @promptEmbedding VECTOR(3072, float16);
    
    SET @promptEmbedding = AI_GENERATE_EMBEDDINGS(
        @Prompt USE MODEL FoundryEmbeddingModel
    );

    -- Hybrid search (latest/Version 3 DiskANN index):
    -- TOP (N) WITH APPROXIMATE + VECTOR_SEARCH (no TOP_N parameter).
    -- Relational WHERE filters are applied DURING graph traversal (iterative pre-filtering) —
    -- the engine keeps walking the graph until it finds @TopN rows that satisfy
    -- both the semantic similarity and all relational predicates.
    SELECT TOP(@TopN) WITH APPROXIMATE
        lh.LoanId,
        lh.LoanType,
        lh.RequestedAmount,
        lh.ApprovedAmount,
        lh.CreditScore,
        lh.DebtToIncomeRatio,
        lh.LoanOutcome,
        lh.DefaultRate,
        lh.LoanPurpose,
        lh.ApplicationDate,
        LEFT(lh.LoanNarrative, 200) AS NarrativePreview,
        vs.distance AS SemanticDistance,
        CASE 
            WHEN vs.distance < 0.15 THEN 'Very High'
            WHEN vs.distance < 0.30 THEN 'High'
            WHEN vs.distance < 0.45 THEN 'Moderate'
            ELSE 'Low'
        END AS SemanticRelevance
    FROM VECTOR_SEARCH(
        TABLE = dbo.LoanNarrativeEmbeddings AS e,
        COLUMN = NarrativeEmbedding,
        SIMILAR_TO = @promptEmbedding,
        METRIC = 'cosine'
    ) AS vs
    JOIN dbo.LoanHistory lh ON e.LoanId = lh.LoanId
    WHERE 1 = 1
      -- Relational filters (applied DURING DiskANN traversal — iterative pre-filtering)
      AND (@LoanType      IS NULL OR lh.LoanType      = @LoanType)
      AND (@MinCreditScore IS NULL OR lh.CreditScore   >= @MinCreditScore)
      AND (@MaxCreditScore IS NULL OR lh.CreditScore   <= @MaxCreditScore)
      AND (@LoanOutcome    IS NULL OR lh.LoanOutcome   = @LoanOutcome)
      AND (@MinAmount      IS NULL OR lh.RequestedAmount >= @MinAmount)
      AND (@MaxAmount      IS NULL OR lh.RequestedAmount <= @MaxAmount)
      AND (@DateFrom       IS NULL OR lh.ApplicationDate >= @DateFrom)
      AND (@DateTo         IS NULL OR lh.ApplicationDate <= @DateTo)
    ORDER BY vs.distance;
END
GO

PRINT '  Procedure created.'
GO

-- ============================================
-- CREATE the legacy hybrid search procedure (CTE post-filtering)
-- ============================================
PRINT '=== Creating usp_HybridLoanSearchLegacy ==='
GO

-- "This is the OLD approach — how you'd write it if the engine
--  couldn't combine vector search with relational filters.
--  A CTE fetches the @TopN nearest embeddings FIRST (ignoring
--  business filters), then the outer query applies WHERE clauses.
--  If fewer than @TopN pass the filters, you get fewer rows."

CREATE OR ALTER PROCEDURE dbo.usp_HybridLoanSearchLegacy
    @Prompt             NVARCHAR(1000),
    @LoanType           NVARCHAR(30)  = NULL,
    @MinCreditScore     INT           = NULL,
    @MaxCreditScore     INT           = NULL,
    @LoanOutcome        NVARCHAR(20)  = NULL,
    @MinAmount          DECIMAL(18,2) = NULL,
    @MaxAmount          DECIMAL(18,2) = NULL,
    @DateFrom           DATE          = NULL,
    @DateTo             DATE          = NULL,
    @TopN               INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @promptEmbedding VECTOR(3072, float16);
    SET @promptEmbedding = AI_GENERATE_EMBEDDINGS(
        @Prompt USE MODEL FoundryEmbeddingModel
    );

    -- OLD WAY: CTE fetches the @TopN nearest neighbors FIRST,
    -- then relational filters are applied AFTER on the CTE result.
    -- If fewer than @TopN pass the filters, you get fewer rows.
    ;WITH NearestNeighbors AS (
        SELECT
            e.LoanId, vs.distance
        FROM VECTOR_SEARCH(
            TABLE = dbo.LoanNarrativeEmbeddings AS e,
            COLUMN = NarrativeEmbedding,
            SIMILAR_TO = @promptEmbedding,
            METRIC = 'cosine',
            TOP_N = @TopN
        ) AS vs
    )
    SELECT 
        lh.LoanId,
        lh.LoanType,
        lh.RequestedAmount,
        lh.ApprovedAmount,
        lh.CreditScore,
        lh.DebtToIncomeRatio,
        lh.LoanOutcome,
        lh.DefaultRate,
        lh.LoanPurpose,
        lh.ApplicationDate,
        LEFT(lh.LoanNarrative, 200) AS NarrativePreview,
        nn.distance AS SemanticDistance,
        CASE 
            WHEN nn.distance < 0.15 THEN 'Very High'
            WHEN nn.distance < 0.30 THEN 'High'
            WHEN nn.distance < 0.45 THEN 'Moderate'
            ELSE 'Low'
        END AS SemanticRelevance
    FROM NearestNeighbors nn
    JOIN dbo.LoanHistory lh ON nn.LoanId = lh.LoanId
    WHERE 1 = 1
      AND (@LoanType      IS NULL OR lh.LoanType      = @LoanType)
      AND (@MinCreditScore IS NULL OR lh.CreditScore   >= @MinCreditScore)
      AND (@MaxCreditScore IS NULL OR lh.CreditScore   <= @MaxCreditScore)
      AND (@LoanOutcome    IS NULL OR lh.LoanOutcome   = @LoanOutcome)
      AND (@MinAmount      IS NULL OR lh.RequestedAmount >= @MinAmount)
      AND (@MaxAmount      IS NULL OR lh.RequestedAmount <= @MaxAmount)
      AND (@DateFrom       IS NULL OR lh.ApplicationDate >= @DateFrom)
      AND (@DateTo         IS NULL OR lh.ApplicationDate <= @DateTo)
    ORDER BY nn.distance;
END
GO

PRINT '  Legacy procedure created.'
GO

-- ============================================
-- TEST 1: Pure semantic search (no filters)
-- ============================================
PRINT '=== TEST 1: Pure semantic search ==='
GO

-- "Show me loans where the borrower was financially stretched"
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'borrower was financially stretched and had trouble making payments';
GO

-- ============================================
-- TEST 2: Hybrid — semantic + loan type filter
-- ============================================
PRINT '=== TEST 2: Semantic + loan type filter ==='
GO

-- "Find auto loans where the buyer was stretching for something expensive"
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'buyer stretching beyond their means for an expensive vehicle',
    @LoanType = 'Auto';
GO

-- ============================================
-- TEST 3: Hybrid — semantic + outcome filter
-- ============================================
PRINT '=== TEST 3: Semantic + outcome filter ==='
GO

-- "Show me loans that defaulted where the borrower had unstable employment"
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'borrower with unstable employment and job changes who defaulted on the loan',
    @LoanOutcome = 'Default';
GO

-- ============================================
-- TEST 4: Hybrid — semantic + credit score range
-- ============================================
PRINT '=== TEST 4: Semantic + credit score range ==='
GO

-- "Find strong borrowers with excellent financials and low risk"
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'strong borrower with excellent credit history low debt and stable employment',
    @MinCreditScore = 720;
GO

-- ============================================
-- TEST 5: Hybrid — semantic + amount range + date
-- ============================================
PRINT '=== TEST 5: Semantic + amount range + date ==='
GO

-- "Find small business loans over $100K from 2024 where the business was growing"
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'growing business expanding operations with strong revenue trajectory',
    @LoanType = 'SmallBusiness',
    @MinAmount = 100000,
    @DateFrom = '2024-01-01';
GO

-- ============================================
-- TEST 6: The contrast — same prompt, FTS vs Vector
-- ============================================
PRINT '=== TEST 6: Side-by-side — FTS vs Vector for the same prompt ==='
GO

-- Full-Text Search result
PRINT '--- Full-Text Search result: ---'
SELECT LoanId, LoanType, LoanOutcome, 
       LEFT(LoanNarrative, 80) + '...' AS NarrativePreview
FROM dbo.LoanHistory
WHERE FREETEXT(LoanNarrative, 'risky first-time borrower with no collateral and thin credit history');
GO

-- Vector Search result  
PRINT '--- Vector Search result (same prompt): ---'
EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'risky first-time borrower with no collateral and thin credit history',
    @TopN = 5;
GO

-- "Full-Text Search matches random words. Vector Search understands the
--  MEANING — it finds the loans with narratives about first-time borrowers,
--  thin credit files, no collateral, and high risk. 
--  That's the power of native vector search in the database engine."

PRINT '=== Hybrid search procedure ready. ==='
GO
