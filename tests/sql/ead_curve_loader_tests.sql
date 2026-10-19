/*
Synthetic regression test for ecl_core.usp_LoadEADCurve.
Requires migrations 001..006. All test data is rolled back.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482901;
DECLARE @ROWS bigint;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'EAD loader synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'EAD-LOADER-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic shared EAD loader test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-AUTO-001', NULL, 'AUTO', 2,
         'POOL-AUTO', '20271015', 1, 1, 0),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001', NULL, 'PERSONALLOAN', 2,
         'POOL-PL', '20281015', 1, 1, 0);

    INSERT INTO ecl_stg.EADCurveInput
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE, SOURCE_REFERENCE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-AUTO-001', 1, 90000000, 'VND', 1, 1, N'synthetic auto source'),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001',   1, 50000000, 'VND', 1, 1, N'synthetic PL source'),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001',   2, 25000000, 'VND', 1, 1, N'synthetic PL source');

    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;

    SELECT @ROWS = COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID;
    IF @ROWS <> 3
        THROW 51690, 'EAD loader should promote all three annual input rows.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-EAD-AUTO-001'
          AND FORECAST_PERIOD = 1 AND EAD = 90000000 AND CURRENCY_CODE = 'VND'
          AND VERSION_ID = 1 AND IS_ACTIVE = 1
    )
        THROW 51691, 'Auto EAD row was not promoted with its canonical values.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-EAD-PL-001'
          AND FORECAST_PERIOD = 2 AND EAD = 25000000
    )
        THROW 51692, 'Non-Revolving Personal Loan period-2 EAD row was not promoted.', 1;

    /* A second call must replace the run's canonical rows, not duplicate them. */
    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;
    SELECT @ROWS = COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID;
    IF @ROWS <> 3
        THROW 51693, 'Repeated EAD load should remain idempotent for the same run.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: shared EAD loader promotes Auto and Non-Revolving synthetic curves, and supports reruns.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
