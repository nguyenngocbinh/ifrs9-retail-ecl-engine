/*
Synthetic regression test for ecl_core.usp_LoadPDCurve.
Requires migrations 001..007. All test data is rolled back.
Source ETL inserts scenario-specific marginal PD rows into canonical PDCurve;
the shared procedure validates coverage and records the audit event.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482902;
DECLARE @ROWS bigint;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'PD loader synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'PD-LOADER-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic shared PD loader test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-AUTO-001', NULL, 'RETAIL_LN_AUTO', 2,
         'POOL-AUTO', '20271015', 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', NULL, 'RETAIL_LN_CONS_UNSEC', 1,
         'POOL-PL', '20281015', 1, 1);

    /* One-year Auto account: one row per canonical scenario. */
    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD,
         MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-AUTO-001', 'DOWNTURN', 1, 0.025000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-AUTO-001', 'BASE',     1, 0.020000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-AUTO-001', 'UPTURN',   1, 0.015000000000, 1, 1),

        /* Two-year Personal Loan account: all three scenarios in periods 1 and 2. */
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'DOWNTURN', 1, 0.035000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'BASE',     1, 0.030000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'UPTURN',   1, 0.025000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'DOWNTURN', 2, 0.040000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'BASE',     2, 0.035000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-PL-001', 'UPTURN',   2, 0.030000000000, 1, 1);

    EXEC ecl_core.usp_LoadPDCurve @RUN_ID = @RUN_ID;

    SELECT @ROWS = COUNT_BIG(*)
    FROM ecl_stg.PDCurve
    WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

    IF @ROWS <> 9
        THROW 51790, 'PD loader should validate all nine scenario-period rows already loaded into PDCurve.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-PD-AUTO-001'
          AND SCENARIO_CODE = 'BASE' AND FORECAST_PERIOD = 1
          AND MARGINAL_PD = 0.020000000000 AND VERSION_ID = 1 AND IS_ACTIVE = 1
    )
        THROW 51791, 'Canonical marginal PD values should remain unchanged after validation.', 1;

    /* Revalidation must not duplicate or rewrite canonical PD rows. */
    EXEC ecl_core.usp_LoadPDCurve @RUN_ID = @RUN_ID;

    SELECT @ROWS = COUNT_BIG(*)
    FROM ecl_stg.PDCurve
    WHERE RUN_ID = @RUN_ID;

    IF @ROWS <> 9
        THROW 51792, 'Repeated PD load validation must not duplicate canonical rows.', 1;

    IF (SELECT COUNT_BIG(*) FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'PD_LOAD' AND EVENT_STATUS = 'SUCCEEDED') <> 2
        THROW 51793, 'Each successful PD validation call should be recorded in run audit.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: shared PD loader validates canonical scenario-specific marginal PD rows and annual coverage.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
