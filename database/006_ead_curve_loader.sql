/*
Migration 006: load and validate annual EAD curves.

If product ETL has not already populated ecl_stg.EADCurve for the run, this
procedure derives annual year-end EAD from STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE.
It then validates the canonical curve and records the successful load in audit.

Source contract:
  PROCESS_DATE, ACCOUNT_NUMBER, SCHEDULE_DUE_DATE, SCHEDULE_NO,
  EAD_0, EAD_AFTER_REPAYMENT, MATURITY_DATE.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_core.usp_LoadEADCurve', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_LoadEADCurve;
GO
CREATE PROCEDURE ecl_core.usp_LoadEADCurve
    @RUN_ID bigint
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
            THROW 51600, 'EAD loader: run does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51601, 'EAD loader is only allowed before calculation begins.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1
        )
            THROW 51602, 'EAD loader: no active account snapshots exist for this run.', 1;

        /*
          Prefer an existing product-specific annual curve. If no rows have
          been staged for this run, derive annual year-end balances from the
          shared Non-Revolving schedule source. Do not append to a partial load.
        */
        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurve
            WHERE RUN_ID = @RUN_ID
        )
        BEGIN
            IF OBJECT_ID(N'STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE', N'U') IS NULL
                THROW 51607, 'EAD loader: source table STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE does not exist or is not accessible.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM ecl_stg.AccountSnapshot a
                WHERE a.RUN_ID = @RUN_ID
                  AND a.IS_ACTIVE = 1
                  AND (a.MATURITY_DATE IS NULL OR a.MATURITY_DATE <= @PROCESS_DATE)
            )
                THROW 51608, 'EAD loader: active accounts must have a maturity date after PROCESS_DATE.', 1;

            ;WITH AccountHorizon AS
            (
                SELECT
                    a.RUN_ID,
                    a.PROCESS_DATE,
                    a.ACCOUNT_ID,
                    a.MATURITY_DATE,
                    a.VERSION_ID,
                    CONVERT(int, CEILING(DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE) / 12.0)) AS HORIZON
                FROM ecl_stg.AccountSnapshot a
                WHERE a.RUN_ID = @RUN_ID
                  AND a.PROCESS_DATE = @PROCESS_DATE
                  AND a.IS_ACTIVE = 1
            ),
            AnnualPeriods AS
            (
                SELECT
                    h.RUN_ID,
                    h.PROCESS_DATE,
                    h.ACCOUNT_ID,
                    h.MATURITY_DATE,
                    h.VERSION_ID,
                    h.HORIZON,
                    n.N AS FORECAST_PERIOD,
                    DATEADD(year, n.N, h.PROCESS_DATE) AS PERIOD_END_DATE
                FROM AccountHorizon h
                CROSS APPLY
                (
                    SELECT TOP (120)
                        CONVERT(int, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) AS N
                    FROM sys.all_objects x
                    CROSS JOIN sys.all_objects y
                ) n
                WHERE n.N <= h.HORIZON
            )
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
                p.RUN_ID,
                p.PROCESS_DATE,
                p.ACCOUNT_ID,
                p.FORECAST_PERIOD,
                CONVERT(decimal(19,4),
                    CASE
                        WHEN schedule_row.EAD_AFTER_REPAYMENT IS NOT NULL
                            THEN schedule_row.EAD_AFTER_REPAYMENT
                        ELSE source_balance.EAD_0
                    END) AS EAD,
                'VND',
                p.VERSION_ID,
                1
            FROM AnnualPeriods p
            OUTER APPLY
            (
                SELECT TOP (1)
                    s.EAD_AFTER_REPAYMENT
                FROM STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE s
                WHERE s.PROCESS_DATE = p.PROCESS_DATE
                  AND s.ACCOUNT_NUMBER = p.ACCOUNT_ID
                  AND s.SCHEDULE_DUE_DATE <= p.PERIOD_END_DATE
                ORDER BY s.SCHEDULE_DUE_DATE DESC, s.SCHEDULE_NO DESC
            ) schedule_row
            OUTER APPLY
            (
                SELECT TOP (1)
                    s.EAD_0
                FROM STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE s
                WHERE s.PROCESS_DATE = p.PROCESS_DATE
                  AND s.ACCOUNT_NUMBER = p.ACCOUNT_ID
                ORDER BY s.SCHEDULE_DUE_DATE, s.SCHEDULE_NO
            ) source_balance
            WHERE p.HORIZON BETWEEN 1 AND 120
              AND source_balance.EAD_0 IS NOT NULL;

            IF NOT EXISTS
            (
                SELECT 1
                FROM ecl_stg.EADCurve
                WHERE RUN_ID = @RUN_ID
            )
                THROW 51603, 'EAD loader: no EAD rows were derived. Check PROCESS_DATE and ACCOUNT_ID/ACCOUNT_NUMBER matches in STAGING_MPP.dbo.TBL_NONREVOLVING_EAD_SCHEDULE.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurve
            WHERE RUN_ID = @RUN_ID
              AND (PROCESS_DATE <> @PROCESS_DATE OR EAD < 0 OR CURRENCY_CODE <> 'VND')
        )
            THROW 51604, 'EAD loader: input date must match the run, EAD must be non-negative, and currency must be VND.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.EADCurve e
            LEFT JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = e.RUN_ID
             AND a.ACCOUNT_ID = e.ACCOUNT_ID
            WHERE e.RUN_ID = @RUN_ID
              AND (a.ACCOUNT_ID IS NULL OR a.PROCESS_DATE <> e.PROCESS_DATE)
        )
            THROW 51605, 'EAD loader: every EAD row must match an account snapshot with the same process date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            CROSS APPLY
            (
                SELECT CONVERT(int, CEILING(DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE) / 12.0)) AS HORIZON
            ) h
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND
              (
                  a.MATURITY_DATE <= @PROCESS_DATE
                  OR h.HORIZON < 1
                  OR h.HORIZON > 120
                  OR EXISTS
                  (
                      SELECT 1
                      FROM
                      (
                          SELECT TOP (120)
                              ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                          FROM sys.all_objects x
                          CROSS JOIN sys.all_objects y
                      ) n
                      WHERE n.N <= h.HORIZON
                        AND NOT EXISTS
                        (
                            SELECT 1
                            FROM ecl_stg.EADCurve e
                            WHERE e.RUN_ID = a.RUN_ID
                              AND e.ACCOUNT_ID = a.ACCOUNT_ID
                              AND e.PROCESS_DATE = @PROCESS_DATE
                              AND e.FORECAST_PERIOD = n.N
                              AND e.IS_ACTIVE = 1
                              AND e.CURRENCY_CODE = 'VND'
                        )
                  )
              )
        )
            THROW 51606, 'EAD loader: active accounts need active VND EAD rows for every annual period through maturity (maximum 120 periods).', 1;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID
          AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'EAD_LOAD', 'SUCCEEDED',
            N'Loaded or validated annual EAD rows in canonical EADCurve.',
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS EAD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
