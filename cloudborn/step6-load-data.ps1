<#
.SYNOPSIS
    Loads generated CSV data into ZavaLendingDB via SqlBulkCopy.

.DESCRIPTION
    Uploads three CSV files produced by step5-generate-data.ps1:
      1. loan-history-expanded.csv → dbo.LoanHistoryExpanded  (DELETE + INSERT)
      2. loan-transactions.csv    → dbo.LoanTransactions      (TRUNCATE + INSERT)
      3. monthly-snapshots.csv    → dbo.MonthlyPortfolioSnapshot (TRUNCATE + INSERT)

    RE-RUNNABLE: Truncates scale tables before loading. Never modifies original LoanHistory.
    Uses Azure access token via Get-AzAccessToken (no browser popup needed).

    Streams CSV files in chunks to avoid loading millions of rows into memory.

.PARAMETER Server
    Azure SQL server (e.g., zavafinsql.database.windows.net). Required.

.PARAMETER Database
    Target database name. Required.

.PARAMETER DataDir
    Directory containing CSV files. Default: .\data

.PARAMETER BatchSize
    SqlBulkCopy batch size. Default: 100000

.EXAMPLE
    .\step6-load-data.ps1 -Server zavafinsql.database.windows.net -Database zavalending
    .\step6-load-data.ps1 -Server zavafinsql.database.windows.net -Database zavalending -DataDir C:\temp\scaledata
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Database,
    [string]$DataDir = (Join-Path $PSScriptRoot "data"),
    [int]$BatchSize = 100000,
    [string]$SqlsimPath = "C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe"
)

$ErrorActionPreference = "Stop"

# ── Load SQL client library ──
$sqlClientNs = $null
try {
    [void][Microsoft.Data.SqlClient.SqlConnection]
    $sqlClientNs = "Microsoft.Data.SqlClient"
} catch {
    try {
        Import-Module SqlServer -ErrorAction Stop
        [void][Microsoft.Data.SqlClient.SqlConnection]
        $sqlClientNs = "Microsoft.Data.SqlClient"
    } catch {
        try {
            [void][System.Data.SqlClient.SqlConnection]
            $sqlClientNs = "System.Data.SqlClient"
        } catch {
            Write-Host "ERROR: No SQL client library found." -ForegroundColor Red
            Write-Host "  Install the SqlServer module: Install-Module SqlServer -Scope CurrentUser" -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "Using SQL client: $sqlClientNs" -ForegroundColor Gray

# ── Validate data files exist ──
$loanFile = Join-Path $DataDir "loan-history-expanded.csv"
$txnFile  = Join-Path $DataDir "loan-transactions.csv"
$snapFile = Join-Path $DataDir "monthly-snapshots.csv"

foreach ($f in @($loanFile, $txnFile, $snapFile)) {
    if (-not (Test-Path $f)) {
        Write-Host "ERROR: Missing data file: $f" -ForegroundColor Red
        Write-Host "Run .\step5-generate-data.ps1 first" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Scale Data Loader — Zava Lending"           -ForegroundColor Cyan
Write-Host " Server:   $Server"                           -ForegroundColor Cyan
Write-Host " Database: $Database"                         -ForegroundColor Cyan
Write-Host " Data:     $DataDir"                          -ForegroundColor Cyan
Write-Host " Method:   SqlBulkCopy (token auth)"          -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Acquire Azure auth token ──
Write-Host "Acquiring Azure access token..." -ForegroundColor Yellow
$token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token | ConvertFrom-SecureString -AsPlainText
if (-not $token) {
    Write-Host "ERROR: Could not acquire Azure access token." -ForegroundColor Red
    Write-Host "Make sure you are logged in: Connect-AzAccount" -ForegroundColor Red
    exit 1
}
Write-Host "  Token acquired" -ForegroundColor Green

# ── Validate sqlsim ──
if (-not (Test-Path $SqlsimPath)) {
    Write-Host "ERROR: sqlsim.exe not found at: $SqlsimPath" -ForegroundColor Red
    exit 1
}

# ── Pre-load cleanup: TRUNCATE scale tables ──
Write-Host ""
Write-Host "Truncating scale tables..." -ForegroundColor Yellow
$cleanupSql = @"
TRUNCATE TABLE dbo.LoanTransactions;
TRUNCATE TABLE dbo.MonthlyPortfolioSnapshot;
DELETE FROM dbo.LoanHistoryExpanded;
PRINT 'Scale tables cleaned';
"@

& $SqlsimPath -S "tcp:$Server,1433" -d $Database -T $token -Q $cleanupSql -q
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Cleanup failed. Make sure 04-scale-schema.sql has been run." -ForegroundColor Red
    exit 1
}
Write-Host "  Tables truncated" -ForegroundColor Green

# ── Helper: Open SQL connection with token ──
function New-SqlConnection {
    $connStr = "Server=tcp:$Server,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;"
    if ($sqlClientNs -eq "Microsoft.Data.SqlClient") {
        $c = New-Object Microsoft.Data.SqlClient.SqlConnection($connStr)
    } else {
        $c = New-Object System.Data.SqlClient.SqlConnection($connStr)
    }
    $c.AccessToken = $token
    $c.Open()
    return $c
}

# ── Helper: Create SqlBulkCopy ──
function New-BulkCopy($conn, [string]$tableName) {
    if ($sqlClientNs -eq "Microsoft.Data.SqlClient") {
        $bc = New-Object Microsoft.Data.SqlClient.SqlBulkCopy($conn)
    } else {
        $bc = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
    }
    $bc.DestinationTableName = $tableName
    $bc.BatchSize = $BatchSize
    $bc.BulkCopyTimeout = 0
    $bc.NotifyAfter = $BatchSize
    Register-ObjectEvent -InputObject $bc -EventName SqlRowsCopied -Action {
        Write-Host "    $($EventArgs.RowsCopied.ToString('N0')) rows sent..." -ForegroundColor Gray
    } | Out-Null
    return $bc
}

# ── Helper: Streaming CSV bulk loader ──
# Reads CSV line-by-line, fills a DataTable in chunks, and calls WriteToServer.
# Returns total rows loaded.
function Import-CsvBulk {
    param(
        [string]$FilePath,
        [System.Data.DataTable]$Schema,
        $BulkCopy,
        [scriptblock]$RowParser   # { param($fields, $row) ... }
    )

    $reader = $null
    $totalRows = 0
    try {
        $reader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        while (($line = $reader.ReadLine()) -ne $null) {
            $fields = $line.Split(',')
            $row = $Schema.NewRow()
            & $RowParser $fields $row
            $Schema.Rows.Add($row)
            $totalRows++

            if ($totalRows % $BatchSize -eq 0) {
                $BulkCopy.WriteToServer($Schema)
                $Schema.Clear()
            }
        }
        # flush remaining
        if ($Schema.Rows.Count -gt 0) {
            $BulkCopy.WriteToServer($Schema)
            $Schema.Clear()
        }
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    return $totalRows
}

# ══════════════════════════════════════════════
# LOAD 1: LoanHistoryExpanded (500K rows)
# CSV cols: LoanId,ApplicantId,LoanType,RequestedAmount,ApprovedAmount,InterestRate,TermMonths,
#           ApplicantIncome,CreditScore,DebtToIncomeRatio,EmploymentYears,LoanPurpose,
#           LoanOutcome,DefaultRate,ApplicationDate,DecisionDate,Region,Channel
# ══════════════════════════════════════════════
Write-Host ""
Write-Host "Loading LoanHistoryExpanded..." -ForegroundColor Yellow
$loanFileSize = [math]::Round((Get-Item $loanFile).Length / 1MB, 1)
Write-Host "  Source: $loanFile ($loanFileSize MB)"

$dtLoans = New-Object System.Data.DataTable
[void]$dtLoans.Columns.Add("LoanId",            [long])
[void]$dtLoans.Columns.Add("ApplicantId",       [int])
[void]$dtLoans.Columns.Add("LoanType",          [string])
[void]$dtLoans.Columns.Add("RequestedAmount",   [decimal])
[void]$dtLoans.Columns.Add("ApprovedAmount",    [decimal])
[void]$dtLoans.Columns.Add("InterestRate",      [decimal])
[void]$dtLoans.Columns.Add("TermMonths",        [int])
[void]$dtLoans.Columns.Add("ApplicantIncome",   [decimal])
[void]$dtLoans.Columns.Add("CreditScore",       [int])
[void]$dtLoans.Columns.Add("DebtToIncomeRatio", [decimal])
[void]$dtLoans.Columns.Add("EmploymentYears",   [decimal])
[void]$dtLoans.Columns.Add("LoanPurpose",       [string])
[void]$dtLoans.Columns.Add("LoanOutcome",       [string])
[void]$dtLoans.Columns.Add("DefaultRate",       [decimal])
[void]$dtLoans.Columns.Add("ApplicationDate",   [datetime])
[void]$dtLoans.Columns.Add("DecisionDate",      [datetime])
[void]$dtLoans.Columns.Add("Region",            [string])
[void]$dtLoans.Columns.Add("Channel",           [string])

$connLoans = New-SqlConnection
$bcLoans = New-BulkCopy $connLoans "dbo.LoanHistoryExpanded"
# Explicit column mappings (CSV order matches table order)
for ($i = 0; $i -lt $dtLoans.Columns.Count; $i++) {
    [void]$bcLoans.ColumnMappings.Add($i, $dtLoans.Columns[$i].ColumnName)
}

$swLoans = [System.Diagnostics.Stopwatch]::StartNew()
$loanRowParser = {
    param($f, $r)
    $r["LoanId"]            = [long]$f[0]
    $r["ApplicantId"]       = [int]$f[1]
    $r["LoanType"]          = $f[2]
    $r["RequestedAmount"]   = [decimal]$f[3]
    $r["ApprovedAmount"]    = [decimal]$f[4]
    $r["InterestRate"]      = [decimal]$f[5]
    $r["TermMonths"]        = [int]$f[6]
    $r["ApplicantIncome"]   = [decimal]$f[7]
    $r["CreditScore"]       = [int]$f[8]
    $r["DebtToIncomeRatio"] = [decimal]$f[9]
    $r["EmploymentYears"]   = [decimal]$f[10]
    $r["LoanPurpose"]       = $f[11]
    $r["LoanOutcome"]       = $f[12]
    $r["DefaultRate"]       = [decimal]$f[13]
    $r["ApplicationDate"]   = [datetime]$f[14]
    $r["DecisionDate"]      = [datetime]$f[15]
    $r["Region"]            = $f[16]
    $r["Channel"]           = $f[17]
}

$loadedLoans = Import-CsvBulk -FilePath $loanFile -Schema $dtLoans -BulkCopy $bcLoans -RowParser $loanRowParser
$swLoans.Stop()
$bcLoans.Close(); $connLoans.Close(); $connLoans.Dispose()
Write-Host "  LoanHistoryExpanded: $($loadedLoans.ToString('N0')) rows in $([math]::Round($swLoans.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

# ══════════════════════════════════════════════
# LOAD 2: LoanTransactions (18M+ rows)
# CSV cols: LoanId,TransactionDate,TransactionType,Amount,RunningBalance,
#           InterestComponent,PrincipalComponent,DaysPastDue,LoanType,
#           Region,Channel,CreditScoreBand,ProcessedBy
# Table has IDENTITY (TransactionId) and DEFAULT (CreatedAt) — skip both.
# ══════════════════════════════════════════════
Write-Host ""
Write-Host "Loading LoanTransactions (this will take a while)..." -ForegroundColor Yellow
$txnSize = [math]::Round((Get-Item $txnFile).Length / 1GB, 2)
Write-Host "  Source: $txnFile ($txnSize GB)"

$dtTxn = New-Object System.Data.DataTable
[void]$dtTxn.Columns.Add("LoanId",             [long])
[void]$dtTxn.Columns.Add("TransactionDate",    [datetime])
[void]$dtTxn.Columns.Add("TransactionType",    [string])
[void]$dtTxn.Columns.Add("Amount",             [decimal])
[void]$dtTxn.Columns.Add("RunningBalance",     [decimal])
$colIC = $dtTxn.Columns.Add("InterestComponent",  [decimal]); $colIC.AllowDBNull = $true
$colPC = $dtTxn.Columns.Add("PrincipalComponent", [decimal]); $colPC.AllowDBNull = $true
[void]$dtTxn.Columns.Add("DaysPastDue",        [int])
[void]$dtTxn.Columns.Add("LoanType",           [string])
[void]$dtTxn.Columns.Add("Region",             [string])
[void]$dtTxn.Columns.Add("Channel",            [string])
[void]$dtTxn.Columns.Add("CreditScoreBand",    [string])
[void]$dtTxn.Columns.Add("ProcessedBy",        [string])

$connTxn = New-SqlConnection
$bcTxn = New-BulkCopy $connTxn "dbo.LoanTransactions"
# Map CSV columns → table columns (skip TransactionId IDENTITY, skip CreatedAt DEFAULT)
$txnColNames = @("LoanId","TransactionDate","TransactionType","Amount","RunningBalance",
                  "InterestComponent","PrincipalComponent","DaysPastDue","LoanType",
                  "Region","Channel","CreditScoreBand","ProcessedBy")
for ($i = 0; $i -lt $txnColNames.Count; $i++) {
    [void]$bcTxn.ColumnMappings.Add($i, $txnColNames[$i])
}

$swTxn = [System.Diagnostics.Stopwatch]::StartNew()
$txnRowParser = {
    param($f, $r)
    $r["LoanId"]            = [long]$f[0]
    $r["TransactionDate"]   = [datetime]$f[1]
    $r["TransactionType"]   = $f[2]
    $r["Amount"]            = [decimal]$f[3]
    $r["RunningBalance"]    = [decimal]$f[4]
    if ($f[5] -ne '') { $r["InterestComponent"]  = [decimal]$f[5] } else { $r["InterestComponent"]  = [System.DBNull]::Value }
    if ($f[6] -ne '') { $r["PrincipalComponent"] = [decimal]$f[6] } else { $r["PrincipalComponent"] = [System.DBNull]::Value }
    $r["DaysPastDue"]       = [int]$f[7]
    $r["LoanType"]          = $f[8]
    $r["Region"]            = $f[9]
    $r["Channel"]           = $f[10]
    $r["CreditScoreBand"]   = $f[11]
    $r["ProcessedBy"]       = $f[12]
}

$loadedTxns = Import-CsvBulk -FilePath $txnFile -Schema $dtTxn -BulkCopy $bcTxn -RowParser $txnRowParser
$swTxn.Stop()
$bcTxn.Close(); $connTxn.Close(); $connTxn.Dispose()
Write-Host "  LoanTransactions: $($loadedTxns.ToString('N0')) rows in $([math]::Round($swTxn.Elapsed.TotalMinutes, 1)) min" -ForegroundColor Green

# ══════════════════════════════════════════════
# LOAD 3: MonthlyPortfolioSnapshot (12.8K rows)
# CSV cols: SnapshotMonth,LoanType,Region,Channel,CreditScoreBand,
#           ActiveLoanCount,TotalOutstanding,TotalPayments,TotalDefaults,
#           AvgDaysPastDue,DefaultRate,WeightedAvgRate,PortfolioAtRisk,ProvisionAmount
# ══════════════════════════════════════════════
Write-Host ""
Write-Host "Loading MonthlyPortfolioSnapshot..." -ForegroundColor Yellow

$dtSnap = New-Object System.Data.DataTable
[void]$dtSnap.Columns.Add("SnapshotMonth",     [datetime])
[void]$dtSnap.Columns.Add("LoanType",          [string])
[void]$dtSnap.Columns.Add("Region",            [string])
[void]$dtSnap.Columns.Add("Channel",           [string])
[void]$dtSnap.Columns.Add("CreditScoreBand",   [string])
[void]$dtSnap.Columns.Add("ActiveLoanCount",   [int])
[void]$dtSnap.Columns.Add("TotalOutstanding",  [decimal])
[void]$dtSnap.Columns.Add("TotalPayments",     [decimal])
[void]$dtSnap.Columns.Add("TotalDefaults",     [int])
[void]$dtSnap.Columns.Add("AvgDaysPastDue",    [decimal])
[void]$dtSnap.Columns.Add("DefaultRate",       [decimal])
[void]$dtSnap.Columns.Add("WeightedAvgRate",   [decimal])
[void]$dtSnap.Columns.Add("PortfolioAtRisk",   [decimal])
[void]$dtSnap.Columns.Add("ProvisionAmount",   [decimal])

$connSnap = New-SqlConnection
$bcSnap = New-BulkCopy $connSnap "dbo.MonthlyPortfolioSnapshot"
for ($i = 0; $i -lt $dtSnap.Columns.Count; $i++) {
    [void]$bcSnap.ColumnMappings.Add($i, $dtSnap.Columns[$i].ColumnName)
}

$swSnap = [System.Diagnostics.Stopwatch]::StartNew()
$snapRowParser = {
    param($f, $r)
    $r["SnapshotMonth"]     = [datetime]$f[0]
    $r["LoanType"]          = $f[1]
    $r["Region"]            = $f[2]
    $r["Channel"]           = $f[3]
    $r["CreditScoreBand"]   = $f[4]
    $r["ActiveLoanCount"]   = [int]$f[5]
    $r["TotalOutstanding"]  = [decimal]$f[6]
    $r["TotalPayments"]     = [decimal]$f[7]
    $r["TotalDefaults"]     = [int]$f[8]
    $r["AvgDaysPastDue"]    = [decimal]$f[9]
    $r["DefaultRate"]       = [decimal]$f[10]
    $r["WeightedAvgRate"]   = [decimal]$f[11]
    $r["PortfolioAtRisk"]   = [decimal]$f[12]
    $r["ProvisionAmount"]   = [decimal]$f[13]
}

$loadedSnaps = Import-CsvBulk -FilePath $snapFile -Schema $dtSnap -BulkCopy $bcSnap -RowParser $snapRowParser
$swSnap.Stop()
$bcSnap.Close(); $connSnap.Close(); $connSnap.Dispose()
Write-Host "  MonthlyPortfolioSnapshot: $($loadedSnaps.ToString('N0')) rows in $([math]::Round($swSnap.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

# ── Post-load: Rebuild CCI with ORDER for segment elimination ──
Write-Host ""
Write-Host "Rebuilding CCI_LoanTransactions with ORDER(TransactionDate) for segment elimination..." -ForegroundColor Yellow
Write-Host "  (This ensures BranchActivity's date filter can skip irrelevant segments)" -ForegroundColor Gray
# Re-acquire token (original may have expired during long bulk load)
$token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token | ConvertFrom-SecureString -AsPlainText
$rebuildSql = @"
ALTER INDEX CCI_LoanTransactions ON dbo.LoanTransactions
    REBUILD WITH (MAXDOP = 1);
PRINT 'CCI rebuilt with ordered segments';
"@
$swRebuild = [System.Diagnostics.Stopwatch]::StartNew()
& $SqlsimPath -S "tcp:$Server,1433" -d $Database -T $token -Q $rebuildSql -q
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: CCI rebuild failed — segment elimination may not work" -ForegroundColor Red
} else {
    $swRebuild.Stop()
    Write-Host "  CCI rebuilt in $([math]::Round($swRebuild.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
}

# ── Post-load validation ──
Write-Host ""
Write-Host "Validating row counts..." -ForegroundColor Yellow
# Re-acquire token (may have expired during rebuild)
$token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token | ConvertFrom-SecureString -AsPlainText
$validateSql = @"
SELECT 
    'LoanHistoryExpanded' AS TableName, COUNT(*) AS Cnt FROM dbo.LoanHistoryExpanded
UNION ALL
SELECT 
    'LoanTransactions', COUNT(*) FROM dbo.LoanTransactions
UNION ALL
SELECT 
    'MonthlyPortfolioSnapshot', COUNT(*) FROM dbo.MonthlyPortfolioSnapshot
UNION ALL
SELECT
    'vw_AllLoans (combined)', COUNT(*) FROM dbo.vw_AllLoans;
"@

& $SqlsimPath -S "tcp:$Server,1433" -d $Database -T $token -Q $validateSql

# ── Create workload stored procedures ──
Write-Host ""
Write-Host "Creating workload stored procedures..." -ForegroundColor Yellow
$workloadProcsFile = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "workload\setup-workload-procs.sql"
if (Test-Path $workloadProcsFile) {
    & $SqlsimPath -S "tcp:$Server,1433" -d $Database -T $token -i $workloadProcsFile -v
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Workload procs created successfully." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Workload procs setup returned exit code $LASTEXITCODE." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARNING: $workloadProcsFile not found. Workload procs not created." -ForegroundColor Yellow
}

# ── Summary ──
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Data Load Complete"                          -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Run scale workload at 32 vCores:  .\step7-run-workload.ps1 -Phase Before" -ForegroundColor White
Write-Host "  2. Scale to 192 vCores via Azure Portal" -ForegroundColor White
Write-Host "  3. Run scale workload at 192 vCores: .\step7-run-workload.ps1 -Phase After" -ForegroundColor White
Write-Host ""
