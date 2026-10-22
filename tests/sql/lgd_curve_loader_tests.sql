/*
Synthetic regression test for ecl_core.usp_LoadLGDCurve.
Requires migrations 001..008. All test data is rolled back.
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
    VALUES (@WEIGHT_VERSION, N'LGD loader synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'BASE', 0.68640000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'UPTURN', 0.15680000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'LGD-LOADER-TEST', @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic shared LGD loader test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-LGD-A-001', NULL, 'RETAIL_LN_AUTO', 2,
         'POOL-AUTO', '20281015', 7, 1);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-LGD-A-001', 1, 0.130000000000, 7, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-LGD-A-001', 2, 0.130000000000, 7, 1);

    EXEC ecl_core.usp_LoadLGDCurve @RUN_ID = @RUN_ID;

    SELECT @ROWS = COUNT_BIG(*)
    FROM ecl_stg.LGDCurve
    WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

    IF @ROWS <> 2
        THROW 51890, 'LGD loader should validate the two annual account-level rows.', 1;

    EXEC ecl_core.usp_LoadLGDCurve @RUN_ID = @RUN_ID;

    IF (SELECT COUNT_BIG(*) FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'LGD_LOAD' AND EVENT_STATUS = 'SUCCEEDED') <> 2
        THROW 51891, 'Each successful LGD validation should be recorded in run audit.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: shared LGD loader validates annual account-level LGD rows and records audit events.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
