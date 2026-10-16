/*
Selective-run scope regression tests.
Prerequisite: migrations 001..004 deployed to a disposable SQL Server 2022 database.
Uses synthetic inputs only. No ECL formulas or outputs are generated.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @PROCESS_DATE date = '20261016';
DECLARE @WEIGHT_VERSION int = 2147482992;
DECLARE @RUN_VALID bigint;
DECLARE @RUN_INVALID bigint;
DECLARE @EXPECTED_ERROR int;
DECLARE @STATUS varchar(20);
DECLARE @SCOPE_FINDINGS int;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, N'Selective scope synthetic regression', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
           (@WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    /* Positive case: every active account matches both requested product and pool. */
    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'SELECTIVE',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'SELECTIVE-SCOPE-PASS',
        @REQUESTED_PRODUCT_TYPE = 'MORTGAGE', @REQUESTED_POOL_ID = 'POOL-A',
        @RUN_ID = @RUN_VALID OUTPUT;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_VALID, 'VALIDATING', N'Selective scope positive case';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE, STAGE, POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 'SYN-CUST-SCOPE-OK', 'MORTGAGE', 1, 'POOL-A', '20271016', 1, 1, 0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 'DOWNTURN', 1, 0.03, 1, 1),
           (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 'BASE',     1, 0.02, 1, 1),
           (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 'UPTURN',   1, 0.01, 1, 1);
    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 1, 0.4, 1, 1);
    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_VALID, @PROCESS_DATE, 'SYN-SCOPE-OK', 1, 1000000, 'VND', 1, 1);
    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_VALID, @PROCESS_DATE, 1, 0.05, 'OTHER', 1, 1);

    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'PD', 'TEST', 'synthetic.pd', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_VALID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_VALID;
    EXEC ecl_core.usp_ValidateRunInputs @RUN_VALID;

    IF EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_VALID AND VALIDATION_CODE = 'RUN_SCOPE_MISMATCH')
        THROW 52300, 'Valid selective-run account was incorrectly flagged out of scope.', 1;
    IF EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_VALID AND SEVERITY IN ('ERROR','FATAL'))
        THROW 52301, 'Valid selective-run fixture unexpectedly has ERROR/FATAL findings.', 1;

    /* Negative case: one product mismatch and one pool mismatch must both be flagged. */
    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE, @RUN_TYPE = 'SELECTIVE',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'SELECTIVE-SCOPE-BLOCK',
        @REQUESTED_PRODUCT_TYPE = 'MORTGAGE', @REQUESTED_POOL_ID = 'POOL-A',
        @RUN_ID = @RUN_INVALID OUTPUT;
    EXEC ecl_core.usp_TransitionRunStatus @RUN_INVALID, 'VALIDATING', N'Selective scope negative case';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE, STAGE, POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES (@RUN_INVALID, @PROCESS_DATE, 'SYN-SCOPE-IN', 'SYN-CUST-IN', 'MORTGAGE', 1, 'POOL-A', '20271016', 1, 1, 0),
           (@RUN_INVALID, @PROCESS_DATE, 'SYN-SCOPE-BAD-PROD', 'SYN-CUST-BAD-PROD', 'AUTO', 1, 'POOL-A', '20271016', 1, 1, 0),
           (@RUN_INVALID, @PROCESS_DATE, 'SYN-SCOPE-BAD-POOL', 'SYN-CUST-BAD-POOL', 'MORTGAGE', 1, 'POOL-B', '20271016', 1, 1, 0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    SELECT @RUN_INVALID, @PROCESS_DATE, a.ACCOUNT_ID, s.SCENARIO_CODE, 1,
           CASE s.SCENARIO_CODE WHEN 'DOWNTURN' THEN 0.03 WHEN 'BASE' THEN 0.02 ELSE 0.01 END, 1, 1
    FROM (VALUES ('SYN-SCOPE-IN'), ('SYN-SCOPE-BAD-PROD'), ('SYN-SCOPE-BAD-POOL')) a(ACCOUNT_ID)
    CROSS JOIN (VALUES ('DOWNTURN'), ('BASE'), ('UPTURN')) s(SCENARIO_CODE);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    SELECT @RUN_INVALID, @PROCESS_DATE, ACCOUNT_ID, 1, 0.4, 1, 1
    FROM (VALUES ('SYN-SCOPE-IN'), ('SYN-SCOPE-BAD-PROD'), ('SYN-SCOPE-BAD-POOL')) a(ACCOUNT_ID);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    SELECT @RUN_INVALID, @PROCESS_DATE, ACCOUNT_ID, 1, 1000000, 'VND', 1, 1
    FROM (VALUES ('SYN-SCOPE-IN'), ('SYN-SCOPE-BAD-PROD'), ('SYN-SCOPE-BAD-POOL')) a(ACCOUNT_ID);

    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES (@RUN_INVALID, @PROCESS_DATE, 1, 0.05, 'OTHER', 1, 1);

    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'PD', 'TEST', 'synthetic.pd', 'v1', 9, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_INVALID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_INVALID;
    EXEC ecl_core.usp_ValidateRunInputs @RUN_INVALID;

    SELECT @SCOPE_FINDINGS = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_INVALID AND VALIDATION_CODE = 'RUN_SCOPE_MISMATCH' AND SEVERITY = 'FATAL';
    IF @SCOPE_FINDINGS <> 2
        THROW 52302, 'Expected exactly two selective scope findings: product mismatch and pool mismatch.', 1;

    /* Commit fixtures before invoking a guarded procedure that rolls back its own transaction on rejection. */
    COMMIT TRANSACTION;

    SET @EXPECTED_ERROR = NULL;
    BEGIN TRY
        EXEC ecl_core.usp_TransitionRunStatus @RUN_INVALID, 'CALCULATING', N'Scope violations must block calculation';
    END TRY
    BEGIN CATCH
        SET @EXPECTED_ERROR = ERROR_NUMBER();
    END CATCH;
    IF @EXPECTED_ERROR <> 51035
        THROW 52303, 'Selective run with out-of-scope accounts was not blocked from CALCULATING.', 1;

    SELECT @STATUS = RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID = @RUN_INVALID;
    IF @STATUS <> 'VALIDATING'
        THROW 52304, 'Rejected selective-run calculation changed lifecycle status.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID IN (@RUN_VALID, @RUN_INVALID))
       OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID IN (@RUN_VALID, @RUN_INVALID))
       OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID IN (@RUN_VALID, @RUN_INVALID))
        THROW 52305, 'Selective-run scope tests must not generate ECL output rows.', 1;

    PRINT 'PASS: valid product/pool selective scope is accepted; product and pool mismatches are flagged and block calculation; no ECL outputs.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
