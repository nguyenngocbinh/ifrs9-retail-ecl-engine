/*
Smoke test for migration 010. Run only after migrations 001..010 on a disposable
SQL Server database. This test is metadata-only and writes no business data.
*/
SET NOCOUNT ON;

IF SCHEMA_ID(N'ecl_bt') IS NULL
    THROW 51950, 'Missing ecl_bt schema; deploy migration 010 first.', 1;

IF OBJECT_ID(N'ecl_bt.BacktestRun', N'U') IS NULL
    THROW 51951, 'Missing ecl_bt.BacktestRun.', 1;
IF OBJECT_ID(N'ecl_bt.CohortAccount', N'U') IS NULL
    THROW 51952, 'Missing ecl_bt.CohortAccount.', 1;
IF OBJECT_ID(N'ecl_bt.AccountOutcome', N'U') IS NULL
    THROW 51953, 'Missing ecl_bt.AccountOutcome.', 1;
IF OBJECT_ID(N'ecl_bt.BacktestFinding', N'U') IS NULL
    THROW 51954, 'Missing ecl_bt.BacktestFinding.', 1;
IF OBJECT_ID(N'ecl_bt.usp_Build12MonthCohort', N'P') IS NULL
    THROW 51955, 'Missing ecl_bt.usp_Build12MonthCohort.', 1;

IF COL_LENGTH(N'ecl_bt.CohortAccount', N'SOURCE_RUN_ID') IS NULL
   OR COL_LENGTH(N'ecl_bt.CohortAccount', N'FORECAST_PD_12M') IS NULL
   OR COL_LENGTH(N'ecl_bt.CohortAccount', N'IS_PD_BACKTEST_ELIGIBLE') IS NULL
    THROW 51956, 'Cohort table is missing required forecast lineage/eligibility columns.', 1;

IF COL_LENGTH(N'ecl_bt.AccountOutcome', N'DEFAULT_DATE') IS NULL
   OR COL_LENGTH(N'ecl_bt.AccountOutcome', N'OBSERVATION_END_DATE') IS NULL
   OR COL_LENGTH(N'ecl_bt.AccountOutcome', N'OUTCOME_STATUS') IS NULL
    THROW 51957, 'Outcome table is missing required default-observation fields.', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.CohortAccount')
      AND referenced_object_id = OBJECT_ID(N'ecl_result.ECLAccount')
)
    THROW 51958, 'Cohort rows must retain a foreign-key link to published account ECL output.', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.BacktestRun')
      AND name = N'CK_BT_Run_Horizon'
)
    THROW 51959, '12-month horizon constraint is missing.', 1;

PRINT 'PASS: backtest foundation objects, lineage, outcome fields, and 12-month horizon constraint exist.';
