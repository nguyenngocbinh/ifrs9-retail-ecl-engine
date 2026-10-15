/*
Synthetic test for the mandatory scenario-weight provenance gate.
Prerequisite: migrations 001..005 deployed to a disposable database.
All test changes are rolled back; no ECL formulas are executed.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482996;

BEGIN TRY
    BEGIN TRANSACTION;

    /* Structurally valid weights, intentionally lacking source/approval evidence. */
    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, N'Provenance regression test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'WEIGHT-PROVENANCE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic scenario-weight provenance gate test';

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, PRODUCT_TYPE, STAGE, POOL_ID,
         MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES (@RUN_ID, @PROCESS_DATE, 'SYN-WEIGHT-PROV-001', 'MORTGAGE', 1,
            'POOL-PROV', '20271015', 1, 1, 0);

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID
          AND VALIDATION_CODE = 'SCENARIO_WEIGHT_PROVENANCE_MISSING'
          AND SEVERITY = 'FATAL')
        THROW 51801, 'Expected missing scenario-weight provenance to block validation.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
        THROW 51802, 'Provenance validation must not create ECL detail rows.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: missing scenario-weight provenance blocks validation and produces no ECL output.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
