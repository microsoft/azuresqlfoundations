# Step 3 — Modernize on Hyperscale (optional)

Detailed steps for the post-migration modernization. Run each script on the **Hyperscale
target** after the migration (Step 2) completes. These are independent — run all three or
just the ones you want.

**Starting point:** `ZavaLendingDB` migrated to Hyperscale, still at **compatibility level
150**, with `LoanTransactions` as a rowstore table.

---

## 3a — Compatibility level 150 → 170

**Script:** [01-compatibility-level.sql](01-compatibility-level.sql)

Move the database from compat 150 to 170 — one statement. Jumping two major levels lights
up the entire 160 intelligent-query-processing suite plus 170, none of which was active at
150:

- **Parameter Sensitive Plan (PSP) optimization** — multiple cached plans for skewed parameters.
- **Cardinality Estimation feedback** — bad estimates self-correct across executions.
- **Degree of Parallelism (DOP) feedback** — parallelism right-sizes automatically.
- **Memory Grant Feedback (persistence + percentile)** — spills stop recurring after restart.

The script includes a representative before/after query (a skewed `LoanType` parameter) so
you can see the plan shape and duration change.

```sql
ALTER DATABASE ZavaLendingDB SET COMPATIBILITY_LEVEL = 170;
```

---

## 3b — Rowstore → clustered columnstore

**Script:** [02-columnstore.sql](02-columnstore.sql)

`LoanTransactions` (~5.8M rows) migrated as **rowstore**. Convert it to a **clustered
columnstore index** and keep a nonclustered rowstore index on top for OLTP point lookups —
best of both worlds. The script shows:

- space before/after (compression), and
- an analytic aggregation before/after (batch mode) — a 12-month portfolio aggregation.

---

## 3c — Automatic index compaction (preview)

**Script:** [03-auto-index-compaction.sql](03-auto-index-compaction.sql)

Enable automatic index compaction. The OLTP write workload bloats B-tree leaf pages over
time; on-prem you'd run weekend rebuild jobs. On Hyperscale the platform compacts pages
continuously, with low overhead and no maintenance jobs.

```sql
ALTER DATABASE ZavaLendingDB SET AUTOMATIC_INDEX_COMPACTION = ON;
```

The script captures a page-density baseline via `sys.dm_db_index_physical_stats` and points
to the `auto_index_compaction_stats` Extended Event for ongoing visibility.

> **Preview + scope.** Automatic index compaction is in preview and acts on **B-tree leaf
> pages only** (not heaps, not compressed columnstore rowgroups) — so it complements, and
> does not overlap, the columnstore conversion in 3b.

---

**Next:** the database is migrated and modernized — continue to **Act 2 (`scale/`)** to
scale it to 192 vCores.

## Files

| File | Purpose |
|------|---------|
| [01-compatibility-level.sql](01-compatibility-level.sql) | Bump compat 150 → 170, before/after query |
| [02-columnstore.sql](02-columnstore.sql) | Convert `LoanTransactions` rowstore → clustered columnstore |
| [03-auto-index-compaction.sql](03-auto-index-compaction.sql) | Enable automatic index compaction (preview) + monitoring |
