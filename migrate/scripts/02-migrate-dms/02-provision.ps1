<#
.SYNOPSIS
  Phase 2 — provision Hyperscale: an Azure SQL logical server + an empty
  Hyperscale database + a firewall rule. Run BEFORE 03-dms-shir.ps1.

.DESCRIPTION
  The migrate script (04-migrate.ps1) assumes the target server and database
  already exist. This script creates them with `az sql server create` and
  `az sql db create -e Hyperscale`. Control-plane (ARM) calls — needs `az login`.

  No identity defaults are baked in; every environment value is a parameter.
  You are prompted for the server admin password (masked SecureString).

  Authentication mode: unless you pass -EntraAdminName/-EntraAdminObjectId or
  -NonInteractive, the script PROMPTS whether you want mixed-mode authentication
  (a Microsoft Entra ID admin ALONGSIDE the SQL admin) and asks which Entra
  account to use. Pass -EntraAdminName alone (UPN or group) and the object ID is
  resolved automatically; pass -EntraAdminObjectId too only to skip the lookup.
  The SQL admin is always kept because DMS writes schema/data with it.

  Zone redundancy is a CREATE-TIME-ONLY decision for Hyperscale — it cannot be
  changed after the database is provisioned (you would have to redeploy via
  database copy / point-in-time restore / geo-replica). If you don't pass
  -ZoneRedundant or -NonInteractive, this script PROMPTS you to decide and
  explains that it can't be added later. Saying yes auto-sets the two
  prerequisites Hyperscale requires: one HA replica and zone-redundant backup
  storage. The default (no replicas, no ZR) is left in place if you say no.

.EXAMPLE
  # Provisioned compute, 4 vCores, Gen5, allow your client IP:
  .\02-provision.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
      -Location eastus2 -ServerName <unique-server> -DatabaseName <db> `
      -AdminUser sqladmin -Capacity 4 -ClientIpAddress 203.0.113.10

.EXAMPLE
  # Serverless Hyperscale, 0.5–4 vCores, one HA replica, zone redundant:
  .\02-provision.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
      -Location eastus2 -ServerName <unique-server> -DatabaseName <db> `
      -AdminUser sqladmin -ComputeModel Serverless -MinCapacity 0.5 -Capacity 4 `
      -HaReplicas 1 -ZoneRedundant -AllowAzureServices
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$Location,

    # Logical server name — globally unique, no domain suffix (becomes <name>.database.windows.net).
    [Parameter(Mandatory)] [string]$ServerName,
    [Parameter(Mandatory)] [string]$DatabaseName,
    [Parameter(Mandatory)] [string]$AdminUser,

    # --- Entra ID (Azure AD) admin (optional; mixed-mode — keeps the SQL admin for DMS) ---
    # Provide BOTH to set an Entra admin on the server. Leave empty for SQL-auth only.
    # Entra-only auth is intentionally NOT enabled here because DMS writes to the target
    # with the SQL admin; switch to Entra-only after migration if desired.
    [string]$EntraAdminName = '',                        # display name / UPN of the Entra user or group
    [string]$EntraAdminObjectId = '',                    # object (principal) ID GUID; auto-resolved from the name if omitted

    # --- Hyperscale shape (sizing, not identity) ---
    [int]$Capacity = 2,                                   # max vCores
    [string]$Family = 'Gen5',
    [ValidateSet('Provisioned', 'Serverless')]
    [string]$ComputeModel = 'Provisioned',
    [double]$MinCapacity = 0.5,                           # Serverless only (min vCores)
    [int]$HaReplicas = 0,                                 # high-availability secondary replicas
    [ValidateSet('Local', 'Zone', 'Geo', 'GeoZone')]
    [string]$BackupStorageRedundancy = 'Geo',
    [switch]$ZoneRedundant,

    # --- Firewall (optional; pick what you need) ---
    [string]$ClientIpAddress = '',                       # single IP to allow (e.g. your public IP)
    [switch]$AllowAzureServices,                         # allow Azure services / the SHIR egress

    # Skip the interactive zone-redundancy prompt (for automation). When set, the
    # -ZoneRedundant switch (present or not) is taken as the final answer.
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '02-provision'
trap { Stop-PhaseLog; break }

# Ensure the Azure CLI is on PATH even right after a fresh install/upgrade.
. (Join-Path $PSScriptRoot '_resolve-az.ps1')

# Control-plane calls — require an authenticated az context.
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE) — run 'az login' first." }

Write-Host "==> Ensuring resource group '$ResourceGroup' in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az group create failed (exit $LASTEXITCODE)." }

# Prompt for the admin password without echoing it.
$securePwd = Read-Host -Prompt "Server admin password for '$AdminUser'" -AsSecureString
$plainPwd  = [System.Net.NetworkCredential]::new('', $securePwd).Password

try {
    Write-Host "==> Creating logical server '$ServerName'" -ForegroundColor Cyan
    az sql server create `
        --name $ServerName `
        --resource-group $ResourceGroup `
        --location $Location `
        --admin-user $AdminUser `
        --admin-password $plainPwd `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az sql server create failed (exit $LASTEXITCODE)." }

    # --- Microsoft Entra ID admin decision (mixed-mode) ---
    # Mixed-mode keeps the SQL admin '$AdminUser' (DMS writes schema/data with it)
    # AND adds a Microsoft Entra ID administrator so you (or a group) can sign in
    # with Entra ID — the recommended path for least-privilege access. Prompt only
    # when running interactively and the caller didn't already pass Entra values.
    if (-not $NonInteractive -and -not ($EntraAdminName -or $EntraAdminObjectId)) {
        Write-Host ""
        Write-Host "Microsoft Entra ID admin (mixed-mode authentication):" -ForegroundColor Yellow
        Write-Host "  Mixed-mode adds an Entra ID administrator ALONGSIDE the SQL admin" -ForegroundColor Yellow
        Write-Host "  '$AdminUser'. The SQL admin is kept because DMS writes with it; the" -ForegroundColor Yellow
        Write-Host "  Entra admin lets a user or group sign in with Entra ID and is the" -ForegroundColor Yellow
        Write-Host "  recommended path for least-privilege access after migration." -ForegroundColor Yellow
        $wantEntra = Read-Host "Add a Microsoft Entra ID admin now (mixed-mode)? [y/N]"
        if ($wantEntra -match '^(y|yes)$') {
            $EntraAdminName = (Read-Host "  Entra admin UPN or display name (e.g. user@contoso.com or a group name)").Trim()
            if (-not $EntraAdminName) { throw "Entra admin name cannot be empty." }
        }
    }

    # Resolve the object ID from the name when a name was supplied (via the prompt
    # OR via -EntraAdminName) but no -EntraAdminObjectId. This lets callers pass
    # just the name; the GUID is looked up automatically (user first, then group).
    if ($EntraAdminName -and -not $EntraAdminObjectId) {
        Write-Host "==> Resolving object ID for Entra admin '$EntraAdminName'..." -ForegroundColor DarkCyan
        $resolvedId = az ad user show --id $EntraAdminName --query id -o tsv 2>$null
        if (-not $resolvedId) {
            $resolvedId = az ad group show --group $EntraAdminName --query id -o tsv 2>$null
        }
        if ($resolvedId) {
            $EntraAdminObjectId = $resolvedId.Trim()
            Write-Host "==> Found object ID: $EntraAdminObjectId" -ForegroundColor DarkCyan
        }
        elseif ($NonInteractive) {
            throw "Could not resolve an object ID for '$EntraAdminName'. Pass -EntraAdminObjectId explicitly."
        }
        else {
            $EntraAdminObjectId = (Read-Host "  Could not auto-resolve; enter the Entra admin object ID (GUID)").Trim()
            if (-not $EntraAdminObjectId) { throw "Entra admin object ID cannot be empty." }
        }
    }

    if ($EntraAdminName -and $EntraAdminObjectId) {
        Write-Host "==> Setting Entra ID admin '$EntraAdminName' (mixed-mode; SQL admin retained for DMS)" -ForegroundColor Cyan
        az sql server ad-admin create `
            --resource-group $ResourceGroup --server $ServerName `
            --display-name $EntraAdminName --object-id $EntraAdminObjectId --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az sql server ad-admin create failed (exit $LASTEXITCODE)." }
    }
    elseif ($EntraAdminObjectId -and -not $EntraAdminName) {
        throw "Provide -EntraAdminName (the object ID is resolved automatically, or pass -EntraAdminObjectId too)."
    }

    if ($AllowAzureServices) {
        Write-Host "==> Firewall: allow Azure services (0.0.0.0)" -ForegroundColor Cyan
        az sql server firewall-rule create `
            --resource-group $ResourceGroup --server $ServerName `
            --name AllowAzureServices `
            --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "firewall-rule create (Azure services) failed (exit $LASTEXITCODE)." }
    }
    if ($ClientIpAddress) {
        Write-Host "==> Firewall: allow client IP $ClientIpAddress" -ForegroundColor Cyan
        az sql server firewall-rule create `
            --resource-group $ResourceGroup --server $ServerName `
            --name "AllowClient-$ClientIpAddress" `
            --start-ip-address $ClientIpAddress --end-ip-address $ClientIpAddress --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "firewall-rule create (client IP) failed (exit $LASTEXITCODE)." }
    }

    # --- Zone redundancy decision (CREATE-TIME ONLY for Hyperscale) ---
    # Zone redundancy can ONLY be set when a Hyperscale database is created. It
    # cannot be enabled in place afterward — adding it later means redeploying the
    # database (copy / point-in-time restore / geo-replica) and repointing the
    # connection string. Make a conscious choice now.
    $enableZr = [bool]$ZoneRedundant
    if (-not $NonInteractive -and -not $PSBoundParameters.ContainsKey('ZoneRedundant')) {
        Write-Host ""
        Write-Host "Zone redundancy is a CREATE-TIME-ONLY setting for Hyperscale." -ForegroundColor Yellow
        Write-Host "It CANNOT be enabled later in place. Adding it after creation means" -ForegroundColor Yellow
        Write-Host "redeploying the database (copy / point-in-time restore / geo-replica)" -ForegroundColor Yellow
        Write-Host "and repointing your connection string." -ForegroundColor Yellow
        Write-Host "Enabling it now also requires one HA replica and zone-redundant backup" -ForegroundColor Yellow
        Write-Host "storage — this script will set both for you if you choose yes." -ForegroundColor Yellow
        $answer  = Read-Host "Enable zone redundancy for '$DatabaseName' now? [y/N]"
        $enableZr = ($answer -match '^(y|yes)$')
    }
    if ($enableZr) {
        # Hyperscale ZR prerequisites — set them if the caller hasn't already.
        if ($HaReplicas -lt 1) {
            Write-Host "==> Zone redundancy requires >= 1 HA replica; setting HaReplicas = 1." -ForegroundColor Yellow
            $HaReplicas = 1
        }
        if ($BackupStorageRedundancy -notin @('Zone', 'GeoZone')) {
            Write-Host "==> Zone redundancy requires zone-redundant backup storage; setting BackupStorageRedundancy = Zone." -ForegroundColor Yellow
            $BackupStorageRedundancy = 'Zone'
        }
    }

    # Build the Hyperscale db create args.
    $dbArgs = @(
        'sql', 'db', 'create',
        '--resource-group', $ResourceGroup,
        '--server', $ServerName,
        '--name', $DatabaseName,
        '--edition', 'Hyperscale',
        '--family', $Family,
        '--capacity', $Capacity,
        '--compute-model', $ComputeModel,
        '--ha-replicas', $HaReplicas,
        '--backup-storage-redundancy', $BackupStorageRedundancy,
        '--only-show-errors'
    )
    if ($ComputeModel -eq 'Serverless') { $dbArgs += @('--min-capacity', $MinCapacity) }
    if ($enableZr)                      { $dbArgs += '--zone-redundant' }

    Write-Host "==> Creating Hyperscale database '$DatabaseName' ($ComputeModel, $Family, max $Capacity vCores, $HaReplicas HA replica(s))" -ForegroundColor Cyan
    az @dbArgs
    if ($LASTEXITCODE -ne 0) { throw "az sql db create failed (exit $LASTEXITCODE)." }
}
finally {
    $plainPwd  = $null
    $securePwd = $null
}

$fqdn = "$ServerName.database.windows.net"
Write-Host ""
Write-Host "Target ready: $fqdn / $DatabaseName (Hyperscale)" -ForegroundColor Green
Write-Host "Next: .\03-dms-shir.ps1 -SubscriptionId <sub> -ResourceGroup $ResourceGroup -Location <region> -DmsName <dms-name>" -ForegroundColor Green
Stop-PhaseLog
