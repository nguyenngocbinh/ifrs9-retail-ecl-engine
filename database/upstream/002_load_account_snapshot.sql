/*
IFRS 9 Retail ECL Engine — canonical AccountSnapshot loader
Target: SQL Server 2022 (repository CI target)

Prerequisites:
  1. database/001_create_logical_schema.sql
  2. database/002_run_control.sql
  3. database/upstream/001_load_account_stage_pool_source.sql
  4. ecl_stg.AccountStagePoolSource populated for the RUN_ID

Purpose:
  - Reuse Stage/Pool already validated by usp_LoadAccountStagePoolSource.
  - Read MATURITY_DATE from dbo.VW_ODR_CONTRACT_LEVEL_IRB.expiry_date.
  - Reuse POOL_NAME already mapped by usp_LoadAccountStagePoolSource and validate it against ecl_cfg.PoolName.
  - Insert the canonical account grain RUN_ID + ACCOUNT_ID into AccountSnapshot.

Important:
  - Does not recalculate Stage or Pool.
  - Does not infer a pool name. Source POOL_NAME must match an active configured value in ecl_cfg.PoolName.
  - Review physical source names and test in a disposable database before use.
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_LoadAccountSnapshot
    @RUN_ID bigint,
    @VERSION_ID int,
    @REPLACE_EXISTING bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date;
    DECLARE @RUN_STATUS varchar(20);
    DECLARE @RUN_TYPE varchar(20);
    DECLARE @REQUESTED_POOL_NAME varchar(100);
    DECLARE @REQUESTED_POOL_ID varchar(100);
    DECLARE @ROW_COUNT bigint;

    SELECT
        @PROCESS_DATE = PROCESS_DATE,
        @RUN_STATUS = RUN_STATUS,
        @RUN_TYPE = RUN_TYPE,
        @REQUESTED_POOL_NAME = REQUESTED_POOL_NAME,
        @REQUESTED_POOL_ID = REQUESTED_POOL_ID
    FROM ecl_core.RunControl
    WHERE RUN_ID = @RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51301, 'RUN_ID does not exist.', 1;

    IF @VERSION_ID IS NULL OR @VERSION_ID < 0
        THROW 51302, 'VERSION_ID must be a non-negative value.', 1;

    IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
        THROW 51303, 'AccountSnapshot can only be loaded while the run is CREATED or VALIDATING.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM ecl_stg.AccountStagePoolSource
        WHERE RUN_ID = @RUN_ID
          AND IS_ACTIVE = 1
    )
        THROW 51304, 'No active Stage/Pool source rows exist for RUN_ID. Load AccountStagePoolSource first.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM ecl_stg.AccountStagePoolSource
        WHERE RUN_ID = @RUN_ID
          AND IS_ACTIVE = 1
          AND (PROCESS_DATE <> @PROCESS_DATE OR VERSION_ID <> @VERSION_ID)
    )
        THROW 51305, 'Stage/Pool source PROCESS_DATE or VERSION_ID does not match the requested run/load.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM ecl_stg.AccountStagePoolSource
        WHERE RUN_ID = @RUN_ID
          AND IS_ACTIVE = 1
          AND (STAGE IS NULL OR STAGE NOT IN (1,2,3) OR POOL_ID IS NULL OR POOL_NAME IS NULL OR ACCOUNT_ID IS NULL)
    )
        THROW 51306, 'Stage/Pool source contains a missing or invalid STAGE, POOL_ID, or ACCOUNT_ID.', 1;

    /* Defense in depth: do not materialize a snapshot outside the run's requested pool. */
    IF @RUN_TYPE = 'SELECTIVE'
       AND EXISTS
       (
           SELECT 1
           FROM ecl_stg.AccountStagePoolSource AS s
           WHERE s.RUN_ID = @RUN_ID
             AND s.IS_ACTIVE = 1
             AND
             (
                 (@REQUESTED_POOL_NAME IS NOT NULL AND s.POOL_NAME <> @REQUESTED_POOL_NAME)
                 OR
                 (@REQUESTED_POOL_ID IS NOT NULL AND s.POOL_ID <> @REQUESTED_POOL_ID)
             )
       )
        THROW 51316, 'Stage/Pool source contains accounts outside the requested selective-run scope.', 1;

    /*
      A contract must resolve to exactly one source row for this process date.
      The upstream loader already checks this, but the canonical boundary repeats
      the check so this procedure remains safe if staging rows are modified later.
    */
    IF EXISTS
    (
        SELECT s.ACCOUNT_ID
        FROM ecl_stg.AccountStagePoolSource AS s
        LEFT JOIN dbo.VW_ODR_CONTRACT_LEVEL_IRB AS c
          ON c.PROCESS_DATE = s.PROCESS_DATE
         AND c.CONTRACT_ID = s.ACCOUNT_ID
        WHERE s.RUN_ID = @RUN_ID
          AND s.IS_ACTIVE = 1
        GROUP BY s.ACCOUNT_ID
        HAVING COUNT_BIG(c.CONTRACT_ID) <> 1
    )
        THROW 51307, 'Each active Stage/Pool account must match exactly one VW_ODR_CONTRACT_LEVEL_IRB row by PROCESS_DATE + CONTRACT_ID.', 1;

    DROP TABLE IF EXISTS #SnapshotCandidate;

    SELECT
        s.RUN_ID,
        s.PROCESS_DATE,
        s.ACCOUNT_ID,
        s.CUSTOMER_ID,
        p.POOL_NAME,
        s.STAGE,
        s.POOL_ID,
        TRY_CONVERT(date, c.expiry_date) AS MATURITY_DATE,
        @VERSION_ID AS VERSION_ID,
        CONVERT(bit, 1) AS IS_ACTIVE,
        CONVERT(nvarchar(200), N'dbo.VW_ODR_CONTRACT_LEVEL_IRB') AS SOURCE_REFERENCE
    INTO #SnapshotCandidate
    FROM ecl_stg.AccountStagePoolSource AS s
    INNER JOIN dbo.VW_ODR_CONTRACT_LEVEL_IRB AS c
      ON c.PROCESS_DATE = s.PROCESS_DATE
     AND c.CONTRACT_ID = s.ACCOUNT_ID
    LEFT JOIN ecl_cfg.PoolName AS p
      ON p.POOL_NAME = s.POOL_NAME
     AND p.IS_ACTIVE = 1
    WHERE s.RUN_ID = @RUN_ID
      AND s.IS_ACTIVE = 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE POOL_NAME IS NULL
    )
        THROW 51308, 'At least one source POOL_NAME is missing or inactive in ecl_cfg.PoolName. Configure the pool name before loading AccountSnapshot.', 1;

    IF @RUN_TYPE = 'SELECTIVE'
       AND EXISTS
       (
           SELECT 1
           FROM #SnapshotCandidate AS s
           WHERE (@REQUESTED_POOL_NAME IS NOT NULL AND s.POOL_NAME <> @REQUESTED_POOL_NAME)
              OR (@REQUESTED_POOL_ID IS NOT NULL AND s.POOL_ID <> @REQUESTED_POOL_ID)
       )
        THROW 51317, 'Snapshot candidates contain accounts outside the requested selective-run scope.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE MATURITY_DATE IS NULL
    )
        THROW 51309, 'At least one source contract has NULL or unconvertible expiry_date; MATURITY_DATE cannot be loaded.', 1;

    /*
      A maturity date earlier than PROCESS_DATE is allowed for Stage 3
      (credit-impaired/defaulted) accounts that may still have outstanding debt.
      For Stage 1 or Stage 2, treat this as an exception requiring review.
      Keep the NULL/unconvertible MATURITY_DATE validation above.
    */
    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE MATURITY_DATE < PROCESS_DATE
          AND STAGE <> 3
    )
        THROW 51310, 'At least one non-Stage-3 contract MATURITY_DATE is earlier than PROCESS_DATE. Review maturity/status data before loading.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        GROUP BY RUN_ID, ACCOUNT_ID
        HAVING COUNT_BIG(*) > 1
    )
        THROW 51311, 'Candidate AccountSnapshot rows are not unique at RUN_ID + ACCOUNT_ID grain.', 1;

    IF NOT EXISTS (SELECT 1 FROM #SnapshotCandidate)
        THROW 51312, 'No active AccountSnapshot candidates were produced.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
        )
        BEGIN
            IF @REPLACE_EXISTING = 0
                THROW 51313, 'AccountSnapshot rows already exist for RUN_ID. Set @REPLACE_EXISTING = 1 to replace them before the manifest is sealed.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM ecl_core.RunInputManifest
                WHERE RUN_ID = @RUN_ID
                  AND IS_SEALED = 1
            )
                THROW 51314, 'Cannot replace AccountSnapshot after the run input manifest is sealed.', 1;

            /*
              Child curve rows may reference AccountSnapshot. Refuse to replace
              after dependent curves exist instead of deleting or cascading data.
            */
            IF EXISTS (SELECT 1 FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_stg.LGDCurve WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_stg.EADCurve WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID)
               OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID = @RUN_ID)
            BEGIN
                THROW 51315, 'Cannot replace AccountSnapshot while dependent curves or ECL results exist for RUN_ID. Use a new RUN_ID or remove dependent inputs through an approved reset procedure.', 1;
            END;

            DELETE FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID;
        END;

        INSERT INTO ecl_stg.AccountSnapshot
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME,
            STAGE, POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, SOURCE_REFERENCE
        )
        SELECT
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, POOL_NAME,
            STAGE, POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, SOURCE_REFERENCE
        FROM #SnapshotCandidate;

        SET @ROW_COUNT = @@ROWCOUNT;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'ACCOUNT_SNAPSHOT_LOAD', 'SUCCEEDED',
            N'Loaded canonical AccountSnapshot from AccountStagePoolSource with validated POOL_NAME from Stage/Pool staging.',
            @ROW_COUNT
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        RUN_ID,
        PROCESS_DATE,
        COUNT_BIG(*) AS ACCOUNT_COUNT,
        COUNT_BIG(DISTINCT POOL_NAME) AS POOL_NAME_COUNT,
        COUNT_BIG(DISTINCT POOL_ID) AS POOL_COUNT,
        MIN(MATURITY_DATE) AS MIN_MATURITY_DATE,
        MAX(MATURITY_DATE) AS MAX_MATURITY_DATE
    FROM ecl_stg.AccountSnapshot
    WHERE RUN_ID = @RUN_ID
    GROUP BY RUN_ID, PROCESS_DATE;
END;
GO

/*
The pool names are seeded in ecl_cfg.PoolName by database/001_create_logical_schema.sql. Review them against the approved source mapping before execution.

Execution:
EXEC ecl_core.usp_LoadAccountSnapshot
    @RUN_ID = 123,
    @VERSION_ID = 1,
    @REPLACE_EXISTING = 0;
*/
