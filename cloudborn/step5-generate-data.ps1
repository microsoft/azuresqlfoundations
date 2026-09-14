<#
.SYNOPSIS
    Generates CSV data files for the Demo 2 scale workload.

.DESCRIPTION
    Creates three CSV files locally for bcp upload to ZavaLendingDB:
      1. loan-history-expanded.csv  — 500K loan records (IDs 101-500100)
      2. loan-transactions.csv      — Millions of columnstore transactions
      3. monthly-snapshots.csv      — Portfolio summary rows

    Uses .NET StreamWriter for performance (PowerShell pipeline is too slow for millions of rows).

    RE-RUNNABLE: Overwrites existing CSV files.

.PARAMETER OutputDir
    Directory for CSV files (created if needed). Default: .\data

.PARAMETER LoanCount
    Number of expanded loan history rows to generate. Default: 500000

.PARAMETER TransactionsPerLoan
    Average transactions per loan (actual varies by loan age/outcome). Default: 100
    Total transactions ≈ LoanCount × TransactionsPerLoan × 0.85 (excludes Denied loans)

.EXAMPLE
    .\step5-generate-data.ps1
    .\step5-generate-data.ps1 -LoanCount 100000 -TransactionsPerLoan 50
    .\step5-generate-data.ps1 -OutputDir C:\temp\scaledata -LoanCount 500000
#>

param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "data"),
    [int]$LoanCount = 500000,
    [int]$TransactionsPerLoan = 100
)

$ErrorActionPreference = "Stop"

# ── Create output directory ──
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Scale Data Generator — Zava Lending"        -ForegroundColor Cyan
Write-Host " Loans:          $($LoanCount.ToString('N0'))"                -ForegroundColor Cyan
Write-Host " Txns/loan:      ~$TransactionsPerLoan (avg)" -ForegroundColor Cyan
Write-Host " Output:         $OutputDir"                  -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Reference data ──
$loanTypes = @('Auto', 'Personal', 'SmallBusiness', 'HomeImprovement')
$loanTypeWeights = @(0.60, 0.20, 0.12, 0.08)  # cumulative: 0.60, 0.80, 0.92, 1.00
$outcomes = @('PaidInFull', 'Active', 'Default', 'Denied')
$outcomeWeights = @(0.45, 0.25, 0.15, 0.15)
$regions = @('US-West', 'US-East', 'US-Central', 'EU-West')
$channels = @('Web', 'Mobile', 'PartnerAPI', 'Branch')
$channelWeights = @(0.40, 0.30, 0.20, 0.10)

$purposes = @{
    'Auto' = @('New vehicle purchase', 'Used vehicle purchase', 'Certified pre-owned', 'Vehicle refinance', 'Lease buyout')
    'Personal' = @('Debt consolidation', 'Home renovation', 'Medical expenses', 'Wedding expenses', 'Education costs', 'Moving expenses')
    'SmallBusiness' = @('Equipment purchase', 'Business expansion', 'Inventory financing', 'Working capital', 'Commercial renovation')
    'HomeImprovement' = @('Kitchen remodel', 'Bathroom renovation', 'Roof replacement', 'Energy efficiency upgrade', 'Basement finishing', 'Deck and outdoor')
}

$random = [System.Random]::new(42)  # Fixed seed for reproducibility

function Get-WeightedChoice([string[]]$items, [double[]]$weights) {
    $r = $random.NextDouble()
    $cumulative = 0.0
    for ($i = 0; $i -lt $weights.Length; $i++) {
        $cumulative += $weights[$i]
        if ($r -le $cumulative) { return $items[$i] }
    }
    return $items[$items.Length - 1]
}

function Get-CreditScoreBand([int]$score) {
    if ($score -ge 750) { return 'Excellent' }
    if ($score -ge 700) { return 'Good' }
    if ($score -ge 650) { return 'Fair' }
    return 'Poor'
}

# ============================================
# FILE 1: Expanded Loan History (500K rows)
# ============================================
$loanFile = Join-Path $OutputDir "loan-history-expanded.csv"
Write-Host "Generating expanded loan history ($($LoanCount.ToString('N0')) rows)..." -ForegroundColor Yellow
$sw = $null
try {
$sw = [System.IO.StreamWriter]::new($loanFile, $false, [System.Text.Encoding]::UTF8)

$startLoanId = 101
$dateStart = [DateTime]::new(2025, 1, 1)
$dateRange = ([DateTime]::new(2026, 2, 28) - $dateStart).Days

$loanMeta = [System.Collections.Generic.List[PSCustomObject]]::new($LoanCount)

for ($i = 0; $i -lt $LoanCount; $i++) {
    $loanId = $startLoanId + $i
    # Distribute loans across 10,000 applicants (~50 loans per applicant)
    $applicantId = ($loanId % 10000) + 1
    $loanType = Get-WeightedChoice $loanTypes $loanTypeWeights
    $outcome = Get-WeightedChoice $outcomes $outcomeWeights
    $region = $regions[$random.Next($regions.Length)]
    $channel = Get-WeightedChoice $channels $channelWeights
    $creditScore = $random.Next(550, 820)
    $creditBand = Get-CreditScoreBand $creditScore

    # Adjust outcome based on credit score (more realistic)
    if ($creditScore -ge 750 -and $outcome -eq 'Default') { $outcome = 'PaidInFull' }
    if ($creditScore -lt 600 -and $outcome -eq 'PaidInFull' -and $random.NextDouble() -gt 0.5) { $outcome = 'Default' }

    $income = [math]::Round(30000 + $random.NextDouble() * 270000, 2)
    $dti = [math]::Round(0.10 + $random.NextDouble() * 0.50, 2)
    $empYears = [math]::Round(0.5 + $random.NextDouble() * 24.5, 1)
    
    $amountBase = switch ($loanType) {
        'Auto' { 15000 + $random.NextDouble() * 55000 }
        'Personal' { 3000 + $random.NextDouble() * 47000 }
        'SmallBusiness' { 25000 + $random.NextDouble() * 475000 }
        'HomeImprovement' { 10000 + $random.NextDouble() * 90000 }
    }
    $requested = [math]::Round($amountBase, 2)
    
    if ($outcome -eq 'Denied') {
        $approved = ""
        $rate = ""
        $defaultRate = ""
    } else {
        $trim = if ($random.NextDouble() -gt 0.7) { $random.NextDouble() * 0.15 } else { 0 }
        $approved = [math]::Round($requested * (1 - $trim), 2)
        $rate = [math]::Round(3.99 + $random.NextDouble() * 9.0, 2)
        $defaultRate = if ($outcome -eq 'Default') { [math]::Round(0.08 + $random.NextDouble() * 0.10, 4) } else { [math]::Round(0.01 + $random.NextDouble() * 0.08, 4) }
    }

    $termMonths = @(12, 24, 36, 48, 60, 72, 84, 120)[$random.Next(8)]
    $appDate = $dateStart.AddDays($random.Next($dateRange))
    $purpose = $purposes[$loanType][$random.Next($purposes[$loanType].Length)]

    # CSV: LoanId,ApplicantId,LoanType,RequestedAmount,ApprovedAmount,InterestRate,TermMonths,ApplicantIncome,CreditScore,DebtToIncomeRatio,EmploymentYears,LoanPurpose,LoanOutcome,DefaultRate,ApplicationDate,DecisionDate,Region,Channel
    $line = "$loanId,$applicantId,$loanType,$requested,$approved,$rate,$termMonths,$income,$creditScore,$dti,$empYears,$purpose,$outcome,$defaultRate,$($appDate.ToString('yyyy-MM-dd')),$($appDate.ToString('yyyy-MM-dd')),$region,$channel"
    $sw.WriteLine($line)

    # Store metadata for transaction generation
    if ($outcome -ne 'Denied') {
        $loanMeta.Add([PSCustomObject]@{
            LoanId = $loanId; LoanType = $loanType; Approved = [double]($approved); Rate = [double]($rate)
            Term = $termMonths; Outcome = $outcome; AppDate = $appDate; Region = $region
            Channel = $channel; CreditBand = $creditBand
        })
    }

    if (($i + 1) % 100000 -eq 0) {
        Write-Host "  Loans: $($($i + 1).ToString('N0')) / $($LoanCount.ToString('N0'))" -ForegroundColor Gray
    }
}

$sw.Close()
Write-Host "  Written: $loanFile ($($LoanCount.ToString('N0')) rows)" -ForegroundColor Green
} finally {
    if ($sw) { $sw.Dispose() }
}
Write-Host ""

# ============================================
# Add the original 100 loans to the meta list
# (for transaction generation — they exist in LoanHistory)
# ============================================
# We'll generate transactions for LoanIds 1-100 too
# using estimated values since we can't read the DB here
for ($lid = 1; $lid -le 100; $lid++) {
    $lt = $loanTypes[$random.Next($loanTypes.Length)]
    $out = @('PaidInFull', 'Active', 'Default')[$random.Next(3)]
    $loanMeta.Add([PSCustomObject]@{
        LoanId = $lid; LoanType = $lt; Approved = 30000 + $random.NextDouble() * 50000
        Rate = 5.0 + $random.NextDouble() * 5.0; Term = @(36,48,60)[$random.Next(3)]
        Outcome = $out; AppDate = [DateTime]::new(2024, 1, 1).AddDays($random.Next(450))
        Region = $regions[$random.Next(4)]; Channel = $channels[$random.Next(4)]
        CreditBand = @('Excellent','Good','Fair','Poor')[$random.Next(4)]
    })
}

# ============================================
# FILE 2: Loan Transactions (millions of rows)
# ============================================
$txnFile = Join-Path $OutputDir "loan-transactions.csv"
Write-Host "Generating loan transactions..." -ForegroundColor Yellow
$sw = $null
try {
$sw = [System.IO.StreamWriter]::new($txnFile, $false, [System.Text.Encoding]::UTF8)

$totalTxns = 0
$targetTxns = [long]$LoanCount * $TransactionsPerLoan * 0.85  # ~85% of loans are non-Denied
$sb = [System.Text.StringBuilder]::new(10000)  # Buffer for batch writes

$loanIndex = 0
foreach ($loan in $loanMeta) {
    $loanIndex++
    $balance = $loan.Approved
    $monthlyRate = $loan.Rate / 100.0 / 12.0
    $monthlyPayment = if ($monthlyRate -gt 0 -and $loan.Term -gt 0) {
        [math]::Round($balance * $monthlyRate / (1 - [math]::Pow(1 + $monthlyRate, -$loan.Term)), 2)
    } else { [math]::Round($balance / [math]::Max($loan.Term, 1), 2) }

    $txnDate = $loan.AppDate
    $dpd = 0

    # Disbursement
    $sb.AppendLine("$($loan.LoanId),$($txnDate.ToString('yyyy-MM-dd')),Disbursement,$($loan.Approved),$balance,,,0,$($loan.LoanType),$($loan.Region),$($loan.Channel),$($loan.CreditBand),System") | Out-Null
    $totalTxns++

    # Monthly transactions
    $maxMonths = [math]::Min($loan.Term, [int](([DateTime]::new(2026, 2, 28) - $txnDate).Days / 30))
    $defaultMonth = if ($loan.Outcome -eq 'Default' -and $maxMonths -ge 4) {
        $random.Next([math]::Max(3, [int]($maxMonths / 2)), $maxMonths)
    } else { -1 }

    for ($m = 1; $m -le $maxMonths; $m++) {
        $txnDate = $loan.AppDate.AddMonths($m)
        if ($txnDate -gt [DateTime]::new(2026, 2, 28)) { break }

        # Interest accrual
        $interest = [math]::Round($balance * $monthlyRate, 2)
        $sb.AppendLine("$($loan.LoanId),$($txnDate.ToString('yyyy-MM-dd')),InterestAccrual,$interest,$balance,,,0,$($loan.LoanType),$($loan.Region),$($loan.Channel),$($loan.CreditBand),System") | Out-Null
        $totalTxns++

        if ($m -eq $defaultMonth) {
            # Default event
            $sb.AppendLine("$($loan.LoanId),$($txnDate.ToString('yyyy-MM-dd')),Default,$balance,0,,,0,$($loan.LoanType),$($loan.Region),$($loan.Channel),$($loan.CreditBand),Collections") | Out-Null
            $totalTxns++
            break
        }

        # Payment (occasional late payments for realism)
        $isLate = $random.NextDouble() -lt 0.08
        $dpd = if ($isLate) { $random.Next(5, 45) } else { 0 }
        $principal = [math]::Round([math]::Min($monthlyPayment - $interest, $balance), 2)
        if ($principal -lt 0) { $principal = 0 }
        $balance = [math]::Round([math]::Max($balance - $principal, 0), 2)
        
        $sb.AppendLine("$($loan.LoanId),$($txnDate.ToString('yyyy-MM-dd')),Payment,$monthlyPayment,$balance,$interest,$principal,$dpd,$($loan.LoanType),$($loan.Region),$($loan.Channel),$($loan.CreditBand),AutoPay") | Out-Null
        $totalTxns++

        # Late fee
        if ($dpd -gt 30) {
            $fee = [math]::Round($monthlyPayment * 0.05, 2)
            $sb.AppendLine("$($loan.LoanId),$($txnDate.ToString('yyyy-MM-dd')),Fee,$fee,$balance,,,0,$($loan.LoanType),$($loan.Region),$($loan.Channel),$($loan.CreditBand),System") | Out-Null
            $totalTxns++
        }

        if ($balance -le 0) { break }
    }

    # Flush buffer every 10K loans
    if ($loanIndex % 10000 -eq 0) {
        $sw.Write($sb.ToString())
        $sb.Clear() | Out-Null
        Write-Host "  Transactions: $($totalTxns.ToString('N0')) ($loanIndex loans processed)" -ForegroundColor Gray
    }
}

# Final flush
if ($sb.Length -gt 0) {
    $sw.Write($sb.ToString())
}
$sw.Close()
Write-Host "  Written: $txnFile ($($totalTxns.ToString('N0')) rows)" -ForegroundColor Green
} finally {
    if ($sw) { $sw.Dispose() }
}
Write-Host ""

# ============================================
# FILE 3: Monthly Portfolio Snapshots
# ============================================
$snapFile = Join-Path $OutputDir "monthly-snapshots.csv"
Write-Host "Generating monthly portfolio snapshots..." -ForegroundColor Yellow
$sw = $null
try {
$sw = [System.IO.StreamWriter]::new($snapFile, $false, [System.Text.Encoding]::UTF8)

$snapCount = 0
$snapStart = [DateTime]::new(2025, 1, 1)
$snapEnd = [DateTime]::new(2026, 2, 1)
$bands = @('Excellent', 'Good', 'Fair', 'Poor')

$snapDate = $snapStart
while ($snapDate -le $snapEnd) {
    foreach ($lt in $loanTypes) {
        foreach ($r in $regions) {
            foreach ($ch in $channels) {
                foreach ($band in $bands) {
                    $active = $random.Next(50, 5000)
                    $outstanding = [math]::Round($active * (10000 + $random.NextDouble() * 40000), 2)
                    $payments = [math]::Round($outstanding * (0.02 + $random.NextDouble() * 0.04), 2)
                    $defaults = [math]::Max(0, $random.Next(-5, [math]::Max(1, [int]($active * 0.03))))
                    $avgDpd = [math]::Round($random.NextDouble() * 15, 2)
                    $defRate = [math]::Round([double]$defaults / [math]::Max($active, 1), 4)
                    $avgRate = [math]::Round(4.5 + $random.NextDouble() * 7.0, 2)
                    $atRisk = [math]::Round($outstanding * (0.01 + $random.NextDouble() * 0.06), 2)
                    $provision = [math]::Round($atRisk * (0.3 + $random.NextDouble() * 0.4), 2)

                    $sw.WriteLine("$($snapDate.ToString('yyyy-MM-dd')),$lt,$r,$ch,$band,$active,$outstanding,$payments,$defaults,$avgDpd,$defRate,$avgRate,$atRisk,$provision")
                    $snapCount++
                }
            }
        }
    }
    $snapDate = $snapDate.AddMonths(1)
}

$sw.Close()
Write-Host "  Written: $snapFile ($($snapCount.ToString('N0')) rows)" -ForegroundColor Green
} finally {
    if ($sw) { $sw.Dispose() }
}

# ── Summary ──
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Data Generation Complete"                    -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Loan History:    $($LoanCount.ToString('N0')) rows" -ForegroundColor White
Write-Host " Transactions:    $($totalTxns.ToString('N0')) rows" -ForegroundColor White
Write-Host " Snapshots:       $($snapCount.ToString('N0')) rows" -ForegroundColor White
Write-Host " Output:          $OutputDir" -ForegroundColor White
Write-Host ""
Write-Host "Next: Run .\step6-load-data.ps1 to bcp upload to Azure SQL" -ForegroundColor Yellow
Write-Host ""
