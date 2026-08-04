<#
.SYNOPSIS
    Deploys an Azure VM from the Marketplace running SQL Server 2019 Standard Edition
    (on Windows Server 2022) for Act 1 — Migrate & Modernize. The VM doubles as the
    convenient way to *deploy* SQL Server 2019, and as the Option A (lift & shift)
    rehost target whose disk layout mirrors the on-prem VMware source spec.

.DESCRIPTION
    Creates (idempotently) a resource group, VNet/subnet, NSG (RDP 3389 + SQL 1433
    locked to your client IP), public IP, NIC, and a SQL Server 2019 Standard VM
    from the first-party Marketplace image:

        MicrosoftSQLServer:sql2019-ws2022:standard:latest

    The VM is deployed **non-zonal** (no -Zone) on purpose, so the demo can contrast
    it with Hyperscale's managed zone resilience. It provisions the committed
    3-disk Premium SSD layout:

        OS   disk  127 GB Premium SSD (P10)          — default caching
        Data disk  128 GB Premium SSD (P10), LUN 0   — ReadOnly caching (SQL data)
        Log  disk  512 GB Premium SSD (P20), LUN 1   — None caching (SQL log, 150 MB/s)

    (tempdb belongs on the VM's local NVMe temp drive — guest-side step, not provisioned
    here.) The 512 GB P20 log disk is sized for **throughput, not capacity**: 150 MB/s
    is the smallest Premium SSD v1 tier that matches Hyperscale's 150 MiB/s log rate.

    It then registers the VM with the SQL IaaS Agent extension (az sql vm create)
    so SQL is manageable from the portal, and opens the SQL TCP port.

    Uses your existing 'az login' session. Run 'az login' first.

.EXAMPLE
    # You'll be prompted for the admin password (masked input):
    .\deploy-sql2019-vm.ps1

.EXAMPLE
    # Override size and lock access to a specific public IP:
    .\deploy-sql2019-vm.ps1 -VMSize Standard_E32s_v5 -ClientIp 203.0.113.7
#>
param(
    [string]$SubscriptionId = '<your-subscription-id>',
    [string]$ResourceGroup = '<your-resource-group>',
    # eastus2 is capacity-blocked for E32ds_v5; eastus is price-identical and
    # adjacent (lowest cross-region latency to the eastus2 Hyperscale target).
    [string]$Location      = 'eastus',
    [string]$VMName        = '<your-server>',
    # Windows computer (NetBIOS) name — must be <= 15 chars
    [string]$ComputerName  = '<your-server>',
    [string]$VMSize        = 'Standard_E32ds_v5',
    [string]$AdminUser     = 'azureuser',
    # SecureString so the prompt masks input and the secret is never echoed.
    [Parameter(Mandatory = $true)]
    [SecureString]$AdminPassword,
    # Marketplace image URN for SQL Server 2019 Standard on Windows Server 2022
    [string]$ImageUrn      = 'MicrosoftSQLServer:sql2019-ws2022:standard:latest',
    # Committed 3-disk Premium SSD layout (P10 OS + P10 data + P20 log)
    [string]$OsDiskSku       = 'Premium_LRS',
    [int]$DataDiskSizeGB     = 128,            # P10 -> 500 IOPS / 100 MB/s
    [string]$DataDiskSku     = 'Premium_LRS',
    [string]$DataDiskCaching = 'ReadOnly',     # SQL data file best practice
    [int]$LogDiskSizeGB      = 512,            # P20 -> 2,300 IOPS / 150 MB/s (matches HS log rate)
    [string]$LogDiskSku      = 'Premium_LRS',
    [string]$LogDiskCaching  = 'None',         # SQL log file best practice
    [int]$SqlPort          = 1433,
    # Optional availability zone (1/2/3). Capacity for the v5 E-family is often
    # available zonally even when regional (non-zonal) allocation is restricted.
    # A single zonal VM is still a single point of failure (SLA unchanged at 99.9%).
    [string]$Zone          = '',
    # Source IP allowed for RDP + SQL. Defaults to your current public IP.
    [string]$ClientIp      = ''
)

$ErrorActionPreference = 'Stop'

# Resource names derived from the VM name
$vnetName   = "$VMName-vnet"
$subnetName = "$VMName-subnet"
$nsgName    = "$VMName-nsg"
$pipName    = "$VMName-pip"
$nicName    = "$VMName-nic"

# -----------------------------
# 0. Verify az session
# -----------------------------
Write-Host ">>> Verifying existing Azure CLI session..." -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    throw "No active Azure CLI session. Run 'az login' first."
}
if ($acct.id -ne $SubscriptionId) {
    Write-Host ">>> Switching to subscription $SubscriptionId..." -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
    $acct = az account show -o json | ConvertFrom-Json
}
Write-Host ">>> Using subscription: $($acct.name) ($($acct.id))" -ForegroundColor Green

# Ensure the SQL VM resource provider is registered (needed for az sql vm)
Write-Host ">>> Ensuring Microsoft.SqlVirtualMachine provider is registered..." -ForegroundColor Cyan
$sqlVmState = az provider show --namespace Microsoft.SqlVirtualMachine --query registrationState -o tsv 2>$null
if ($sqlVmState -ne 'Registered') {
    az provider register --namespace Microsoft.SqlVirtualMachine | Out-Null
    Write-Host ">>> Registration submitted (may take a few minutes to complete)." -ForegroundColor Yellow
}

# -----------------------------
# 1. Resolve client IP for NSG rules
# -----------------------------
if (-not $ClientIp) {
    Write-Host ">>> Detecting your public IP for NSG allow rules..." -ForegroundColor Cyan
    try {
        $ClientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
    } catch {
        throw "Could not auto-detect public IP. Pass -ClientIp <your.public.ip> explicitly."
    }
}
Write-Host ">>> Allowing RDP (3389) and SQL ($SqlPort) from: $ClientIp" -ForegroundColor Green

# -----------------------------
# 2. Resource group
# -----------------------------
if ((az group exists --name $ResourceGroup -o tsv) -eq 'true') {
    Write-Host ">>> Resource group '$ResourceGroup' already exists, skipping." -ForegroundColor Yellow
} else {
    Write-Host ">>> Creating resource group: $ResourceGroup in $Location..." -ForegroundColor Cyan
    az group create --name $ResourceGroup --location $Location | Out-Null
}

# -----------------------------
# 3. VNet + subnet
# -----------------------------
Write-Host ">>> Creating VNet $vnetName / subnet $subnetName..." -ForegroundColor Cyan
az network vnet create `
    --resource-group $ResourceGroup `
    --name $vnetName `
    --location $Location `
    --address-prefixes "10.10.0.0/16" `
    --subnet-name $subnetName `
    --subnet-prefixes "10.10.1.0/24" | Out-Null

# -----------------------------
# 4. NSG + rules (RDP + SQL from client IP only)
# -----------------------------
Write-Host ">>> Creating NSG $nsgName with locked-down rules..." -ForegroundColor Cyan
az network nsg create --resource-group $ResourceGroup --name $nsgName --location $Location | Out-Null

az network nsg rule create --resource-group $ResourceGroup --nsg-name $nsgName `
    --name allow_rdp --priority 1000 --direction Inbound --access Allow --protocol Tcp `
    --source-address-prefixes $ClientIp --source-port-ranges "*" `
    --destination-address-prefixes "*" --destination-port-ranges 3389 `
    --description "Allow RDP from client IP" | Out-Null

az network nsg rule create --resource-group $ResourceGroup --nsg-name $nsgName `
    --name allow_sql --priority 1010 --direction Inbound --access Allow --protocol Tcp `
    --source-address-prefixes $ClientIp --source-port-ranges "*" `
    --destination-address-prefixes "*" --destination-port-ranges $SqlPort `
    --description "Allow SQL TDS from client IP" | Out-Null

# -----------------------------
# 5. Public IP + NIC
# -----------------------------
Write-Host ">>> Creating public IP $pipName..." -ForegroundColor Cyan
az network public-ip create `
    --resource-group $ResourceGroup `
    --name $pipName `
    --location $Location `
    --sku Standard `
    --allocation-method Static | Out-Null

Write-Host ">>> Creating NIC $nicName..." -ForegroundColor Cyan
az network nic create `
    --resource-group $ResourceGroup `
    --name $nicName `
    --location $Location `
    --vnet-name $vnetName `
    --subnet $subnetName `
    --network-security-group $nsgName `
    --public-ip-address $pipName | Out-Null

# -----------------------------
# 6. Create the VM from the Marketplace image (non-zonal, OS disk only)
#    Data + log disks are attached separately below so each gets its own
#    SKU + caching (az vm create can't set per-disk caching).
# -----------------------------
Write-Host ">>> Creating VM $VMName from image $ImageUrn (non-zonal)..." -ForegroundColor Cyan
# Convert the SecureString to plaintext just-in-time for the az CLI argument.
$plainPwd = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
$zoneArgs = @()
if ($Zone) {
    $zoneArgs = @('--zone', $Zone)
    Write-Host ">>> Pinning VM to availability zone $Zone (single zonal VM; SLA still 99.9%)." -ForegroundColor Cyan
}
az vm create `
    --resource-group $ResourceGroup `
    --name $VMName `
    --location $Location `
    --size $VMSize `
    --image $ImageUrn `
    --admin-username $AdminUser `
    --admin-password $plainPwd `
    --computer-name $ComputerName `
    --nics $nicName `
    --os-disk-name "$VMName-osdisk" `
    --storage-sku $OsDiskSku `
    --license-type Windows_Server @zoneArgs | Out-Null
$plainPwd = $null   # drop the cleartext copy ASAP

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: 'az vm create' failed (exit $LASTEXITCODE). Aborting before disk/SQL steps." -ForegroundColor Red
    Write-Host "       If this was a SkuNotAvailable / Capacity Restriction, retry with a" -ForegroundColor Red
    Write-Host "       different -Location or -VMSize, then re-run. No VM was created." -ForegroundColor Red
    exit 1
}

# -----------------------------
# 6b. Attach the committed data (P10) + log (P20) Premium SSD disks
# -----------------------------
Write-Host ">>> Attaching data disk ($DataDiskSizeGB GB $DataDiskSku, LUN 0, caching $DataDiskCaching)..." -ForegroundColor Cyan
az vm disk attach `
    --resource-group $ResourceGroup `
    --vm-name $VMName `
    --name "$VMName-datadisk" `
    --new --size-gb $DataDiskSizeGB --sku $DataDiskSku `
    --lun 0 --caching $DataDiskCaching | Out-Null

Write-Host ">>> Attaching log disk ($LogDiskSizeGB GB $LogDiskSku, LUN 1, caching $LogDiskCaching — 150 MB/s)..." -ForegroundColor Cyan
az vm disk attach `
    --resource-group $ResourceGroup `
    --vm-name $VMName `
    --name "$VMName-logdisk" `
    --new --size-gb $LogDiskSizeGB --sku $LogDiskSku `
    --lun 1 --caching $LogDiskCaching | Out-Null

# -----------------------------
# 7. Register the SQL IaaS Agent extension (Lightweight management mode)
# -----------------------------
Write-Host ">>> Registering SQL VM (IaaS Agent extension)..." -ForegroundColor Cyan
az sql vm create `
    --resource-group $ResourceGroup `
    --name $VMName `
    --location $Location `
    --license-type PAYG `
    --sql-mgmt-type Lightweight | Out-Null

# -----------------------------
# 8. Summary
# -----------------------------
$publicIp = az network public-ip show --resource-group $ResourceGroup --name $pipName --query ipAddress -o tsv

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " SQL Server 2019 Standard VM deployed" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Resource group : $ResourceGroup"
Write-Host " VM name        : $VMName ($VMSize, non-zonal)"
Write-Host " Image          : $ImageUrn"
Write-Host " Disks          : OS 127GB P10 | data ${DataDiskSizeGB}GB P10 (LUN0,$DataDiskCaching) | log ${LogDiskSizeGB}GB P20 (LUN1,$LogDiskCaching)"
Write-Host " Public IP      : $publicIp"
Write-Host " RDP            : mstsc /v:$publicIp   (user: $AdminUser)"
Write-Host " SQL endpoint   : $publicIp,$SqlPort"
Write-Host ""
Write-Host " Next steps:"
Write-Host "  1. RDP in and confirm SQL Server 2019 is running (SQL config mgr)."
Write-Host "  2. In Disk Management: bring LUN 1 (512GB) online -> NTFS, 64KB allocation"
Write-Host "     unit -> assign L:; bring LUN 0 (128GB) online -> NTFS 64KB -> assign F:."
Write-Host "  3. Place SQL data files on F:, log files on L:, tempdb on the local NVMe (D:)."
Write-Host "  4. Enable TCP/IP + mixed-mode auth, set sa or create a SQL login."
Write-Host "  5. Open Windows Firewall for TCP $SqlPort on the guest."
Write-Host "  6. Run scripts/00-build-source-sql2019.sql against this instance."
Write-Host "==================================================================" -ForegroundColor Green
