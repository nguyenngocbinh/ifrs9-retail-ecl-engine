/*
Synthetic reconciliation tests. Execute on disposable DB after migrations 001..004.
All changes rolled back; no ECL result generation.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @RUN_ID bigint, @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482998;
DECLARE @EXPECTED_FAILURE int, @MATCHED int;
BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, N'Reconciliation synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'BASE', 0.68640000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'UPTURN', 0.15680000, @PROCESS_DATE, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'RECON-TEST', @RUN_ID = @RUN_ID OUTPUT;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_ID, 'VALIDATING';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, PRODUCT_TYPE, STAGE, POOL_ID,
         MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-RECON-001', 'MORTGAGE', 1, 'POOL-A',
         '20281015', 1, 1, 0),
        (@RUN_ID, @PROCESS_DATE, 'SYN-RECON-002', 'AUTO', 2, 'POOL-B',
         '20271015', 1, 1, 1);

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'MANIFEST_COUNT_MISMATCH' AND SEVERITY = 'ERROR')
        THROW 51601, 'Expected manifest/account count mismatch.', 1;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'POCI_RECON_BLOCKED' AND SEVERITY = 'ERROR')
        THROW 51602, 'Expected detected POCI to block calculation.', 1;

    IF NOT EXISTS
       (SELECT 1 FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_RECONCILIATION' AND EVENT_STATUS = 'FAILED')
        THROW 51603, 'Expected failed input reconciliation event.', 1;

    IF EXISTS
       (SELECT 1 FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'RECONCILIATION' AND EVENT_STATUS = 'SUCCEEDED')
        THROW 51604, 'Input reconciliation must not authorize final ECL reconciliation.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
        THROW 51605, 'Input reconciliation must not calculate ECL.', 1;

    /* Test idempotent finding count for rerun of unchanged inputs. */
    SELECT @EXPECTED_FAILURE = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'MANIFEST_COUNT_MISMATCH';
    EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID;
    SELECT @MATCHED = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'MANIFEST_COUNT_MISMATCH';
    IF @EXPECTED_FAILURE <> @MATCHED
        THROW 51606, 'Repeated input reconciliation duplicated count-mismatch findings.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: manifest mismatch, POCI blocking, no publication gate bypass, and repeat finding idempotence.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
