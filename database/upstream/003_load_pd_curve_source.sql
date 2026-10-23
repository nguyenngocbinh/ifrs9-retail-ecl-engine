/*
Source-specific PD ETL for IFRS 9 Retail ECL Engine.
Deploy after database/001_create_logical_schema.sql and database/007_pd_curve_loader.sql.

Important:
- This procedure stages source PD rows; it does not infer the meaning of source SCENARIO codes.
- Pass the approved source codes explicitly for DOWNTURN, BASE, and UPTURN.
- RETAIL_MARGINAL_PIT_PD.PROCESS_DATE is intentionally not filtered because the source
  is currently maintained on a fixed annual date. The actual source dates are returned
  for audit/confirmation; REPORTING_DATE on TBL_MAN_FACILITY_RATING must match the run.
- Default source schema is dbo. Set @SOURCE_DATABASE/@SOURCE_SCHEMA to the real source location.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourcePDCurve
    @RUN_ID bigint,
    @VERSION_ID int,
    @SOURCE_SCENARIO_DOWNTURN varchar(50),
    @SOURCE_SCENARIO_BASE varchar(50),
    @SOURCE_SCENARIO_UPTURN varchar(50),
    @SOURCE_DATABASE sysname = NULL,
    @SOURCE_SCHEMA sysname = N'dbo'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @SQL nvarchar(max),
        @SOURCE_QUALIFIER nvarchar(517),
        @ROW_COUNT bigint,
        @SOURCE_DATE_COUNT int,
        @SOURCE_DATES nvarchar(1000);

    IF NULLIF(LTRIM(RTRIM(@SOURCE_SCENARIO_DOWNTURN)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SOURCE_SCENARIO_BASE)), '') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SOURCE_SCENARIO_UPTURN)), '') IS NULL
        THROW 51800, 'PD source ETL: explicitly provide all three approved source scenario codes.', 1;

    IF @SOURCE_SCENARIO_DOWNTURN = @SOURCE_SCENARIO_BASE
       OR @SOURCE_SCENARIO_DOWNTURN = @SOURCE_SCENARIO_UPTURN
       OR @SOURCE_SCENARIO_BASE = @SOURCE_SCENARIO_UPTURN
        THROW 51801, 'PD source ETL: source scenario codes must be distinct.', 1;

    IF NULLIF(LTRIM(RTRIM(@SOURCE_SCHEMA)), '') IS NULL
        THROW 51802, 'PD source ETL: SOURCE_SCHEMA cannot be empty.', 1;

    SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
    FROM ecl_core.RunControl
    WHERE RUN_ID = @RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51803, 'PD source ETL: RUN_ID does not exist.', 1;

    IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
        THROW 51804, 'PD source ETL: only CREATED or VALIDATING runs may be loaded.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM ecl_stg.AccountSnapshot
        WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
    )
        THROW 51805, 'PD source ETL: no active AccountSnapshot rows exist for this run.', 1;

    IF @SOURCE_DATABASE IS NULL
        SET @SOURCE_QUALIFIER = QUOTENAME(@SOURCE_SCHEMA);
    ELSE
        SET @SOURCE_QUALIFIER = QUOTENAME(@SOURCE_DATABASE) + N'.' + QUOTENAME(@SOURCE_SCHEMA);

    IF @SOURCE_QUALIFIER IS NULL
        THROW 51806, 'PD source ETL: invalid source database/schema identifier.', 1;

    CREATE TABLE #PDSource
    (
        ACCOUNT_ID varchar(100) NOT NULL,
        SCENARIO_CODE varchar(20) NOT NULL,
        FORECAST_PERIOD smallint NULL,
        MARGINAL_PD decimal(19,12) NULL,
        SOURCE_PROCESS_DATE date NULL
    );

    SET @SQL = N'
      INSERT INTO #PDSource
          (ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD, MARGINAL_PD, SOURCE_PROCESS_DATE)
      SELECT
          CONVERT(varchar(100), fr.ACCOUNT_ID),
          CASE CONVERT(varchar(50), pd.SCENARIO)
              WHEN @SRC_DOWN THEN ''DOWNTURN''
              WHEN @SRC_BASE THEN ''BASE''
              WHEN @SRC_UP THEN ''UPTURN''
          END,
          TRY_CONVERT(smallint, pd.PERIOD),
          TRY_CONVERT(decimal(19,12), pd.FINAL_MARGINAL_PIT_PD),
          TRY_CONVERT(date, pd.PROCESS_DATE)
      FROM ' + @SOURCE_QUALIFIER + N'.' + QUOTENAME(N'TBL_MAN_FACILITY_RATING') + N' AS fr
      INNER JOIN ecl_stg.AccountSnapshot AS a
          ON a.RUN_ID = @P_RUN_ID
         AND a.PROCESS_DATE = @P_PROCESS_DATE
         AND a.ACCOUNT_ID = CONVERT(varchar(100), fr.ACCOUNT_ID)
         AND a.IS_ACTIVE = 1
      INNER JOIN ecl_cfg.PoolName AS pn
          ON pn.POOL_NAME = a.POOL_NAME
         AND pn.IS_ACTIVE = 1
      INNER JOIN ' + @SOURCE_QUALIFIER + N'.' + QUOTENAME(N'RETAIL_MARGINAL_PIT_PD') + N' AS pd
          ON pd.BUCKET = fr.BUCKET
         AND pd.RATING = fr.RATING
         AND pd.SEGMENT_LV2 = pn.SEGMENT
         AND CONVERT(varchar(50), pd.SCENARIO) IN (@SRC_DOWN, @SRC_BASE, @SRC_UP)
      WHERE fr.REPORTING_DATE = @P_PROCESS_DATE;'

    EXEC sys.sp_executesql
        @SQL,
        N'@P_RUN_ID bigint, @P_PROCESS_DATE date,
          @SRC_DOWN varchar(50), @SRC_BASE varchar(50), @SRC_UP varchar(50)',
        @P_RUN_ID = @RUN_ID,
        @P_PROCESS_DATE = @PROCESS_DATE,
        @SRC_DOWN = @SOURCE_SCENARIO_DOWNTURN,
        @SRC_BASE = @SOURCE_SCENARIO_BASE,
        @SRC_UP = @SOURCE_SCENARIO_UPTURN;

    IF NOT EXISTS (SELECT 1 FROM #PDSource)
        THROW 51807, 'PD source ETL: no matching source rows. Check source schema, REPORTING_DATE, account/rating/bucket/segment mapping, and scenario codes.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #PDSource
        WHERE SCENARIO_CODE IS NULL
           OR FORECAST_PERIOD IS NULL
           OR FORECAST_PERIOD < 1
           OR MARGINAL_PD IS NULL
           OR MARGINAL_PD < 0
           OR MARGINAL_PD > 1
    )
        THROW 51808, 'PD source ETL: source contains an invalid scenario, period, or PD value.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #PDSource
        GROUP BY ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
        HAVING COUNT_BIG(*) > 1
    )
        THROW 51809, 'PD source ETL: duplicate rows exist for ACCOUNT_ID + SCENARIO_CODE + PERIOD. Resolve source duplicates before loading.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #PDSource s
        LEFT JOIN ecl_stg.AccountSnapshot a
          ON a.RUN_ID = @RUN_ID
         AND a.PROCESS_DATE = @PROCESS_DATE
         AND a.ACCOUNT_ID = s.ACCOUNT_ID
         AND a.IS_ACTIVE = 1
        WHERE a.ACCOUNT_ID IS NULL
    )
        THROW 51810, 'PD source ETL: a source account does not match an active AccountSnapshot row.', 1;

    SELECT @SOURCE_DATE_COUNT = COUNT(DISTINCT SOURCE_PROCESS_DATE)
    FROM #PDSource;

    SELECT @SOURCE_DATES =
        STRING_AGG(CONVERT(nvarchar(10), d.SOURCE_PROCESS_DATE, 23), N', ')
    FROM
    (
        SELECT DISTINCT SOURCE_PROCESS_DATE
        FROM #PDSource
    ) AS d;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Replace only this run's staged PD rows. Rollback restores the old rows if insert fails. */
        DELETE FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.PDCurve
            (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD,
             MARGINAL_PD, VERSION_ID, IS_ACTIVE)
        SELECT
            @RUN_ID, @PROCESS_DATE, s.ACCOUNT_ID, s.SCENARIO_CODE, s.FORECAST_PERIOD,
            s.MARGINAL_PD, @VERSION_ID, 1
        FROM #PDSource AS s;

        SET @ROW_COUNT = @@ROWCOUNT;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_SOURCE_ETL', 'SUCCEEDED',
             CONCAT(N'Staged source PD rows. Source RETAIL_MARGINAL_PIT_PD.PROCESS_DATE was not filtered; observed date(s): ',
                    COALESCE(@SOURCE_DATES, N'NULL'),
                    N'. Confirm source date is approved for run PROCESS_DATE.'),
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        @RUN_ID AS RUN_ID,
        @PROCESS_DATE AS RUN_PROCESS_DATE,
        @ROW_COUNT AS PD_ROW_COUNT,
        @SOURCE_DATE_COUNT AS SOURCE_PD_PROCESS_DATE_COUNT,
        @SOURCE_DATES AS SOURCE_PD_PROCESS_DATES,
        'STAGED' AS LOAD_STATUS,
        N'Next run ecl_core.usp_LoadPDCurve @RUN_ID to validate coverage and scenario completeness.' AS NEXT_STEP;
END;
GO
