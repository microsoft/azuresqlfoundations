-- OLD METHOD
EXEC dbo.usp_HybridLoanSearchLegacy
    @Prompt = N'utterly tapped out and drowning in red ink',
    @LoanType = 'SmallBusiness',
    @MinCreditScore = 700,
    @TopN = 5;
GO

-- NEW: WITH APPROXIMATE
EXEC dbo.usp_HybridLoanSearch
    @Prompt = N'utterly tapped out and drowning in red ink',
    @LoanType = 'SmallBusiness',
    @MinCreditScore = 700,
    @TopN = 5;
GO
