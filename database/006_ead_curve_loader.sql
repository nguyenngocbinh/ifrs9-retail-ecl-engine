/*
Migration 006: shared EAD curve validation for all retail products.

Product-specific ETL calculates annual EAD and loads it directly into the canonical
ecl_stg.EADCurve table. This procedure validates the rows for a RUN_ID and records
the successful load in audit; it does not copy rows through a second staging table
or calculate product-specific EAD.
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

    DECLARE @PROCESS_DATE date, @RUN_STATUS varchar(20), @ROW_COUNT bigint;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51600, 'EAD loader: run does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51601, 'EAD loader is only allowed before calculation begins.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1
        )
            THROW 51602, 'EAD loader: no active account snapshots exist for this run.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM ecl_stg.EADCurve
            WHERE RUN_ID = @RUN_ID
        )
            THROW 51603, 'EAD loader: no EAD rows have been loaded directly into ecl_stg.EADCurve for this run.', 1;

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
              ON a.RUN_ID = e.RUN_ID AND a.ACCOUNT_ID = e.ACCOUNT_ID
            WHERE e.RUN_ID = @RUN_ID
              AND (a.ACCOUNT_ID IS NULL OR a.PROCESS_DATE <> e.PROCESS_DATE)
        )
            THROW 51605, 'EAD loader: every EAD row must match an account snapshot with the same process date.', 1;

        /*
          Accounts with MATURITY_DATE <= PROCESS_DATE use exactly FORECAST_PERIOD=1
          as the post-maturity processing period, regardless of Stage. Accounts with
          future maturity require coverage through their annual horizon. Maximum
          supported horizon remains 120 periods.
        */
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
                  h.HORIZON > 120
                  OR
                  (
                      h.HORIZON >= 1
                      AND EXISTS
                      (
                          SELECT 1
                          FROM
                          (
                              SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                              FROM sys.all_objects x CROSS JOIN sys.all_objects y
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
        )
            THROW 51606, 'EAD loader: active accounts need active VND EAD rows for every required period; matured accounts use FORECAST_PERIOD=1. Maximum supported horizon is 120 periods.', 1;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.EADCurve
        WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'EAD_LOAD', 'SUCCEEDED',
             N'Validated annual EAD rows loaded directly into canonical EADCurve.',
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS EAD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
