# SQL Server deployment and synthetic end-to-end verification

## 1. Purpose and limits

This guide deploys migrations 001–008 into a **new, disposable SQL Server 2022 database**, verifies objects, and runs the repository's synthetic regression suite. It is a developer/test procedure, not production approval.

- The current CI target is SQL Server 2022 (major version 16). Migration 008 creates `ecl_cfg.PDScenarioMapping` with the approved mapping `1=BASE`, `2=UPTURN`, `3=DOWNTURN` and installs the retail marginal PIT PD source loader.
- CI uses an ephemeral Developer-edition container. A green CI run does not prove production readiness, successful deployment to another instance, production permissions, data mappings, capacity, or operational readiness.
- The migration files are not a single idempotent migration framework. Do not blindly rerun the full sequence against a partially deployed database.
- Use synthetic test fixtures only. Never commit customer records, credentials, or secrets.
- Do not claim SQL Server 2016 compatibility based on this guide.

## 2. Prerequisites and permissions

1. Use a clean SQL Server 2022 instance and a database approved for development/testing.
2. Install sqlcmd and ensure it is on PATH.
3. Use a deployment identity permitted to create schemas, tables, indexes, and stored procedures and to alter/drop procedures during migration. A database owner/admin identity is simplest for a disposable database. Do not grant broad deployment permissions to the application runtime identity.
4. Use a separate runtime identity for real application execution. Review and grant only required procedure and data access under your organization's security model; a production permission package is not yet provided here.
5. Ensure the database is empty or can be safely discarded. Take an approved backup before any deployment to a database containing valuable data.

## 3. Create and verify the database

In SSMS, create a new database, for example IFRS9_ECL_DEV. Substitute your server/database names below.

```sql
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS product_major_version,
    SERVERPROPERTY('ProductVersion') AS product_version,
    SERVERPROPERTY('Edition') AS edition;

SELECT name, state_desc, compatibility_level
FROM sys.databases
WHERE name = N'IFRS9_ECL_DEV';
```

For parity with current CI, expect major version 16. Record the actual server version, edition, database name, deployment date, and results in your local change record. Do not include secrets.

## 4. Deploy migrations in order

Run from the repository root in Windows PowerShell. Change the server/database variables. The -b option makes sqlcmd return a nonzero exit code for SQL errors; stop immediately if a script fails.

```powershell
$Server = "localhost"
$Database = "IFRS9_ECL_DEV"
$Scripts = @(
    "database/001_create_logical_schema.sql",
    "database/002_run_control.sql",
    "database/003_input_validation.sql",
    "database/004_input_reconciliation.sql",
    "database/005_ecl_calculation.sql",
    "database/006_ead_curve_loader.sql",
    "database/007_pd_curve_loader.sql",\n    "database/008_retail_marginal_pit_pd_source_loader.sql"
)

foreach ($Script in $Scripts) {
    Write-Host "Deploying $Script"
    sqlcmd -S $Server -d $Database -E -b -i $Script
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment stopped at $Script (sqlcmd exit code $LASTEXITCODE). Do not continue."
    }
}
```

This example uses Windows integrated authentication. If using SQL authentication, follow your organization's approved secret-handling method; do not hard-code passwords in scripts, command history, or logs.

### If a migration fails

- Stop; do not run later migrations against a partially deployed database.
- Capture the script name, SQL error number/message, and relevant non-sensitive log context.
- For a disposable database, drop and recreate it, then rerun from migration 001 after correcting the cause.
- For a database containing valuable data, do not drop objects or manually reverse DDL. Follow the approved restore/rollback procedure and investigate the partial state first.

## 5. Verify deployed objects

Run after all seven migrations. The five functional schemas and ten listed procedures should exist.

```sql
SELECT name AS schema_name
FROM sys.schemas
WHERE name IN (N'ecl_cfg', N'ecl_stg', N'ecl_core', N'ecl_result', N'ecl_audit')
ORDER BY name;

SELECT SCHEMA_NAME(schema_id) AS schema_name, name AS object_name, type_desc
FROM sys.objects
WHERE SCHEMA_NAME(schema_id) = N'ecl_core'
  AND name IN (N'usp_CreateRun', N'usp_TransitionRunStatus',
               N'usp_RegisterRunInput', N'usp_SealRunInputs',
               N'usp_ValidateRunInputs', N'usp_ReconcileInputSnapshots',
               N'usp_CalculateECL', N'usp_PublishECL',
               N'usp_LoadEADCurve', N'usp_LoadPDCurve')
ORDER BY name;

SELECT name, state_desc, compatibility_level
FROM sys.databases
WHERE name = DB_NAME();
```

Expected: all five schemas exist; all eight procedures have type SQL_STORED_PROCEDURE; the database is online. If an object is missing, stop and inspect deployment output.

## 6. Run the synthetic integration suite

The authoritative test sequence is maintained in the [SQL Server 2022 GitHub Actions workflow](../.github/workflows/sql-server-2022-tests.yml). To reproduce the test list locally, run from the repository root:

```powershell
$Server = "localhost"
$Database = "IFRS9_ECL_DEV"
$Scripts = @(
    "tests/sql/ead_curve_loader_tests.sql",
    "tests/sql/pd_curve_loader_tests.sql",
    "tests/sql/run_control_smoke_tests.sql",
    "tests/sql/input_validation_smoke_tests.sql",
    "tests/sql/input_reconciliation_smoke_tests.sql",
    "tests/sql/input_contract_regression_tests.sql",
    "tests/sql/maturity_curve_coverage_tests.sql",
    "tests/sql/canonical_input_happy_path_tests.sql",
    "tests/sql/scenario_weight_boundary_tests.sql",
    "tests/sql/run_lifecycle_gate_tests.sql",
    "tests/sql/precalculation_rerun_safety_tests.sql",
    "tests/sql/publication_gate_tests.sql",
    "tests/sql/selective_run_scope_tests.sql",
    "tests/sql/input_data_quality_tests.sql",
    "tests/sql/ecl_calculation_tests.sql",
    "tests/sql/ecl_calculation_rollback_fault_injection_tests.sql"
)

foreach ($Script in $Scripts) {
    Write-Host "Testing $Script"
    sqlcmd -S $Server -d $Database -E -b -i $Script
    if ($LASTEXITCODE -ne 0) {
        throw "Test failed at $Script (sqlcmd exit code $LASTEXITCODE)."
    }
}
```

Expected: every script completes with exit code 0 and its PASS message. Some tests create synthetic rows inside transactions and roll them back. The calculation test exercises Stage 1/2/3, scenario weighting, partial-period discounting, rerun rejection, and publication rounding. The fault-injection test creates a test-only trigger scoped to synthetic account identifiers and removes it during cleanup. Use a disposable database regardless.

Do not report the suite as passed until it has actually completed on your target test instance. A successful GitHub Actions run is evidence for that CI container only.

## 7. Controlled run lifecycle

The engine consumes upstream snapshots; it does not populate staging tables or build PD/LGD/EAD models. Each run needs complete snapshots for ACCOUNT, PD, LGD, EAD, EIR, and SCENARIO_WEIGHT.

1. Create the run with ecl_core.usp_CreateRun and an effective scenario-weight version; capture the returned RUN_ID.
2. Transition CREATED to VALIDATING with ecl_core.usp_TransitionRunStatus.
3. Load the staged snapshots for that RUN_ID and PROCESS_DATE.
4. Register each input family using ecl_core.usp_RegisterRunInput with source system/object/version, expected row count, completeness flag, and optional content hash.
5. Seal the manifest with ecl_core.usp_SealRunInputs.
6. Run ecl_core.usp_ValidateRunInputs and inspect findings. ERROR/FATAL findings block calculation.
7. Run ecl_core.usp_ReconcileInputSnapshots and verify the latest INPUT_RECONCILIATION event succeeded.
8. Transition the run to CALCULATING.
9. Execute ecl_core.usp_CalculateECL. Output writes and successful calculation/reconciliation milestones are transactional.
10. Execute ecl_core.usp_PublishECL only after calculation succeeds. Publication rounds account and portfolio-summary ECL amounts to whole VND and moves the run to PUBLISHED.

Use the repository tests as executable examples of exact parameter contracts. Do not run a live account-level workflow until source mappings, access control, monitoring, and operational ownership are approved.

## 8. Status, output, and reconciliation queries

Replace 12345 with the RUN_ID returned by usp_CreateRun.

```sql
DECLARE @RUN_ID bigint = 12345;

SELECT * FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;

SELECT EVENT_ID, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, EVENT_AT
FROM ecl_audit.RunEvent
WHERE RUN_ID = @RUN_ID
ORDER BY EVENT_ID;

SELECT COUNT_BIG(*) AS detail_rows
FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID;

SELECT COUNT_BIG(*) AS account_rows,
       SUM(ECL_12_MONTH) AS ecl_12_month,
       SUM(ECL_LIFETIME) AS ecl_lifetime,
       SUM(ECL_DEFAULT) AS ecl_default,
       SUM(ECL_TOTAL) AS ecl_total
FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID;

SELECT POOL_NAME, AGGREGATION_LEVEL, POOL_ID, STAGE, ACCOUNT_COUNT,
       ECL_12_MONTH, ECL_LIFETIME, ECL_DEFAULT, ECL_TOTAL
FROM ecl_result.ECLPortfolioSummary
WHERE RUN_ID = @RUN_ID
ORDER BY POOL_NAME, AGGREGATION_LEVEL, POOL_ID, STAGE;
```

Before accepting results, verify PUBLISHED status, successful latest input-reconciliation and publication milestones, reconciliation of account and summary totals to detail under approved reporting rules, correct scenario-weight version, and whole-VND published account/summary values. Stage categories are mutually exclusive; do not add Stage 3 default ECL to Stage 2 lifetime ECL.

## 9. Failure handling, reruns, and cleanup

- If validation/reconciliation fails, do not calculate. Inspect ecl_audit.ValidationError and ecl_audit.RunEvent, correct upstream data, and use a new RUN_ID for a corrected snapshot.
- If calculation throws, its output writes are designed to roll back atomically. Verify no partial rows remain in ECLDetail, ECLAccount, or ECLPortfolioSummary.
- If output already exists for a RUN_ID, a second calculation call is rejected. Do not delete result rows to force a retry. Use a new RUN_ID and preserve audit history.
- If publication fails, inspect run status/events before retrying. Do not manually set lifecycle status to bypass procedure gates.
- For test cleanup, the safest approach is to drop and recreate the disposable database. The test scripts are regression fixtures, not a general-purpose production cleanup utility.
- Before production deployment, define and rehearse backup/restore, rollback criteria, migration history tracking, retention, monitoring/alerting, and operational escalation. These are not fully automated by current migrations.

## 10. Release readiness checklist

- [ ] Migrations 001–008 deployed to a clean disposable SQL Server 2022 database.
- [ ] Object verification queries passed.
- [ ] Every synthetic SQL test completed successfully on that database.
- [ ] End-to-end synthetic calculation reached PUBLISHED and its assertions passed.
- [ ] Fault-injection test confirmed no partial calculation output remained after the injected error.
- [ ] Actual database version, compatibility level, test date, and results recorded without secrets.
- [ ] Environment-specific permissions, source mapping, scenario-weight provenance, performance, monitoring, backup/restore, and operational runbooks reviewed separately before production rollout.


## Retail PD source-loader deployment notes

Migration 008 requires the run database to contain `dbo.RETAIL_MARGINAL_PIT_PD` and have read access to `[IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING]` (for example, via appropriate cross-database permissions). It selects the latest source PD `PROCESS_DATE` as a dataset version and records a warning with the selected date. Confirm source freshness and the mapping of source scenarios 1/2/3 before operational use. Populate `ecl_cfg.PoolName.SEGMENT` with values that exactly match source `SEGMENT_LV2`.
