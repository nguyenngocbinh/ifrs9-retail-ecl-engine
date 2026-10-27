/*
IFRS 9 Retail ECL Engine — upstream source EAD ETL
Purpose:
- Derive annual time-weighted average EAD from STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE.
- Map source ACCOUNT_NUMBER to the canonical AccountSnapshot.ACCOUNT_ID.
- Load the resulting annual curve into ecl_stg.EADCurve.
- Keep ecl_core.usp_LoadEADCurve validation-only.

Methodology status:
- Annual calendar-day-weighted average is proposed and requires methodology-owner approval.
- Stage 3 remains on reporting-date EAD_0 pending confirmation of its exposure basis.
- Missing schedule rows are not silently treated as a zero balance; EAD_0 is used only when no schedule event is effective yet, and the source procedure's synthetic row supports accounts with no future schedule.
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

        /*
          Build annual periods. Stage 3 remains period 1 and uses EAD_0.
          Performing accounts use [period start, period end) and the average
          is weighted by calendar days. Each schedule balance is effective
          from SCHEDULE_DUE_DATE until the next event boundary.
        */
        DROP TABLE IF EXISTS #AnnualPeriods;

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
        )
        SELECT
            h.RUN_ID,
            h.PROCESS_DATE,
            h.ACCOUNT_ID,
            h.MATURITY_DATE,
            h.STAGE,
            h.SNAPSHOT_VERSION_ID,
            h.EAD_0,
            n.N AS FORECAST_PERIOD,
            DATEADD(year, n.N - 1, h.PROCESS_DATE) AS PERIOD_START_DATE,
            DATEADD(year, n.N, h.PROCESS_DATE) AS PERIOD_END_DATE
        INTO #AnnualPeriods
        FROM AccountHorizon AS h
        CROSS APPLY
        (
            SELECT TOP (120)
                CONVERT(int, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) AS N
            FROM sys.all_objects AS x
            CROSS JOIN sys.all_objects AS y
        ) AS n
        WHERE n.N <= h.HORIZON;

        DROP TABLE IF EXISTS #MappedRows;

        ;WITH EventDates AS
        (
            SELECT
                p.RUN_ID, p.PROCESS_DATE, p.ACCOUNT_ID, p.MATURITY_DATE,
                p.STAGE, p.SNAPSHOT_VERSION_ID, p.EAD_0, p.FORECAST_PERIOD,
                p.PERIOD_START_DATE, p.PERIOD_END_DATE,
                p.PERIOD_START_DATE AS EVENT_DATE
            FROM #AnnualPeriods AS p
            WHERE p.STAGE <> 3

            UNION

            SELECT
                p.RUN_ID, p.PROCESS_DATE, p.ACCOUNT_ID, p.MATURITY_DATE,
                p.STAGE, p.SNAPSHOT_VERSION_ID, p.EAD_0, p.FORECAST_PERIOD,
                p.PERIOD_START_DATE, p.PERIOD_END_DATE,
                CONVERT(date, s.SCHEDULE_DUE_DATE) AS EVENT_DATE
            FROM #AnnualPeriods AS p
            JOIN STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE AS s
              ON s.PROCESS_DATE = p.PROCESS_DATE
             AND s.ACCOUNT_NUMBER = p.ACCOUNT_ID
             AND s.SCHEDULE_DUE_DATE >= p.PERIOD_START_DATE
             AND s.SCHEDULE_DUE_DATE < p.PERIOD_END_DATE
            WHERE p.STAGE <> 3
              AND TRY_CONVERT(decimal(19,4), s.EAD_AFTER_REPAYMENT) IS NOT NULL

            UNION

            SELECT
                p.RUN_ID, p.PROCESS_DATE, p.ACCOUNT_ID, p.MATURITY_DATE,
                p.STAGE, p.SNAPSHOT_VERSION_ID, p.EAD_0, p.FORECAST_PERIOD,
                p.PERIOD_START_DATE, p.PERIOD_END_DATE,
                DATEADD(day, 1, p.MATURITY_DATE) AS EVENT_DATE
            FROM #AnnualPeriods AS p
            WHERE p.STAGE <> 3
              AND p.MATURITY_DATE >= p.PERIOD_START_DATE
              AND p.MATURITY_DATE < p.PERIOD_END_DATE
        ),
        OrderedEvents AS
        (
            SELECT
                e.*,
                LEAD(e.EVENT_DATE, 1, e.PERIOD_END_DATE) OVER
                (
                    PARTITION BY e.RUN_ID, e.ACCOUNT_ID, e.FORECAST_PERIOD
                    ORDER BY e.EVENT_DATE
                ) AS NEXT_EVENT_DATE
            FROM EventDates AS e
        ),
        Segments AS
        (
            SELECT
                e.*,
                CONVERT(decimal(19,4),
                    CASE
                        WHEN e.EVENT_DATE > e.MATURITY_DATE THEN 0
                        WHEN e.EVENT_DATE > e.PERIOD_END_DATE THEN 0
                        ELSE COALESCE
                        (
                            (
                                SELECT TOP (1)
                                    TRY_CONVERT(decimal(19,4), s.EAD_AFTER_REPAYMENT)
                                FROM STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE AS s
                                WHERE s.PROCESS_DATE = e.PROCESS_DATE
                                  AND s.ACCOUNT_NUMBER = e.ACCOUNT_ID
                                  AND s.SCHEDULE_DUE_DATE < DATEADD(day, 1, e.EVENT_DATE)
                                  AND TRY_CONVERT(decimal(19,4), s.EAD_AFTER_REPAYMENT) IS NOT NULL
                                ORDER BY s.SCHEDULE_DUE_DATE DESC, s.SCHEDULE_NO DESC
                            ),
                            e.EAD_0
                        )
                    END
                ) AS EFFECTIVE_EAD
            FROM OrderedEvents AS e
        ),
        WeightedAverage AS
        (
            SELECT
                RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD,
                CONVERT(decimal(19,4),
                    SUM(EFFECTIVE_EAD * CONVERT(decimal(19,4), DATEDIFF(day, EVENT_DATE, NEXT_EVENT_DATE)))
                    / NULLIF(CONVERT(decimal(19,4), DATEDIFF(day, PERIOD_START_DATE, PERIOD_END_DATE)), 0)
                ) AS EAD
            FROM Segments
            WHERE NEXT_EVENT_DATE > EVENT_DATE
            GROUP BY
                RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD,
                PERIOD_START_DATE, PERIOD_END_DATE
        )
        SELECT
            p.RUN_ID,
            p.PROCESS_DATE,
            p.ACCOUNT_ID,
            p.FORECAST_PERIOD,
            CONVERT(decimal(19,4),
                CASE WHEN p.STAGE = 3 THEN p.EAD_0 ELSE w.EAD END
            ) AS EAD,
            CONVERT(varchar(3), 'VND') AS CURRENCY_CODE,
            @VERSION_ID AS VERSION_ID,
            CONVERT(bit, 1) AS IS_ACTIVE
        INTO #MappedRows
        FROM #AnnualPeriods AS p
        LEFT JOIN WeightedAverage AS w
          ON w.RUN_ID = p.RUN_ID
         AND w.ACCOUNT_ID = p.ACCOUNT_ID
         AND w.FORECAST_PERIOD = p.FORECAST_PERIOD;

        IF EXISTS
        (
            SELECT 1
            FROM #MappedRows
            WHERE FORECAST_PERIOD < 1
               OR EAD IS NULL
               OR EAD < 0
        )
            THROW 51908, 'EAD source ETL: mapped annual rows contain an invalid period or EAD value; check missing period coverage.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            FROM #MappedRows
            GROUP BY RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51909, 'EAD source ETL: source produced duplicate canonical account/period keys.', 1;

        INSERT INTO ecl_stg.EADCurve
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, EAD,
            CURRENCY_CODE, VERSION_ID, IS_ACTIVE
        )
        SELECT
            m.RUN_ID, m.PROCESS_DATE, m.ACCOUNT_ID, m.FORECAST_PERIOD, m.EAD,
            m.CURRENCY_CODE, m.VERSION_ID, m.IS_ACTIVE
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
            N'Loaded annual time-weighted average Non-Revolving EAD from STAGING_MPP schedule into ecl_stg.EADCurve.',
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
