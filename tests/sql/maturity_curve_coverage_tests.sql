/*
Synthetic boundary regression for maturity horizon and curve coverage.
Prerequisite: migrations 001..004 deployed to a disposable database.
All test rows and audit findings are rolled back; no ECL formulas are run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20261015';
DECLARE @WEIGHT_VERSION int = 2147482998;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Maturity boundary regression only', @PROCESS_DATE, @PROCESS_DATE, 0);

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
        @CALCULATION_VERSION = 'MATURITY-COVERAGE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic boundary test: exact 12 months versus 12 months plus one day';

    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'ACCOUNT', 'TEST', 'synthetic.account', 'v1', 2, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'PD', 'TEST', 'synthetic.pd', 'v1', 6, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'LGD', 'TEST', 'synthetic.lgd', 'v1', 2, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EAD', 'TEST', 'synthetic.ead', 'v1', 2, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'EIR', 'TEST', 'synthetic.eir', 'v1', 1, 1, NULL;
    EXEC ecl_core.usp_RegisterRunInput @RUN_ID, 'SCENARIO_WEIGHT', 'TEST', 'synthetic.weights', 'v1', 3, 1, NULL;
    EXEC ecl_core.usp_SealRunInputs @RUN_ID;

    /*
      Account A matures exactly 12 months after PROCESS_DATE => horizon 1.
      Account B matures 12 months + 1 day after PROCESS_DATE => horizon 2.
      Only period 1 is supplied for both; period 2 must be required only for B.
    */
    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE, POOL_ID,
         MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', NULL, 'RETAIL_LN_MORTGAGE', 1, 'POOL-MAT',
         '20271015', 1, 1, 0),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', NULL, 'RETAIL_LN_AUTO', 2, 'POOL-MAT',
         '20271016', 1, 1, 0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', 'DOWNTURN', 1, 0.020000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', 'BASE',     1, 0.010000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', 'UPTURN',   1, 0.005000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', 'DOWNTURN', 1, 0.020000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', 'BASE',     1, 0.010000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', 'UPTURN',   1, 0.005000000000, 1, 1);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', 1, 0.400000000000, 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', 1, 0.400000000000, 1, 1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M', 1, 100000.0000, 'VND', 1, 1),
        (@RUN_ID, @PROCESS_DATE, 'SYN-MATURITY-12M-1D', 1, 200000.0000, 'VND', 1, 1);

    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 1, 0.050000000000, 'OTHER', 1, 1);

    EXEC ecl_core.usp_ValidateRunInputs @RUN_ID;

    IF EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-MATURITY-12M'
          AND FORECAST_PERIOD = 2
          AND VALIDATION_CODE IN ('PD_COVERAGE_MISSING', 'CURVE_COVERAGE_MISSING')
    )
        THROW 51901, 'Exact 12-month maturity must not require period 2 curves.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-MATURITY-12M-1D'
          AND SCENARIO_CODE = 'DOWNTURN' AND FORECAST_PERIOD = 2
          AND VALIDATION_CODE = 'PD_COVERAGE_MISSING'
    )
        THROW 51902, 'Maturity at 12 months + 1 day must require period 2 PD coverage.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-MATURITY-12M-1D'
          AND FORECAST_PERIOD = 2 AND VALIDATION_CODE = 'CURVE_COVERAGE_MISSING'
          AND ERROR_MESSAGE LIKE N'Missing or inactive LGD curve%'
    )
        THROW 51903, 'Maturity at 12 months + 1 day must require period 2 LGD coverage.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-MATURITY-12M-1D'
          AND FORECAST_PERIOD = 2 AND VALIDATION_CODE = 'CURVE_COVERAGE_MISSING'
          AND ERROR_MESSAGE LIKE N'Missing or inactive EAD curve%'
    )
        THROW 51904, 'Maturity at 12 months + 1 day must require period 2 EAD coverage.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND FORECAST_PERIOD = 2
          AND VALIDATION_CODE = 'EIR_COVERAGE_MISSING'
    )
        THROW 51905, 'A two-period horizon must require shared EIR period 2.', 1;

    IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
        THROW 51906, 'Input validation must not produce ECL detail rows.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: maturity boundary at 12 months/12 months+1 day and PD/LGD/EAD/EIR period-2 coverage.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
