/*
SQL Server 2022 regression test for the FTP 12-month EIR source loader.
Prerequisites: migrations 001-009 deployed.
The loader reads [CORE].[dbo].[rb_ftp_bv_12m] directly. If that source is not
available in the CI database instance, the source-integration test is skipped.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[CORE].[dbo].[rb_ftp_bv_12m]', N'U') IS NULL
BEGIN
    PRINT 'SKIP: EIR source integration test requires [CORE].[dbo].[rb_ftp_bv_12m] on this SQL Server instance.';
    RETURN;
END;
GO

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20260930';
DECLARE @WEIGHT_VERSION int = 2147482995;
DECLARE @SOURCE_ROWS int;
DECLARE @RATE decimal(19,12);
DECLARE @EXPECTED_RATE decimal(19,12);
DECLARE @STATUS varchar(20);

SELECT TOP (1) @EXPECTED_RATE = TRY_CONVERT(decimal(19,12), ftp_bv)
FROM [CORE].[dbo].[rb_ftp_bv_12m]
WHERE ccy = 'VND'
  AND process_date <= @PROCESS_DATE
ORDER BY process_date DESC;

IF @EXPECTED_RATE IS NULL OR @EXPECTED_RATE <= -1
    THROW 52700, 'EIR source integration test requires a valid VND FTP rate on or before 2026-09-30.', 1;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (2147482995, N'EIR source-loader integration test', '20260930', '20260930', 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, IS_ACTIVE)
    VALUES
        (2147482995, 'DOWNTURN', 0.15680000, 1),
        (2147482995, 'BASE',     0.68640000, 1),
        (2147482995, 'UPTURN',   0.15680000, 1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = '20260930',
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = 2147482995,
        @CALCULATION_VERSION = 'EIR-SOURCE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'FTP 12-month source ETL integration test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, '20260930', 'SYN-EIR-001', 'SYN-CUST-EIR', 'RETAIL_LN_MORTGAGE', 2,
         'POOL-EIR', '20280930', 1, 1);

    EXEC ecl_core.usp_StageSourceEIRCurve @RUN_ID = @RUN_ID;
    EXEC ecl_core.usp_LoadEIRCurve @RUN_ID = @RUN_ID;

    SELECT @SOURCE_ROWS = COUNT(*)
    FROM ecl_stg.EIRCurve
    WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

    IF @SOURCE_ROWS <> 2
        THROW 52701, 'EIR source ETL should generate exactly two periods for the synthetic two-year horizon.', 1;

    SELECT @RATE = EIR
    FROM ecl_stg.EIRCurve
    WHERE RUN_ID = @RUN_ID AND FORECAST_PERIOD = 1;

    IF @RATE <> @EXPECTED_RATE
        THROW 52702, 'EIR source ETL must preserve the source ftp_bv numeric value without dividing by 100.', 1;

    SELECT @RATE = EIR
    FROM ecl_stg.EIRCurve
    WHERE RUN_ID = @RUN_ID AND FORECAST_PERIOD = 2;

    IF @RATE <> @EXPECTED_RATE
        THROW 52703, 'Both forecast periods should use the latest source rate available on or before the run process date.', 1;

    SELECT @STATUS = EVENT_STATUS
    FROM ecl_audit.RunEvent
    WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'EIR_LOAD';

    IF @STATUS <> 'SUCCEEDED'
        THROW 52704, 'EIR loader must record a successful audit event.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: EIR annual horizon, direct CORE source, source-rate preservation, and load audit.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO
