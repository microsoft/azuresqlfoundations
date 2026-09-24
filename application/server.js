"use strict";

require("dotenv").config();

const path = require("node:path");
const express = require("express");
const helmet = require("helmet");
const sql = require("mssql");
const { DefaultAzureCredential } = require("@azure/identity");

const app = express();
const port = Number(process.env.PORT || 3000);
const appKinds = {
  customer: "loan-platform-customer",
  internal: "loan-platform-internal",
  "internal-ai": "loan-platform-internal-ai"
};
const appKind = process.env.APP_KIND || "customer";

if (!appKinds[appKind]) {
  throw new Error(`APP_KIND must be one of: ${Object.keys(appKinds).join(", ")}`);
}

app.disable("x-powered-by");
app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: "32kb" }));
app.use("/shared", express.static(path.join(__dirname, "shared")));

const credential = new DefaultAzureCredential();
let poolState;

function databaseConfig() {
  const rawServer = process.env.AZURE_SQL_SERVER;
  const database = process.env.AZURE_SQL_DATABASE;
  if (!rawServer || !database) {
    throw new Error("AZURE_SQL_SERVER and AZURE_SQL_DATABASE must be configured");
  }

  return {
    server: rawServer.replace(/\.database\.windows\.net$/i, ""),
    database
  };
}

async function getPool() {
  const now = Date.now();
  if (poolState && poolState.expiresOn > now + 5 * 60 * 1000) {
    return poolState.pool;
  }

  if (poolState) {
    await poolState.pool.close();
    poolState = undefined;
  }

  const { server, database } = databaseConfig();
  const accessToken = await credential.getToken("https://database.windows.net/.default");
  const pool = await new sql.ConnectionPool({
    server: `${server}.database.windows.net`,
    database,
    authentication: {
      type: "azure-active-directory-access-token",
      options: { token: accessToken.token }
    },
    options: {
      encrypt: true,
      trustServerCertificate: false,
      enableArithAbort: true
    },
    pool: { min: 0, max: 10, idleTimeoutMillis: 30000 }
  }).connect();

  poolState = { pool, expiresOn: accessToken.expiresOnTimestamp };
  return pool;
}

function asyncRoute(handler) {
  return (request, response, next) => Promise.resolve(handler(request, response, next)).catch(next);
}

function requireAppKind(...allowedKinds) {
  return (_request, response, next) => {
    if (!allowedKinds.includes(appKind)) {
      return response.status(404).json({ error: "API endpoint not found." });
    }
    next();
  };
}

function optionalString(value, maxLength) {
  if (typeof value !== "string" || !value.trim()) return null;
  return value.trim().slice(0, maxLength);
}

function integer(value, fallback, min, max) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

app.get("/api/health", asyncRoute(async (_request, response) => {
  const pool = await getPool();
  const result = await pool.request().query("SELECT DB_NAME() AS [database], SYSUTCDATETIME() AS databaseTime");
  response.json({ status: "ok", app: appKind, ...result.recordset[0] });
}));

app.get("/api/config", requireAppKind("internal", "internal-ai"), (_request, response) => {
  const { server, database } = databaseConfig();
  response.json({
    server: `${server}.database.windows.net`,
    database,
    authentication: "Microsoft Entra managed identity"
  });
});

app.post("/api/rates", requireAppKind("customer"), asyncRoute(async (request, response) => {
  const amount = Number(request.body.amount);
  const income = Number(request.body.income);
  const creditScore = integer(request.body.creditScore, 650, 300, 850);
  const loanType = optionalString(request.body.loanType, 30);
  const supportedLoanTypes = new Set(["Auto", "Personal", "SmallBusiness", "HomeImprovement"]);
  if (!Number.isFinite(amount) || amount < 2000 || amount > 500000 || !supportedLoanTypes.has(loanType)) {
    return response.status(400).json({ error: "A supported loan type and amount from 2,000 to 500,000 are required." });
  }
  if (!Number.isFinite(income) || income <= 0) {
    return response.status(400).json({ error: "Annual income must be greater than zero." });
  }

  const pool = await getPool();
  const result = await pool.request()
    .input("LoanType", sql.NVarChar(30), loanType)
    .input("CreditScore", sql.Int, creditScore)
    .query(`
      SELECT
        CAST(COALESCE(AVG(CASE WHEN InterestRate > 0 THEN InterestRate END), 9.99) AS decimal(5,2)) AS InterestRate,
        COUNT_BIG(*) AS ComparableLoans
      FROM dbo.LoanHistory
      WHERE LoanType = @LoanType
        AND CreditScore BETWEEN @CreditScore - 50 AND @CreditScore + 50
        AND LoanOutcome IN (N'Approved', N'PaidInFull', N'Active');
    `);

  let interestRate = Number(result.recordset[0].InterestRate);
  if (amount / income > 0.5) interestRate += 0.75;
  const termMonths = 60;
  const monthlyRate = interestRate / 100 / 12;
  const monthlyPayment = monthlyRate === 0
    ? amount / termMonths
    : amount * monthlyRate * Math.pow(1 + monthlyRate, termMonths) /
      (Math.pow(1 + monthlyRate, termMonths) - 1);

  response.json({
    interestRate: Number(interestRate.toFixed(2)),
    monthlyPayment: Math.round(monthlyPayment),
    termMonths,
    comparableLoans: Number(result.recordset[0].ComparableLoans)
  });
}));

app.get("/api/operations/dashboard", requireAppKind("internal", "internal-ai"), asyncRoute(async (_request, response) => {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT COUNT_BIG(*) AS TotalLoans,
           SUM(CASE WHEN LoanOutcome IN (N'Approved', N'Active', N'PaidInFull') THEN 1 ELSE 0 END) AS ApprovedLoans,
           CAST(COALESCE(SUM(ApprovedAmount), 0) AS decimal(18,2)) AS TotalApproved,
           CAST(COALESCE(AVG(DefaultRate), 0) AS decimal(8,4)) AS AverageDefaultRate
    FROM dbo.LoanHistory;

    SELECT TOP (8) lh.LoanId, CONCAT(a.FirstName, N' ', a.LastName) AS Applicant,
           lh.LoanType, lh.ApprovedAmount, lh.CreditScore, lh.DebtToIncomeRatio,
           lh.LoanOutcome, a.Region
    FROM dbo.LoanHistory lh
    LEFT JOIN dbo.Applicants a ON a.ApplicantId = lh.ApplicantId
    ORDER BY COALESCE(lh.DecisionDate, lh.ApplicationDate) DESC;

    SELECT DATEPART(HOUR, CreatedAt) AS HourOfDay, COUNT_BIG(*) AS TransactionCount
    FROM dbo.LoanTransactions
    WHERE CreatedAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
    GROUP BY DATEPART(HOUR, CreatedAt)
    ORDER BY HourOfDay;

    SELECT COALESCE(a.Region, N'Unknown') AS Region, COUNT_BIG(*) AS LoanCount
    FROM dbo.LoanHistory lh
    LEFT JOIN dbo.Applicants a ON a.ApplicantId = lh.ApplicantId
    GROUP BY COALESCE(a.Region, N'Unknown')
    ORDER BY LoanCount DESC;
  `);

  response.json({
    summary: result.recordsets[0][0],
    recentReviews: result.recordsets[1],
    hourlyTransactions: result.recordsets[2],
    loansByRegion: result.recordsets[3]
  });
}));

app.get("/api/operations/account", requireAppKind("internal", "internal-ai"), asyncRoute(async (request, response) => {
  const search = optionalString(request.query.q, 100);
  if (!search) return response.status(400).json({ error: "Enter a loan ID or applicant name." });
  const loanId = Number.parseInt(search.replace(/\D/g, ""), 10) || null;
  const pool = await getPool();
  const result = await pool.request()
    .input("LoanId", sql.BigInt, loanId)
    .input("Name", sql.NVarChar(102), `%${search}%`)
    .query(`
      SELECT TOP (1) lh.*, CONCAT(a.FirstName, N' ', a.LastName) AS Applicant,
             a.Email, a.PhoneNumber, a.AnnualIncome, a.EmploymentStatus, a.Region
      FROM dbo.LoanHistory lh
      LEFT JOIN dbo.Applicants a ON a.ApplicantId = lh.ApplicantId
      WHERE (@LoanId IS NOT NULL AND lh.LoanId = @LoanId)
         OR CONCAT(a.FirstName, N' ', a.LastName) LIKE @Name
      ORDER BY lh.ApplicationDate DESC;

      SELECT TOP (25) TransactionDate, TransactionType, Amount,
             PrincipalComponent, InterestComponent, RunningBalance, DaysPastDue
      FROM dbo.LoanTransactions
      WHERE LoanId = COALESCE(@LoanId, (
        SELECT TOP (1) lh2.LoanId FROM dbo.LoanHistory lh2
        JOIN dbo.Applicants a2 ON a2.ApplicantId = lh2.ApplicantId
        WHERE CONCAT(a2.FirstName, N' ', a2.LastName) LIKE @Name
        ORDER BY lh2.ApplicationDate DESC))
      ORDER BY TransactionDate DESC;
    `);
  if (!result.recordsets[0].length) return response.status(404).json({ error: "No matching account was found." });
  response.json({ account: result.recordsets[0][0], transactions: result.recordsets[1] });
}));

app.get("/api/operations/risk", requireAppKind("internal", "internal-ai"), asyncRoute(async (_request, response) => {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT TOP (20) lh.LoanId, CONCAT(a.FirstName, N' ', a.LastName) AS Applicant,
           lh.LoanType, COALESCE(lh.ApprovedAmount, lh.RequestedAmount) AS Balance,
           COALESCE(tx.MaxDaysPastDue, 0) AS DaysPastDue, lh.DebtToIncomeRatio,
           a.Region, lh.DefaultRate,
           CASE WHEN COALESCE(lh.DefaultRate, 0) >= .15 THEN N'Critical'
                WHEN COALESCE(lh.DefaultRate, 0) >= .08 THEN N'High'
                WHEN COALESCE(lh.DefaultRate, 0) >= .04 THEN N'Medium' ELSE N'Low' END AS RiskCategory
    FROM dbo.LoanHistory lh
    LEFT JOIN dbo.Applicants a ON a.ApplicantId = lh.ApplicantId
    OUTER APPLY (SELECT MAX(DaysPastDue) AS MaxDaysPastDue FROM dbo.LoanTransactions t WHERE t.LoanId = lh.LoanId) tx
    WHERE COALESCE(lh.DefaultRate, 0) >= .04 OR COALESCE(tx.MaxDaysPastDue, 0) > 0
    ORDER BY COALESCE(lh.DefaultRate, 0) DESC, COALESCE(tx.MaxDaysPastDue, 0) DESC;
  `);
  response.json({ loans: result.recordset });
}));

app.get("/api/operations/branches", requireAppKind("internal", "internal-ai"), asyncRoute(async (_request, response) => {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT a.Region, la.Channel, COUNT_BIG(*) AS Applications,
           SUM(CASE WHEN la.Status = N'Decided' THEN 1 ELSE 0 END) AS Decisions,
           CAST(100.0 * SUM(CASE WHEN la.Status = N'Decided' THEN 1 ELSE 0 END) / NULLIF(COUNT_BIG(*), 0) AS decimal(5,1)) AS DecisionRate,
           CAST(SUM(COALESCE(ld.ApprovedAmount, 0)) AS decimal(18,2)) AS FundedAmount,
           CAST(AVG(NULLIF(ld.ApprovedAmount, 0)) AS decimal(18,2)) AS AverageFunded
    FROM dbo.LoanApplications la
    JOIN dbo.Applicants a ON a.ApplicantId = la.ApplicantId
    LEFT JOIN dbo.LoanDecisions ld ON ld.ApplicationId = la.ApplicationId
    GROUP BY a.Region, la.Channel
    ORDER BY a.Region, Applications DESC;
  `);
  response.json({ branches: result.recordset });
}));

app.get("/api/operations/payments", requireAppKind("internal", "internal-ai"), asyncRoute(async (_request, response) => {
  const pool = await getPool();
  const result = await pool.request().query(`
    SELECT TOP (30) t.TransactionId, t.LoanId,
           CONCAT(a.FirstName, N' ', a.LastName) AS Applicant,
           t.Amount, t.PrincipalComponent, t.InterestComponent,
           t.ProcessedBy, t.TransactionType, t.DaysPastDue, t.TransactionDate
    FROM dbo.LoanTransactions t
    LEFT JOIN dbo.LoanHistory lh ON lh.LoanId = t.LoanId
    LEFT JOIN dbo.Applicants a ON a.ApplicantId = lh.ApplicantId
    WHERE t.TransactionType IN (N'Payment', N'Fee', N'Adjustment')
    ORDER BY t.TransactionDate DESC, t.TransactionId DESC;
  `);
  response.json({ payments: result.recordset });
}));

app.post("/api/ai/search", requireAppKind("internal-ai"), asyncRoute(async (request, response) => {
  const prompt = optionalString(request.body.prompt, 1000);
  if (!prompt) return response.status(400).json({ error: "A search prompt is required." });
  const loanType = optionalString(request.body.loanType, 30);
  const topN = integer(request.body.topN, 10, 1, 25);
  const pool = await getPool();
  const startedAt = Date.now();
  const result = await pool.request()
    .input("Prompt", sql.NVarChar(1000), prompt)
    .input("LoanType", sql.NVarChar(30), loanType)
    .input("TopN", sql.Int, topN)
    .execute("dbo.usp_HybridLoanSearch");
  response.json({ results: result.recordset, processingTimeMs: Date.now() - startedAt });
}));

app.post("/api/ai/score", requireAppKind("internal-ai"), asyncRoute(async (request, response) => {
  const applicationId = integer(request.body.applicationId, 0, 1, Number.MAX_SAFE_INTEGER);
  if (!applicationId) return response.status(400).json({ error: "A valid application ID is required." });
  const pool = await getPool();
  const result = await pool.request()
    .input("ApplicationId", sql.BigInt, applicationId)
    .execute("dbo.usp_ScoreLoanApplication");
  const firstRow = result.recordset[0] || null;
  const payload = firstRow && Object.keys(firstRow).length === 1 ? Object.values(firstRow)[0] : firstRow;
  response.json(typeof payload === "string" ? JSON.parse(payload) : payload);
}));

app.use("/api", (_request, response) => response.status(404).json({ error: "API endpoint not found." }));

const staticRoot = path.join(__dirname, appKinds[appKind]);
app.use(express.static(staticRoot));
app.get("/{*path}", (_request, response) => response.sendFile(path.join(staticRoot, "index.html")));

app.use((error, _request, response, _next) => {
  console.error(error);
  const status = error.statusCode && error.statusCode < 500 ? error.statusCode : 500;
  response.status(status).json({ error: status === 500 ? "The request could not be completed." : error.message });
});

const server = app.listen(port, () => {
  console.log(`Zava Lending ${appKind} app listening on port ${port}`);
});

async function shutdown() {
  server.close();
  if (poolState) await poolState.pool.close();
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);