<#
.SYNOPSIS
    Guest-side VM setup for the Act 1 source SQL Server 2019 box.

    Run this INSIDE the VM (RDP session), in an ELEVATED PowerShell. It:
      1. Initializes the two attached Azure data disks (RAW) and formats them
         NTFS with a 64-KB allocation unit (SQL Server best practice):
            128 GB data disk -> F:  (label SQLData)
            512 GB log  disk -> L:  (label SQLLog)
      2. Creates F:\Data and L:\Log.
      3. Repoints the SQL Server instance DEFAULT data/log directories to those
         folders (via xp_instance_regwrite) so CREATE DATABASE lands files there.
      4. Restarts the SQL Server service so the new defaults take effect.
      5. Verifies the drives + the instance default paths.

    The local NVMe temp drive (D:) is left alone -- that's where tempdb belongs.
    Host caching (data=ReadOnly, log=None) is set at the Azure layer; nothing to
    do here.

.NOTES
    Default instance assumed (service MSSQLSERVER, -S localhost -E Windows auth).
    Re-runnable: skips disks already formatted and folders that already exist.

.EXAMPLE
    # From an elevated PowerShell on the VM:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\init-vm-disks.ps1
#>
#Requires -RunAsAdministrator
param(
    [int]$DataDiskSizeGB    = 128,
    [int]$LogDiskSizeGB     = 512,
    [char]$DataDriveLetter  = 'F',
    [char]$LogDriveLetter   = 'L',
    [string]$DataPath       = 'F:\Data',
    [string]$LogPath        = 'L:\Log',
    [int]$AllocationUnit    = 65536,          # 64 KB
    [string]$SqlInstance    = 'localhost',
    [string]$SqlServiceName = 'MSSQLSERVER'
)

$ErrorActionPreference = 'Stop'

function Initialize-SqlDisk {
    param(
        [int]$ApproxSizeGB,
        [char]$DriveLetter,
        [string]$Label,
        [int]$AllocationUnit
    )

    # If the target drive letter already has a volume, assume it's done.
    $existing = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host ">>> ${DriveLetter}: already exists (label '$($existing.FileSystemLabel)'), skipping init." -ForegroundColor Yellow
        return
    }

    # Find the RAW (uninitialized) disk closest to the expected size.
    $disk = Get-Disk |
        Where-Object { $_.PartitionStyle -eq 'RAW' -and [math]::Abs([math]::Round($_.Size/1GB) - $ApproxSizeGB) -le 2 } |
        Sort-Object Number | Select-Object -First 1

    if (-not $disk) {
        throw "No RAW disk of ~${ApproxSizeGB} GB found. Run 'Get-Disk' to inspect; the disk may already be initialized or the size differs."
    }

    Write-Host ">>> Initializing disk $($disk.Number) (~$([math]::Round($disk.Size/1GB)) GB) -> ${DriveLetter}: ($Label, $($AllocationUnit/1KB)-KB NTFS)..." -ForegroundColor Cyan
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $DriveLetter |
        Format-Volume -FileSystem NTFS -AllocationUnitSize $AllocationUnit `
            -NewFileSystemLabel $Label -Confirm:$false | Out-Null
}

# -----------------------------
# 1-2. Disks + folders
# -----------------------------
Initialize-SqlDisk -ApproxSizeGB $DataDiskSizeGB -DriveLetter $DataDriveLetter -Label 'SQLData' -AllocationUnit $AllocationUnit
Initialize-SqlDisk -ApproxSizeGB $LogDiskSizeGB  -DriveLetter $LogDriveLetter  -Label 'SQLLog'  -AllocationUnit $AllocationUnit

New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogPath  -Force | Out-Null
Write-Host ">>> Folders ready: $DataPath, $LogPath" -ForegroundColor Green

# -----------------------------
# 3. Repoint SQL default data/log directories (instance-wide)
#    xp_instance_regwrite maps the generic path to the running instance's hive.
# -----------------------------
Write-Host ">>> Setting SQL default data path -> $DataPath, log path -> $LogPath..." -ForegroundColor Cyan
$setPathsTsql = @"
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultData', REG_SZ, N'$DataPath';
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'DefaultLog',  REG_SZ, N'$LogPath';
"@
sqlcmd -S $SqlInstance -E -b -Q $setPathsTsql
if ($LASTEXITCODE -ne 0) { throw "Failed to write SQL default data/log registry values via sqlcmd." }

# -----------------------------
# 4. Restart SQL so the new defaults take effect
# -----------------------------
Write-Host ">>> Restarting SQL Server service '$SqlServiceName'..." -ForegroundColor Cyan
Restart-Service -Name $SqlServiceName -Force
# SQL Agent (if present) follows the engine restart.
Start-Sleep -Seconds 3

# -----------------------------
# 5. Verify
# -----------------------------
Write-Host ""
Write-Host "=== Volume check ===" -ForegroundColor Green
Get-Volume -DriveLetter $DataDriveLetter, $LogDriveLetter |
    Select-Object DriveLetter, FileSystemLabel,
        @{n='AllocKB';e={ (Get-Partition -DriveLetter $_.DriveLetter | Get-Volume).AllocationUnitSize / 1KB }},
        @{n='SizeGB';e={ [math]::Round($_.Size/1GB) }},
        @{n='FreeGB';e={ [math]::Round($_.SizeRemaining/1GB) }} |
    Format-Table -AutoSize

Write-Host "=== SQL default paths (post-restart) ===" -ForegroundColor Green
sqlcmd -S $SqlInstance -E -h -1 -W -Q "SELECT 'DefaultData=' + CONVERT(sysname, SERVERPROPERTY('InstanceDefaultDataPath')); SELECT 'DefaultLog=' + CONVERT(sysname, SERVERPROPERTY('InstanceDefaultLogPath'));"

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Disks initialized and SQL default paths set." -ForegroundColor Green
Write-Host "   Data -> $DataPath   Log -> $LogPath   tempdb -> local D:" -ForegroundColor Green
Write-Host " Next: run 00-build-source-sql2019.sql against this instance." -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
