# Step 1 — Stand up the SQL Server 2019 source

> 📺 Part of the [Azure SQL Foundations video series & workshop](../../../README.md) — companion to <https://aka.ms/azuresqlfoundationseries>.

Detailed steps for the migrate source. The "on-prem SQL Server 2019" is simulated by an
**Azure VM** — purely to avoid standing up a physical box. It migrates to Hyperscale over
the **public endpoint**, exactly as a real datacenter server would.

**Skip this entirely if you already have a SQL Server source** to migrate — just point the
migration (Part 2) at it.

**End state:** a `ZavaLendingDB` at **compatibility level 150** with a rowstore
`LoanTransactions` history table, ready to migrate.

---

## What gets deployed

| Component | Spec |
|-----------|------|
| VM | `<your-server>` — **Standard_E32ads_v5** (AMD, 32 vCPU / 256 GiB), non-zonal |
| Region | **centralus** · resource group `<your-resource-group>` |
| Image | `MicrosoftSQLServer:sql2019-ws2022:standard:latest` (SQL 2019 Std on WS2022) |
| OS disk | 127 GB Premium SSD (P10) |
| Data disk | 128 GB Premium SSD (P10), LUN 0, host caching ReadOnly → `F:\Data` |
| Log disk | 512 GB Premium SSD (P20), LUN 1, host caching None → `L:\Log` |
| tempdb | local NVMe temp drive `D:` |
| Network | VNet/subnet + NSG (RDP 3389 + SQL 1433 locked to your client IP) + static public IP |
| SQL mgmt | SQL IaaS Agent extension (Lightweight, license PAYG) |

---

## Steps

### 1. Provision the VM

Run locally. Prompts for a masked admin password. Defaults to centralus + E32ads_v5;
override with `-Location` / `-VMSize` as needed.

```powershell
cd migrate/scripts/01-source-sql2019
.\deploy-sql2019-vm.ps1
```

### 2. Initialize disks (inside the VM)

RDP into the VM, then in an **elevated** PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\init-vm-disks.ps1        # 128GB -> F:, 512GB -> L:, repoints SQL default data/log, restarts SQL
```

### 3. Build and seed the source database (inside the VM)

```powershell
sqlcmd -S localhost -E -i 00-build-source-sql2019.sql -o build.log
```

Load ~5.8M rows into `LoanTransactions` for realistic modernization impact, or fewer for a
quick run.

### 4. Confirm the source

```sql
SELECT name, compatibility_level FROM sys.databases WHERE name = 'ZavaLendingDB';  -- 150
```

**Next:** migrate it — see [../02-migrate-dms/](../02-migrate-dms/) or the parent
[README](../../README.md).

---

## Teardown

Remove the VM tier when you're done. Deletes **only** the VM-tier resources by exact name
(SQL registration → VM → disks → NIC → PIP → NSG + policy NSG → VNet). It never touches the
Hyperscale logical server, the migrated database, or other Azure SQL resources.

```powershell
cd migrate/scripts/01-source-sql2019
.\teardown-sql2019-vm.ps1            # type DELETE to confirm (or -Force)
```

---

## Notes

- **Region / capacity.** The v5 E-family is quota-constrained in some regions; centralus
  had both quota and AMD `E32ads_v5` capacity. Region is irrelevant to the migration (DMS
  runs over the Hyperscale public endpoint). To probe a clean region without leaving
  orphans, use `az deployment group validate`.

## Files

| File | Purpose |
|------|---------|
| [deploy-sql2019-vm.ps1](deploy-sql2019-vm.ps1) | Provision the Azure VM (VM + 3-disk Premium SSD layout + SQL IaaS registration) |
| [init-vm-disks.ps1](init-vm-disks.ps1) | Initialize/format the data + log disks and repoint SQL default paths (run in the VM) |
| [00-build-source-sql2019.sql](00-build-source-sql2019.sql) | Build the SQL 2019 source DB at compat 150 with rowstore `LoanTransactions` + seed data |
| [teardown-sql2019-vm.ps1](teardown-sql2019-vm.ps1) | Delete only the VM-tier resources (never the Hyperscale server/DB) |
