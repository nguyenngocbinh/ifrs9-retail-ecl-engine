/*
Migration 009: shared FTP 12-month EIR source loading and validation.

Source:
  CORE.dbo.rb_ftp_bv_12m(process_date, ftp_bv, ccy)

Source values are consumed exactly as supplied. In particular, this loader does NOT
divide ftp_bv by 100: the canonical contract explicitly states the source numeric
value has no unit and must not be transformed. Confirm the source's approved rate
semantics before deployment; this is a technical mapping, not an accounting approval.

Forecast mapping:
  FORECAST_PERIOD 1 = run PROCESS_DATE + 12 months
  FORECAST_PERIOD 2 = run PROCESS_DATE + 24 months, etc.
For each target date, select the latest source PROCESS_DATE on or before that date,
for VND. Missing historical observations, duplicate source-date/currency rows,
invalid rates (NULL or <= -1), or a horizon beyond 120 periods fail closed.

Deploy after migrations 001-008. The source table must be readable from the same
SQL Server instance; if CORE is on another instance, provision an approved view
or linked-server abstraction and adapt the source reference explicitly.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Migration 001 used a restricted list that omitted the agreed FTP_12M semantic. */
IF OBJECT_ID(N'ecl_stg.EIRCurve', N'U') IS NOT NULL
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID(N'ecl_stg.EIRCurve')
          AND name = N'CK_EIRCurve_RateBasis'
    )
        ALTER TABLE ecl_stg.EIRCurve DROP CONSTRAINT CK_EIRCurve_RateBasis;

    ALTER TABLE ecl_stg.EIRCurve
      ADD CONSTRAINT CK_EIRCurve_RateBasis
      CHECK (RATE_BASIS IN ('ANNUAL_EFFECTIVE','NOMINAL_ANNUAL','OTHER','FTP_12M'));
END;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_StageSourceEIRCurve
    @RUN_ID bigint,
    @SOURCE_DATABASE sysname = N'CORE',
    @SOURCE_SCHEMA sysname = N'dbo',
    @SOURCE_TABLE sysname = N'rb_ftp_bv_12m',
    @CURRENCY_CODE char(3) = 'VND'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @PROCESS_DATE date,
        @RUN_STATUS varchar(20),
        @HORIZON int,
        @ROW_COUNT bigint,
        @SOURCE_OBJECT nvarchar(776),
        @SQL nvarchar(max);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @PROCESS_DATE = PROCESS_DATE,
            @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 52500, 'EIR source ETL: RUN_ID does not exist.', 1;

        IF @RUN_STATUS NOT IN ('CREATED','VALIDATING')
            THROW 52501, 'EIR source ETL is only allowed while run is CREATED or VALIDATING.', 1;

        IF @CURRENCY_CODE IS NULL OR @CURRENCY_CODE <> 'VND'
            THROW 52502, 'EIR source ETL: this engine version requires VND rates.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE = @PROCESS_DATE
              AND IS_ACTIVE = 1
        )
            THROW 52503, 'EIR source ETL: no active AccountSnapshot rows exist for this run.', 1;

        SELECT @HORIZON = ISNULL(MAX(HORIZON),0)
        FROM
        (
            SELECT CASE
                WHEN STAGE = 3 OR MATURITY_DATE <= @PROCESS_DATE THEN 1
                ELSE CONVERT(int, CEILING
                (
                    (
                        DATEDIFF(month,@PROCESS_DATE,MATURITY_DATE)
                        + CASE WHEN DATEADD(month,DATEDIFF(month,@PROCESS_DATE,MATURITY_DATE),@PROCESS_DATE) < MATURITY_DATE
                               THEN 1 ELSE 0 END
                    ) / 12.0
                ))
            END AS HORIZON
            FROM ecl_stg.AccountSnapshot
            WHERE RUN_ID = @RUN_ID
              AND PROCESS_DATE = @PROCESS_DATE
              AND IS_ACTIVE = 1
        ) AS h;

        IF @HORIZON < 1
            THROW 52504, 'EIR source ETL: no positive forecast horizon could be derived.', 1;
        IF @HORIZON > 120
            THROW 52505, 'EIR source ETL: maximum supported forecast horizon is 120 periods.', 1;

        IF @SOURCE_DATABASE IS NULL OR NULLIF(LTRIM(RTRIM(@SOURCE_DATABASE)),'') IS NULL
           OR @SOURCE_SCHEMA IS NULL OR NULLIF(LTRIM(RTRIM(@SOURCE_SCHEMA)),'') IS NULL
           OR @SOURCE_TABLE IS NULL OR NULLIF(LTRIM(RTRIM(@SOURCE_TABLE)),'') IS NULL
           OR QUOTENAME(@SOURCE_DATABASE) IS NULL
           OR QUOTENAME(@SOURCE_SCHEMA) IS NULL
           OR QUOTENAME(@SOURCE_TABLE) IS NULL
            THROW 52506, 'EIR source ETL: source database/schema/table names are invalid.', 1;

        SET @SOURCE_OBJECT = QUOTENAME(@SOURCE_DATABASE) + N'.'
                           + QUOTENAME(@SOURCE_SCHEMA) + N'.'
                           + QUOTENAME(@SOURCE_TABLE);

        /* Check the database exists and the configured source has the required columns. */
        IF DB_ID(@SOURCE_DATABASE) IS NULL
        BEGIN
            DECLARE @MissingDatabaseMessage nvarchar(2048) =
                CONCAT(N'EIR source ETL: source database ', QUOTENAME(@SOURCE_DATABASE), N' does not exist or is not visible.');
            THROW 52507, @MissingDatabaseMessage, 1;
        END;

        DECLARE @MetadataSQL nvarchar(max);
        DECLARE @SourceMetadata TABLE
        (
            OBJECT_ID int NULL,
            COLUMN_NAME sysname NULL
        );

        SET @MetadataSQL = N'
SELECT o.object_id, c.name
FROM ' + QUOTENAME(@SOURCE_DATABASE) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@SOURCE_DATABASE) + N'.sys.schemas AS s
  ON s.schema_id = o.schema_id
LEFT JOIN ' + QUOTENAME(@SOURCE_DATABASE) + N'.sys.columns AS c
  ON c.object_id = o.object_id
WHERE s.name = @SchemaName
  AND o.name = @TableName
  AND o.type IN (''U'',''V'');';

        INSERT INTO @SourceMetadata (OBJECT_ID, COLUMN_NAME)
        EXEC sys.sp_executesql
            @MetadataSQL,
            N'@SchemaName sysname, @TableName sysname',
            @SchemaName = @SOURCE_SCHEMA,
            @TableName = @SOURCE_TABLE;

        IF NOT EXISTS (SELECT 1 FROM @SourceMetadata WHERE OBJECT_ID IS NOT NULL)
            THROW 52508, 'EIR source ETL: configured source object does not exist or is not visible.', 1;

        IF NOT EXISTS (SELECT 1 FROM @SourceMetadata WHERE COLUMN_NAME = N'process_date')
           OR NOT EXISTS (SELECT 1 FROM @SourceMetadata WHERE COLUMN_NAME = N'ftp_bv')
           OR NOT EXISTS (SELECT 1 FROM @SourceMetadata WHERE COLUMN_NAME = N'ccy')
            THROW 52509, 'EIR source ETL: required columns process_date, ftp_bv, ccy are missing.', 1;

        CREATE TABLE #MappedEIR
        (
            RUN_ID bigint NOT NULL,
            PROCESS_DATE date NOT NULL,
            FORECAST_PERIOD smallint NOT NULL,
            EIR decimal(19,12) NULL,
            RATE_BASIS varchar(20) NOT NULL,
            VERSION_ID int NOT NULL,
            IS_ACTIVE bit NOT NULL,
            SOURCE_PROCESS_DATE date NULL,
            CURRENCY_CODE char(3) NULL,
            TARGET_DATE date NOT NULL
        );

        /* Fail on duplicate date/currency keys and bad source values relevant to the run horizon. */
        SET @SQL = N'
IF EXISTS
(
    SELECT 1
    FROM ' + @SOURCE_OBJECT + N' AS s
    WHERE s.ccy = @Currency
      AND s.process_date <= @ProcessDate
    GROUP BY s.process_date, s.ccy
    HAVING COUNT_BIG(*) > 1
)
    THROW 52510, ''EIR source ETL: duplicate source rows exist for process_date and currency.'', 1;

IF EXISTS
(
    SELECT 1
    FROM ' + @SOURCE_OBJECT + N' AS s
    WHERE s.ccy = @Currency
      AND s.process_date IS NULL
      AND s.ftp_bv IS NOT NULL
)
    THROW 52517, ''EIR source ETL: source process_date cannot be NULL for VND observations.'', 1;

IF EXISTS
(
    SELECT 1
    FROM ' + @SOURCE_OBJECT + N' AS s
    WHERE s.ccy = @Currency
      AND s.process_date <= DATEADD(month, @Horizon * 12, @ProcessDate)
      AND (s.ftp_bv IS NULL OR TRY_CONVERT(decimal(19,12), s.ftp_bv) IS NULL
           OR TRY_CONVERT(decimal(19,12), s.ftp_bv) <= -1)
)
    THROW 52511, ''EIR source ETL: FTP rate must be numeric, non-null, and greater than -1.'', 1;

IF NOT EXISTS
(
    SELECT 1 FROM ' + @SOURCE_OBJECT + N' AS s
    WHERE s.ccy = @Currency AND s.process_date <= @ProcessDate
)
    THROW 52512, ''EIR source ETL: no VND FTP observation exists on or before the first forecast target date.'', 1;

;WITH Numbers AS
(
    SELECT n
    FROM (VALUES
      (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
      (11),(12),(13),(14),(15),(16),(17),(18),(19),(20),
      (21),(22),(23),(24),(25),(26),(27),(28),(29),(30),
      (31),(32),(33),(34),(35),(36),(37),(38),(39),(40),
      (41),(42),(43),(44),(45),(46),(47),(48),(49),(50),
      (51),(52),(53),(54),(55),(56),(57),(58),(59),(60),
      (61),(62),(63),(64),(65),(66),(67),(68),(69),(70),
      (71),(72),(73),(74),(75),(76),(77),(78),(79),(80),
      (81),(82),(83),(84),(85),(86),(87),(88),(89),(90),
      (91),(92),(93),(94),(95),(96),(97),(98),(99),(100),
      (101),(102),(103),(104),(105),(106),(107),(108),(109),(110),
      (111),(112),(113),(114),(115),(116),(117),(118),(119),(120)
    ) v(n)
),
TargetPeriods AS
(
    SELECT n AS FORECAST_PERIOD,
           DATEADD(month, CONVERT(int,n) * 12, @ProcessDate) AS TARGET_DATE
    FROM Numbers
    WHERE n <= @Horizon
)
INSERT INTO #MappedEIR
(
    RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS,
    VERSION_ID, IS_ACTIVE, SOURCE_PROCESS_DATE, CURRENCY_CODE, TARGET_DATE
)
SELECT
    @RunId AS RUN_ID,
    @ProcessDate AS PROCESS_DATE,
    t.FORECAST_PERIOD,
    CONVERT(decimal(19,12),s.ftp_bv) AS EIR,
    CONVERT(varchar(20),''FTP_12M'') AS RATE_BASIS,
    CONVERT(int,1) AS VERSION_ID,
    CONVERT(bit,1) AS IS_ACTIVE,
    CONVERT(date,s.process_date) AS SOURCE_PROCESS_DATE,
    CONVERT(char(3),s.ccy) AS CURRENCY_CODE,
    DATEADD(month, CONVERT(int,t.FORECAST_PERIOD) * 12, @ProcessDate) AS TARGET_DATE
FROM TargetPeriods t
OUTER APPLY
(
    SELECT TOP (1) s.process_date, s.ftp_bv, s.ccy
    FROM ' + @SOURCE_OBJECT + N' AS s
    WHERE s.ccy = @Currency
      AND s.process_date <= @ProcessDate
    ORDER BY s.process_date DESC
) s;

IF EXISTS (SELECT 1 FROM #MappedEIR WHERE EIR IS NULL OR EIR <= -1)
    THROW 52513, ''EIR source ETL: one or more periods have no valid source rate.'', 1;

IF (SELECT COUNT_BIG(*) FROM #MappedEIR) <> @Horizon
    THROW 52514, ''EIR source ETL: generated rows do not cover the required forecast horizon.'', 1;

IF EXISTS
(
    SELECT FORECAST_PERIOD FROM #MappedEIR
    GROUP BY FORECAST_PERIOD HAVING COUNT_BIG(*) <> 1
)
    THROW 52515, ''EIR source ETL: generated canonical EIR grain is not unique.'', 1;

IF EXISTS
(
    SELECT 1 FROM #MappedEIR
    WHERE TARGET_DATE < PROCESS_DATE
)
    THROW 52516, ''EIR source ETL: invalid forecast target date.'', 1;

';

        EXEC sys.sp_executesql
            @SQL,
            N'@RunId bigint, @ProcessDate date, @Horizon int, @Currency char(3)',
            @RunId = @RUN_ID,
            @ProcessDate = @PROCESS_DATE,
            @Horizon = @HORIZON,
            @Currency = @CURRENCY_CODE;

        DELETE FROM ecl_stg.EIRCurve
        WHERE RUN_ID = @RUN_ID;

        INSERT INTO ecl_stg.EIRCurve
        (
            RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE
        )
        SELECT
            RUN_ID, PROCESS_DATE, FORECAST_PERIOD, EIR, RATE_BASIS, VERSION_ID, IS_ACTIVE
        FROM #MappedEIR;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.EIRCurve
        WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
        (
            RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS,
            EVENT_MESSAGE, ROW_COUNT, ACTOR
        )
        VALUES
        (
            @RUN_ID, @PROCESS_DATE, 'EIR_SOURCE_ETL', 'SUCCEEDED',
            CONCAT(N'Loaded FTP 12-month curve from ', @SOURCE_OBJECT,
                   N'; source values consumed without percentage/decimal conversion; currency=',
                   @CURRENCY_CODE, N'.'),
            @ROW_COUNT, SUSER_SNAME()
        );

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, @PROCESS_DATE AS PROCESS_DATE,
               @ROW_COUNT AS EIR_ROW_COUNT, 'SUCCEEDED' AS LOAD_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE ecl_core.usp_LoadEIRCurve
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @RUN_STATUS varchar(20), @ROW_COUNT bigint, @HORIZON int;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL
            THROW 52600, 'EIR loader: RUN_ID does not exist.', 1;
        IF @RUN_STATUS NOT IN ('CREATED','VALIDATING')
            THROW 52601, 'EIR loader is only allowed before calculation begins.', 1;

        SELECT @HORIZON = ISNULL(MAX(CASE
            WHEN STAGE = 3 OR MATURITY_DATE <= @PROCESS_DATE THEN 1
            ELSE CONVERT(int, CEILING
            (
                (
                    DATEDIFF(month,@PROCESS_DATE,MATURITY_DATE)
                    + CASE WHEN DATEADD(month,DATEDIFF(month,@PROCESS_DATE,MATURITY_DATE),@PROCESS_DATE) < MATURITY_DATE
                           THEN 1 ELSE 0 END
                ) / 12.0
            ))
        END),0)
        FROM ecl_stg.AccountSnapshot
        WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1;

        IF @HORIZON < 1 OR @HORIZON > 120
            THROW 52602, 'EIR loader: active accounts must have a required horizon between 1 and 120 periods.', 1;

        IF NOT EXISTS (SELECT 1 FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID)
            THROW 52603, 'EIR loader: no canonical EIR rows were staged for this run.', 1;

        IF EXISTS
        (
            SELECT 1 FROM ecl_stg.EIRCurve
            WHERE RUN_ID = @RUN_ID
              AND (PROCESS_DATE <> @PROCESS_DATE OR EIR <= -1 OR RATE_BASIS <> 'FTP_12M'
                   OR FORECAST_PERIOD < 1 OR FORECAST_PERIOD > @HORIZON)
        )
            THROW 52604, 'EIR loader: date, rate range, FTP_12M basis, or forecast period is invalid.', 1;

        IF EXISTS
        (
            SELECT v.N
            FROM (VALUES
                (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
                (11),(12),(13),(14),(15),(16),(17),(18),(19),(20),
                (21),(22),(23),(24),(25),(26),(27),(28),(29),(30),
                (31),(32),(33),(34),(35),(36),(37),(38),(39),(40),
                (41),(42),(43),(44),(45),(46),(47),(48),(49),(50),
                (51),(52),(53),(54),(55),(56),(57),(58),(59),(60),
                (61),(62),(63),(64),(65),(66),(67),(68),(69),(70),
                (71),(72),(73),(74),(75),(76),(77),(78),(79),(80),
                (81),(82),(83),(84),(85),(86),(87),(88),(89),(90),
                (91),(92),(93),(94),(95),(96),(97),(98),(99),(100),
                (101),(102),(103),(104),(105),(106),(107),(108),(109),(110),
                (111),(112),(113),(114),(115),(116),(117),(118),(119),(120)
            ) AS v(N)
            WHERE v.N <= @HORIZON
              AND NOT EXISTS
              (
                  SELECT 1 FROM ecl_stg.EIRCurve AS e
                  WHERE e.RUN_ID = @RUN_ID AND e.PROCESS_DATE = @PROCESS_DATE
                    AND e.FORECAST_PERIOD = v.N AND e.IS_ACTIVE = 1
              )
        )
            THROW 52605, 'EIR loader: active EIR coverage is missing for one or more required periods.', 1;

        SELECT @ROW_COUNT = COUNT_BIG(*)
        FROM ecl_stg.EIRCurve WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1;

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, ACTOR)
        VALUES
            (@RUN_ID, @PROCESS_DATE, 'EIR_LOAD', 'SUCCEEDED',
             N'Validated annual shared FTP_12M EIR curve coverage; rate values are used exactly as staged.',
             @ROW_COUNT, SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID, 'SUCCEEDED' AS LOAD_STATUS, @ROW_COUNT AS EIR_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/*
Example:
  EXEC ecl_core.usp_StageSourceEIRCurve @RUN_ID = 123;
  EXEC ecl_core.usp_LoadEIRCurve @RUN_ID = 123;

Then register the EIR input-family manifest with the resulting canonical row count.
*/
