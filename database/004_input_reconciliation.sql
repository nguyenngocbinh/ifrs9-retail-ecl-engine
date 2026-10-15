/*
Migration 004: source manifest vs staging reconciliation (SQL Server 2016).
This is a pre-calculation control. It does not create ECL or mark a run as reconciled
for publication. Snapshot counts include active and inactive rows, matching physical
staged row counts. The source contract must certify that manifest counts use the same grain.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'ecl_core.usp_ReconcileInputSnapshots', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_ReconcileInputSnapshots;
GO
CREATE PROCEDURE ecl_core.usp_ReconcileInputSnapshots
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @STATUS varchar(20), @SEALED bit;
    SELECT @PROCESS_DATE = PROCESS_DATE, @STATUS = RUN_STATUS
    FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;
    IF @PROCESS_DATE IS NULL THROW 51500, 'Run does not exist.', 1;
    IF @STATUS <> 'VALIDATING' THROW 51501, 'Input reconciliation requires VALIDATING status.', 1;
    SELECT @SEALED = IS_SEALED FROM ecl_core.RunInputManifest WHERE RUN_ID = @RUN_ID;
    IF ISNULL(@SEALED, 0) <> 1 THROW 51502, 'Input reconciliation requires sealed manifest.', 1;

    DECLARE @COUNTS TABLE
    (
        INPUT_FAMILY varchar(30) NOT NULL PRIMARY KEY,
        EXPECTED_ROWS bigint NULL,
        ACTUAL_ROWS bigint NOT NULL
    );

    INSERT INTO @COUNTS (INPUT_FAMILY, EXPECTED_ROWS, ACTUAL_ROWS)
    SELECT f.INPUT_FAMILY, m.SNAPSHOT_ROW_COUNT, f.ACTUAL_ROWS
    FROM
    (
        SELECT 'ACCOUNT' AS INPUT_FAMILY, COUNT_BIG(*) AS ACTUAL_ROWS
        FROM ecl_stg.AccountSnapshot WHERE RUN_ID = @RUN_ID
        UNION ALL
        SELECT 'PD', COUNT_BIG(*) FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID
        UNION ALL
        SELECT 'LGD', COUNT_BIG(*) FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID
        UNION ALL
        SELECT 'EAD', COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID
        UNION ALL
        SELECT 'EIR', COUNT_BIG(*) FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID
        UNION ALL
        SELECT 'SCENARIO_WEIGHT', COUNT_BIG(*)
        FROM ecl_cfg.ScenarioWeight w
        JOIN ecl_core.RunControl r
          ON r.RUN_ID = @RUN_ID AND r.SCENARIO_WEIGHT_VERSION_ID = w.VERSION_ID
    ) f
    LEFT JOIN ecl_core.RunInputManifestItem m
      ON m.RUN_ID = @RUN_ID AND m.INPUT_FAMILY = f.INPUT_FAMILY
     AND m.IS_COMPLETE = 1;

    /* Reject stale dates even if manifest row counts happen to match. */
    DECLARE @DATE_MISMATCH bigint =
        (SELECT COUNT_BIG(*) FROM ecl_stg.AccountSnapshot WHERE RUN_ID = @RUN_ID AND PROCESS_DATE <> @PROCESS_DATE)
      + (SELECT COUNT_BIG(*) FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID AND PROCESS_DATE <> @PROCESS_DATE)
      + (SELECT COUNT_BIG(*) FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID AND PROCESS_DATE <> @PROCESS_DATE)
      + (SELECT COUNT_BIG(*) FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID AND PROCESS_DATE <> @PROCESS_DATE)
      + (SELECT COUNT_BIG(*) FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID AND PROCESS_DATE <> @PROCESS_DATE);

    DECLARE @POCI_COUNT bigint =
        (SELECT COUNT_BIG(*) FROM ecl_stg.AccountSnapshot
         WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1 AND IS_POCI = 1);
    DECLARE @UNKNOWN_POCI_COUNT bigint =
        (SELECT COUNT_BIG(*) FROM ecl_stg.AccountSnapshot
         WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1 AND IS_POCI IS NULL);
    DECLARE @ACTIVE_ACCOUNT_COUNT bigint =
        (SELECT COUNT_BIG(*) FROM ecl_stg.AccountSnapshot
         WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1);

    DECLARE @MISMATCH_COUNT int = (SELECT COUNT(*) FROM @COUNTS
                                    WHERE EXPECTED_ROWS IS NULL OR EXPECTED_ROWS <> ACTUAL_ROWS);
    DECLARE @FAIL_COUNT int = @MISMATCH_COUNT
        + CASE WHEN @DATE_MISMATCH > 0 THEN 1 ELSE 0 END
        + CASE WHEN @UNKNOWN_POCI_COUNT > 0 THEN 1 ELSE 0 END
        + CASE WHEN @POCI_COUNT > 0 THEN 1 ELSE 0 END;

    /* Serialize this run's reconciliation audit writes; no lifecycle status changes. */
    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @STATUS = RUN_STATUS FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;
        IF @STATUS <> 'VALIDATING' THROW 51503, 'Run status changed during reconciliation.', 1;

        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'MANIFEST_COUNT_MISMATCH', 'ERROR',
               CONCAT(N'Input family ', c.INPUT_FAMILY, N': manifest rows=',
                      COALESCE(CONVERT(varchar(30), c.EXPECTED_ROWS), 'MISSING'),
                      N'; staged rows=', c.ACTUAL_ROWS, N'.')
        FROM @COUNTS c
        WHERE (c.EXPECTED_ROWS IS NULL OR c.EXPECTED_ROWS <> c.ACTUAL_ROWS)
          AND NOT EXISTS
          (
              SELECT 1 FROM ecl_audit.ValidationError v
              WHERE v.RUN_ID = @RUN_ID AND v.VALIDATION_CODE = 'MANIFEST_COUNT_MISMATCH'
                AND v.ERROR_MESSAGE = CONCAT(N'Input family ', c.INPUT_FAMILY, N': manifest rows=',
                      COALESCE(CONVERT(varchar(30), c.EXPECTED_ROWS), 'MISSING'),
                      N'; staged rows=', c.ACTUAL_ROWS, N'.')
          );

        IF @DATE_MISMATCH > 0 AND NOT EXISTS
            (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'STAGING_DATE_MISMATCH')
            INSERT INTO ecl_audit.ValidationError
                (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
            VALUES (@RUN_ID, @PROCESS_DATE, 'STAGING_DATE_MISMATCH', 'ERROR',
                    CONCAT(@DATE_MISMATCH, N' staged rows have PROCESS_DATE different from the run.'));

        IF @UNKNOWN_POCI_COUNT > 0 AND NOT EXISTS
            (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'POCI_RECON_UNKNOWN')
            INSERT INTO ecl_audit.ValidationError
                (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
            VALUES (@RUN_ID, @PROCESS_DATE, 'POCI_RECON_UNKNOWN', 'ERROR',
                    CONCAT(@UNKNOWN_POCI_COUNT, N' active accounts have unknown POCI classification.'));

        /* Until downstream calculation excludes and reconciles POCI, ERROR is mandatory. */
        IF @POCI_COUNT > 0 AND NOT EXISTS
            (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'POCI_RECON_BLOCKED')
            INSERT INTO ecl_audit.ValidationError
                (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
            VALUES (@RUN_ID, @PROCESS_DATE, 'POCI_RECON_BLOCKED', 'ERROR',
                    CONCAT(@POCI_COUNT, N' POCI accounts require explicit downstream exclusion and reconciliation.'));

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, AMOUNT_VALUE)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'INPUT_RECONCILIATION',
             CASE WHEN @FAIL_COUNT = 0 THEN 'SUCCEEDED' ELSE 'FAILED' END,
             CONCAT(N'Manifest count mismatches=', @MISMATCH_COUNT,
                    N'; stale-date rows=', @DATE_MISMATCH,
                    N'; active accounts=', @ACTIVE_ACCOUNT_COUNT,
                    N'; POCI=', @POCI_COUNT,
                    N'; unknown POCI=', @UNKNOWN_POCI_COUNT,
                    N'. This event does NOT authorize ECL publication.'),
             @ACTIVE_ACCOUNT_COUNT, CONVERT(decimal(28,8), @POCI_COUNT));
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT INPUT_FAMILY, EXPECTED_ROWS, ACTUAL_ROWS,
           CASE WHEN EXPECTED_ROWS = ACTUAL_ROWS THEN 'MATCH' ELSE 'MISMATCH' END AS RESULT
    FROM @COUNTS ORDER BY INPUT_FAMILY;

    SELECT @RUN_ID AS RUN_ID,
           CASE WHEN @FAIL_COUNT = 0 THEN 'SUCCEEDED' ELSE 'FAILED' END AS RECONCILIATION_STATUS,
           @MISMATCH_COUNT AS MANIFEST_MISMATCH_FAMILIES,
           @DATE_MISMATCH AS STAGING_DATE_MISMATCH_ROWS,
           @ACTIVE_ACCOUNT_COUNT AS ACTIVE_ACCOUNT_COUNT,
           @POCI_COUNT AS POCI_ACCOUNT_COUNT,
           @UNKNOWN_POCI_COUNT AS UNKNOWN_POCI_ACCOUNT_COUNT;
END;
GO
