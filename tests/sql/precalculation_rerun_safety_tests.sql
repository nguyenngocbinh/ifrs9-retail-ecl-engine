/*
Pre-calculation replay safety regression.
Prerequisite: migrations 001..004 deployed to a disposable SQL Server 2022 database.
Repeats successful input validation and input reconciliation for the same RUN_ID.
As no ECL calculation procedure exists yet, this does not claim result-level calculation idempotency.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261016';
DECLARE @WEIGHT_VERSION int = 2147482995;
DECLARE @FINDINGS_FIRST int;
DECLARE @FINDINGS_SECOND int;
DECLARE @MANIFEST_ITEMS_FIRST int;
DECLARE @MANIFEST_ITEMS_SECOND int;
DECLARE @STATUS varchar(20);
DECLARE @INPUT_RECON_EVENTS int;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Pre-calculation replay safety synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

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
        @CALCULATION_VERSION = 'PRECALC-RERUN-SAFETY',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Pre-calculation replay safety regression';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 'SYN-CUST-RERUN-001', 'RETAIL_LN_MORTGAGE', 1,
         'POOL-RERUN', '20271016', 1, 1, 0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 'DOWNTURN', 1, 0.030000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 'BASE',     1, 0.020000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 'UPTURN',   1, 0.010000000000, 1, 1);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 1, 0.400000000000, 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_ID, @PROCESS_DATE, 'SYN-RERUN-001', 1, 100000000.0000, 'VND', 1, 1);

    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_ID, @PROCESS_DATE, 1, 0.050000000000, 'OTHER', 1, 1);

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;
    EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID;

    IF EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL')
    )
        THROW 52100, 'First successful input validation/reconciliation unexpectedly produced ERROR/FATAL findings.', 1;

    SELECT @FINDINGS_FIRST = COUNT(*)
    FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID;
    SELECT @MANIFEST_ITEMS_FIRST = COUNT(*)
    FROM ecl_core.RunInputManifestItem WHERE RUN_ID = @RUN_ID;
    SELECT @INPUT_RECON_EVENTS = COUNT(*)
    FROM ecl_audit.RunEvent WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_RECONCILIATION';

    IF @MANIFEST_ITEMS_FIRST <> 6 OR @INPUT_RECON_EVENTS <> 1
        THROW 52101, 'Expected six immutable manifest items and one input-reconciliation event after the first pass.', 1;

    /* Replay both idempotent pre-calculation gates on the same RUN_ID. */
    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;
    EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID;

    SELECT @FINDINGS_SECOND = COUNT(*)
    FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID;
    SELECT @MANIFEST_ITEMS_SECOND = COUNT(*)
    FROM ecl_core.RunInputManifestItem WHERE RUN_ID = @RUN_ID;
    SELECT @INPUT_RECON_EVENTS = COUNT(*)
    FROM ecl_audit.RunEvent WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'INPUT_RECONCILIATION';

    IF @FINDINGS_SECOND <> @FINDINGS_FIRST
        THROW 52102, 'Replaying successful validation/reconciliation changed the validation-finding count.', 1;

    IF @MANIFEST_ITEMS_SECOND <> @MANIFEST_ITEMS_FIRST
        THROW 52103, 'Replaying validation/reconciliation changed the sealed manifest.', 1;

    IF @INPUT_RECON_EVENTS <> 2
        THROW 52104, 'Each reconciliation attempt should be represented by exactly one audit event.', 1;

    SELECT @STATUS = RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;
    IF @STATUS <> 'VALIDATING'
        THROW 52105, 'Pre-calculation replay unexpectedly changed the run lifecycle status.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
       OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID)
       OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID = @RUN_ID)
        THROW 52106, 'Pre-calculation replay must not create ECL output rows.', 1;

    IF EXISTS
    (
        SELECT 1 FROM ecl_audit.RunEvent
        WHERE RUN_ID = @RUN_ID AND EVENT_TYPE IN ('RECONCILIATION','PUBLICATION')
    )
        THROW 52107, 'Input reconciliation must not create final calculation/publication milestones.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: same-run pre-calculation replay preserves findings, sealed manifest, lifecycle state, and empty ECL outputs; each reconciliation attempt is audited.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
