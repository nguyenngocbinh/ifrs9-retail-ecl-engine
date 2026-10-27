/*
SQL Server 2022 regression tests for the FTP 12-month EIR source loader and validator.
Prerequisites: migrations 001-009 deployed. The test uses a disposable source fixture in the `eir_source_test` schema.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20260930';
DECLARE @SOURCE_DATABASE sysname = DB_NAME();
DECLARE @WEIGHT_VERSION int = 2147482995;
DECLARE @SOURCE_ROWS int;
DECLARE @RATE decimal(19,12);
DECLARE @STATUS varchar(20);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'EIR source-loader synthetic test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, 1);

    /* Use a unique fixture table name so the regression can run repeatedly or concurrently. */
    DECLARE @FIXTURE_TABLE sysname = CONCAT(N'rb_ftp_bv_12m_', @@SPID, N'_', RIGHT(CONVERT(varchar(36), NEWID()), 8));
    DECLARE @FIXTURE_QUALIFIED nvarchar(300) = QUOTENAME(N'eir_source_test') + N'.' + QUOTENAME(@FIXTURE_TABLE);
    IF SCHEMA_ID(N'eir_source_test') IS NULL EXEC(N'CREATE SCHEMA eir_source_test AUTHORIZATION dbo;');
    DECLARE @FixtureSql nvarchar(max) = N'CREATE TABLE eir_source_test.' + QUOTENAME(@FIXTURE_TABLE) + N'
    (
        process_date date NOT NULL,
        ftp_bv decimal(19,10) NULL,
        ccy char(3) NOT NULL
    );
    INSERT INTO eir_source_test.' + QUOTENAME(@FIXTURE_TABLE) + N'(process_date,ftp_bv,ccy)
    VALUES (''2026-09-30'',9.2000000000,''VND''),
           (''2026-08-31'',9.2000000000,''VND''),
           (''2026-05-31'',8.8000000000,''VND''),
           (''2026-09-30'',4.0000000000,''USD'');';
    EXEC sys.sp_executesql @FixtureSql;

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'EIR-SOURCE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic FTP 12-month source ETL test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, IS_POCI, CUSTOMER_ID)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-EIR-001', 'SYN-CUST-EIR', 'RETAIL_LN_MORTGAGE', 2,
         'POOL-EIR', '20280930', 1, 1, 0, 'SYN-CUST-EIR');

    EXEC ecl_core.usp_StageSourceEIRCurve
        @RUN_ID = @RUN_ID, @SOURCE_DATABASE = @SOURCE_DATABASE,
        @SOURCE_SCHEMA = N'eir_source_test', @SOURCE_TABLE = @FIXTURE_TABLE;

    EXEC ecl_core.usp_LoadEIRCurve @RUN_ID = @RUN_ID;

    SELECT @SOURCE_ROWS = COUNT(*) FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;
    IF @SOURCE_ROWS <> 2
        THROW 52701, 'EIR source ETL should generate exactly two periods for the synthetic two-year horizon.', 1;

    SELECT @RATE = EIR FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID AND FORECAST_PERIOD = 1;
    IF @RATE <> CONVERT(decimal(19,12),9.2000000000)
        THROW 52702, 'EIR source ETL must preserve the supplied ftp_bv numeric value without dividing by 100.', 1;

    SELECT @RATE = EIR FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID AND FORECAST_PERIOD = 2;
    IF @RATE <> CONVERT(decimal(19,12),9.2000000000)
        THROW 52703, 'Second forecast period should use latest source process_date not after its target date.', 1;

    SELECT @STATUS = EVENT_STATUS
    FROM ecl_audit.RunEvent
    WHERE RUN_ID = @RUN_ID AND EVENT_TYPE = 'EIR_LOAD';
    IF @STATUS <> 'SUCCEEDED'
        THROW 52704, 'EIR loader must record a successful audit event.', 1;

    ROLLBACK TRANSACTION;

    PRINT 'PASS: EIR annual horizon, FTP_12M basis, source-rate preservation, and load audit.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO
