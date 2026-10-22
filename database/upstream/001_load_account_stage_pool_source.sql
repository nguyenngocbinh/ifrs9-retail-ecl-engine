/*
IFRS 9 Retail ECL Engine — upstream Stage/Pool source loader
Target: SQL Server 2022 (CI target)
Run after the core schema migrations have created ecl_core.RunControl and ecl_stg.

Purpose:
- Expand finalized customer-level Stage/bucket to contract-level rows.
- Join on PROCESS_DATE + CUSTOMER_ID + CUSTOMER_TYPE + SEGMENT_ODR_LV1.
- Use CONTRACT_ID as ACCOUNT_ID.
- Preserve the finalized bucket from VW_CUSTOMER_ODR_LRA_IRB; do not recalculate DPD/MOB rules here.

This loader writes to a separate staging table, NOT ecl_stg.AccountSnapshot.
The canonical AccountSnapshot also requires approved POOL_NAME and MATURITY_DATE mappings;
those fields are deliberately not guessed by this source loader.
Review source column names and business rules before deployment.
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_stg.AccountStagePoolSource', N'U') IS NULL
BEGIN
    CREATE TABLE ecl_stg.AccountStagePoolSource
    (
        RUN_ID bigint NOT NULL,
        PROCESS_DATE date NOT NULL,
        ACCOUNT_ID varchar(100) NOT NULL,
        CUSTOMER_ID varchar(100) NULL,
        SEGMENT_ODR_LV1 nvarchar(100) NOT NULL,
        BUCKET nvarchar(30) NULL,
        STAGE tinyint NULL,
        POOL_ID varchar(100) NULL,
        POOL_NAME nvarchar(100) NULL,
        CUSTOMER_TYPE_MODEL varchar(20) NULL,
        VERSION_ID int NOT NULL,
        IS_ACTIVE bit NOT NULL CONSTRAINT DF_AccountStagePoolSource_IsActive DEFAULT (1),
        LOADED_AT datetime2(0) NOT NULL CONSTRAINT DF_AccountStagePoolSource_LoadedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_AccountStagePoolSource PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID),
        CONSTRAINT FK_AccountStagePoolSource_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
        CONSTRAINT CK_AccountStagePoolSource_Stage CHECK (STAGE IS NULL OR STAGE IN (1,2,3))
    );

    CREATE INDEX IX_AccountStagePoolSource_Run_Pool
        ON ecl_stg.AccountStagePoolSource (RUN_ID, POOL_ID, STAGE)
        INCLUDE (ACCOUNT_ID, CUSTOMER_ID, SEGMENT_ODR_LV1, VERSION_ID, IS_ACTIVE);
END;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_LoadAccountStagePoolSource
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

    SELECT
        @PROCESS_DATE = PROCESS_DATE,
        @RUN_STATUS = RUN_STATUS,
        @RUN_TYPE = RUN_TYPE,
        @REQUESTED_POOL_NAME = REQUESTED_POOL_NAME,
        @REQUESTED_POOL_ID = REQUESTED_POOL_ID
    FROM ecl_core.RunControl
    WHERE RUN_ID = @RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51201, 'RUN_ID does not exist.', 1;

    IF @VERSION_ID IS NULL OR @VERSION_ID < 0
        THROW 51202, 'VERSION_ID must be a non-negative value.', 1;

    IF @RUN_STATUS NOT IN ('CREATED','VALIDATING')
        THROW 51203, 'Stage/Pool source can only be loaded while the run is CREATED or VALIDATING.', 1;

    IF @RUN_TYPE = 'SELECTIVE'
       AND @REQUESTED_POOL_NAME IS NULL
       AND @REQUESTED_POOL_ID IS NULL
        THROW 51212, 'Selective run requires REQUESTED_POOL_NAME or REQUESTED_POOL_ID.', 1;

    IF @REQUESTED_POOL_NAME IS NOT NULL
       AND NOT EXISTS
       (
           SELECT 1
           FROM ecl_cfg.PoolName
           WHERE POOL_NAME = @REQUESTED_POOL_NAME
             AND IS_ACTIVE = 1
       )
        THROW 51213, 'Requested POOL_NAME is not active in ecl_cfg.PoolName.', 1;

    IF @REQUESTED_POOL_ID IS NOT NULL
       AND NULLIF(LTRIM(RTRIM(@REQUESTED_POOL_ID)), '') IS NULL
        THROW 51214, 'REQUESTED_POOL_ID cannot be blank.', 1;

    /*
      Normalize contract segment using the same source rules supplied for
      VW_CUSTOMER_ODR_LRA_IRB. Customer-level segment_odr_lv1 is derived from segment_lv2
      after this normalization:
        corporate -> Large / Medium / Small
        individual (KHCN or CC with NULL segment_lv1) -> segment_lv2
        nonbank -> nonbank
        unknown -> x
    */
    DROP TABLE IF EXISTS #ContractNormalized;

    SELECT
        c.PROCESS_DATE,
        c.CUSTOMER_ID,
        c.CONTRACT_ID AS ACCOUNT_ID,
        CASE
            WHEN c.segment_lv1 IN
                ('bigcorp 1','bigcorp 2','medium 1','medium 2',
                 'micro','small','upper 1','upper 2','micro sme') THEN 'c'
            WHEN c.segment_lv1 = 'khcn' THEN 'i'
            WHEN c.segment_lv1 IS NULL AND c.modul = 'cc' THEN 'i'
            ELSE NULL
        END AS CUSTOMER_TYPE,
        CASE
            WHEN c.segment_lv1 IN
                ('bigcorp 1','bigcorp 2','medium 1','medium 2',
                 'micro','small','upper 1','upper 2','micro sme')
                THEN CASE
                    WHEN c.segment_lv1 IN ('bigcorp 1','bigcorp 2','upper 1','upper 2') THEN N'Large'
                    WHEN c.segment_lv1 IN ('medium 1','medium 2') THEN N'Medium'
                    WHEN c.segment_lv1 IN ('micro','small','micro sme') THEN N'Small'
                END
            WHEN c.segment_lv1 = 'khcn'
                OR (c.segment_lv1 IS NULL AND c.modul = 'cc')
                THEN CONVERT(nvarchar(100), c.segment_lv2)
            WHEN c.segment_lv1 = 'nonbank' THEN N'nonbank'
            ELSE N'x'
        END AS SEGMENT_ODR_LV1
    INTO #ContractNormalized
    FROM dbo.VW_ODR_CONTRACT_LEVEL_IRB AS c
    WHERE c.PROCESS_DATE = @PROCESS_DATE;

    IF NOT EXISTS (SELECT 1 FROM #ContractNormalized)
        THROW 51204, 'No contract source rows found for the run PROCESS_DATE.', 1;

    IF EXISTS
    (
        SELECT PROCESS_DATE, ACCOUNT_ID
        FROM #ContractNormalized
        GROUP BY PROCESS_DATE, ACCOUNT_ID
        HAVING COUNT_BIG(*) > 1
    )
        THROW 51205, 'Contract source has duplicate PROCESS_DATE + CONTRACT_ID rows.', 1;

    /*
      The customer view includes CUSTOMER_TYPE. Use it as part of the matching
      key because SEGMENT_LV2 can be shared by KHCN and KHDN. Do not silently
      duplicate contracts if the four-column key is not unique.
    */
    IF EXISTS
    (
        SELECT s.PROCESS_DATE, s.CUSTOMER_ID, s.customer_type, s.segment_odr_lv1
        FROM dbo.VW_CUSTOMER_ODR_LRA_IRB AS s
        WHERE s.PROCESS_DATE = @PROCESS_DATE
        GROUP BY s.PROCESS_DATE, s.CUSTOMER_ID, s.customer_type, s.segment_odr_lv1
        HAVING COUNT_BIG(*) > 1
    )
        THROW 51206, 'VW_CUSTOMER_ODR_LRA_IRB has duplicate PROCESS_DATE + CUSTOMER_ID + CUSTOMER_TYPE + SEGMENT_ODR_LV1 keys; resolve upstream duplicates before loading.', 1;

    DROP TABLE IF EXISTS #Mapped;

    WITH StageMap AS
    (
        SELECT *
        FROM (VALUES
            (N'b1: mob <6 & dpd 0-30', CONVERT(tinyint,1)),
            (N'b2: mob >=6 & dpd 0-30', CONVERT(tinyint,1)),
            (N'b3: dpd 31-60', CONVERT(tinyint,2)),
            (N'b4: dpd 61-90', CONVERT(tinyint,2)),
            (N'b5: dpd >90', CONVERT(tinyint,3))
        ) AS v(BUCKET, STAGE)
    ),
    SegmentPool AS
    (
        SELECT *
        FROM (VALUES
            (100, 'RETAIL_LN_AUTO',       'RETAIL', N'Autoloan'),
            (101, 'RETAIL_LN_CONS_SEC',   'RETAIL', N'Consumer lending - secured'),
            (102, 'RETAIL_LN_CONS_UNSEC', 'RETAIL', N'Consumer lending - unsecured'),
            (103, 'RETAIL_LN_MORTGAGE',   'RETAIL', N'Mortgage'),
            (104, 'RETAIL_LN_OTHERS',     'RETAIL', N'Others'),
            (105, 'RETAIL_CARD',          'RETAIL', N'CC'),
            (106, 'RETAIL_OVERDRAFT',     'RETAIL', N'OD'),
            (200, 'CORP_LARGE_LOAN',      'CORP_L', N'Large'),
            (201, 'CORP_MEDIUM_LOAN',     'CORP_M', N'Medium'),
            (202, 'CORP_SMALL_LOAN',      'CORP_S', N'Small')
        ) AS v(POOL_ID, POOL_NAME, CUSTOMER_TYPE_MODEL, SEGMENT)
    )
    SELECT
        c.PROCESS_DATE,
        c.ACCOUNT_ID,
        c.CUSTOMER_ID,
        c.SEGMENT_ODR_LV1,
        s.bucket AS BUCKET,
        sm.STAGE,
        sp.POOL_ID,
        sp.POOL_NAME,
        sp.CUSTOMER_TYPE_MODEL
    INTO #Mapped
    FROM #ContractNormalized AS c
    INNER JOIN dbo.VW_CUSTOMER_ODR_LRA_IRB AS s
        ON  s.PROCESS_DATE = c.PROCESS_DATE
        AND s.CUSTOMER_ID = c.CUSTOMER_ID
        AND s.customer_type = c.CUSTOMER_TYPE
        AND s.segment_odr_lv1 = c.SEGMENT_ODR_LV1
    LEFT JOIN StageMap AS sm
        ON sm.BUCKET = s.bucket
    LEFT JOIN SegmentPool AS sp
        ON sp.SEGMENT = c.SEGMENT_ODR_LV1
    WHERE sp.POOL_ID IS NOT NULL
      AND
      (
          @RUN_TYPE = 'FULL'
          OR
          (
              (@REQUESTED_POOL_NAME IS NULL OR sp.POOL_NAME = @REQUESTED_POOL_NAME)
              AND
              (@REQUESTED_POOL_ID IS NULL OR CONVERT(varchar(100), sp.POOL_ID) = @REQUESTED_POOL_ID)
          )
      );

    IF EXISTS (SELECT 1 FROM #Mapped WHERE STAGE IS NULL)
        THROW 51207, 'One or more matched customer rows have NULL or unrecognized BUCKET values.', 1;

    /*
      Only mapped supported segments are loaded. The anti-join below blocks
      silently dropping supported-segment contracts without a customer Stage row.
      Nonbank/unknown segments are not part of the configured 10-pool scope.
    */
    IF EXISTS
    (
        SELECT 1
        FROM #ContractNormalized AS c
        WHERE c.SEGMENT_ODR_LV1 IN
            (N'Autoloan',N'Consumer lending - secured',N'Consumer lending - unsecured',
             N'Mortgage',N'Others',N'CC',N'OD',N'Large',N'Medium',N'Small')
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.VW_CUSTOMER_ODR_LRA_IRB AS s
              WHERE s.PROCESS_DATE = c.PROCESS_DATE
                AND s.CUSTOMER_ID = c.CUSTOMER_ID
                AND s.customer_type = c.CUSTOMER_TYPE
                AND s.segment_odr_lv1 = c.SEGMENT_ODR_LV1
          )
    )
        THROW 51208, 'One or more supported contracts have no matching customer-level Stage row on PROCESS_DATE + CUSTOMER_ID + CUSTOMER_TYPE + SEGMENT_ODR_LV1.', 1;

    IF NOT EXISTS (SELECT 1 FROM #Mapped)
        THROW 51209, 'No contracts matched the configured Stage/Pool mappings and requested run scope.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM ecl_stg.AccountStagePoolSource WHERE RUN_ID = @RUN_ID)
        BEGIN
            IF @REPLACE_EXISTING = 0
                THROW 51210, 'Rows already exist for RUN_ID. Set @REPLACE_EXISTING = 1 to replace them before the manifest is sealed.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM ecl_core.RunInputManifest
                WHERE RUN_ID = @RUN_ID AND IS_SEALED = 1
            )
                THROW 51211, 'Cannot replace Stage/Pool source rows after the run manifest is sealed.', 1;

            DELETE FROM ecl_stg.AccountStagePoolSource
            WHERE RUN_ID = @RUN_ID;
        END;

        INSERT INTO ecl_stg.AccountStagePoolSource
        (
            RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, SEGMENT_ODR_LV1,
            BUCKET, STAGE, POOL_ID, POOL_NAME, CUSTOMER_TYPE_MODEL, VERSION_ID, IS_ACTIVE
        )
        SELECT
            @RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, SEGMENT_ODR_LV1,
            BUCKET, STAGE, CONVERT(varchar(100), POOL_ID), POOL_NAME,
            CUSTOMER_TYPE_MODEL, @VERSION_ID, 1
        FROM #Mapped;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        RUN_ID, PROCESS_DATE, ACCOUNT_ID, CUSTOMER_ID, SEGMENT_ODR_LV1,
        BUCKET, STAGE, POOL_ID, POOL_NAME, CUSTOMER_TYPE_MODEL, VERSION_ID, IS_ACTIVE
    FROM ecl_stg.AccountStagePoolSource
    WHERE RUN_ID = @RUN_ID
    ORDER BY POOL_ID, STAGE, ACCOUNT_ID;
END;
GO

/*
Example — full run:
DECLARE @RUN_ID bigint = 123; -- existing FULL run with PROCESS_DATE matching source
EXEC ecl_core.usp_LoadAccountStagePoolSource
    @RUN_ID = @RUN_ID,
    @VERSION_ID = 1,
    @REPLACE_EXISTING = 0;

Example — one portfolio:
-- Create the run with RUN_TYPE='SELECTIVE' and
-- @REQUESTED_POOL_NAME='RETAIL_LN_AUTO' in usp_CreateRun first.
EXEC ecl_core.usp_LoadAccountStagePoolSource
    @RUN_ID = @RUN_ID,
    @VERSION_ID = 1,
    @REPLACE_EXISTING = 0;

This is the Stage/Pool source-loading step only. Do not copy rows to
ecl_stg.AccountSnapshot until approved POOL_NAME and MATURITY_DATE mappings
are supplied and validated.
*/
