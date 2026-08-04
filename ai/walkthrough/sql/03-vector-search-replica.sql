-- Connection: zavalending_Analytics (named replica)

EXEC dbo.usp_HybridLoanSearch 
    @Prompt = N'utterly tapped out and drowning in red ink',
    @TopN = 5;
GO
