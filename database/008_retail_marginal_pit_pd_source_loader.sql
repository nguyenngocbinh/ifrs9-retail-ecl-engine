/*
Migration 008: source-specific retail marginal PIT PD ingestion.
Deploy after migrations 001..007.

The PD source PROCESS_DATE is treated as a source-version marker, not a join
key to the ECL run date. The procedure selects the latest source PROCESS_DATE
and emits a WARN audit finding/event so operators can see which source version
is being used. Facility ratings are matched to the run date.

The approved source scenario mapping is stored centrally in ecl_cfg.PDScenarioMapping:
1 -> BASE, 2 -> UPTURN, 3 -> DOWNTURN.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Central, approved mapping from source SCENARIO numbers to canonical scenario codes. */
IF OBJECT_ID(N'ecl_cfg.PDScenarioMapping', N'U') IS NULL
BEGIN
    CREATE TABLE ecl_cfg.PDScenarioMapping
    (
        SOURCE_SCENARIO tinyint NOT NULL,
        SCENARIO_CODE varchar(20) NOT NULL,
        IS_ACTIVE bit NOT NULL CONSTRAINT DF_PDScenarioMapping_IsActive DEFAULT (1),
        CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_PDScenarioMapping_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CREATED_BY sysname NOT NULL CONSTRAINT DF_PDScenarioMapping_CreatedBy DEFAULT (SUSER_SNAME()),
        CONSTRAINT PK_PDScenarioMapping PRIMARY KEY CLUSTERED (SOURCE_SCENARIO),
        CONSTRAINT FK_PDScenarioMapping_Scenario FOREIGN KEY (SCENARIO_CODE)
            REFERENCES ecl_cfg.Scenario(SCENARIO_CODE),
        CONSTRAINT CK_PDScenarioMapping_SourceScenario CHECK (SOURCE_SCENARIO IN (1,2,3))
    );

    CREATE UNIQUE INDEX UX_PDScenarioMapping_ActiveScenarioCode
        ON ecl_cfg.PDScenarioMapping (SCENARIO_CODE)
        WHERE IS_ACTIVE = 1;

    INSERT INTO ecl_cfg.PDScenarioMapping (SOURCE_SCENARIO, SCENARIO_CODE)
    VALUES (1, 'BASE'), (2, 'UPTURN'), (3, 'DOWNTURN');
END;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_LoadRetailMarginalPITPD
    @RUN_ID bigint,
    @VERSION_ID int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @PD_SOURCE_PROCESS_DATE date,
        @ROW_COUNT bigint,
        @WARNING_MESSAGE nvarchar(2000);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 51800, 'Retail PD source loader: RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED', 'VALIDATING')
            THROW 51801, 'Retail PD source loader is only allowed before calculation begins.', 1;

        IF @VERSION_ID IS NULL OR @VERSION_ID < 1
            THROW 51802, 'Retail PD source loader requires a positive VERSION_ID.', 1;

        IF (SELECT COUNT(*) FROM ecl_cfg.PDScenarioMapping WHERE IS_ACTIVE = 1) <> 3
           OR NOT EXISTS (SELECT 1 FROM ecl_cfg.PDScenarioMapping WHERE SOURCE_SCENARIO = 1 AND SCENARIO_CODE = 'BASE' AND IS_ACTIVE = 1)
           OR NOT EXISTS (SELECT 1 FROM ecl_cfg.PDScenarioMapping WHERE SOURCE_SCENARIO = 2 AND SCENARIO_CODE = 'UPTURN' AND IS_ACTIVE = 1)
           OR NOT EXISTS (SELECT 1 FROM ecl_cfg.PDScenarioMapping WHERE SOURCE_SCENARIO = 3 AND SCENARIO_CODE = 'DOWNTURN' AND IS_ACTIVE = 1)
            THROW 51803, 'PDScenarioMapping must contain active mappings 1=BASE, 2=UPTURN, 3=DOWNTURN.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
        )
            THROW 51804, 'Retail PD source loader: no active account snapshots exist for this run.', 1;

        IF EXISTS (SELECT 1 FROM ecl_stg.PDCurve WHERE RUN_ID = @RUN_ID)
            THROW 51805, 'Retail PD source loader: PDCurve already contains rows for this RUN_ID; refusing to overwrite.', 1;

        SELECT @PD_SOURCE_PROCESS_DATE = MAX(PROCESS_DATE)
        FROM dbo.RETAIL_MARGINAL_PIT_PD;

        IF @PD_SOURCE_PROCESS_DATE IS NULL
            THROW 51806, 'Retail PD source loader: dbo.RETAIL_MARGINAL_PIT_PD is empty.', 1;

        SET @WARNING_MESSAGE = CONCAT(
            N'WARNING: source PD dataset selected from dbo.RETAIL_MARGINAL_PIT_PD.PROCESS_DATE = ',
            CONVERT(nvarchar(10), @PD_SOURCE_PROCESS_DATE, 23),
            N'. This source PROCESS_DATE is a version marker and is not required to equal the ECL run PROCESS_DATE ',
            CONVERT(nvarchar(10), @PROCESS_DATE, 23),
            N'. Confirm source freshness before production use.'
        );

        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_SOURCE_PROCESS_DATE', 'WARN', @WARNING_MESSAGE);

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'PD_SOURCE_VERSION', 'WARNING', @WARNING_MESSAGE, SUSER_SNAME());

        /* Source rating must be for the ECL reporting date and same pool/account.
           PoolName.SEGMENT is the approved bridge from POOL_NAME to SEGMENT_LV2. */
        IF EXISTS
        (
            SELECT a.ACCOUNT_ID
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
            GROUP BY a.ACCOUNT_ID
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51807, 'Retail PD source loader: more than one facility-rating row matches an account for the run date and pool.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            LEFT JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND fr.ACCOUNT_ID IS NULL
        )
            THROW 51808, 'Retail PD source loader: one or more active accounts have no facility rating for the run date and pool.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            JOIN ecl_cfg.PoolName pn
              ON pn.POOL_NAME = a.POOL_NAME AND pn.IS_ACTIVE = 1
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.RETAIL_MARGINAL_PIT_PD pd
                  WHERE pd.PROCESS_DATE = @PD_SOURCE_PROCESS_DATE
                    AND pd.SEGMENT_LV2 = pn.SEGMENT
                    AND pd.BUCKET = fr.BUCKET
                    AND pd.RATING = fr.RATING
              )
        )
            THROW 51809, 'Retail PD source loader: missing PD curve for at least one account rating/bucket/segment combination.', 1;

        ;WITH SourcePD AS
        (
            SELECT
                pd.SEGMENT_LV2,
                pd.BUCKET,
                pd.RATING,
                pd.PERIOD,
                pd.SCENARIO,
                pd.FINAL_MARGINAL_PIT_PD,
                CONVERT(smallint,
                    DATEDIFF(year, @PROCESS_DATE, pd.PERIOD)
                    + CASE WHEN @PROCESS_DATE < DATEFROMPARTS(YEAR(@PROCESS_DATE), 12, 31)
                           THEN 1 ELSE 0 END
                ) AS FORECAST_PERIOD,
                sm.SCENARIO_CODE AS SCENARIO_CODE
            FROM dbo.RETAIL_MARGINAL_PIT_PD pd
            JOIN ecl_cfg.PDScenarioMapping sm
              ON sm.SOURCE_SCENARIO = pd.SCENARIO
             AND sm.IS_ACTIVE = 1
            WHERE pd.PROCESS_DATE = @PD_SOURCE_PROCESS_DATE
              AND pd.PERIOD > @PROCESS_DATE
              AND pd.SCENARIO IN (1,2,3)
        ),
        MappedRows AS
        (
            SELECT
                a.RUN_ID,
                @PROCESS_DATE AS PROCESS_DATE,
                a.ACCOUNT_ID,
                sp.SCENARIO_CODE,
                sp.FORECAST_PERIOD,
                CONVERT(decimal(19,12), sp.FINAL_MARGINAL_PIT_PD) AS MARGINAL_PD,
                @VERSION_ID AS VERSION_ID,
                CAST(1 AS bit) AS IS_ACTIVE
            FROM ecl_stg.AccountSnapshot a
            JOIN [IRB_MHRR].[pd].[TBL_MAN_FACILITY_RATING] fr
              ON CONVERT(varchar(100), fr.ACCOUNT_ID) = a.ACCOUNT_ID
             AND fr.REPORTING_DATE = @PROCESS_DATE
             AND fr.POOL_NAME = a.POOL_NAME
            JOIN ecl_cfg.PoolName pn
              ON pn.POOL_NAME = a.POOL_NAME AND pn.IS_ACTIVE = 1
            JOIN SourcePD sp
              ON sp.SEGMENT_LV2 = pn.SEGMENT
             AND sp.BUCKET = fr.BUCKET
             AND sp.RATING = fr.RATING
            WHERE a.RUN_ID = @RUN_ID
              AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1
        )
        INSERT INTO ecl_stg.PDCurve
            (RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
             FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE)
        SELECT RUN_ID, PROCESS_DATE, ACCOUNT_ID, SCENARIO_CODE,
               FORECAST_PERIOD, MARGINAL_PD, VERSION_ID, IS_ACTIVE
        FROM MappedRows
        WHERE SCENARIO_CODE IS NOT NULL
          AND FORECAST_PERIOD >= 1;

        SET @ROW_COUNT = @@ROWCOUNT;

        IF @ROW_COUNT = 0
            THROW 51810, 'Retail PD source loader: no canonical PD rows were produced.', 1;

        IF EXISTS
        (
            SELECT RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            FROM ecl_stg.PDCurve
            WHERE RUN_ID = @RUN_ID
            GROUP BY RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51811, 'Retail PD source loader: duplicate canonical PD keys were produced; verify source uniqueness.', 1;

        COMMIT TRANSACTION;

        SELECT
            @RUN_ID AS RUN_ID,
            @PROCESS_DATE AS RUN_PROCESS_DATE,
            @PD_SOURCE_PROCESS_DATE AS PD_SOURCE_PROCESS_DATE,
            @ROW_COUNT AS PD_ROW_COUNT,
            @WARNING_MESSAGE AS SOURCE_VERSION_WARNING,
            'LOADED_WITH_WARNING' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
