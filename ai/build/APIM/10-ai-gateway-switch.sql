/*
    Act 3, Step 10 — AI Gateway: Governed Loan Scoring
    Act 3: "The Engine Knows: Vector Search + AI Scoring"
    
    Switches the Phi-4 scoring endpoint from direct Azure AI Services
    to an Azure API Management AI Gateway. The scoring procedure
    (usp_ScoreLoanApplication) doesn't change — we just swap the
    credential and URL it uses.
    
    What the gateway adds:
      - Token rate limiting (10K TPM — cost control)
      - Token metrics (Azure Monitor — observability)  
      - Managed identity auth (no API key in transit)
      - Content safety + jailbreak detection (future)
    
    The key demo moment: same stored proc call, same results,
    but now every interaction is governed and auditable.
    
    Prerequisites:
      - setup-ai-gateway.ps1 has been run (creates APIM instance)
      - apim-config.json exists with gateway URL and subscription key
    
    Target: <your-server>.database.windows.net / zavalending
    Auth:   Microsoft Entra ID (sqlcmd -G)
    
    Run with sqlcmd (Azure AD auth):
      sqlcmd -S <your-server>.database.windows.net -d zavalending -G -i <this-file>
*/

-- ============================================
-- STEP 10a: Show current direct endpoint (baseline)
-- ============================================
PRINT '=== Step 10a: Current scoring endpoint (direct to Azure AI Services) ==='
GO

SELECT 
    name AS CredentialName,
    CASE 
        WHEN name LIKE '%cognitiveservices%' THEN 'Direct to Azure AI Services'
        WHEN name LIKE '%azure-api.net%' THEN 'Via AI Gateway (APIM)'
        ELSE 'Other'
    END AS EndpointType
FROM sys.database_scoped_credentials
WHERE name LIKE '%<your-ai-account>%' OR name LIKE '%azure-api.net%';
GO

-- Run a baseline scoring call through the DIRECT endpoint
PRINT ''
PRINT 'Baseline scoring (direct to Phi-4)...'
EXEC dbo.usp_ScoreLoanApplication @ApplicationId = 1;
GO

-- ============================================
-- STEP 10b: Create gateway credential and update proc
-- ============================================
PRINT ''
PRINT '=== Step 10b: Switching to AI Gateway endpoint ==='
GO

-- NOTE: Replace <GATEWAY_HOST> and <APIM_SUBSCRIPTION_KEY> with values
--       from apim-config.json (output of setup-ai-gateway.ps1)
--
-- Example:
--   GATEWAY_HOST = zavafin-ai-gateway.azure-api.net
--   APIM_SUBSCRIPTION_KEY = (from apim-key.txt)

-- Create credential for the APIM gateway
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'https://zavafin-ai-gateway.azure-api.net/')
    DROP DATABASE SCOPED CREDENTIAL [https://zavafin-ai-gateway.azure-api.net/];
GO

CREATE DATABASE SCOPED CREDENTIAL [https://zavafin-ai-gateway.azure-api.net/]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET = '{"Ocp-Apim-Subscription-Key": "<your-apim-subscription-key>"}';
GO

PRINT '  Gateway credential created.'
GO

-- Update the scoring procedure to use the gateway endpoint
-- The only changes: @url and @credential in the sp_invoke_external_rest_endpoint call
CREATE OR ALTER PROCEDURE dbo.usp_ScoreLoanApplication
    @ApplicationId      BIGINT,
    @ModelVersion       NVARCHAR(30) = 'Phi-4',
    @UseGateway         BIT = 1  -- NEW: toggle between direct and gateway
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
    -- =========================================
    
    DECLARE @searchPrompt NVARCHAR(1000) = 
        @loanType + N' loan for $' + FORMAT(@requestedAmount, 'N0') + 
        N', income $' + FORMAT(@applicantIncome, 'N0') + 
        N', credit score ' + CAST(@creditScore AS NVARCHAR(10)) + 
        N', DTI ' + CAST(@debtToIncomeRatio AS NVARCHAR(10)) + 
        N', purpose: ' + ISNULL(@loanPurpose, 'general');
    
    DECLARE @promptEmbedding VECTOR(3072, float16);
    SET @promptEmbedding = AI_GENERATE_EMBEDDINGS(
        @searchPrompt USE MODEL FoundryEmbeddingModel
    );
    
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
    SELECT
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
        METRIC = 'cosine',
        TOP_N = 10
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
    
    DECLARE @similarLoansSummary NVARCHAR(MAX) = '';
    
    SELECT @similarLoansSummary = @similarLoansSummary + 
        'Loan ' + CAST(LoanId AS NVARCHAR(20)) + ': ' +
        '$' + FORMAT(RequestedAmount, 'N0') + ', ' +
        'Income $' + FORMAT(ApplicantIncome, 'N0') + ', ' +
        'Credit ' + CAST(CreditScore AS NVARCHAR(10)) + ', ' +
        'DTI ' + CAST(DebtToIncomeRatio AS NVARCHAR(10)) + ', ' +
        'Purpose: ' + ISNULL(LoanPurpose, 'N/A') + ', ' +
        'Outcome: ' + LoanOutcome + 
        CASE WHEN DefaultRate IS NOT NULL THEN ', Default Risk: ' + CAST(DefaultRate AS NVARCHAR(10)) ELSE '' END +
        CHAR(10)
    FROM @similarLoans
    ORDER BY SemanticDistance;
    
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
    -- 5. Call Phi-4 — via Gateway or Direct
    -- =========================================
    
    DECLARE @payload NVARCHAR(MAX) = N'{
        "messages": [
            {"role": "system", "content": "You are a precise loan risk assessment engine. Always respond with valid JSON only."},
            {"role": "user", "content": ' + STRING_ESCAPE(@prompt, 'json') + N'}
        ],
        "max_tokens": 500,
        "temperature": 0.3
    }';

    SET @payload = REPLACE(@payload, STRING_ESCAPE(@prompt, 'json'), '"' + STRING_ESCAPE(@prompt, 'json') + '"');
    
    DECLARE @response NVARCHAR(MAX);
    DECLARE @retval INT;
    DECLARE @endpoint NVARCHAR(500);
    DECLARE @credName NVARCHAR(500);
    
    IF @UseGateway = 1
    BEGIN
        -- Through AI Gateway (APIM) — governed, metered, protected
        SET @endpoint = 'https://zavafin-ai-gateway.azure-api.net/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview';
        SET @credName = 'https://zavafin-ai-gateway.azure-api.net/';
    END
    ELSE
    BEGIN
        -- Direct to Azure AI Services — ungoverned
        SET @endpoint = 'https://<your-ai-account>.cognitiveservices.azure.com/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview';
        SET @credName = 'https://<your-ai-account>.cognitiveservices.azure.com/';
    END
    
    EXEC @retval = sp_invoke_external_rest_endpoint
        @url = @endpoint,
        @method = 'POST',
        @credential = @credName,
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
        
        IF @content LIKE '%```json%'
        BEGIN
            SET @content = SUBSTRING(@content, CHARINDEX('```json', @content) + 7, LEN(@content));
            SET @content = SUBSTRING(@content, 1, CHARINDEX('```', @content) - 1);
        END
        SET @content = LTRIM(RTRIM(@content));
        
        SET @riskScore    = TRY_CAST(JSON_VALUE(@content, '$.risk_score') AS DECIMAL(5,2));
        SET @riskCategory = JSON_VALUE(@content, '$.risk_category');
        SET @decision     = JSON_VALUE(@content, '$.decision');
        SET @narrative    = JSON_VALUE(@content, '$.narrative');
        
        SET @decision = CASE
            WHEN @decision LIKE 'Approve%' THEN 'Approved'
            WHEN @decision LIKE 'Conditional%' THEN 'ConditionallyApproved'
            WHEN @decision LIKE 'Deni%' OR @decision LIKE 'Deny%' OR @decision LIKE 'Reject%' THEN 'Denied'
            WHEN @decision LIKE 'Manual%' OR @decision LIKE 'Review%' THEN 'ManualReview'
            ELSE ISNULL(@decision, 'ManualReview')
        END;
        
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
        SET @riskScore = CASE 
            WHEN @creditScore >= 740 AND @debtToIncomeRatio < 0.30 THEN 25.0
            WHEN @creditScore >= 700 AND @debtToIncomeRatio < 0.36 THEN 45.0
            WHEN @creditScore >= 660 AND @debtToIncomeRatio < 0.43 THEN 65.0
            ELSE 85.0
        END;
        SET @riskCategory = CASE 
            WHEN @riskScore < 30 THEN 'Low'
            WHEN @riskScore < 60 THEN 'Medium'
            WHEN @riskScore < 80 THEN 'High'
            ELSE 'Critical'
        END;
        SET @decision = CASE 
            WHEN @riskScore < 50 THEN 'Approved'
            WHEN @riskScore < 70 THEN 'ConditionallyApproved'
            ELSE 'Denied'
        END;
        SET @narrative = 'Rule-based fallback: endpoint unavailable (UseGateway=' + CAST(@UseGateway AS NVARCHAR) + '). Score based on credit score (' 
            + CAST(@creditScore AS NVARCHAR) + ') and DTI ratio (' 
            + CAST(@debtToIncomeRatio AS NVARCHAR) + '). Response: '
            + LEFT(ISNULL(@response, 'NULL'), 200);
    END
    
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
    
    DECLARE @auditInput NVARCHAR(MAX) = CAST(@ApplicationId AS NVARCHAR) + '|' +
        CAST(@creditScore AS NVARCHAR) + '|' + CAST(@requestedAmount AS NVARCHAR) + '|' +
        CAST(@riskScore AS NVARCHAR) + '|' + @decision;
    
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
        @ModelVersion + CASE WHEN @UseGateway = 1 THEN ' (via AI Gateway)' ELSE ' (direct)' END,
        DATEDIFF(MILLISECOND, @startTime, SYSUTCDATETIME()),
        HASHBYTES('SHA2_256', @auditInput)
    );
    
    UPDATE dbo.LoanApplications 
    SET Status = 'Decided' 
    WHERE ApplicationId = @ApplicationId;
    
    -- =========================================
    -- 8. Return the result
    -- =========================================
    
    SELECT 
        @applicantName                  AS Applicant,
        @loanType                       AS LoanType,
        FORMAT(@requestedAmount, 'C')   AS RequestedAmount,
        @riskScore                      AS RiskScore,
        @riskCategory                   AS RiskCategory,
        @decision                       AS Decision,
        FORMAT(@approvedAmount, 'C')    AS ApprovedAmount,
        @approvedRate                   AS InterestRate,
        @narrative                      AS AINarrative,
        @similarCount                   AS SimilarLoansFound,
        CAST(@approvalRate AS VARCHAR) + '%' AS SimilarApprovalRate,
        DATEDIFF(MILLISECOND, @startTime, SYSUTCDATETIME()) AS ProcessingTimeMs,
        CASE WHEN @UseGateway = 1 THEN 'AI Gateway (governed)' ELSE 'Direct (ungoverned)' END AS Endpoint;
END
GO

PRINT '  Scoring procedure updated with @UseGateway toggle.'
GO

-- ============================================
-- STEP 10c: Score through the gateway
-- ============================================
PRINT ''
PRINT '=== Step 10c: Scoring through AI Gateway ==='
GO

-- Reset the application status so we can score again
UPDATE dbo.LoanApplications SET Status = 'Pending' WHERE ApplicationId = 1;
GO

-- Score through the gateway — same proc, same result, but governed
EXEC dbo.usp_ScoreLoanApplication @ApplicationId = 1, @UseGateway = 1;
GO

-- ============================================
-- STEP 10d: Compare — show both paths
-- ============================================
PRINT ''
PRINT '=== Step 10d: Decision audit trail ==='
GO

SELECT 
    d.ApplicationId,
    d.Decision,
    d.RiskScore,
    d.RiskCategory,
    d.ModelVersion,
    d.ProcessingTimeMs,
    d.CreatedAt
FROM dbo.LoanDecisions d
WHERE d.ApplicationId = 1
ORDER BY d.CreatedAt DESC;
GO

PRINT ''
PRINT '=== AI Gateway setup complete ==='
PRINT 'The scoring procedure now supports @UseGateway = 1 (default) for governed scoring.'
PRINT 'Check Azure Portal > APIM > Analytics for token metrics and request logs.'
GO
