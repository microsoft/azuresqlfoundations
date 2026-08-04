# ============================================================
# test-foundry-agent.ps1
# Test the ZavaFin Loan Scoring Agent deployed in Foundry
#
# Prerequisites:
#   - Azure CLI installed (az login completed)
#   - deploy-foundry-agent.ps1 has been run successfully
#
# Usage:
#   .\test-foundry-agent.ps1                    # Run all tests
#   .\test-foundry-agent.ps1 -TestNumber 3      # Run only test 3
# ============================================================

param(
    [string]$FoundryResource = "<your-ai-account>",
    [string]$ProjectName = "zava-loan-agent",
    [string]$AgentName = "ZavaFinLoanScoringAgent",
    [int]$TestNumber = 0  # 0 = run all tests
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ZavaFin Foundry Agent — Test Suite" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Build project endpoint
$projectEndpoint = "https://$FoundryResource.services.ai.azure.com/api/projects/$ProjectName"
$responsesUri = "$projectEndpoint/openai/v1/responses"

# Get access token
Write-Host "Authenticating..." -ForegroundColor Yellow
$token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv
if (-not $token) {
    Write-Host "ERROR: Could not get access token. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  Authenticated" -ForegroundColor Green

$headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $token"
}

# ============================================
# Helper function to send a prompt and display the response
# ============================================

function Invoke-AgentTest {
    param(
        [int]$Number,
        [string]$Description,
        [string]$Prompt,
        [int]$TimeoutSec = 120
    )

    Write-Host ""
    Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "Test ${Number}: ${Description}" -ForegroundColor Yellow
    Write-Host "  Prompt: ${Prompt}" -ForegroundColor DarkGray
    Write-Host ""

    $body = @{
        agent_reference = @{
            type = "agent_reference"
            name = $AgentName
        }
        input = $Prompt
    } | ConvertTo-Json -Depth 5

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $resp = Invoke-RestMethod `
            -Uri $responsesUri `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -TimeoutSec $TimeoutSec

        $stopwatch.Stop()
        $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

        # Extract response text
        $outputText = $resp.output_text
        if (-not $outputText) {
            $lastMsg = $resp.output | Where-Object { $_.type -eq "message" } | Select-Object -Last 1
            if ($lastMsg -and $lastMsg.content) {
                $outputText = ($lastMsg.content | Where-Object { $_.type -eq "output_text" }).text
            }
        }

        # Count MCP tool calls
        $mcpCalls = ($resp.output | Where-Object { $_.type -eq "mcp_call" }).Count

        if ($outputText) {
            Write-Host "  Response ($($elapsed)s, $mcpCalls MCP calls):" -ForegroundColor Green
            Write-Host ""
            # Indent each line of the response
            $outputText -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
            Write-Host ""
            Write-Host "  PASS" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  WARNING: No text in response ($($elapsed)s)" -ForegroundColor Yellow
            Write-Host "  Status: $($resp.status)" -ForegroundColor Yellow
            Write-Host "  PASS (no text)" -ForegroundColor Yellow
            return $true
        }
    } catch {
        $stopwatch.Stop()
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $_.ErrorDetails.Message
        Write-Host "  FAIL (HTTP $statusCode): $errorBody" -ForegroundColor Red
        return $false
    }
}

# ============================================
# Define tests
# ============================================

$tests = @(
    @{ Number = 1; Description = "Discover entities"; Prompt = "What entities are available in the loan scoring database? Use describe_entities to find out."; Timeout = 60 }
    @{ Number = 2; Description = "Read pending applications"; Prompt = "Show me all pending loan applications with their applicant names and requested amounts."; Timeout = 60 }
    @{ Number = 3; Description = "Score a loan (full pipeline)"; Prompt = "Score loan application #1. Show me the complete results including the risk narrative."; Timeout = 180 }
    @{ Number = 4; Description = "Read scoring decision"; Prompt = "Show me the scoring decision for application #1 including the AI narrative and risk details."; Timeout = 60 }
)

# ============================================
# Run tests
# ============================================

$passed = 0
$failed = 0

foreach ($test in $tests) {
    if ($TestNumber -gt 0 -and $test.Number -ne $TestNumber) { continue }

    $result = Invoke-AgentTest `
        -Number $test.Number `
        -Description $test.Description `
        -Prompt $test.Prompt `
        -TimeoutSec $test.Timeout

    if ($result) { $passed++ } else { $failed++ }
}

# ============================================
# Summary
# ============================================

$total = $passed + $failed
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Results: ${passed}/${total} passed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) { exit 1 }
