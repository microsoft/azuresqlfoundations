<#
.SYNOPSIS
    Surgically deletes the SQL Server 2019 VM tier created by deploy-sql2019-vm.ps1,
    so the environment can be reprovisioned from scratch.

.DESCRIPTION
    Deletes ONLY the resources that deploy-sql2019-vm.ps1 creates, by exact name:

        SQL IaaS Agent registration (Microsoft.SqlVirtualMachine)
        VM                          ($VMName)
        OS + data + log disks       (captured live from the VM before deletion)
        NIC                         ($VMName-nic)
        Public IP                   ($VMName-pip)
        NSG                         ($VMName-nsg)  (+ policy NRMS-*-$VMName-vnet)
        VNet                        ($VMName-vnet)

    It NEVER touches same-prefix resources that are NOT part of the VM, notably the
    Hyperscale target and its dependencies:

        <your-server>  (logical server) + zavalending (HS DB) + named replica
        zavatesting* , <your-ai-account> (+ agent), <your-server>kv (Key Vault)

    Disk names are read from the live VM first (az vm show), so the auto-generated
    data-disk name (e.g. <your-server>_disk2_<guid>) is captured and removed too.

    Requires confirmation: type DELETE when prompted, or pass -Force to skip.
    Uses your existing 'az login' session. Run 'az login' first.

.EXAMPLE
    .\teardown-sql2019-vm.ps1

.EXAMPLE
    # Non-interactive (e.g. from a reprovision wrapper):
    .\teardown-sql2019-vm.ps1 -Force
#>
param(
    [string]$SubscriptionId = '<your-subscription-id>',
    [string]$ResourceGroup  = '<your-resource-group>',
    [string]$VMName         = '<your-server>',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resource names derived from the VM name (must match deploy-sql2019-vm.ps1)
$vnetName = "$VMName-vnet"
$nsgName  = "$VMName-nsg"
$pipName  = "$VMName-pip"
$nicName  = "$VMName-nic"

# -----------------------------
# 0. Verify az session
# -----------------------------
Write-Host ">>> Verifying existing Azure CLI session..." -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "No active Azure CLI session. Run 'az login' first." }
if ($acct.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    $acct = az account show -o json | ConvertFrom-Json
}
Write-Host ">>> Using subscription: $($acct.name) ($($acct.id))" -ForegroundColor Green

# -----------------------------
# 1. Capture the VM's disks (so we delete the auto-named data disk too)
# -----------------------------
$diskNames = @()
$vm = az vm show -g $ResourceGroup -n $VMName -o json 2>$null | ConvertFrom-Json
if ($vm) {
    if ($vm.storageProfile.osDisk.name) { $diskNames += $vm.storageProfile.osDisk.name }
    foreach ($d in $vm.storageProfile.dataDisks) {
        if ($d.name) { $diskNames += $d.name }
        elseif ($d.managedDisk.id) { $diskNames += ($d.managedDisk.id -split '/')[-1] }
    }
} else {
    Write-Host ">>> VM '$VMName' not found; will still clean up any leftover network/disks by name." -ForegroundColor Yellow
}

# -----------------------------
# 2. Confirmation
# -----------------------------
Write-Host ""
Write-Host "About to DELETE the following VM-tier resources in RG '$ResourceGroup':" -ForegroundColor Red
Write-Host "  SQL VM registration : $VMName"
Write-Host "  VM                  : $VMName"
Write-Host "  Disks               : $([string]::Join(', ', $diskNames))"
Write-Host "  NIC / PIP / NSG     : $nicName / $pipName / $nsgName"
Write-Host "  VNet                : $vnetName"
Write-Host ""
Write-Host "PRESERVED (never touched): <your-server>, zavalending (+ named replica)," -ForegroundColor Green
Write-Host "  zavatesting*, <your-ai-account> (+ agent), <your-server>kv." -ForegroundColor Green
Write-Host ""
if (-not $Force) {
    $confirm = Read-Host "Type DELETE to confirm teardown"
    if ($confirm -ne 'DELETE') { Write-Host ">>> Aborted." -ForegroundColor Yellow; return }
}

# Helper: run an az delete only if the resource exists
function Remove-IfExists {
    param([string]$Label, [scriptblock]$Exists, [scriptblock]$Delete)
    if (& $Exists) {
        Write-Host ">>> Deleting $Label..." -ForegroundColor Cyan
        & $Delete | Out-Null
    } else {
        Write-Host ">>> $Label not found, skipping." -ForegroundColor Yellow
    }
}

# -----------------------------
# 3. SQL IaaS Agent registration (must go before/with the VM)
# -----------------------------
Remove-IfExists "SQL VM registration '$VMName'" `
    { (az sql vm show -g $ResourceGroup -n $VMName -o tsv --query name 2>$null) } `
    { az sql vm delete -g $ResourceGroup -n $VMName --yes }

# -----------------------------
# 4. VM (does not cascade to disks/NIC)
# -----------------------------
Remove-IfExists "VM '$VMName'" `
    { $vm } `
    { az vm delete -g $ResourceGroup -n $VMName --yes }

# -----------------------------
# 5. Disks captured from the VM
# -----------------------------
foreach ($disk in $diskNames) {
    Remove-IfExists "disk '$disk'" `
        { (az disk show -g $ResourceGroup -n $disk -o tsv --query name 2>$null) } `
        { az disk delete -g $ResourceGroup -n $disk --yes }
}

# -----------------------------
# 6. Network: NIC -> PIP -> NSG(s) -> VNet  (dependency order)
# -----------------------------
Remove-IfExists "NIC '$nicName'" `
    { (az network nic show -g $ResourceGroup -n $nicName -o tsv --query name 2>$null) } `
    { az network nic delete -g $ResourceGroup -n $nicName }

Remove-IfExists "public IP '$pipName'" `
    { (az network public-ip show -g $ResourceGroup -n $pipName -o tsv --query name 2>$null) } `
    { az network public-ip delete -g $ResourceGroup -n $pipName }

Remove-IfExists "NSG '$nsgName'" `
    { (az network nsg show -g $ResourceGroup -n $nsgName -o tsv --query name 2>$null) } `
    { az network nsg delete -g $ResourceGroup -n $nsgName }

Remove-IfExists "VNet '$vnetName'" `
    { (az network vnet show -g $ResourceGroup -n $vnetName -o tsv --query name 2>$null) } `
    { az network vnet delete -g $ResourceGroup -n $vnetName }

# Policy-managed NRMS NSG -- delete AFTER the VNet, since it's associated with the
# subnet and cannot be removed while that association exists.
# Note: filter in PowerShell -- a JMESPath --query with contains(...) breaks
# when az.cmd is invoked through cmd.exe ("\Microsoft was unexpected at this time").
$nrms = az network nsg list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json |
    Where-Object { $_.name -like "*$vnetName*" } |
    Select-Object -ExpandProperty name
foreach ($n in $nrms) {
    Remove-IfExists "policy NSG '$n'" `
        { $true } `
        { az network nsg delete -g $ResourceGroup -n $n }
}

# -----------------------------
# 7. Summary
# -----------------------------
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " VM tier torn down. Reprovision with:" -ForegroundColor Green
Write-Host "   .\deploy-sql2019-vm.ps1 -AdminPassword <will prompt>" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
