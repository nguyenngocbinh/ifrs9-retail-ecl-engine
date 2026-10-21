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
  - Read MATURITY_DATE from DEFAULT.dbo.ODR_CONTRACT_LEVEL_IRB.expiry_date.
  - Map POOL_ID to canonical PRODUCT_TYPE through governed configuration.
  - Insert the canonical account grain RUN_ID + ACCOUNT_ID into AccountSnapshot.

Important:
  - Does not recalculate Stage or Pool.
  - Does not guess product mapping. Populate ecl_cfg.PoolProductTypeMap only with
    mappings approved by the business/data owner.
  - Review physical source names and test in a disposable database before use.
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_cfg.PoolProductTypeMap', N'U') IS NULL
BEGIN
    CREATE TABLE ecl_cfg.PoolProductTypeMap
    (
        POOL_ID varchar(100) NOT NULL,
        PRODUCT_TYPE varchar(30) NOT NULL,
        IS_ACTIVE bit NOT NULL CONSTRAINT DF_PoolProductTypeMap_IsActive DEFAULT (1),
        CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_PoolProductTypeMap_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CREATED_BY sysname NOT NULL CONSTRAINT DF_PoolProductTypeMap_CreatedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT PK_PoolProductTypeMap PRIMARY KEY CLUSTERED (POOL_ID),
        CONSTRAINT FK_PoolProductTypeMap_ProductType FOREIGN KEY (PRODUCT_TYPE)
            REFERENCES ecl_cfg.ProductType(PRODUCT_TYPE)
    );
END;
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
    DECLARE @ROW_COUNT bigint;

    SELECT
        @PROCESS_DATE = PROCESS_DATE,
        @RUN_STATUS = RUN_STATUS
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
          AND (STAGE IS NULL OR STAGE NOT IN (1,2,3) OR POOL_ID IS NULL OR ACCOUNT_ID IS NULL)
    )
        THROW 51306, 'Stage/Pool source contains a missing or invalid STAGE, POOL_ID, or ACCOUNT_ID.', 1;

    /*
      A contract must resolve to exactly one source row for this process date.
      The upstream loader already checks this, but the canonical boundary repeats
      the check so this procedure remains safe if staging rows are modified later.
    */
    IF EXISTS
    (
        SELECT s.ACCOUNT_ID
        FROM ecl_stg.AccountStagePoolSource AS s
        LEFT JOIN [DEFAULT].[dbo].[ODR_CONTRACT_LEVEL_IRB] AS c
          ON c.PROCESS_DATE = s.PROCESS_DATE
         AND CONVERT(varchar(100), c.CONTRACT_ID) = s.ACCOUNT_ID
        WHERE s.RUN_ID = @RUN_ID
          AND s.IS_ACTIVE = 1
        GROUP BY s.ACCOUNT_ID
        HAVING COUNT_BIG(c.CONTRACT_ID) <> 1
    )
        THROW 51307, 'Each active Stage/Pool account must match exactly one ODR_CONTRACT_LEVEL_IRB row by PROCESS_DATE + CONTRACT_ID.', 1;

    DROP TABLE IF EXISTS #SnapshotCandidate;

    SELECT
        s.RUN_ID,
        s.PROCESS_DATE,
        s.ACCOUNT_ID,
        s.CUSTOMER_ID,
        m.PRODUCT_TYPE,
        s.STAGE,
        s.POOL_ID,
        TRY_CONVERT(date, c.expiry_date) AS MATURITY_DATE,
        @VERSION_ID AS VERSION_ID,
        CONVERT(bit, 1) AS IS_ACTIVE,
        CONVERT(nvarchar(200), N'DEFAULT.dbo.ODR_CONTRACT_LEVEL_IRB') AS SOURCE_REFERENCE
    INTO #SnapshotCandidate
    FROM ecl_stg.AccountStagePoolSource AS s
    INNER JOIN [DEFAULT].[dbo].[ODR_CONTRACT_LEVEL_IRB] AS c
      ON c.PROCESS_DATE = s.PROCESS_DATE
     AND c.CONTRACT_ID = s.ACCOUNT_ID
    LEFT JOIN ecl_cfg.PoolProductTypeMap AS m
      ON m.POOL_ID = s.POOL_ID
     AND m.IS_ACTIVE = 1
    WHERE s.RUN_ID = @RUN_ID
      AND s.IS_ACTIVE = 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE PRODUCT_TYPE IS NULL
    )
        THROW 51308, 'At least one POOL_ID has no active approved mapping in ecl_cfg.PoolProductTypeMap. Configure mappings before loading AccountSnapshot.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE MATURITY_DATE IS NULL
    )
        THROW 51309, 'At least one source contract has NULL or unconvertible expiry_date; MATURITY_DATE cannot be loaded.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #SnapshotCandidate
        WHERE MATURITY_DATE < PROCESS_DATE
    )
        THROW 51310, 'At least one contract MATURITY_DATE is earlier than PROCESS_DATE. Resolve matured/invalid contracts before loading.', 1;

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
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE,
            STAGE, POOL_ID, MATURITY_DATE, VERSION_ID, IS_ACTIVE, SOURCE_REFERENCE
        )
        SELECT
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, PRODUCT_TYPE,
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
            N'Loaded canonical AccountSnapshot from AccountStagePoolSource with approved pool-to-product mapping.',
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
        COUNT_BIG(DISTINCT PRODUCT_TYPE) AS PRODUCT_TYPE_COUNT,
        COUNT_BIG(DISTINCT POOL_ID) AS POOL_COUNT,
        MIN(MATURITY_DATE) AS MIN_MATURITY_DATE,
        MAX(MATURITY_DATE) AS MAX_MATURITY_DATE
    FROM ecl_stg.AccountSnapshot
    WHERE RUN_ID = @RUN_ID
    GROUP BY RUN_ID, PROCESS_DATE;
END;
GO

/*
Configuration example — do not run until each mapping is approved.

INSERT INTO ecl_cfg.PoolProductTypeMap (POOL_ID, PRODUCT_TYPE)
VALUES
    ('RETAIL_LN_AUTO', 'AUTO'),
    ('RETAIL_LN_MORTGAGE', 'MORTGAGE'),
    ('RETAIL_CARD', 'CREDITCARD');

The remaining pools (including consumer lending, overdraft and others) must be
mapped to PERSONALLOAN or OTHER only after the bank's product taxonomy is confirmed.

Execution:
EXEC ecl_core.usp_LoadAccountSnapshot
    @RUN_ID = 123,
    @VERSION_ID = 1,
    @REPLACE_EXISTING = 0;
*/
