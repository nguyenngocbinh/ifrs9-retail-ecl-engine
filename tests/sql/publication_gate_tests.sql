/*
Publication gate regression tests.
Prerequisite: migrations 001..004 deployed to a disposable SQL Server 2022 database.
These tests intentionally commit synthetic lifecycle fixtures before invoking a rejected
transition, so they can prove that the run status remains unchanged after the gate rejects it.
The CI database is isolated and disposable. No ECL calculation/publication procedure exists yet;
this tests lifecycle gating, not transaction atomicity of a future output writer.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @PROCESS_DATE date = '20261016';
DECLARE @WEIGHT_VERSION int = 2147482993;
DECLARE @RUN_RECON bigint;
DECLARE @RUN_PUBLISH bigint;
DECLARE @EXPECTED_ERROR int;
DECLARE @STATUS varchar(20);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Publication gate synthetic regression', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    /* Case 1: a later FAILED reconciliation must override an earlier SUCCEEDED event. */
    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'PUB-GATE-RECON', @RUN_ID = @RUN_RECON OUTPUT;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_RECON, 'VALIDATING', N'Publication gate regression';
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_RECON, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_RECON;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_RECON, 'CALCULATING', N'Fixture for failed reconciliation gate';
    EXEC ecl_core.usp_RecordRunMilestone @RUN_RECON, 'RECONCILIATION', 'SUCCEEDED', N'Initial synthetic success', 0, 0;
    EXEC ecl_core.usp_RecordRunMilestone @RUN_RECON, 'RECONCILIATION', 'FAILED', N'Latest reconciliation intentionally failed', 0, 0;

    COMMIT TRANSACTION;

    SET @EXPECTED_ERROR = NULL;
    BEGIN TRY
        EXEC ecl_core.usp_TransitionRunStatus @RUN_RECON, 'SUCCEEDED', N'Must be blocked by latest failed reconciliation';
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
    END CATCH;
    IF @EXPECTED_ERROR <> 51036
        THROW 52200, 'A run with latest FAILED reconciliation was not blocked from SUCCEEDED with error 51036.', 1;

    SELECT @STATUS = RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID = @RUN_RECON;
    IF @STATUS <> 'CALCULATING'
        THROW 52201, 'Rejected reconciliation gate changed run status; expected CALCULATING.', 1;

    SET @EXPECTED_ERROR = NULL;
    BEGIN TRY
        EXEC ecl_core.usp_RecordRunMilestone @RUN_RECON, 'PUBLICATION', 'SUCCEEDED', N'Must be blocked before SUCCEEDED', 0, 0;
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
    END CATCH;
    IF @EXPECTED_ERROR <> 51045
        THROW 52202, 'Publication milestone was accepted while run was CALCULATING; expected error 51045.', 1;

    /* Case 2: a FAILED publication milestone must block transition to PUBLISHED. */
    BEGIN TRANSACTION;
    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'PUB-GATE-PUBLISH', @RUN_ID = @RUN_PUBLISH OUTPUT;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_PUBLISH, 'VALIDATING', N'Publication gate regression';
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'PD', 'TEST', 'synthetic.pd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'EAD', 'TEST', 'synthetic.ead', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'EIR', 'TEST', 'synthetic.eir', 'v1', 0, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_PUBLISH, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_PUBLISH;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_PUBLISH, 'CALCULATING', N'Fixture for failed publication gate';
    EXEC ecl_core.usp_RecordRunMilestone @RUN_PUBLISH, 'RECONCILIATION', 'SUCCEEDED', N'Synthetic reconciliation success', 0, 0;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_PUBLISH, 'SUCCEEDED', N'Fixture for publication gate';
    EXEC ecl_core.usp_RecordRunMilestone @RUN_PUBLISH, 'PUBLICATION', 'FAILED', N'Publication intentionally failed', 0, 0;
    COMMIT TRANSACTION;

    SET @EXPECTED_ERROR = NULL;
    BEGIN TRY
        EXEC ecl_core.usp_TransitionRunStatus @RUN_PUBLISH, 'PUBLISHED', N'Must be blocked by failed publication';
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
    END CATCH;
    IF @EXPECTED_ERROR <> 51037
        THROW 52203, 'A run with latest FAILED publication was not blocked from PUBLISHED with error 51037.', 1;

    SELECT @STATUS = RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID = @RUN_PUBLISH;
    IF @STATUS <> 'SUCCEEDED'
        THROW 52204, 'Rejected publication gate changed run status; expected SUCCEEDED.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID IN (@RUN_RECON, @RUN_PUBLISH))
       OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID IN (@RUN_RECON, @RUN_PUBLISH))
       OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID IN (@RUN_RECON, @RUN_PUBLISH))
        THROW 52205, 'Lifecycle gate regression unexpectedly found ECL output rows.', 1;

    PRINT 'PASS: latest failed reconciliation blocks SUCCEEDED; premature publication milestone is rejected; failed publication blocks PUBLISHED; rejected transitions preserve status and no ECL outputs exist.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
