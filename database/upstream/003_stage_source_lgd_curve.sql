/*
IFRS 9 Retail ECL Engine — upstream LGD source loader

Purpose:
- Read the reporting-date LGD observation from dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD.
- Match source accounts to the active ecl_stg.AccountSnapshot for RUN_ID.
- Expand calibration_lgd into the canonical annual ecl_stg.LGDCurve contract
  through MATURITY_DATE, following the source-loader pattern used by PD/EAD.
- Keep LGD flat across scenarios in v1. downturn_lgd is intentionally not applied.

Prerequisites:
  database/001_create_logical_schema.sql
  database/002_run_control.sql
  database/upstream/002_load_account_snapshot.sql
Source contract must be queryable in the same SQL Server database as this procedure.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourceLGDCurve
    @RUN_ID bigint,
    @REPLACE_EXISTING bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @ROW_COUNT bigint,
        @SOURCE_VERSIONS nvarchar(500);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @PROCESS_DATE = PROCESS_DATE,
            @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51900, 'LGD source ETL: RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51901, 'LGD source ETL is only allowed while the run is CREATED or VALIDATING.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE = @PROCESS_DATE
              AND IS_ACTIVE = 1
        )
            THROW 51902, 'LGD source ETL: no active AccountSnapshot rows exist for this run.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.LGDCurve
            WHERE RUN_ID = @RUN_ID
        )
        BEGIN
            IF @REPLACE_EXISTING = 0
                THROW 51903, 'LGD source ETL: LGDCurve rows already exist for RUN_ID. Set @REPLACE_EXISTING = 1 to replace before the run manifest is sealed.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM ecl_core.RunInputManifest
                WHERE RUN_ID = @RUN_ID
                  AND IS_SEALED = 1
            )
                THROW 51904, 'LGD source ETL: cannot replace LGDCurve after the run input manifest is sealed.', 1;

            IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID = @RUN_ID)
                THROW 51905, 'LGD source ETL: cannot replace LGDCurve after ECL results exist; use a new RUN_ID or an approved reset.', 1;
        END;

        /* One and only one source row per active account for the run date. */
        IF EXISTS
        (
            SELECT s.account_id
            FROM dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
            INNER JOIN ecl_stg.AccountSnapshot AS a
              ON a.RUN_ID = @RUN_ID
             AND a.PROCESS_DATE = @PROCESS_DATE
             AND a.ACCOUNT_ID = s.account_id
             AND a.IS_ACTIVE = 1
            WHERE s.reporting_date = @PROCESS_DATE
            GROUP BY s.account_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51906, 'LGD source ETL: duplicate source observations for an account and reporting date.', 1;

        /* Fail closed if any active account lacks a same-date LGD source row. */
        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot AS a
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
                  WHERE s.reporting_date = @PROCESS_DATE
                    AND s.account_id = a.ACCOUNT_ID
              )
        )
            THROW 51907, 'LGD source ETL: at least one active account has no LGD observation for the run reporting date.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
            INNER JOIN ecl_stg.AccountSnapshot AS a
              ON a.RUN_ID = @RUN_ID
             AND a.PROCESS_DATE = @PROCESS_DATE
             AND a.ACCOUNT_ID = s.account_id
             AND a.IS_ACTIVE = 1
            WHERE s.reporting_date = @PROCESS_DATE
              AND
              (
                  s.calibration_lgd IS NULL
                  OR s.calibration_lgd < 0
                  OR s.calibration_lgd > 1
              )
        )
            THROW 51908, 'LGD source ETL: calibration_lgd must be non-null and within [0,1].', 1;

        /* Retain source version provenance in the audit event when available. */
        SELECT @SOURCE_VERSIONS =
            STRING_AGG(CONVERT(nvarchar(50), q.source_version), N',')
        FROM
        (
            SELECT DISTINCT s.source_version
            FROM dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
            INNER JOIN ecl_stg.AccountSnapshot AS a
              ON a.RUN_ID = @RUN_ID
             AND a.PROCESS_DATE = @PROCESS_DATE
             AND a.ACCOUNT_ID = s.account_id
             AND a.IS_ACTIVE = 1
            WHERE s.reporting_date = @PROCESS_DATE
              AND s.source_version IS NOT NULL
        ) AS q;

        DROP TABLE IF EXISTS #MappedLGD;

        ;WITH SourceLGD AS
        (
            SELECT
                a.RUN_ID,
                a.PROCESS_DATE,
                a.ACCOUNT_ID,
                a.MATURITY_DATE,
                a.VERSION_ID,
                CONVERT(decimal(19,12), s.calibration_lgd) AS LGD,
                CASE
                    WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                    ELSE CONVERT(int, CEILING(
                        (
                            DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                            + CASE
                                WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE
                                THEN 1 ELSE 0
                              END
                        ) / 12.0
                    ))
                END AS HORIZON
            FROM ecl_stg.AccountSnapshot AS a
            INNER JOIN dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
              ON s.account_id = a.ACCOUNT_ID
             AND s.reporting_date = @PROCESS_DATE
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
        )
        SELECT
            s.RUN_ID,
            s.PROCESS_DATE,
            s.ACCOUNT_ID,
            n.N AS FORECAST_PERIOD,
            s.LGD,
            s.VERSION_ID,
            CONVERT(bit, 1) AS IS_ACTIVE
        INTO #MappedLGD
        FROM SourceLGD AS s
        CROSS APPLY
        (
            SELECT TOP
            (
                CASE WHEN s.HORIZON BETWEEN 1 AND 120 THEN s.HORIZON ELSE 0 END
            )
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects AS x
            CROSS JOIN sys.all_objects AS y
        ) AS n;

        IF EXISTS
        (
            SELECT 1 FROM #MappedLGD
            WHERE LGD IS NULL OR LGD < 0 OR LGD > 1 OR FORECAST_PERIOD < 1
        )
            THROW 51909, 'LGD source ETL: mapped rows contain invalid LGD or forecast periods.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot AS a
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND
              (
                  a.MATURITY_DATE IS NULL
                  OR a.MATURITY_DATE > DATEADD(year, 120, @PROCESS_DATE)
                  OR NOT EXISTS
                  (
                      SELECT 1
                      FROM #MappedLGD AS l
                      WHERE l.RUN_ID = a.RUN_ID
                        AND l.ACCOUNT_ID = a.ACCOUNT_ID
                        AND l.FORECAST_PERIOD = 1
                  )
              )
        )
            THROW 51910, 'LGD source ETL: maturity horizon is invalid or no annual LGD rows were generated for an active account.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            FROM #MappedLGD
            GROUP BY RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51911, 'LGD source ETL: mapped data contains duplicate canonical LGD keys.', 1;

        IF @REPLACE_EXISTING = 1
            DELETE FROM ecl_stg.LGDCurve
            WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.LGDCurve
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD,
            LGD, VERSION_ID, IS_ACTIVE
        )
        SELECT
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, FORECAST_PERIOD,
            LGD, VERSION_ID, IS_ACTIVE
        FROM #MappedLGD;

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51912, 'LGD source ETL: no annual LGD rows were generated.', 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'LGD_SOURCE_ETL', 'SUCCEEDED',
            CONCAT(
                N'Loaded source calibration_lgd into annual ecl_stg.LGDCurve through maturity. Source version(s)=',
                COALESCE(@SOURCE_VERSIONS, N'unknown'),
                N'; downturn_lgd is not applied in v1.'
            ),
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT
            @RUN_ID AS RUN_ID,
            @PROCESS_DATE AS PROCESS_DATE,
            @ROW_COUNT AS LGD_ROW_COUNT,
            'SUCCEEDED' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
