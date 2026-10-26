/*
IFRS 9 Retail ECL Engine — upstream source EAD ETL
Purpose:
- Derive annual year-end EAD from STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE.
- Map source ACCOUNT_NUMBER to the canonical AccountSnapshot.ACCOUNT_ID.
- Load the resulting annual curve directly into ecl_stg.EADCurve.
- Keep source extraction/calculation here, separate from database/006_ead_curve_loader.sql,
  which remains a shared validation-only loader.

Source contract to confirm in the target environment:
  PROCESS_DATE, ACCOUNT_NUMBER, SCHEDULE_DUE_DATE, SCHEDULE_NO,
  EAD_0, EAD_AFTER_REPAYMENT.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourceEADCurve
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
            THROW 51900, 'EAD source ETL: RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51901, 'EAD source ETL is only allowed while the run is CREATED or VALIDATING.', 1;

        IF @VERSION_ID IS NULL OR @VERSION_ID < 1
            THROW 51902, 'EAD source ETL: VERSION_ID must be a positive integer.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE = @PROCESS_DATE
              AND IS_ACTIVE = 1
        )
            THROW 51903, 'EAD source ETL: no active AccountSnapshot rows exist for this run.', 1;

        IF OBJECT_ID(N'STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE', N'U') IS NULL
            THROW 51904, 'EAD source ETL: STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE does not exist or is not accessible.', 1;

        /*
          Build annual periods only for accounts that:
          1) are active in this run;
          2) have not already been loaded into EADCurve by another product-specific ETL;
          3) have a matching source schedule for this PROCESS_DATE. The DB2
             source procedure emits a synthetic PROCESS_DATE row when no future
             principal schedule exists but the reporting-date account balance does.

          This allows product-specific ETLs (for example Auto) to populate their
          own accounts without this Non-Revolving ETL deleting or overwriting them.
        */
        DROP TABLE IF EXISTS #SourceAccounts;

        SELECT
            a.RUN_ID,
            a.PROCESS_DATE,
            a.ACCOUNT_ID,
            a.MATURITY_DATE,
            a.STAGE,
            a.VERSION_ID AS SNAPSHOT_VERSION_ID,
            MAX(TRY_CONVERT(decimal(19,4), s.EAD_0)) AS EAD_0
        INTO #SourceAccounts
        FROM ecl_stg.AccountSnapshot AS a
        JOIN STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE AS s
          ON s.PROCESS_DATE = @PROCESS_DATE
         AND s.ACCOUNT_NUMBER = a.ACCOUNT_ID
        WHERE a.RUN_ID = @RUN_ID
          AND a.PROCESS_DATE = @PROCESS_DATE
          AND a.IS_ACTIVE = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM ecl_stg.EADCurve AS e
              WHERE e.RUN_ID = a.RUN_ID
                AND e.ACCOUNT_ID = a.ACCOUNT_ID
          )
        GROUP BY
            a.RUN_ID, a.PROCESS_DATE, a.ACCOUNT_ID, a.MATURITY_DATE, a.STAGE, a.VERSION_ID;

        IF NOT EXISTS (SELECT 1 FROM #SourceAccounts)
            THROW 51905, 'EAD source ETL: no unloaded active accounts matched the Non-Revolving source schedule for this run.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM #SourceAccounts
            WHERE (MATURITY_DATE IS NULL AND STAGE <> 3)
               OR EAD_0 IS NULL
               OR EAD_0 < 0
        )
            THROW 51906, 'EAD source ETL: maturity date is required except for Stage 3; EAD_0 must be non-negative.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE AS s
            JOIN #SourceAccounts AS a
              ON s.ACCOUNT_NUMBER = a.ACCOUNT_ID
             AND s.PROCESS_DATE = @PROCESS_DATE
            WHERE s.EAD_AFTER_REPAYMENT IS NOT NULL
              AND TRY_CONVERT(decimal(19,4), s.EAD_AFTER_REPAYMENT) < 0
        )
            THROW 51907, 'EAD source ETL: EAD_AFTER_REPAYMENT cannot be negative.', 1;

        DROP TABLE IF EXISTS #MappedRows;

        ;WITH AccountHorizon AS
        (
            SELECT
                a.RUN_ID,
                a.PROCESS_DATE,
                a.ACCOUNT_ID,
                a.MATURITY_DATE,
                a.STAGE,
                a.SNAPSHOT_VERSION_ID,
                a.EAD_0,
                CONVERT(int, CASE
                    WHEN a.STAGE = 3 THEN 1
                    WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                    WHEN CEILING(DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE) / 12.0) < 1 THEN 1
                    ELSE CEILING(DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE) / 12.0)
                END) AS HORIZON
            FROM #SourceAccounts AS a
        ),
        AnnualPeriods AS
        (
            SELECT
                h.RUN_ID,
                h.PROCESS_DATE,
                h.ACCOUNT_ID,
                h.MATURITY_DATE,
                h.STAGE,
                h.SNAPSHOT_VERSION_ID,
                h.EAD_0,
                h.HORIZON,
                n.N AS FORECAST_PERIOD,
                DATEADD(year, n.N, h.PROCESS_DATE) AS PERIOD_END_DATE
            FROM AccountHorizon AS h
            CROSS APPLY
            (
                SELECT TOP (120)
                    CONVERT(int, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) AS N
                FROM sys.all_objects AS x
                CROSS JOIN sys.all_objects AS y
            ) AS n
            WHERE n.N <= h.HORIZON
        )
        SELECT
            p.RUN_ID,
            p.PROCESS_DATE,
            p.ACCOUNT_ID,
            p.FORECAST_PERIOD,
            CONVERT(decimal(19,4),
                COALESCE(
                    TRY_CONVERT(decimal(19,4), schedule_row.EAD_AFTER_REPAYMENT),
                    p.EAD_0
                )
            ) AS EAD,
            CONVERT(varchar(3), 'VND') AS CURRENCY_CODE,
            @VERSION_ID AS VERSION_ID,
            CONVERT(bit, 1) AS IS_ACTIVE
        INTO #MappedRows
        FROM AnnualPeriods AS p
        OUTER APPLY
        (
            SELECT TOP (1)
                s.EAD_AFTER_REPAYMENT
            FROM STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE AS s
            WHERE s.PROCESS_DATE = p.PROCESS_DATE
              AND s.ACCOUNT_NUMBER = p.ACCOUNT_ID
              AND s.SCHEDULE_DUE_DATE <= p.PERIOD_END_DATE
              AND TRY_CONVERT(decimal(19,4), s.EAD_AFTER_REPAYMENT) IS NOT NULL
            ORDER BY
                s.SCHEDULE_DUE_DATE DESC,
                s.SCHEDULE_NO DESC
        ) AS schedule_row;

        IF EXISTS
        (
            SELECT 1
            FROM #MappedRows
            WHERE FORECAST_PERIOD < 1
               OR EAD IS NULL
               OR EAD < 0
        )
            THROW 51908, 'EAD source ETL: mapped annual rows contain an invalid period or EAD value.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            FROM #MappedRows
            GROUP BY RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51909, 'EAD source ETL: source produced duplicate canonical account/period keys.', 1;

        /*
          Insert only accounts not already present for this run. The source ETL
          never deletes or overwrites curves populated by another product ETL.
        */
        INSERT INTO ecl_stg.EADCurve
        (
            RUN_ID,
            PROCESS_DATE,
            ACCOUNT_ID,
            FORECAST_PERIOD,
            EAD,
            CURRENCY_CODE,
            VERSION_ID,
            IS_ACTIVE
        )
        SELECT
            m.RUN_ID,
            m.PROCESS_DATE,
            m.ACCOUNT_ID,
            m.FORECAST_PERIOD,
            m.EAD,
            m.CURRENCY_CODE,
            m.VERSION_ID,
            m.IS_ACTIVE
        FROM #MappedRows AS m
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurve AS e
            WHERE e.RUN_ID = m.RUN_ID
              AND e.ACCOUNT_ID = m.ACCOUNT_ID
        );

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51910, 'EAD source ETL: no annual rows were inserted into ecl_stg.EADCurve.', 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'EAD_SOURCE_ETL', 'SUCCEEDED',
            N'Loaded annual Non-Revolving EAD from STAGING_MPP schedule into ecl_stg.EADCurve.',
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT
            @RUN_ID AS RUN_ID,
            @PROCESS_DATE AS RUN_PROCESS_DATE,
            @ROW_COUNT AS EAD_ROW_COUNT,
            'STAGED' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
