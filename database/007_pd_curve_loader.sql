/*
Migration 007: shared PD curve validation for all retail products.

Source-specific ETL maps facility rating and the approved PD source into the
canonical ecl_stg.PDCurve contract. This procedure validates rows already
loaded directly into PDCurve; it does not calculate PD or infer scenario mapping.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_core.usp_LoadPDCurve', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_LoadPDCurve;
GO
CREATE PROCEDURE ecl_core.usp_LoadPDCurve
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
            THROW 51700, 'PD loader: run does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51701, 'PD loader is only allowed before calculation begins.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
        )
            THROW 51702, 'PD loader: no active account snapshots exist for this run.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID
        )
            THROW 51703, 'PD loader: no PD rows have been loaded directly into ecl_stg.PDCurve for this run.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.PDCurve
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE <> @PROCESS_DATE
        )
            THROW 51704, 'PD loader: every PD row must use the run PROCESS_DATE.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.PDCurve p
            LEFT JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = p.RUN_ID
             AND a.ACCOUNT_ID = p.ACCOUNT_ID
             AND a.PROCESS_DATE = p.PROCESS_DATE
            WHERE p.RUN_ID = @RUN_ID
              AND (a.ACCOUNT_ID IS NULL OR a.IS_ACTIVE <> 1)
        )
            THROW 51705, 'PD loader: every PD row must match an active account snapshot for the same run and process date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.PDCurve
            WHERE RUN_ID = @RUN_ID
              AND (MARGINAL_PD < 0 OR MARGINAL_PD > 1 OR FORECAST_PERIOD < 1)
        )
            THROW 51706, 'PD loader: MARGINAL_PD must be in [0,1] and FORECAST_PERIOD must be positive.', 1;

        /*
          Require each active, non-POCI account to have all three canonical
          scenarios for every annual forecast period through maturity.
          A final partial year still requires the full annual PD input;
          only the discount-time exponent is partial.
        */
        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            CROSS APPLY
            (
                SELECT CASE
                    WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                    ELSE CONVERT(int, CEILING(
                        CONVERT(decimal(10,2),
                            DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                            + CASE
                                WHEN DATEADD(month,
                                    DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE),
                                    @PROCESS_DATE) < a.MATURITY_DATE
                                THEN 1 ELSE 0
                              END
                        ) / 12.0))
                END AS HORIZON
            ) h
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND
              (
                  h.HORIZON < 1
                  OR h.HORIZON > 120
                  OR EXISTS
                  (
                      SELECT 1
                      FROM
                      (
                          SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                          FROM sys.all_objects x CROSS JOIN sys.all_objects y
                      ) n
                      CROSS JOIN (VALUES ('DOWNTURN'), ('BASE'), ('UPTURN')) s(SCENARIO_CODE)
                      WHERE n.N <= h.HORIZON
                        AND NOT EXISTS
                        (
                            SELECT 1
                            FROM ecl_stg.PDCurve p
                            WHERE p.RUN_ID = a.RUN_ID
                              AND p.ACCOUNT_ID = a.ACCOUNT_ID
                              AND p.PROCESS_DATE = @PROCESS_DATE
                              AND p.FORECAST_PERIOD = n.N
                              AND p.SCENARIO_CODE = s.SCENARIO_CODE
                              AND p.IS_ACTIVE = 1
                        )
                  )
              )
        )
            THROW 51707, 'PD loader: each active non-POCI account needs active PD rows for DOWNTURN, BASE, and UPTURN for every annual period through maturity (maximum 120 periods).', 1;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.PDCurve
        WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_LOAD', 'SUCCEEDED',
             N'Validated scenario-specific annual marginal PD rows loaded directly into canonical PDCurve.',
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS PD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
