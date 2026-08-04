<#
.SYNOPSIS
  Tee a phase script's console output to a deterministic log file.

.DESCRIPTION
  Dot-source this at the top of a phase script (right after $ErrorActionPreference):

      . (Join-Path $PSScriptRoot '_log.ps1')
      Start-PhaseLog '05-validate'
      trap { Stop-PhaseLog; break }   # finalize the log even on a terminating error

  Output still goes to the console (Start-Transcript leaves stdout intact) AND to a
  timestamped log under $env:DMS_LOG_DIR (default C:\dms\logs):

      C:\dms\logs\05-validate-<yyyyMMdd-HHmmss>.log  # this run (timestamped)
      C:\dms\logs\05-validate-latest.log             # mirror of the most recent run
      C:\dms\logs\last-run.txt                       # full path of the newest log

  Read last-run.txt (or <name>-latest.log) to inspect a run's full output reliably,
  instead of scraping the live terminal. The transcript is flushed continuously, so
  the timestamped file is complete even if the script throws before Stop-PhaseLog.

  SECURITY: no secrets are written. Read-Host -AsSecureString does not echo typed
  passwords, and the phase scripts never print connection strings or password args.

.NOTES
  Start-PhaseLog stops any transcript a previous script left running before starting
  a new one, so back-to-back phase runs don't collide ("transcript already started").
#>

function Start-PhaseLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $logDir = if ($env:DMS_LOG_DIR) { $env:DMS_LOG_DIR } else { 'C:\dms\logs' }
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    # Close any transcript a prior phase script left open in this session.
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $global:PhaseLogName    = $Name
    $global:PhaseLogPath    = Join-Path $logDir ("{0}-{1}.log" -f $Name, $stamp)
    $global:PhaseLogLatest  = Join-Path $logDir ("{0}-latest.log" -f $Name)
    $global:PhaseLogPointer = Join-Path $logDir 'last-run.txt'

    # Record the path up front so it can be found even if the run throws.
    Set-Content -LiteralPath $global:PhaseLogPointer -Value $global:PhaseLogPath -Encoding utf8

    Start-Transcript -Path $global:PhaseLogPath -Force | Out-Null
    Write-Host "==> Logging to $global:PhaseLogPath" -ForegroundColor DarkGray
}

function Stop-PhaseLog {
    [CmdletBinding()]
    param()

    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

    # Mirror the just-finished run to <name>-latest.log for a stable, easy-to-find path.
    if ($global:PhaseLogPath -and (Test-Path -LiteralPath $global:PhaseLogPath)) {
        try { Copy-Item -LiteralPath $global:PhaseLogPath -Destination $global:PhaseLogLatest -Force } catch { }
    }
}
