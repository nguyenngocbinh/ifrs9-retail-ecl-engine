/*
Integration test for ecl_core.usp_LoadRetailMarginalPITPD.
Creates isolated synthetic source rows. Uses a source PROCESS_DATE different
from the run date to verify the source-version warning and selection behavior.
All engine data is rolled back; the disposable IRB_MHRR fixture database is
created only for CI/dev testing.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_ID(N'IRB_MHRR') IS NULL
    EXEC(N'CREATE DATABASE IRB_MHRR');
GO
IF SCHEMA_ID(N'pd') IS NULL
    EXEC(N'CREATE SCHEMA pd');
GO
IF OBJECT_ID(N'[IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING]', N'U') IS NULL
BEGIN
    EXEC(N'USE IRB_MHRR;
        IF SCHEMA_ID(N''pd'') IS NULL EXEC(N''CREATE SCHEMA pd'');
        CREATE TABLE pd.TBL_MAN_FACILITY_RATING
        (
            REPORTING_DATE date NOT NULL,
            ACCOUNT_ID varchar(100) NOT NULL,
            CUSTOMER_ID varchar(100) NULL,
            RATING varchar(20) NOT NULL,
            MODEL_TYPE varchar(50) NULL,
            POOL_ID varchar(100) NULL,
            POOL_NAME varchar(100) NOT NULL,
            BUCKET nvarchar(200) NOT NULL,
            BUCKET_DESC nvarchar(200) NULL,
            PD decimal(19,12) NULL
        );');
END;
GO

DECLARE @RUN_ID bigint;
DECLARE @PROCESS_DATE date = '20260630';
DECLARE @SOURCE_PROCESS_DATE date = '20261231';
DECLARE @WEIGHT_VERSION int = 2147482901;
DECLARE @ROWS bigint;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID, VERSION_NAME, EFFECTIVE_FROM, EFFECTIVE_TO, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, N'Retail PD source test', @PROCESS_DATE, @PROCESS_DATE, 0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID, SCENARIO_CODE, SCENARIO_WEIGHT, PROCESS_DATE, IS_ACTIVE)
    VALUES
        (@WEIGHT_VERSION, 'DOWNTURN', 0.15680000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'BASE',     0.68640000, @PROCESS_DATE, 1),
        (@WEIGHT_VERSION, 'UPTURN',   0.15680000, @PROCESS_DATE, 1);

    DELETE FROM [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING]
    WHERE ACCOUNT_ID = 'SYN-PD-SOURCE-001';

    INSERT INTO [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING]
        (REPORTING_DATE, ACCOUNT_ID, CUSTOMER_ID, RATING, MODEL_TYPE,
         POOL_ID, POOL_NAME, BUCKET, BUCKET_DESC, PD)
    VALUES
        (@PROCESS_DATE, 'SYN-PD-SOURCE-001', 'SYN-CUST-001', 'AAA', 'Bscore',
         '105', 'RETAIL_CARD', N'B2A: MOB >=6 & DPD 0-9',
         N'B2A: MOB >=6 & DPD 0-9', 0.01);

    DELETE FROM dbo.RETAIL_MARGINAL_PIT_PD
    WHERE SEGMENT_LV2 = N'Credit card'
      AND BUCKET = N'B2A: MOB >=6 & DPD 0-9'
      AND RATING = 'AAA'
      AND PROCESS_DATE = @SOURCE_PROCESS_DATE;

    INSERT INTO dbo.RETAIL_MARGINAL_PIT_PD
        (PROCESS_DATE, PERIOD, SEGMENT_LV1, SEGMENT_LV2, BUCKET, RATING,
         SCENARIO, MARGINAL_PIT_PD, SUM_MPD, FINAL_MARGINAL_PIT_PD,
         MODIFY_BY, MODIFY_DATE)
    VALUES
        (@SOURCE_PROCESS_DATE, '20261231', 'RETAIL', N'Credit card', N'B2A: MOB >=6 & DPD 0-9', 'AAA', 1, 0.010, 0.010, 0.010, SUSER_SNAME(), SYSUTCDATETIME()),
        (@SOURCE_PROCESS_DATE, '20261231', 'RETAIL', N'Credit card', N'B2A: MOB >=6 & DPD 0-9', 'AAA', 2, 0.020, 0.020, 0.020, SUSER_SNAME(), SYSUTCDATETIME()),
        (@SOURCE_PROCESS_DATE, '20261231', 'RETAIL', N'Credit card', N'B2A: MOB >=6 & DPD 0-9', 'AAA', 3, 0.030, 0.030, 0.030, SUSER_SNAME(), SYSUTCDATETIME());

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE = @PROCESS_DATE,
        @RUN_TYPE = 'FULL',
        @SCENARIO_WEIGHT_VERSION_ID = @WEIGHT_VERSION,
        @CALCULATION_VERSION = 'PD-SOURCE-TEST',
        @RUN_ID = @RUN_ID OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus
        @RUN_ID = @RUN_ID, @NEW_STATUS = 'VALIDATING',
        @EVENT_MESSAGE = N'Synthetic source PD loader test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME, STAGE,
         POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'SYN-PD-SOURCE-001', 'SYN-CUST-001',
         'RETAIL_CARD', 1, '105', '20270630', 1, 1);

    /* Explicit test mapping only; production mapping remains caller-approved. */
    EXEC ecl_core.usp_LoadRetailMarginalPITPD
        @RUN_ID = @RUN_ID,
        @VERSION_ID = 1,
        @SCENARIO_1_CODE = 'BASE',
        @SCENARIO_2_CODE = 'DOWNTURN',
        @SCENARIO_3_CODE = 'UPTURN';

    SELECT @ROWS = COUNT_BIG(*)
    FROM ecl_stg.PDCurve
    WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

    IF @ROWS <> 3
        THROW 51890, 'Source PD loader should create three canonical scenario rows.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID AND ACCOUNT_ID = 'SYN-PD-SOURCE-001'
          AND SCENARIO_CODE = 'BASE' AND FORECAST_PERIOD = 1
          AND MARGINAL_PD = 0.010000000000
    )
        THROW 51891, 'Source SCENARIO 1 should follow the explicit test mapping to BASE.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_audit.ValidationError
        WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'PD_SOURCE_PROCESS_DATE'
          AND SEVERITY = 'WARN' AND ERROR_MESSAGE LIKE N'%2026-12-31%'
    )
        THROW 51892, 'Source PD PROCESS_DATE mismatch should be recorded as a warning.', 1;

    EXEC ecl_core.usp_LoadPDCurve @RUN_ID = @RUN_ID;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: source PD loader maps rating/segment/bucket, uses the selected source version, and records its PROCESS_DATE warning.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
