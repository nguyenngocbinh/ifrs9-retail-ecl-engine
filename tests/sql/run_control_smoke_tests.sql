/*
Run-control smoke tests for SQL Server 2016.
Prerequisite: deploy database/001_create_logical_schema.sql and database/002_run_control.sql
to a disposable database. All table changes are rolled back; identity counters may advance.
This tests lifecycle plumbing only, not ECL calculations or production concurrency.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @TEST_WEIGHT_VERSION int = 2147483000;
DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @EXPECTED_ERROR int;
DECLARE @EXPECTED_ERROR_MESSAGE nvarchar(2048);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@TEST_WEIGHT_VERSION, N'Smoke test only', @PROCESS_DATE, @PROCESS_DATE, 0);

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
        @CALCULATION_VERSION = 'SMOKE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    IF @RUN_ID IS NULL THROW 51100, 'Expected RUN_ID from usp_CreateRun.', 1;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING', @EVENT_MESSAGE = N'Smoke test';

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;

    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    SET @EXPECTED_ERROR = NULL;
    SET @EXPECTED_ERROR_MESSAGE = NULL;
    BEGIN TRY
        UPDATE ecl_core.RunInputManifestItem
        SET SOURCE_VERSION = 'tampered'
        WHERE RUN_ID = @RUN_ID AND INPUT_FAMILY = 'ACCOUNT';
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
        SET @EXPECTED_ERROR_MESSAGE = ERROR_MESSAGE();
    END CATCH;
    IF @EXPECTED_ERROR_MESSAGE <> 'Input manifest items are immutable after the manifest is sealed.'
        THROW 51103, 'Sealed manifest item mutation was not rejected with the expected message.', 1;
    IF XACT_STATE() <> 1
        THROW 51104, 'Rejected manifest mutation left the caller transaction uncommittable.', 1;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'CALCULATING', @EVENT_MESSAGE = N'Smoke test';

    EXEC ecl_core.usp_RecordRunMilestone
        @RUN_ID = @RUN_ID, @MILESTONE = 'RECONCILIATION', @MILESTONE_STATUS = 'SUCCEEDED',
        @EVENT_MESSAGE = N'Synthetic smoke test reconciliation', @ROW_COUNT = 0, @AMOUNT_VALUE = 0;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'SUCCEEDED', @EVENT_MESSAGE = N'Smoke test';

    EXEC ecl_core.usp_RecordRunMilestone
        @RUN_ID = @RUN_ID, @MILESTONE = 'PUBLICATION', @MILESTONE_STATUS = 'SUCCEEDED',
        @EVENT_MESSAGE = N'Synthetic smoke test publication', @ROW_COUNT = 0, @AMOUNT_VALUE = 0;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'PUBLISHED', @EVENT_MESSAGE = N'Smoke test';

    IF NOT EXISTS (
        SELECT 1 FROM ecl_core.RunControl
        WHERE RUN_ID = @RUN_ID AND RUN_STATUS = 'PUBLISHED'
    ) THROW 51101, 'Expected run to reach PUBLISHED.', 1;

    SET @EXPECTED_ERROR = NULL;
    BEGIN TRY
        EXEC ecl_core.usp_TransitionRunStatus
            @RUN_ID = @RUN_ID, @NEW_STATUS = 'CALCULATING', @EVENT_MESSAGE = N'Illegal transition test';
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
    END CATCH;

    IF @EXPECTED_ERROR <> 51033
        THROW 51102, 'Illegal transition from PUBLISHED was not rejected with error 51033.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: run creation, manifest registration/sealing, sealed-item immutability, guarded lifecycle, reconciliation/publication gates, and terminal-state rejection.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
