/*
Source-specific ETL: IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload -> ecl_stg.LGDCurve.

The source supplies one LGD observation per account at reporting_date, not a
multi-year curve. This procedure repeats calibration_lgd across each required
annual forecast period through AccountSnapshot.MATURITY_DATE. The canonical
v1 contract uses one LGD across scenarios, so downturn_lgd is intentionally
not applied; it remains a source attribute for a future approved scenario-LGD
enhancement. Source version is retained in the audit message; canonical
VERSION_ID comes from AccountSnapshot.VERSION_ID.

Requires the source database/table to be queryable from this SQL Server.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_core.usp_StageSourceLGDCurve', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_StageSourceLGDCurve;
GO
CREATE PROCEDURE ecl_core.usp_StageSourceLGDCurve
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @RUN_STATUS varchar(20), @INSERTED bigint, @SOURCE_VERSIONS nvarchar(500);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51900, 'Source LGD ETL: run does not exist.', 1;
        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51901, 'Source LGD ETL is only allowed before calculation begins.', 1;
        IF EXISTS (SELECT 1 FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID)
            THROW 51902, 'Source LGD ETL: LGDCurve already contains rows for this run; use a new RUN_ID instead of overwriting inputs.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload s
            JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = @RUN_ID AND a.ACCOUNT_ID = s.account_id
             AND a.PROCESS_DATE = @PROCESS_DATE
            WHERE s.reporting_date = @PROCESS_DATE
            GROUP BY s.reporting_date, s.account_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51903, 'Source LGD ETL: duplicate source rows exist for an account and reporting date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND NOT EXISTS
              (
                  SELECT 1 FROM IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload s
                  WHERE s.reporting_date = @PROCESS_DATE
                    AND s.account_id = a.ACCOUNT_ID
              )
        )
            THROW 51904, 'Source LGD ETL: an active account has no source LGD row for the run reporting date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload s
            JOIN ecl_stg.AccountSnapshot a
              ON a.RUN_ID = @RUN_ID AND a.ACCOUNT_ID = s.account_id
             AND a.PROCESS_DATE = @PROCESS_DATE AND a.IS_ACTIVE = 1
            WHERE s.reporting_date = @PROCESS_DATE
              AND (s.calibration_lgd IS NULL OR s.calibration_lgd < 0 OR s.calibration_lgd > 1)
        )
            THROW 51905, 'Source LGD ETL: calibration_lgd must be non-null and in [0,1].', 1;

        ;WITH SourceLGD AS
        (
            SELECT
                a.RUN_ID, a.PROCESS_DATE, a.ACCOUNT_ID, a.MATURITY_DATE, a.VERSION_ID,
                CONVERT(decimal(19,12), s.calibration_lgd) AS LGD,
                CASE
                    WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                    ELSE CONVERT(int, CEILING(
                        (DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                         + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE
                                THEN 1 ELSE 0 END) / 12.0))
                END AS HORIZON
            FROM ecl_stg.AccountSnapshot a
            JOIN IRB_MHRR.lgd.irb_tt14_nhnn_lgd_upload s
              ON s.account_id = a.ACCOUNT_ID
             AND s.reporting_date = @PROCESS_DATE
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
        )
        INSERT INTO ecl_stg.LGDCurve
            (RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD, LGD, VERSION_ID, IS_ACTIVE)
        SELECT s.RUN_ID, s.PROCESS_DATE, s.ACCOUNT_ID, n.N, s.LGD, s.VERSION_ID, 1
        FROM SourceLGD s
        CROSS APPLY
        (
            SELECT TOP (CASE WHEN s.HORIZON BETWEEN 1 AND 120 THEN s.HORIZON ELSE 0 END)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects x CROSS JOIN sys.all_objects y
        ) n;

        SET @INSERTED = @@ROWCOUNT;

        IF @INSERTED = 0
            THROW 51906, 'Source LGD ETL: no annual LGD rows were generated.', 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'LGD_SOURCE_STAGE', 'SUCCEEDED',
             CONCAT(N'Expanded source calibration_lgd by account to annual periods through maturity. Source version(s)=', COALESCE(@SOURCE_VERSIONS, N'unknown'), N'; downturn_lgd is not applied in v1.'),
             @INSERTED, SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @INSERTED AS LGD_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
