/*
Positive-path synthetic integration test for the canonical input tables.
Prerequisite: migrations 001..004 deployed to a disposable database.
Loads one account with complete one-period curves, validates and reconciles it,
asserts that no ECL is produced, and rolls back all test data.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482996;
DECLARE @VALIDATION_STATUS varchar(20);
DECLARE @RECON_STATUS varchar(20);
DECLARE @ERROR_COUNT int;
DECLARE @MATCH_COUNT int;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Canonical happy-path synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

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
        @CALCULATION_VERSION = 'CANONICAL-HAPPY-PATH',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Positive-path canonical input integration test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 'SYN-CUST-001', 'MORTGAGE', 1,
         'POOL-HAPPY', '20271015', 1, 1, 0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD,
         MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 'DOWNTURN', 1, 0.030000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 'BASE',     1, 0.020000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 'UPTURN',   1, 0.010000000000, 1, 1);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 1, 0.400000000000, 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-HAPPY-001', 1, 100000000.0000, 'VND', 1, 1);

    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 1, 0.050000000000, 'OTHER', 1, 1);

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    SELECT TOP (1) @VALIDATION_STATUS = VALIDATION_STATUS,
                   @ERROR_COUNT = ERROR_FATAL_COUNT
    FROM
    (
        SELECT CASE WHEN EXISTS
          (SELECT 1 FROM ecl_audit.ValidationError
           WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL'))
          THEN 'FAILED' ELSE 'SUCCEEDED' END AS VALIDATION_STATUS,
          (SELECT COUNT(*) FROM ecl_audit.ValidationError
           WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL')) AS ERROR_FATAL_COUNT
    ) s;

    IF @VALIDATION_STATUS <> 'SUCCEEDED' OR @ERROR_COUNT <> 0
        THROW 51801, 'Canonical happy-path input validation should succeed without ERROR/FATAL findings.', 1;

    EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID;

    SELECT @MATCH_COUNT = COUNT(*)
    FROM
    (
        SELECT INPUT_FAMILY
        FROM
        (
            SELECT 'ACCOUNT' AS INPUT_FAMILY, COUNT_BIG(*) AS ACTUAL_ROWS FROM ecl_stg.AccountSnapshot WHERE RUN_ID = @RUN_ID
            UNION ALL SELECT 'PD', COUNT_BIG(*) FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID
            UNION ALL SELECT 'LGD', COUNT_BIG(*) FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID
            UNION ALL SELECT 'EAD', COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID
            UNION ALL SELECT 'EIR', COUNT_BIG(*) FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID
            UNION ALL SELECT 'SCENARIO_WEIGHT', COUNT_BIG(*) FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID = @WEIGHT_VERSION
        ) actual
        JOIN ecl_core.RunInputManifestItem m
          ON m.RUN_ID = @RUN_ID AND m.INPUT_FAMILY = actual.INPUT_FAMILY
         AND m.IS_COMPLETE = 1 AND m.SNAPSHOT_ROW_COUNT = actual.ACTUAL_ROWS
    ) matched;

    IF @MATCH_COUNT <> 6
        THROW 51802, 'All six canonical input families should reconcile to manifest counts.', 1;

    IF EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL'))
        THROW 51803, 'Positive-path validation/reconciliation should not leave ERROR/FATAL findings.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
       OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID)
       OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID = @RUN_ID)
        THROW 51804, 'Input validation/reconciliation must not generate ECL outputs.', 1;

    SELECT @RECON_STATUS = EVENT_STATUS
    FROM ecl_audit.RunEvent
    WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_RECONCILIATION';

    IF @RECON_STATUS <> 'SUCCEEDED'
        THROW 51805, 'Expected successful input reconciliation audit event.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: canonical positive-path input load, validation, six-family manifest reconciliation, and no ECL output.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
