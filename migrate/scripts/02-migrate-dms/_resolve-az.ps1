<#
.SYNOPSIS
  Ensure the Azure CLI (`az`) is resolvable in the current session.

.DESCRIPTION
  Dot-source this at the top of any script that calls `az`:

      . (Join-Path $PSScriptRoot '_resolve-az.ps1')

  It self-heals the common case where the CLI was just installed/upgraded but the
  running shell (or VS Code's inherited environment) still holds a stale PATH:

    1. If `az` is already on PATH, do nothing.
    2. Otherwise rebuild PATH from the machine + user registry (picks up a fresh install).
    3. Otherwise prepend a known install location (x64 then x86).
    4. If still not found, throw with the install link.

  Modifying $env:Path here affects the current process, so the calling script's
  subsequent `az` calls work without opening a new terminal.
#>

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    # 2) Refresh PATH from the machine + user registry.
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    # 3) Fall back to known install locations (x64 first, then x86).
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs\Azure\CLI2\wbin')
    )
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path (Join-Path $dir 'az.cmd'))) {
            $env:Path = "$dir;$env:Path"
            break
        }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') could not be located. Install it (https://aka.ms/installazurecli), then re-run. If you just installed it, restart this terminal first."
}
