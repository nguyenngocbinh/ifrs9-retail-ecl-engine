/*
Synthetic negative-path tests for ecl_core.usp_ValidateRunInputs.
Prerequisite: deploy migrations 001, 002, and 003 in a disposable database.
All test data and audit rows are rolled back; identity counters may advance.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TEST_WEIGHT_VERSION int = 2147482999;
DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @VALIDATION_STATUS varchar(20);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@TEST_WEIGHT_VERSION, N'Input validation test only', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@TEST_WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
        (@TEST_WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
        (@TEST_WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @TEST_WEIGHT_VERSION,
        @CALCULATION_VERSION = 'VALIDATION-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING', @EVENT_MESSAGE = N'Input validation test';

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 2, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE, POOL_ID,
         MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-VALIDATION-001', NULL, 'RETAIL_LN_MORTGAGE', 1, 'POOL-A',
         '20281015', 1, 1, 0),
        (@RUN_ID, @PROCESS_DATE, 'SYN-VALIDATION-002', NULL, 'AUTO', 2, 'POOL-B',
         '20271015', 1, 1, NULL),
        (@RUN_ID, @PROCESS_DATE, 'SYN-VALIDATION-003', NULL, 'PERSONALLOAN', 1, 'POOL-C',
         '20271015', 1, 1, 1);

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    SELECT @VALIDATION_STATUS = VALIDATION_STATUS
    FROM
    (
        SELECT TOP (1) EVENT_STATUS AS VALIDATION_STATUS
        FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_VALIDATION'
        ORDER BY EVENT_ID DESC
    ) v;

    IF @VALIDATION_STATUS <> 'FAILED'
        THROW 51400, 'Expected validation to fail when required curves and POCI classification are missing.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'PD_COVERAGE_MISSING')
        THROW 51401, 'Expected missing PD coverage finding.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'CURVE_COVERAGE_MISSING')
        THROW 51402, 'Expected missing LGD/EAD coverage finding.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'EIR_COVERAGE_MISSING')
        THROW 51403, 'Expected missing EIR coverage finding.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'POCI_CLASSIFICATION_MISSING' AND ACCOUNT_ID = 'SYN-VALIDATION-002')
        THROW 51404, 'Expected explicit POCI classification finding for the unclassified account.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'POCI_EXCLUDED' AND SEVERITY = 'ERROR' AND ACCOUNT_ID = 'SYN-VALIDATION-003')
        THROW 51406, 'Detected POCI must block calculation until explicit exclusion and reconciliation are implemented.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
        THROW 51405, 'Input validation must not produce ECL calculation detail.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: missing PD/LGD/EAD/EIR coverage, unknown POCI classification, and detected POCI are blocked; no ECL calculation is performed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
