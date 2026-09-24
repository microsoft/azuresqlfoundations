/*
    Act 3, Step 9 — AI Loan Scoring: Vector Search + Phi-4 Risk Assessment
    Act 3: "The Engine Knows: Vector Search + AI Scoring"
    
    The capstone demo. We bring everything together:
      1. Vector search finds semantically similar historical loans
         (using the narrative embeddings + DiskANN index we built earlier)
      2. sp_invoke_external_rest_endpoint calls Phi-4 to generate
         a human-readable risk narrative and scoring decision
      3. The auditable decision is stored in LoanDecisions
    
    This shows the full AI-in-the-engine story:
      - The embedding model understands MEANING (not just keywords)
      - The LLM provides REASONING (not just a number)
      - The database provides AUDITABILITY (tamper-proof hash, explainable)
    
    Uses the same credential as the embedding model — both models are
    deployed in the same Azure AI Services account (<your-ai-account>).
    
    Target: <your-server>.database.windows.net / zavalending
    Auth:   Microsoft Entra ID (sqlcmd -G)
    
    Run with sqlcmd (Azure AD auth):
      sqlcmd -S <your-server>.database.windows.net -d zavalending -G -i <this-file>
*/

-- ============================================
-- STEP 9a: Create append-only ledger table for AI audit
-- ============================================
PRINT '=== Creating AIOperationsLedger (append-only ledger table) ==='
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AIOperationsLedger')
BEGIN
    CREATE TABLE dbo.AIOperationsLedger (
        OperationId         BIGINT IDENTITY(1,1) NOT NULL,
        OperationTimestamp  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        ApplicationId       BIGINT NOT NULL,
        ApplicantId         INT NOT NULL,
        OperationType       NVARCHAR(50) NOT NULL,
        ModelVersion        NVARCHAR(30) NOT NULL,
        GatewayUrl          NVARCHAR(500) NOT NULL,
        RequestPayload      NVARCHAR(MAX) NOT NULL,
        ResponseReturnCode  INT NOT NULL,
        ResponsePayload     NVARCHAR(MAX) NULL,
        RiskScore           DECIMAL(5,2) NULL,
        RiskCategory        NVARCHAR(20) NULL,
        Decision            NVARCHAR(30) NULL,
        ProcessingTimeMs    INT NOT NULL,
        PRIMARY KEY (OperationId)
    )
    WITH (LEDGER = ON (APPEND_ONLY = ON));
    PRINT '  AIOperationsLedger created (append-only ledger).'
END
ELSE
    PRINT '  AIOperationsLedger already exists — skipping.'
GO

-- ============================================
-- STEP 9b: Create the scoring procedure
-- ============================================
PRINT '=== Creating usp_ScoreLoanApplication (Phi-4) ==='
GO

CREATE OR ALTER PROCEDURE dbo.usp_ScoreLoanApplication
    @ApplicationId      BIGINT,
    @ModelVersion       NVARCHAR(30) = 'Phi-4',
    @UseGateway         BIT = 0   -- 0 = direct to Azure AI Services (default, no APIM required);
                                  -- 1 = route through the optional APIM AI gateway (see build/APIM/)
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @startTime DATETIME2 = SYSUTCDATETIME();
    DECLARE @loanType NVARCHAR(30);
    DECLARE @requestedAmount DECIMAL(18,2);
    DECLARE @applicantIncome DECIMAL(18,2);
    DECLARE @creditScore INT;
    DECLARE @debtToIncomeRatio DECIMAL(5,2);
    DECLARE @loanPurpose NVARCHAR(200);
    DECLARE @applicantName NVARCHAR(200);
    DECLARE @applicantId INT;
    
    -- =========================================
    -- 1. Get the application details
    -- =========================================
    
    SELECT 
        @loanType = la.LoanType,
        @requestedAmount = la.RequestedAmount,
        @loanPurpose = la.LoanPurpose,
        @applicantIncome = a.AnnualIncome,
        @creditScore = a.CreditScore,
        @debtToIncomeRatio = a.DebtToIncomeRatio,
        @applicantName = a.FirstName + ' ' + a.LastName,
        @applicantId = la.ApplicantId
    FROM dbo.LoanApplications la
    JOIN dbo.Applicants a ON la.ApplicantId = a.ApplicantId
    WHERE la.ApplicationId = @ApplicationId;
    
    IF @applicantName IS NULL
    BEGIN
        RAISERROR('Application %I64d not found.', 16, 1, @ApplicationId);
        RETURN;
    END
    
    -- Mark application as being scored
    UPDATE dbo.LoanApplications 
    SET Status = 'Scoring' 
    WHERE ApplicationId = @ApplicationId;
    
    -- =========================================
    -- 2. Find similar loans via narrative embeddings
    --    Uses the LoanNarrativeEmbeddings + DiskANN index
    --    we built in scripts 02-06
    -- =========================================
    
    -- Build a search prompt from the application details
    DECLARE @searchPrompt NVARCHAR(1000) = 
        @loanType + N' loan for $' + FORMAT(@requestedAmount, 'N0') + 
        N', income $' + FORMAT(@applicantIncome, 'N0') + 
        N', credit score ' + CAST(@creditScore AS NVARCHAR(10)) + 
        N', DTI ' + CAST(@debtToIncomeRatio AS NVARCHAR(10)) + 
        N', purpose: ' + ISNULL(@loanPurpose, 'general');
    
    -- Generate embedding for the search prompt
    DECLARE @promptEmbedding VECTOR(3072, float16);
    SET @promptEmbedding = AI_GENERATE_EMBEDDINGS(
        @searchPrompt USE MODEL FoundryEmbeddingModel
    );
    
    -- Find the 10 most similar historical loans using VECTOR_SEARCH (V3 updateable index)
    DECLARE @similarLoans TABLE (
        LoanId              BIGINT,
        LoanType            NVARCHAR(30),
        LoanOutcome         NVARCHAR(20),
        RequestedAmount     DECIMAL(18,2),
        ApplicantIncome     DECIMAL(18,2),
        CreditScore         INT,
        DebtToIncomeRatio   DECIMAL(5,2),
        DefaultRate         DECIMAL(5,4),
        LoanPurpose         NVARCHAR(200),
        NarrativePreview    NVARCHAR(200),
        SemanticDistance    FLOAT
    );
    
    INSERT INTO @similarLoans
    SELECT TOP (10) WITH APPROXIMATE
        lh.LoanId,
        lh.LoanType,
        lh.LoanOutcome,
        lh.RequestedAmount,
        lh.ApplicantIncome,
        lh.CreditScore,
        lh.DebtToIncomeRatio,
        lh.DefaultRate,
        lh.LoanPurpose,
        LEFT(lh.LoanNarrative, 200),
        vs.distance
    FROM VECTOR_SEARCH(
        TABLE = dbo.LoanNarrativeEmbeddings AS e,
        COLUMN = NarrativeEmbedding,
        SIMILAR_TO = @promptEmbedding,
        METRIC = 'cosine'
    ) AS vs
    JOIN dbo.LoanHistory lh ON e.LoanId = lh.LoanId
    ORDER BY vs.distance;
    
    -- =========================================
    -- 3. Compute aggregated risk metrics
    -- =========================================
    
    DECLARE @approvalRate DECIMAL(5,2);
    DECLARE @avgDefaultRate DECIMAL(5,4);
    DECLARE @similarCount INT;
    DECLARE @similarLoanIdJson NVARCHAR(MAX);
    
    SELECT 
        @similarCount = COUNT(*),
        @approvalRate = CAST(SUM(CASE WHEN LoanOutcome IN ('Approved', 'PaidInFull') THEN 1.0 ELSE 0.0 END) 
                        / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,2)),
        @avgDefaultRate = AVG(DefaultRate)
    FROM @similarLoans;
    
    SELECT @similarLoanIdJson = '[' + STRING_AGG(CAST(LoanId AS NVARCHAR(20)), ',') + ']'
    FROM @similarLoans;
    
    -- =========================================
    -- 4. Build context for Phi-4
    -- =========================================
    
    -- Keep individual historical applications out of the LLM prompt. The vector search
    -- still selects the comparison cohort; only aggregate outcomes are sent to the model.
    DECLARE @similarLoansSummary NVARCHAR(MAX) =
        N'Aggregate outcomes for ' + CAST(@similarCount AS NVARCHAR(10)) +
        N' semantically similar loans: approval rate ' + CAST(@approvalRate AS NVARCHAR(10)) +
        N'%, average default rate ' + CAST(ISNULL(@avgDefaultRate, 0) AS NVARCHAR(10)) + N'.';
    
    DECLARE @prompt NVARCHAR(MAX) = N'You are a loan underwriting AI assistant for ZavaFin. 
Analyze this loan application against similar historical loans and provide a risk assessment.

APPLICATION:
- Loan Type: ' + @loanType + N'
- Requested Amount: $' + FORMAT(@requestedAmount, 'N0') + N'
- Applicant Income: $' + FORMAT(@applicantIncome, 'N0') + N'
- Credit Score: ' + CAST(@creditScore AS NVARCHAR(10)) + N'
- Debt-to-Income Ratio: ' + CAST(@debtToIncomeRatio AS NVARCHAR(10)) + N'
- Purpose: ' + ISNULL(@loanPurpose, 'Not specified') + N'

SIMILAR HISTORICAL LOANS (' + CAST(@similarCount AS NVARCHAR(10)) + N' matches, found via vector similarity on loan narratives):
' + @similarLoansSummary + N'

AGGREGATE METRICS:
- Approval rate among similar loans: ' + CAST(@approvalRate AS NVARCHAR(10)) + N'%
- Average default rate: ' + CAST(ISNULL(@avgDefaultRate, 0) AS NVARCHAR(10)) + N'

Provide a concise risk narrative (3-4 sentences) that:
1. References the applicant''s stated loan purpose and business type
2. References the similar loan patterns found
3. Identifies the key risk factors
4. States a clear recommendation (Approve, Conditionally Approve, Deny, or Manual Review)
5. Is written for a human underwriter to review

Respond with ONLY a JSON object: {"risk_score": <0-100>, "risk_category": "<Low|Medium|High|Critical>", "decision": "<Approved|ConditionallyApproved|Denied|ManualReview>", "narrative": "<your narrative>"}';
    
    -- =========================================
    -- 5. Call Phi-4 via sp_invoke_external_rest_endpoint
    --    Uses the same Azure AI Services credential as embeddings
    -- =========================================
    
    DECLARE @payload NVARCHAR(MAX) = N'{
        "messages": [
            {"role": "system", "content": "You are a precise loan risk assessment engine. Always respond with valid JSON only."},
            {"role": "user", "content": ' + STRING_ESCAPE(@prompt, 'json') + N'}
        ],
        "max_tokens": 500,
        "temperature": 0.3
    }';

    -- Fix: properly quote the escaped prompt in JSON
    SET @payload = REPLACE(@payload, STRING_ESCAPE(@prompt, 'json'), '"' + STRING_ESCAPE(@prompt, 'json') + '"');
    
    DECLARE @response NVARCHAR(MAX);
    DECLARE @retval INT;

    -- Call Phi-4. Default is DIRECT to Azure AI Services (reuses the credential created in
    -- 01-embeddings-setup.sql — Phi-4 and the embedding model share the same account, so the
    -- account-scoped credential is a valid URL prefix for both).
    -- Set @UseGateway = 1 to route through the optional APIM gateway (build/APIM/).
    -- @credential must be a literal, so each path has its own EXEC.
    DECLARE @endpointUrl NVARCHAR(500) =
        CASE WHEN @UseGateway = 1
             THEN N'https://zavafin-ai-gateway.azure-api.net/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview'
             ELSE N'https://<your-ai-account>.cognitiveservices.azure.com/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview'
        END;

    IF @UseGateway = 1
        EXEC @retval = sp_invoke_external_rest_endpoint
            @url = @endpointUrl,
            @method = 'POST',
            @credential = [https://zavafin-ai-gateway.azure-api.net/],
            @payload = @payload,
            @timeout = 120,
            @response = @response OUTPUT;
    ELSE
        EXEC @retval = sp_invoke_external_rest_endpoint
            @url = @endpointUrl,
            @method = 'POST',
            @credential = [https://<your-ai-account>.cognitiveservices.azure.com/],
            @payload = @payload,
            @timeout = 120,
            @response = @response OUTPUT;
    
    -- =========================================
    -- 6. Parse the AI response
    -- =========================================
    
    DECLARE @riskScore DECIMAL(5,2);
    DECLARE @riskCategory NVARCHAR(20);
    DECLARE @decision NVARCHAR(30);
    DECLARE @narrative NVARCHAR(MAX);
    
    IF @retval = 0
    BEGIN
        DECLARE @content NVARCHAR(MAX);
        SELECT @content = JSON_VALUE(@response, '$.result.choices[0].message.content');
        
        -- Strip markdown code fences if present (some models wrap JSON in ```json...```)
        IF @content LIKE '%```json%'
        BEGIN
            SET @content = SUBSTRING(@content, CHARINDEX('```json', @content) + 7, LEN(@content));
            SET @content = SUBSTRING(@content, 1, CHARINDEX('```', @content) - 1);
        END
        SET @content = LTRIM(RTRIM(@content));
        
        -- Parse the structured response
        SET @riskScore    = TRY_CAST(JSON_VALUE(@content, '$.risk_score') AS DECIMAL(5,2));
        SET @riskCategory = JSON_VALUE(@content, '$.risk_category');
        SET @decision     = JSON_VALUE(@content, '$.decision');
        SET @narrative    = JSON_VALUE(@content, '$.narrative');
        
        -- Normalize decision variants (LLMs may return "Approve" instead of "Approved", etc.)
        SET @decision = CASE
            WHEN @decision LIKE 'Approve%' THEN 'Approved'
            WHEN @decision LIKE 'Conditional%' THEN 'ConditionallyApproved'
            WHEN @decision LIKE 'Deni%' OR @decision LIKE 'Deny%' OR @decision LIKE 'Reject%' THEN 'Denied'
            WHEN @decision LIKE 'Manual%' OR @decision LIKE 'Review%' THEN 'ManualReview'
            ELSE ISNULL(@decision, 'ManualReview')
        END;
        
        -- Fallback if JSON parsing fails
        IF @riskScore IS NULL
        BEGIN
            SET @riskScore = 50.0;
            SET @riskCategory = 'Medium';
            SET @decision = 'ManualReview';
            SET @narrative = 'AI returned response but JSON parsing failed. Raw: ' + LEFT(ISNULL(@content, 'NULL'), 200);
        END
    END
    ELSE
    BEGIN
        -- AI endpoint failed — do NOT score, flag for review
        -- This catches gateway content safety blocks (400/403) and outages
        SET @riskScore = 100.0;
        SET @riskCategory = 'Critical';
        SET @decision = 'Denied';
        SET @narrative = 'AI scoring blocked by AI Gateway. '
            + 'Response: ' + LEFT(ISNULL(@response, 'NULL'), 300);
    END
    
    -- =========================================
    -- 6b. Audit the AI operation in the ledger
    --     Append-only — cannot be updated or deleted
    -- =========================================
    
    INSERT INTO dbo.AIOperationsLedger (
        ApplicationId, ApplicantId, OperationType, ModelVersion,
        GatewayUrl, RequestPayload, ResponseReturnCode, ResponsePayload,
        RiskScore, RiskCategory, Decision, ProcessingTimeMs
    )
    VALUES (
        @ApplicationId, @applicantId, 'LoanScoring', @ModelVersion,
        @endpointUrl, @payload, @retval, LEFT(@response, 4000),
        @riskScore, @riskCategory, @decision,
        DATEDIFF(MILLISECOND, @startTime, SYSUTCDATETIME())
    );
    
    -- =========================================
    -- 7. Store the decision (auditable, explainable)
    -- =========================================
    
    DECLARE @approvedAmount DECIMAL(18,2) = CASE 
        WHEN @decision IN ('Approved', 'ConditionallyApproved') THEN @requestedAmount
        ELSE NULL
    END;
    
    DECLARE @approvedRate DECIMAL(5,2) = CASE
        WHEN @decision = 'Approved' THEN 5.49 + (@riskScore / 50.0)
        WHEN @decision = 'ConditionallyApproved' THEN 6.99 + (@riskScore / 40.0)
        ELSE NULL
    END;
    
    -- Compute audit hash for tamper detection
    DECLARE @auditInput NVARCHAR(MAX) = CAST(@ApplicationId AS NVARCHAR) + '|' +
        CAST(@creditScore AS NVARCHAR) + '|' + CAST(@requestedAmount AS NVARCHAR) + '|' +
        CAST(@riskScore AS NVARCHAR) + '|' + @decision;
    
    -- Clean up any previous scoring for this application (re-runnable)
    DELETE FROM dbo.LoanDecisions WHERE ApplicationId = @ApplicationId AND ApplicantId = @applicantId;
    
    INSERT INTO dbo.LoanDecisions (
        ApplicationId, ApplicantId, RiskScore, RiskCategory, Decision,
        ApprovedAmount, ApprovedRate, Narrative,
        SimilarLoanIds, SimilarLoanCount, SimilarApprovalRate, SimilarDefaultRate,
        ModelVersion, ProcessingTimeMs, AuditHash
    )
    VALUES (
        @ApplicationId, @applicantId, @riskScore, @riskCategory, @decision,
        @approvedAmount, @approvedRate, @narrative,
        @similarLoanIdJson, @similarCount, @approvalRate, @avgDefaultRate,
        @ModelVersion, DATEDIFF(MILLISECOND, @startTime, SYSUTCDATETIME()),
        HASHBYTES('SHA2_256', @auditInput)
    );
    
    -- Mark application as decided
    UPDATE dbo.LoanApplications 
    SET Status = 'Decided' 
    WHERE ApplicationId = @ApplicationId;
    
    -- =========================================
    -- 8. Return the result as JSON (app-consumable)
    -- =========================================
    
    SELECT 
        @applicantName                  AS Applicant,
        @loanType                       AS LoanType,
        @requestedAmount                AS RequestedAmount,
        @riskScore                      AS RiskScore,
        @riskCategory                   AS RiskCategory,
        @decision                       AS Decision,
        @approvedAmount                 AS ApprovedAmount,
        @approvedRate                   AS InterestRate,
        @narrative                      AS AIRiskNarrative,
        @similarCount                   AS SimilarLoansAnalyzed,
        @approvalRate                   AS SimilarLoanApprovalRate,
        @avgDefaultRate                 AS SimilarLoanAvgDefaultRate,
        DATEDIFF(MILLISECOND, @startTime, SYSUTCDATETIME()) AS ProcessingTimeMs
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END
GO

PRINT '  Procedure created.'
GO

-- ============================================
-- STEP 9c: Score the pending loan application
-- ============================================
PRINT ''
PRINT '=== Scoring Application #1 with Phi-4 ==='
PRINT '    Vector search finds similar loans from narrative embeddings'
PRINT '    Phi-4 generates a risk assessment and recommendation'
GO

-- Reset application status for re-runability
UPDATE dbo.LoanApplications SET Status = 'Pending' WHERE ApplicationId = 1;
GO

EXEC dbo.usp_ScoreLoanApplication @ApplicationId = 1;
GO

-- ============================================
-- STEP 9d: View the auditable decision
-- ============================================
PRINT ''
PRINT '=== Auditable AI Decision ==='
PRINT '    Every decision is explainable. Every decision has a tamper-proof hash.'
GO

SELECT 
    ld.DecisionId,
    a.FirstName + ' ' + a.LastName AS Applicant,
    la.LoanType,
    FORMAT(la.RequestedAmount, 'C') AS RequestedAmount,
    ld.RiskScore,
    ld.RiskCategory,
    ld.Decision,
    FORMAT(ld.ApprovedAmount, 'C') AS ApprovedAmount,
    ld.ApprovedRate AS InterestRatePct,
    ld.Narrative AS AIRiskNarrative,
    ld.SimilarLoanCount,
    CAST(ld.SimilarApprovalRate AS NVARCHAR) + '%' AS HistoricalApprovalRate,
    ld.SimilarDefaultRate AS HistoricalDefaultRate,
    ld.ModelVersion,
    CAST(ld.ProcessingTimeMs AS NVARCHAR) + 'ms' AS ProcessingTime,
    ld.DecidedBy,
    ld.DecidedAt,
    CONVERT(NVARCHAR(66), ld.AuditHash, 1) AS TamperDetectionHash
FROM dbo.LoanDecisions ld
JOIN dbo.LoanApplications la ON ld.ApplicationId = la.ApplicationId
JOIN dbo.Applicants a ON la.ApplicantId = a.ApplicantId
WHERE ld.ApplicationId = 1
ORDER BY ld.DecidedAt DESC;
GO

-- ============================================
-- STEP 9e: Drill into the similar loans used
-- ============================================
PRINT ''
PRINT '=== Similar Loans Used for This Decision ==='
PRINT '    These are the loans the vector search found by narrative similarity.'
GO

DECLARE @similarIds NVARCHAR(MAX);
SELECT @similarIds = SimilarLoanIds 
FROM dbo.LoanDecisions 
WHERE ApplicationId = 1;

SELECT 
    lh.LoanId,
    lh.LoanType,
    FORMAT(lh.RequestedAmount, 'C') AS Amount,
    lh.CreditScore,
    lh.DebtToIncomeRatio AS DTI,
    lh.LoanPurpose,
    lh.LoanOutcome,
    lh.DefaultRate,
    LEFT(lh.LoanNarrative, 120) + '...' AS NarrativePreview
FROM dbo.LoanHistory lh
WHERE lh.LoanId IN (SELECT CAST(value AS BIGINT) FROM OPENJSON(@similarIds))
ORDER BY lh.LoanId;
GO

-- "Embeddings understood the MEANING of loan narratives.
--  Phi-4 provided REASONING about the risk.
--  The database stored an AUDITABLE, EXPLAINABLE decision.
--  Everything happened inside the engine — no external orchestration needed."

-- ============================================
-- STEP 9f: View the AI operations ledger
-- ============================================
PRINT ''
PRINT '=== AI Operations Ledger (append-only, tamper-evident) ==='
PRINT '    Every AI call is recorded. Rows cannot be updated or deleted.'
GO

SELECT
    OperationId,
    OperationTimestamp,
    ApplicationId,
    OperationType,
    ModelVersion,
    ResponseReturnCode,
    RiskScore,
    RiskCategory,
    Decision,
    CAST(ProcessingTimeMs AS NVARCHAR) + 'ms' AS ProcessingTime,
    ledger_start_transaction_id AS LedgerTxnId,
    ledger_start_sequence_number AS LedgerSeqNo
FROM dbo.AIOperationsLedger
ORDER BY OperationId;
GO

PRINT '=== AI Loan Scoring complete. ==='
GO
