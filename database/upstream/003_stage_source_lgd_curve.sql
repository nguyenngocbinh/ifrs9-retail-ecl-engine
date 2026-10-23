/*
IFRS 9 Retail ECL Engine — upstream LGD source loader

Purpose:
- Read the reporting-date LGD observation from dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD.
- Match source accounts to active ecl_stg.AccountSnapshot rows for RUN_ID.
- Expand calibration_lgd to annual periods through MATURITY_DATE and load
  the canonical ecl_stg.LGDCurve contract, consistent with PD/EAD ETL structure.
- Keep LGD flat across scenarios in v1; downturn_lgd is not applied.

Prerequisites:
  database/001_create_logical_schema.sql
  database/002_run_control.sql
  database/upstream/002_load_account_snapshot.sql
The source view must be queryable from the same SQL Server database.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourceLGDCurve
    @RUN_ID bigint
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


        /* Exactly one source observation per account for the reporting date. */
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

        /* Every active account must have a source observation for the run date. */
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

        /*
          Source version is optional: dynamically inspect the source metadata first,
          so this loader works whether or not the upload view exposes SOURCE_VERSION.
          Values, when available, are added to the audit event below.
        */
        IF EXISTS
        (
            SELECT 1
            FROM sys.columns AS c
            INNER JOIN sys.views AS v
              ON v.object_id = c.object_id
            INNER JOIN sys.schemas AS sc
              ON sc.schema_id = v.schema_id
            WHERE sc.name = N'dbo'
              AND v.name = N'VW_IRB_TT14_NHNN_LGD_UPLOAD'
              AND c.name = N'source_version'
        )
        BEGIN
            DECLARE @VersionSql nvarchar(max) =
                N'SELECT @Versions = STRING_AGG(CONVERT(nvarchar(50), q.source_version), N'','')
                  FROM
                  (
                      SELECT DISTINCT s.source_version
                      FROM dbo.VW_IRB_TT14_NHNN_LGD_UPLOAD AS s
                      INNER JOIN ecl_stg.AccountSnapshot AS a
                        ON a.RUN_ID = @RunId
                       AND a.PROCESS_DATE = @ProcessDate
                       AND a.ACCOUNT_ID = s.account_id
                       AND a.IS_ACTIVE = 1
                      WHERE s.reporting_date = @ProcessDate
                        AND s.source_version IS NOT NULL
                  ) AS q;';
            EXEC sys.sp_executesql
                @VersionSql,
                N'@RunId bigint, @ProcessDate date, @Versions nvarchar(500) OUTPUT',
                @RunId = @RUN_ID,
                @ProcessDate = @PROCESS_DATE,
                @Versions = @SOURCE_VERSIONS OUTPUT;
        END;

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

        /* Validate all horizons before replacing/committing any rows. */
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
                  OR
                  (
                      a.MATURITY_DATE > @PROCESS_DATE
                      AND
                      (
                          DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                          + CASE
                              WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE
                              THEN 1 ELSE 0
                            END
                      ) > 120 * 12
                  )
                  OR NOT EXISTS
                  (
                      SELECT 1
                      FROM #MappedLGD AS l
                      WHERE l.RUN_ID = a.RUN_ID
                        AND l.ACCOUNT_ID = a.ACCOUNT_ID
                        AND l.FORECAST_PERIOD = 1
                  )
                  OR EXISTS
                  (
                      SELECT 1
                      FROM #MappedLGD AS l
                      WHERE l.RUN_ID = a.RUN_ID
                        AND l.ACCOUNT_ID = a.ACCOUNT_ID
                      GROUP BY l.RUN_ID, l.ACCOUNT_ID
                      HAVING MAX(l.FORECAST_PERIOD) <>
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
                          END
                  )
              )
        )
            THROW 51909, 'LGD source ETL: invalid maturity horizon or generated annual LGD periods do not cover each active account through maturity.', 1;

        IF EXISTS
        (
            SELECT 1 FROM #MappedLGD
            WHERE LGD IS NULL OR LGD < 0 OR LGD > 1 OR FORECAST_PERIOD < 1
        )
            THROW 51910, 'LGD source ETL: mapped rows contain invalid LGD or forecast periods.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            FROM #MappedLGD
            GROUP BY RUN_ID, ACCOUNT_ID, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51911, 'LGD source ETL: mapped data contains duplicate canonical LGD keys.', 1;

        /* Match PD source-loader behavior: replace this RUN_ID after all validations pass. */
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
                COALESCE(@SOURCE_VERSIONS, N'not exposed by source view'),
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

/*
Example:
EXEC ecl_core.usp_StageSourceLGDCurve
    @RUN_ID = 123;

Then run database/008_lgd_curve_loader.sql's ecl_core.usp_LoadLGDCurve
to validate the canonical LGD curve contract.
*/
