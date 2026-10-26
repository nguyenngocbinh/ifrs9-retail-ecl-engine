/*
Synthetic regression test for ecl_core.usp_LoadEADCurve.
Requires migrations 001..006. All test data is rolled back.
ETL writes annual EAD directly to ecl_stg.EADCurve; the procedure validates it.
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
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, 1);

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
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-AUTO-001', NULL, 'RETAIL_LN_AUTO', 2,
         'POOL-AUTO', '20271015', 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001', NULL, 'RETAIL_LN_CONS_UNSEC', 2,
         'POOL-PL', '20281015', 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-AUTO-001', 1, 90000000, 'VND', 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001',   1, 50000000, 'VND', 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-EAD-PL-001',   2, 25000000, 'VND', 1, 1);

    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;

    SELECT @ROWS = COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;
    IF @ROWS <> 3
        THROW 51690, 'EAD loader should validate all three annual rows already loaded into EADCurve.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-EAD-AUTO-001'
          AND FORECAST_PERIOD = 1 AND EAD = 90000000 AND CURRENCY_CODE = 'VND'
          AND VERSION_ID = 1 AND IS_ACTIVE = 1
    )
        THROW 51691, 'Auto EAD row should remain in canonical EADCurve after validation.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-EAD-PL-001'
          AND FORECAST_PERIOD = 2 AND EAD = 25000000
    )
        THROW 51692, 'Non-Revolving Personal Loan period-2 EAD row should remain in canonical EADCurve.', 1;

    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;
    SELECT @ROWS = COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID;
    IF @ROWS <> 3
        THROW 51693, 'Repeated EAD load validation must not duplicate canonical rows.', 1;

    IF (SELECT COUNT_BIG(*) FROM ecl_audit.RunEvent WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'EAD_LOAD' AND EVENT_STATUS = 'SUCCEEDED') <> 2
        THROW 51694, 'Each successful EAD validation call should be recorded in the run audit.', 1;

    /*
      Regression: an account matured before PROCESS_DATE must provide exactly
      the designated period-1 EAD for post-maturity processing.
    */
    DECLARE @STAGE3_ACCOUNT varchar(100) = 'SYN-EAD-STAGE3-001';
    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, @STAGE3_ACCOUNT, NULL, 'RETAIL_LN_CONS_UNSEC', 3,
         'POOL-PL', '20261001', 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_ID, @PROCESS_DATE, @STAGE3_ACCOUNT, 1, 40000000, 'VND', 1, 1);

    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'EAD_LOAD' AND EVENT_STATUS = 'SUCCEEDED'
    )
        THROW 51695, 'Matured Stage 3 account with period-1 EAD should be accepted by EAD loader.', 1;

    /*
      Regression: Stage 1 with maturity later in the same calendar month must
      still require and accept period-1 EAD coverage.
    */
    DECLARE @STAGE12_ACCOUNT varchar(100) = 'SYN-EAD-STAGE12-SUBYEAR-001';
    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, @STAGE12_ACCOUNT, NULL, 'RETAIL_LN_CONS_UNSEC', 1,
         'POOL-PL', '20261020', 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_ID, @PROCESS_DATE, @STAGE12_ACCOUNT, 1, 30000000, 'VND', 1, 1);

    EXEC ecl_core.usp_LoadEADCurve @RUN_ID = @RUN_ID;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'EAD_LOAD' AND EVENT_STATUS = 'SUCCEEDED'
    )
        THROW 51696, 'Stage 1 account with future maturity and period-1 EAD should be accepted.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: EAD loader accepts horizon below one for Stage 1 and Stage 3.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
