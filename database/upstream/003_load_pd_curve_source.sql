/*
IFRS 9 Retail ECL Engine — source PD loader
Purpose:
- Load source marginal PIT PD into the canonical ecl_stg.PDCurve contract.
- Match facility ratings to the ECL run date and account pool.
- Treat source PROCESS_DATE as part of the source curve timeline, not as a snapshot filter.
- Map source scenario codes through the existing ecl_cfg.Scenario configuration.

Assumption: RETAIL_MARGINAL_PIT_PD.PERIOD is a DATE representing annual period-end
dates. FORECAST_PERIOD is derived relative to the ECL run date; confirm this source
contract before production deployment.
Deploy after database/001_create_logical_schema.sql and database/007_pd_curve_loader.sql.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourcePDCurve
    @RUN_ID bigint,
    @VERSION_ID int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @ROW_COUNT bigint;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @PROCESS_DATE = PROCESS_DATE,
            @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51800, 'RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51801, 'PD source loader is only allowed while the run is CREATED or VALIDATING.', 1;

        IF @VERSION_ID IS NULL OR @VERSION_ID < 1
            THROW 51802, 'VERSION_ID must be a positive integer.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE = @PROCESS_DATE
              AND IS_ACTIVE = 1
        )
            THROW 51803, 'No active AccountSnapshot rows exist for this run.', 1;

        /* Source PROCESS_DATE is not used as a snapshot filter in this loader. */

        /* Require the canonical scenario mapping expected by the ECL engine. */
        IF NOT EXISTS
           (SELECT 1 FROM ecl_cfg.Scenario WHERE SCENARIO_CODE = 'BASE' AND SOURCE_SCENARIO_CODE = 1 AND IS_ACTIVE = 1)
           OR NOT EXISTS
           (SELECT 1 FROM ecl_cfg.Scenario WHERE SCENARIO_CODE = 'UPTURN' AND SOURCE_SCENARIO_CODE = 2 AND IS_ACTIVE = 1)
           OR NOT EXISTS
           (SELECT 1 FROM ecl_cfg.Scenario WHERE SCENARIO_CODE = 'DOWNTURN' AND SOURCE_SCENARIO_CODE = 3 AND IS_ACTIVE = 1)
            THROW 51805, 'ecl_cfg.Scenario must map source scenarios 1=BASE, 2=UPTURN, 3=DOWNTURN.', 1;

        /* Every active account must have exactly one facility rating for run date and pool. */
        IF EXISTS
        (
            SELECT a.ACCOUNT_ID
            FROM ecl_stg.AccountSnapshot AS a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] AS fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
            GROUP BY a.ACCOUNT_ID
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51806, 'More than one facility-rating row matches an account for the run date and pool.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot AS a
            LEFT JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] AS fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND fr.ACCOUNT_ID IS NULL
        )
            THROW 51807, 'One or more active accounts have no facility rating for the run date and pool.', 1;

        /* Validate every required account rating has a future PD curve relative to the ECL run date. */
        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot AS a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] AS fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            JOIN ecl_cfg.PoolName AS pn
              ON pn.POOL_NAME = a.POOL_NAME
             AND pn.IS_ACTIVE = 1
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.RETAIL_MARGINAL_PIT_PD AS pd
                  WHERE pd.SEGMENT_LV2 = pn.SEGMENT
                    AND pd.BUCKET = fr.BUCKET
                    AND pd.RATING = fr.RATING
                    AND pd.PERIOD > @PROCESS_DATE
              )
        )
            THROW 51808, 'No future PD period exists for at least one account segment/bucket/rating relative to the ECL run date.', 1;

        /* Build and validate the full load set before replacing any existing run data. */
        DROP TABLE IF EXISTS #MappedRows;

        SELECT
            a.RUN_ID,
            @PROCESS_DATE AS PROCESS_DATE,
            a.ACCOUNT_ID,
            sm.SCENARIO_CODE,
            CONVERT(smallint,
                DATEDIFF(year, @PROCESS_DATE, pd.PERIOD)
                + CASE
                    WHEN @PROCESS_DATE < DATEFROMPARTS(YEAR(@PROCESS_DATE), 12, 31)
                    THEN 1 ELSE 0
                  END
            ) AS FORECAST_PERIOD,
            TRY_CONVERT(decimal(19,12), pd.FINAL_MARGINAL_PIT_PD) AS MARGINAL_PD,
            @VERSION_ID AS VERSION_ID,
            CONVERT(bit, 1) AS IS_ACTIVE
        INTO #MappedRows
        FROM ecl_stg.AccountSnapshot AS a
        JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] AS fr
          ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
         AND fr.REPORTING_DATE = @PROCESS_DATE
         AND fr.POOL_NAME = a.POOL_NAME
        JOIN ecl_cfg.PoolName AS pn
          ON pn.POOL_NAME = a.POOL_NAME
         AND pn.IS_ACTIVE = 1
        JOIN dbo.RETAIL_MARGINAL_PIT_PD AS pd
          ON pd.SEGMENT_LV2 = pn.SEGMENT
         AND pd.BUCKET = fr.BUCKET
         AND pd.RATING = fr.RATING
         AND pd.PERIOD > @PROCESS_DATE
        JOIN ecl_cfg.Scenario AS sm
          ON sm.SOURCE_SCENARIO_CODE = TRY_CONVERT(int, pd.SCENARIO)
         AND sm.IS_ACTIVE = 1
        WHERE a.RUN_ID = @RUN_ID
          AND a.PROCESS_DATE = @PROCESS_DATE
          AND a.IS_ACTIVE = 1;

        IF NOT EXISTS (SELECT 1 FROM #MappedRows)
            THROW 51809, 'No source PD rows matched the run accounts, ratings, pool segments, and scenarios.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM #MappedRows
            WHERE SCENARIO_CODE IS NULL
               OR FORECAST_PERIOD < 1
               OR MARGINAL_PD IS NULL
               OR MARGINAL_PD < 0
               OR MARGINAL_PD > 1
        )
            THROW 51810, 'Mapped PD rows contain an invalid scenario, forecast period, or PD value.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            FROM #MappedRows
            GROUP BY RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51811, 'Source data produces duplicate canonical PD keys; verify source uniqueness.', 1;

        /* Replace only after all source validations have succeeded. */
        DELETE FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.PDCurve
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
            FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE
        )
        SELECT
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
            FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE
        FROM #MappedRows;

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51812, 'No PD rows were inserted into ecl_stg.PDCurve.', 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'PD_SOURCE_ETL', 'SUCCEEDED',
            CONCAT(
                N'Loaded source PD rows using PERIOD relative to ECL run PROCESS_DATE into ecl_stg.PDCurve.'
            ),
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT
            @RUN_ID AS RUN_ID,
            @PROCESS_DATE AS RUN_PROCESS_DATE,
            @ROW_COUNT AS PD_ROW_COUNT,
            'STAGED' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
