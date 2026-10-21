/*
Targeted synthetic regression tests for scenario-weight validation and EIR boundary.
Prerequisite: migrations 001..004 deployed to a disposable database.
No ECL formulas are run; all inserted rows are rolled back.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482997;
DECLARE @WEIGHT_ERRORS_BEFORE int, @EIR_ERRORS_BEFORE int;
DECLARE @WEIGHT_ERRORS_AFTER int, @EIR_ERRORS_AFTER int;
DECLARE @STATUS varchar(20);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Input regression test only', @PROCESS_DATE, @PROCESS_DATE, 0);

    /* Three active scenarios, deliberately invalid total: 0.60 instead of 1.00. */
    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.10000000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'BASE',     0.20000000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.30000000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'INPUT-REGRESSION',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic regression test for scenario weights and EIR boundary';

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE, POOL_ID,
         MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-REGRESSION-001', NULL, 'RETAIL_LN_MORTGAGE', 1, 'POOL-REG',
         '20271015', 1, 1, 0);

    /* EIR = -1 is the exact invalid boundary for DF(t)=1/(1+EIR(t))^t. */
    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 1, -1.000000000000, 'OTHER', 1, 1);

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'SCENARIO_WEIGHTS_INVALID' AND SEVERITY = 'FATAL')
        THROW 51701, 'Expected invalid scenario-weight total to be rejected.', 1;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'EIR_OUT_OF_RANGE' AND SEVERITY = 'FATAL')
        THROW 51702, 'Expected EIR = -1 boundary to be rejected.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
        THROW 51703, 'Input validation must not produce ECL detail rows.', 1;

    SELECT @WEIGHT_ERRORS_BEFORE = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'SCENARIO_WEIGHTS_INVALID';

    SELECT @EIR_ERRORS_BEFORE = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'EIR_OUT_OF_RANGE';

    /* Re-running validation on unchanged inputs must not duplicate these findings. */
    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    SELECT @WEIGHT_ERRORS_AFTER = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'SCENARIO_WEIGHTS_INVALID';

    SELECT @EIR_ERRORS_AFTER = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'EIR_OUT_OF_RANGE';

    IF @WEIGHT_ERRORS_BEFORE <> @WEIGHT_ERRORS_AFTER
        THROW 51704, 'Repeated validation duplicated scenario-weight findings.', 1;

    IF @EIR_ERRORS_BEFORE <> @EIR_ERRORS_AFTER
        THROW 51705, 'Repeated validation duplicated EIR range findings.', 1;

    SELECT TOP (1) @STATUS = EVENT_STATUS
    FROM ecl_audit.RunEvent
    WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_VALIDATION'
    ORDER BY EVENT_ID DESC;

    IF @STATUS <> 'FAILED'
        THROW 51706, 'Expected input validation to remain failed.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: invalid scenario-weight total, EIR=-1 boundary, no ECL output, and finding idempotence.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
