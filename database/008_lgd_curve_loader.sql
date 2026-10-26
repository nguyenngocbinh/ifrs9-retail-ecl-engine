/*
Migration 008: shared LGD curve validation.
Source-specific ETL expands the point-in-time calibration LGD to annual periods
and loads canonical ecl_stg.LGDCurve. This procedure validates the canonical
annual curve; it does not calculate LGD or apply downturn LGD overlays.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_core.usp_LoadLGDCurve', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_LoadLGDCurve;
GO
CREATE PROCEDURE ecl_core.usp_LoadLGDCurve
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
            THROW 51800, 'LGD loader: run does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51801, 'LGD loader is only allowed before calculation begins.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
        )
            THROW 51802, 'LGD loader: no active account snapshots exist for this run.', 1;

        IF NOT EXISTS (SELECT 1 FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID)
            THROW 51803, 'LGD loader: no annual LGD rows have been loaded into ecl_stg.LGDCurve.', 1;

        IF EXISTS
        (
            SELECT 1 FROM ecl_stg.LGDCurve
            WHERE RUN_ID = @RUN_ID
              AND (PROCESS_DATE <> @PROCESS_DATE OR LGD < 0 OR LGD > 1 OR FORECAST_PERIOD < 1)
        )
            THROW 51804, 'LGD loader: PROCESS_DATE must match the run, LGD must be in [0,1], and FORECAST_PERIOD must be positive.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.LGDCurve l
            LEFT JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = l.RUN_ID
             AND a.ACCOUNT_ID = l.ACCOUNT_ID
             AND a.PROCESS_DATE = l.PROCESS_DATE
            WHERE l.RUN_ID = @RUN_ID
              AND (a.ACCOUNT_ID IS NULL OR a.IS_ACTIVE <> 1)
        )
            THROW 51805, 'LGD loader: every LGD row must match an active account snapshot for the same run and process date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            CROSS APPLY
            (
                SELECT CASE
                    WHEN a.STAGE = 3 THEN 1
                    WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                    ELSE CONVERT(int, CEILING(
                        (DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                         + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE
                                THEN 1 ELSE 0 END) / 12.0))
                END AS HORIZON
            ) h
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND
              (
                  h.HORIZON < 1 OR h.HORIZON > 120
                  OR EXISTS
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
                            SELECT 1 FROM ecl_stg.LGDCurve l
                            WHERE l.RUN_ID = a.RUN_ID
                              AND l.ACCOUNT_ID = a.ACCOUNT_ID
                              AND l.PROCESS_DATE = @PROCESS_DATE
                              AND l.FORECAST_PERIOD = n.N
                              AND l.IS_ACTIVE = 1
                        )
                  )
              )
        )
            THROW 51806, 'LGD loader: each active Stage 1/2 account needs LGD rows through maturity; Stage 3 needs only period 1 (maximum 120 periods).', 1;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.LGDCurve
        WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'LGD_LOAD', 'SUCCEEDED',
             N'Validated annual account-level LGD rows loaded into canonical LGDCurve; LGD is flat across scenarios in v1.',
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;
        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS LGD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
