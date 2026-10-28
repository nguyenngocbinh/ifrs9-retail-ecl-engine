/*
IFRS 9 Retail ECL Engine — migration 010: backtest foundation
Target: SQL Server 2016+ (CI target SQL Server 2022).
Additive only: does not alter or recalculate existing ECL output.
Deploy to disposable DEV/UAT after review. No actual-loss logic is implemented.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'ecl_bt') IS NULL EXEC(N'CREATE SCHEMA ecl_bt AUTHORIZATION dbo;');
GO

CREATE TABLE ecl_bt.BacktestRun (
    BACKTEST_RUN_ID bigint IDENTITY(1,1) NOT NULL,
    BACKTEST_NAME nvarchar(200) NOT NULL,
    COHORT_START_DATE date NOT NULL,
    COHORT_END_DATE date NOT NULL,
    OUTCOME_AS_OF_DATE date NOT NULL,
    HORIZON_MONTHS smallint NOT NULL CONSTRAINT DF_BT_Run_Horizon DEFAULT (12),
    RUN_STATUS varchar(20) NOT NULL CONSTRAINT DF_BT_Run_Status DEFAULT ('CREATED'),
    METHODOLOGY_VERSION varchar(30) NOT NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_BT_Run_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CREATED_BY sysname NOT NULL CONSTRAINT DF_BT_Run_CreatedBy DEFAULT (SUSER_SNAME()),
    FINISHED_AT datetime2(0) NULL,
    RUN_NOTE nvarchar(1000) NULL,
    CONSTRAINT PK_BT_BacktestRun PRIMARY KEY CLUSTERED (BACKTEST_RUN_ID),
    CONSTRAINT CK_BT_Run_Dates CHECK (
        COHORT_END_DATE >= COHORT_START_DATE
        AND OUTCOME_AS_OF_DATE >= COHORT_START_DATE
    ),
    CONSTRAINT CK_BT_Run_Horizon CHECK (HORIZON_MONTHS = 12),
    CONSTRAINT CK_BT_Run_Status CHECK (
        RUN_STATUS IN ('CREATED','COHORT_BUILT','OUTCOMES_LOADED','COMPLETED','FAILED','CANCELLED')
    ),
    CONSTRAINT CK_BT_Run_Finished CHECK (FINISHED_AT IS NULL OR FINISHED_AT >= CREATED_AT)
);
GO

CREATE TABLE ecl_bt.CohortAccount (
    BACKTEST_RUN_ID bigint NOT NULL,
    SOURCE_RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    POOL_NAME varchar(100) NOT NULL,
    POOL_ID varchar(100) NOT NULL,
    STAGE tinyint NOT NULL,
    FORECAST_PD_12M decimal(19,12) NULL,
    FORECAST_ECL_TOTAL decimal(28,8) NOT NULL,
    FORECAST_ECL_12_MONTH decimal(28,8) NOT NULL,
    IS_PD_BACKTEST_ELIGIBLE bit NOT NULL,
    INELIGIBLE_REASON varchar(50) NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_BT_Cohort_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_BT_CohortAccount PRIMARY KEY CLUSTERED
        (BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_BT_Cohort_Run FOREIGN KEY (BACKTEST_RUN_ID)
        REFERENCES ecl_bt.BacktestRun(BACKTEST_RUN_ID),
    CONSTRAINT FK_BT_Cohort_SourceECLAccount FOREIGN KEY (SOURCE_RUN_ID, ACCOUNT_ID)
        REFERENCES ecl_result.ECLAccount(RUN_ID, ACCOUNT_ID),
    CONSTRAINT CK_BT_Cohort_Stage CHECK (STAGE IN (1,2,3)),
    CONSTRAINT CK_BT_Cohort_PD CHECK (FORECAST_PD_12M IS NULL OR
        (FORECAST_PD_12M >= 0 AND FORECAST_PD_12M <= 1)),
    CONSTRAINT CK_BT_Cohort_ECL CHECK (
        FORECAST_ECL_TOTAL >= 0 AND FORECAST_ECL_12_MONTH >= 0
    ),
    CONSTRAINT CK_BT_Cohort_Eligibility CHECK (
        (IS_PD_BACKTEST_ELIGIBLE = 1 AND STAGE IN (1,2)
            AND FORECAST_PD_12M IS NOT NULL AND INELIGIBLE_REASON IS NULL)
        OR
        (IS_PD_BACKTEST_ELIGIBLE = 0 AND INELIGIBLE_REASON IS NOT NULL)
    )
);
GO
CREATE INDEX IX_BT_Cohort_Date_Pool_Stage
    ON ecl_bt.CohortAccount (BACKTEST_RUN_ID, PROCESS_DATE, POOL_NAME, STAGE)
    INCLUDE (SOURCE_RUN_ID, ACCOUNT_ID, FORECAST_PD_12M, FORECAST_ECL_TOTAL,
             IS_PD_BACKTEST_ELIGIBLE);
GO

CREATE TABLE ecl_bt.AccountOutcome (
    BACKTEST_RUN_ID bigint NOT NULL,
    SOURCE_RUN_ID bigint NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    DEFAULT_DATE date NULL,
    OBSERVATION_END_DATE date NULL,
    OUTCOME_STATUS varchar(20) NOT NULL CONSTRAINT DF_BT_Outcome_Status DEFAULT ('PENDING'),
    OUTCOME_SOURCE_OBJECT nvarchar(256) NULL,
    OUTCOME_SOURCE_VERSION varchar(100) NULL,
    OUTCOME_NOTE nvarchar(1000) NULL,
    LOADED_AT datetime2(0) NOT NULL CONSTRAINT DF_BT_Outcome_LoadedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_BT_AccountOutcome PRIMARY KEY CLUSTERED
        (BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_BT_Outcome_Cohort FOREIGN KEY
        (BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID)
        REFERENCES ecl_bt.CohortAccount(BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID),
    CONSTRAINT CK_BT_Outcome_Status CHECK (
        OUTCOME_STATUS IN ('PENDING','OBSERVED_DEFAULT','OBSERVED_NO_DEFAULT','IMMATURE','DATA_ISSUE')
    ),
    CONSTRAINT CK_BT_Outcome_DefaultConsistency CHECK (
        (OUTCOME_STATUS = 'OBSERVED_DEFAULT' AND DEFAULT_DATE IS NOT NULL)
        OR OUTCOME_STATUS <> 'OBSERVED_DEFAULT'
    ),
    CONSTRAINT CK_BT_Outcome_EndDate CHECK (
        OBSERVATION_END_DATE IS NULL OR DEFAULT_DATE IS NULL
        OR DEFAULT_DATE >= OBSERVATION_END_DATE
        OR OUTCOME_STATUS = 'OBSERVED_DEFAULT'
    )
);
GO
CREATE INDEX IX_BT_Outcome_Status
    ON ecl_bt.AccountOutcome (BACKTEST_RUN_ID, OUTCOME_STATUS)
    INCLUDE (SOURCE_RUN_ID, ACCOUNT_ID, DEFAULT_DATE, OBSERVATION_END_DATE);
GO

CREATE TABLE ecl_bt.BacktestFinding (
    FINDING_ID bigint IDENTITY(1,1) NOT NULL,
    BACKTEST_RUN_ID bigint NOT NULL,
    SOURCE_RUN_ID bigint NULL,
    ACCOUNT_ID varchar(100) NULL,
    FINDING_CODE varchar(50) NOT NULL,
    SEVERITY varchar(10) NOT NULL,
    FINDING_MESSAGE nvarchar(2000) NOT NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_BT_Finding_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_BT_BacktestFinding PRIMARY KEY CLUSTERED (FINDING_ID),
    CONSTRAINT FK_BT_Finding_Run FOREIGN KEY (BACKTEST_RUN_ID)
        REFERENCES ecl_bt.BacktestRun(BACKTEST_RUN_ID),
    CONSTRAINT CK_BT_Finding_Severity CHECK (SEVERITY IN ('INFO','WARN','ERROR','FATAL'))
);
GO
CREATE INDEX IX_BT_Finding_Run_Severity
    ON ecl_bt.BacktestFinding (BACKTEST_RUN_ID, SEVERITY, FINDING_ID)
    INCLUDE (FINDING_CODE, SOURCE_RUN_ID, ACCOUNT_ID);
GO

/*
Build a frozen monthly cohort from a published ECL run.
Outcome ingestion is intentionally separate because the physical default source
and observation-completeness contract have not yet been confirmed.
*/
CREATE PROCEDURE ecl_bt.usp_Build12MonthCohort
    @BACKTEST_RUN_ID bigint,
    @SOURCE_RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date,
            @RUN_STATUS varchar(20),
            @WEIGHT_VERSION_ID int,
            @COHORT_START_DATE date,
            @COHORT_END_DATE date,
            @OUTCOME_AS_OF_DATE date,
            @BACKTEST_STATUS varchar(20),
            @INSERTED bigint;

    SELECT @COHORT_START_DATE = COHORT_START_DATE,
           @COHORT_END_DATE = COHORT_END_DATE,
           @OUTCOME_AS_OF_DATE = OUTCOME_AS_OF_DATE,
           @BACKTEST_STATUS = RUN_STATUS
    FROM ecl_bt.BacktestRun
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID;

    IF @BACKTEST_STATUS IS NULL
        THROW 51901, 'Backtest run does not exist.', 1;
    IF @BACKTEST_STATUS <> 'CREATED'
        THROW 51902, 'Cohort build requires a CREATED backtest run.', 1;

    SELECT @PROCESS_DATE = PROCESS_DATE,
           @RUN_STATUS = RUN_STATUS,
           @WEIGHT_VERSION_ID = SCENARIO_WEIGHT_VERSION_ID
    FROM ecl_core.RunControl
    WHERE RUN_ID = @SOURCE_RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51903, 'Source ECL RUN_ID does not exist.', 1;
    IF @RUN_STATUS <> 'PUBLISHED'
        THROW 51904, 'Backtest cohort requires a PUBLISHED source ECL run.', 1;
    IF @PROCESS_DATE < @COHORT_START_DATE OR @PROCESS_DATE > @COHORT_END_DATE
        THROW 51905, 'Source PROCESS_DATE is outside the configured cohort date range.', 1;
    IF @PROCESS_DATE > @OUTCOME_AS_OF_DATE
        THROW 51910, 'Source PROCESS_DATE cannot be later than OUTCOME_AS_OF_DATE.', 1;

    IF NOT EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID = @SOURCE_RUN_ID)
        THROW 51906, 'Published source run has no account-level ECL output.', 1;

    IF (SELECT COUNT(*) FROM ecl_cfg.ScenarioWeight
        WHERE VERSION_ID = @WEIGHT_VERSION_ID AND IS_ACTIVE = 1
          AND SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN')) <> 3
       OR ABS((SELECT SUM(SCENARIO_WEIGHT) FROM ecl_cfg.ScenarioWeight
               WHERE VERSION_ID = @WEIGHT_VERSION_ID AND IS_ACTIVE = 1
                 AND SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN')) - 1.0) > 0.00000001
        THROW 51907, 'Source run does not have three active scenario weights summing to one.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (
            SELECT 1 FROM ecl_bt.CohortAccount
            WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
              AND SOURCE_RUN_ID = @SOURCE_RUN_ID
        )
            THROW 51908, 'Cohort for this source RUN_ID already exists.', 1;

        ;WITH PD12 AS (
            SELECT p.RUN_ID, p.ACCOUNT_ID,
                   SUM(CONVERT(decimal(19,12), p.MARGINAL_PD)
                       * CONVERT(decimal(9,8), w.SCENARIO_WEIGHT)) AS FORECAST_PD_12M,
                   COUNT(DISTINCT p.SCENARIO_CODE) AS SCENARIO_COUNT
            FROM ecl_stg.PDCurve p
            JOIN ecl_cfg.ScenarioWeight w
              ON w.VERSION_ID = @WEIGHT_VERSION_ID
             AND w.SCENARIO_CODE = p.SCENARIO_CODE
             AND w.IS_ACTIVE = 1
            WHERE p.RUN_ID = @SOURCE_RUN_ID
              AND p.PROCESS_DATE = @PROCESS_DATE
              AND p.FORECAST_PERIOD = 1
              AND p.IS_ACTIVE = 1
              AND p.SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN')
            GROUP BY p.RUN_ID, p.ACCOUNT_ID
        )
        INSERT INTO ecl_bt.CohortAccount (
            BACKTEST_RUN_ID, SOURCE_RUN_ID, PROCESS_DATE, ACCOUNT_ID,
            POOL_NAME, POOL_ID, STAGE, FORECAST_PD_12M,
            FORECAST_ECL_TOTAL, FORECAST_ECL_12_MONTH,
            IS_PD_BACKTEST_ELIGIBLE, INELIGIBLE_REASON
        )
        SELECT @BACKTEST_RUN_ID, a.RUN_ID, a.PROCESS_DATE, e.ACCOUNT_ID,
               e.POOL_NAME, e.POOL_ID, e.STAGE,
               CASE WHEN e.STAGE IN (1,2) AND pd.SCENARIO_COUNT = 3
                    THEN CONVERT(decimal(19,12), pd.FORECAST_PD_12M) END,
               e.ECL_TOTAL, e.ECL_12_MONTH,
               CASE WHEN e.STAGE IN (1,2) AND pd.SCENARIO_COUNT = 3 THEN 1 ELSE 0 END,
               CASE WHEN e.STAGE = 3 THEN 'STAGE3_ALREADY_DEFAULTED'
                    WHEN pd.ACCOUNT_ID IS NULL THEN 'MISSING_PERIOD1_PD'
                    WHEN pd.SCENARIO_COUNT <> 3 THEN 'INCOMPLETE_SCENARIO_PD'
                    ELSE NULL END
        FROM ecl_stg.AccountSnapshot a
        JOIN ecl_result.ECLAccount e
          ON e.RUN_ID = a.RUN_ID AND e.ACCOUNT_ID = a.ACCOUNT_ID
        LEFT JOIN PD12 pd
          ON pd.RUN_ID = a.RUN_ID AND pd.ACCOUNT_ID = a.ACCOUNT_ID
        WHERE a.RUN_ID = @SOURCE_RUN_ID
          AND a.PROCESS_DATE = @PROCESS_DATE
          AND a.IS_ACTIVE = 1;

        SET @INSERTED = @@ROWCOUNT;

        INSERT INTO ecl_bt.AccountOutcome (
            BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID,
            OBSERVATION_END_DATE, OUTCOME_STATUS
        )
        SELECT @BACKTEST_RUN_ID, c.SOURCE_RUN_ID, c.ACCOUNT_ID,
               CASE WHEN DATEADD(month, 12, c.PROCESS_DATE) <= b.OUTCOME_AS_OF_DATE
                    THEN DATEADD(month, 12, c.PROCESS_DATE)
                    ELSE b.OUTCOME_AS_OF_DATE END,
               CASE WHEN DATEADD(month, 12, c.PROCESS_DATE) <= b.OUTCOME_AS_OF_DATE
                    THEN 'PENDING' ELSE 'IMMATURE' END
        FROM ecl_bt.CohortAccount c
        JOIN ecl_bt.BacktestRun b
          ON b.BACKTEST_RUN_ID = c.BACKTEST_RUN_ID
        WHERE c.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND c.SOURCE_RUN_ID = @SOURCE_RUN_ID;

        UPDATE ecl_bt.BacktestRun
        SET RUN_STATUS = 'COHORT_BUILT'
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND RUN_STATUS = 'CREATED';

        IF @@ROWCOUNT <> 1
            THROW 51909, 'Backtest run status changed during cohort build.', 1;

        COMMIT TRANSACTION;

        SELECT @BACKTEST_RUN_ID AS BACKTEST_RUN_ID,
               @SOURCE_RUN_ID AS SOURCE_RUN_ID,
               @PROCESS_DATE AS PROCESS_DATE,
               @INSERTED AS COHORT_ACCOUNT_COUNT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
