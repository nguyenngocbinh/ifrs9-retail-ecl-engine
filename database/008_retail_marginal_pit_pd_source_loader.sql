/*
Migration 008: source-specific retail marginal PIT PD ingestion.
Deploy after migrations 001..007.

The PD source PROCESS_DATE is treated as a source-version marker, not a join
key to the ECL run date. The procedure selects the latest source PROCESS_DATE
and emits a WARN audit finding/event so operators can see which source version
is being used. Facility ratings are matched to the run date.

Scenario codes are supplied explicitly by the caller because the source
mapping 1/2/3 -> DOWNTURN/BASE/UPTURN has not been approved in code.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_LoadRetailMarginalPITPD
    @RUN_ID bigint,
    @VERSION_ID int,
    @SCENARIO_1_CODE varchar(20),
    @SCENARIO_2_CODE varchar(20),
    @SCENARIO_3_CODE varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @PD_SOURCE_PROCESS_DATE date,
        @ROW_COUNT bigint,
        @WARNING_MESSAGE nvarchar(2000);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51800, 'Retail PD source loader: RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51801, 'Retail PD source loader is only allowed before calculation begins.', 1;

        IF @VERSION_ID IS NULL OR @VERSION_ID < 1
            THROW 51802, 'Retail PD source loader requires a positive VERSION_ID.', 1;

        IF @SCENARIO_1_CODE NOT IN ('DOWNTURN','BASE','UPTURN')
           OR @SCENARIO_2_CODE NOT IN ('DOWNTURN','BASE','UPTURN')
           OR @SCENARIO_3_CODE NOT IN ('DOWNTURN','BASE','UPTURN')
           OR @SCENARIO_1_CODE = @SCENARIO_2_CODE
           OR @SCENARIO_1_CODE = @SCENARIO_3_CODE
           OR @SCENARIO_2_CODE = @SCENARIO_3_CODE
            THROW 51803, 'Map source SCENARIO 1/2/3 to three distinct canonical codes: DOWNTURN, BASE, UPTURN.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
        )
            THROW 51804, 'Retail PD source loader: no active account snapshots exist for this run.', 1;

        IF EXISTS (SELECT 1 FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID)
            THROW 51805, 'Retail PD source loader: PDCurve already contains rows for this RUN_ID; refusing to overwrite.', 1;

        SELECT @PD_SOURCE_PROCESS_DATE = MAX(PROCESS_DATE)
        FROM dbo.RETAIL_MARGINAL_PIT_PD;

        IF @PD_SOURCE_PROCESS_DATE IS NULL
            THROW 51806, 'Retail PD source loader: dbo.RETAIL_MARGINAL_PIT_PD is empty.', 1;

        SET @WARNING_MESSAGE = CONCAT(
            N'WARNING: source PD dataset selected from dbo.RETAIL_MARGINAL_PIT_PD.PROCESS_DATE = ',
            CONVERT(nvarchar(10), @PD_SOURCE_PROCESS_DATE, 23),
            N'. This source PROCESS_DATE is a version marker and is not required to equal the ECL run PROCESS_DATE ',
            CONVERT(nvarchar(10), @PROCESS_DATE, 23),
            N'. Confirm source freshness before production use.'
        );

        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_SOURCE_PROCESS_DATE', 'WARN', @WARNING_MESSAGE);

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_SOURCE_VERSION', 'WARNING', @WARNING_MESSAGE, SUSER_SNAME());

        /* Source rating must be for the ECL reporting date and same pool/account.
           PoolName.SEGMENT is the approved bridge from POOL_NAME to SEGMENT_LV2. */
        IF EXISTS
        (
            SELECT a.ACCOUNT_ID
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
            GROUP BY a.ACCOUNT_ID
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51807, 'Retail PD source loader: more than one facility-rating row matches an account for the run date and pool.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            LEFT JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND fr.ACCOUNT_ID IS NULL
        )
            THROW 51808, 'Retail PD source loader: one or more active accounts have no facility rating for the run date and pool.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            JOIN ecl_cfg.PoolName pn
              ON pn.POOL_NAME = a.POOL_NAME AND pn.IS_ACTIVE = 1
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.RETAIL_MARGINAL_PIT_PD pd
                  WHERE pd.PROCESS_DATE = @PD_SOURCE_PROCESS_DATE
                    AND pd.SEGMENT_LV2 = pn.SEGMENT
                    AND pd.BUCKET = fr.BUCKET
                    AND pd.RATING = fr.RATING
              )
        )
            THROW 51809, 'Retail PD source loader: missing PD curve for at least one account rating/bucket/segment combination.', 1;

        ;WITH SourcePD AS
        (
            SELECT
                pd.SEGMENT_LV2,
                pd.BUCKET,
                pd.RATING,
                pd.PERIOD,
                pd.SCENARIO,
                pd.FINAL_MARGINAL_PIT_PD,
                CONVERT(smallint,
                    DATEDIFF(year, @PROCESS_DATE, pd.PERIOD)
                    + CASE WHEN @PROCESS_DATE < DATEFROMPARTS(YEAR(@PROCESS_DATE), 12, 31)
                           THEN 1 ELSE 0 END
                ) AS FORECAST_PERIOD,
                CASE pd.SCENARIO
                    WHEN 1 THEN @SCENARIO_1_CODE
                    WHEN 2 THEN @SCENARIO_2_CODE
                    WHEN 3 THEN @SCENARIO_3_CODE
                END AS SCENARIO_CODE
            FROM dbo.RETAIL_MARGINAL_PIT_PD pd
            WHERE pd.PROCESS_DATE = @PD_SOURCE_PROCESS_DATE
              AND pd.PERIOD > @PROCESS_DATE
              AND pd.SCENARIO IN (1,2,3)
        ),
        MappedRows AS
        (
            SELECT
                a.RUN_ID,
                @PROCESS_DATE AS PROCESS_DATE,
                a.ACCOUNT_ID,
                sp.SCENARIO_CODE,
                sp.FORECAST_PERIOD,
                CONVERT(decimal(19,12), sp.FINAL_MARGINAL_PIT_PD) AS MARGINAL_PD,
                @VERSION_ID AS VERSION_ID,
                CAST(1 AS bit) AS IS_ACTIVE
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            JOIN ecl_cfg.PoolName pn
              ON pn.POOL_NAME = a.POOL_NAME AND pn.IS_ACTIVE = 1
            JOIN SourcePD sp
              ON sp.SEGMENT_LV2 = pn.SEGMENT
             AND sp.BUCKET = fr.BUCKET
             AND sp.RATING = fr.RATING
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
        )
        INSERT INTO ecl_stg.PDCurve
            (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
             FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
        SELECT RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
               FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE
        FROM MappedRows
        WHERE SCENARIO_CODE IS NOT NULL
          AND FORECAST_PERIOD >= 1;

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51810, 'Retail PD source loader: no canonical PD rows were produced.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            FROM ecl_stg.PDCurve
            WHERE RUN_ID = @RUN_ID
            GROUP BY RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51811, 'Retail PD source loader: duplicate canonical PD keys were produced; verify source uniqueness.', 1;

        COMMIT TRANSACTION;

        SELECT
            @RUN_ID AS RUN_ID,
            @PROCESS_DATE AS RUN_PROCESS_DATE,
            @PD_SOURCE_PROCESS_DATE AS PD_SOURCE_PROCESS_DATE,
            @ROW_COUNT AS PD_ROW_COUNT,
            @WARNING_MESSAGE AS SOURCE_VERSION_WARNING,
            'LOADED_WITH_WARNING' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
