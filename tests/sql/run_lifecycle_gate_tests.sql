/*
Run lifecycle gate regression tests for SQL Server 2022 CI.
Prerequisite: deploy migrations 001..004 to a disposable database.
Synthetic metadata only; this test does not calculate or publish ECL.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @PROCESS_DATE date = '20261016';
DECLARE @WEIGHT_VERSION int = 2147482996;
DECLARE @RUN_ID bigint;
DECLARE @ERROR_NUMBER int;
DECLARE @RUN_STATUS varchar(20);

INSERT INTO ecl_cfg.ScenarioWeightVersion
    (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
VALUES
    (@WEIGHT_VERSION, N'Lifecycle gate regression only', @PROCESS_DATE, @PROCESS_DATE, 0);

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
    @CALCULATION_VERSION = 'LIFECYCLE-GATE-TEST',
    @RUN_ID = @RUN_ID OUTPUT;

IF @RUN_ID IS NULL THROW 51800, 'Expected a run identifier.', 1;

/* A CREATED run cannot skip directly to CALCULATING. */
SET @ERROR_NUMBER = NULL;
BEGIN TRY
    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'CALCULATING',
        @EVENT_MESSAGE = N'Expected rejection: skip validation';
END TRY
BEGIN CATCH
    SET @ERROR_NUMBER = ERROR_NUMBER();
END CATCH;

IF @ERROR_NUMBER <> 51033
    THROW 51801, 'CREATED -> CALCULATING must be rejected as an illegal transition.', 1;

SELECT @RUN_STATUS = RUN_STATUS
FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;
IF @RUN_STATUS <> 'CREATED'
    THROW 51802, 'Rejected transition changed the run status.', 1;

/* Validation can start, but calculation must remain blocked until inputs are sealed. */
EXEC ecl_core.usp_TransitionRunStatus
    @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
    @EVENT_MESSAGE = N'Lifecycle gate regression test';

SET @ERROR_NUMBER = NULL;
BEGIN TRY
    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'CALCULATING',
        @EVENT_MESSAGE = N'Expected rejection: inputs not sealed';
END TRY
BEGIN CATCH
    SET @ERROR_NUMBER = ERROR_NUMBER();
END CATCH;

IF @ERROR_NUMBER <> 51034
    THROW 51803, 'VALIDATING -> CALCULATING must be rejected when the input manifest is not sealed.', 1;

SELECT @RUN_STATUS = RUN_STATUS
FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;
IF @RUN_STATUS <> 'VALIDATING'
    THROW 51804, 'Rejected unsealed-input transition changed the run status.', 1;

IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
    THROW 51805, 'Lifecycle gate tests must not create ECL output.', 1;

PRINT 'PASS: illegal lifecycle skip and unsealed-input calculation are rejected without changing run state or producing ECL.';
