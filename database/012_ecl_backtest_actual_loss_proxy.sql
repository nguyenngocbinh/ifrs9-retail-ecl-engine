/*
IFRS 9 Retail ECL Engine — migration 012: 12-month actual-loss proxy backtest.
Temporary proxy: ABS(os_amount) at the first month-end with current_gb=1
within the 12-month window after the cohort date. This is default exposure,
not realized accounting loss; recoveries/workout cash flows are not modelled.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH(N'ecl_bt.AccountOutcome', N'ACTUAL_LOSS_PROXY') IS NULL
    ALTER TABLE ecl_bt.AccountOutcome ADD ACTUAL_LOSS_PROXY decimal(28,8) NULL;
GO
IF COL_LENGTH(N'ecl_bt.AccountOutcome', N'ACTUAL_LOSS_STATUS') IS NULL
    ALTER TABLE ecl_bt.AccountOutcome ADD ACTUAL_LOSS_STATUS varchar(24) NOT NULL
        CONSTRAINT DF_BT_Outcome_ActualLossStatus DEFAULT ('PENDING') WITH VALUES;
GO
IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'ecl_bt.AccountOutcome')
      AND name = N'CK_BT_Outcome_ActualLoss'
)
    ALTER TABLE ecl_bt.AccountOutcome WITH CHECK ADD CONSTRAINT CK_BT_Outcome_ActualLoss
    CHECK (
        ACTUAL_LOSS_STATUS IN
        ('PENDING','OBSERVED_DEFAULT','ZERO_NO_DEFAULT','ALREADY_DEFAULTED',
         'IMMATURE','UNRESOLVED','DATA_ISSUE')
        AND (ACTUAL_LOSS_PROXY IS NULL OR ACTUAL_LOSS_PROXY >= 0)
        AND (ACTUAL_LOSS_STATUS = 'OBSERVED_DEFAULT' OR ACTUAL_LOSS_PROXY IS NULL)
    );
GO

/* Add an explicit lifecycle state so actual-loss loading is part of the backtest flow. */
ALTER TABLE ecl_bt.BacktestRun DROP CONSTRAINT CK_BT_Run_Status;
GO
ALTER TABLE ecl_bt.BacktestRun WITH CHECK ADD CONSTRAINT CK_BT_Run_Status CHECK (
    RUN_STATUS IN
    ('CREATED','COHORT_BUILT','OUTCOMES_LOADED','ACTUAL_LOSS_LOADED',
     'COMPLETED','FAILED','CANCELLED')
);
GO

CREATE OR ALTER PROCEDURE ecl_bt.usp_Load12MonthActualLossProxy
    @BACKTEST_RUN_ID bigint,
    @SOURCE_RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OUTCOME_AS_OF_DATE date,
            @BACKTEST_STATUS varchar(20),
            @PROCESS_DATE date;

    SELECT @OUTCOME_AS_OF_DATE = OUTCOME_AS_OF_DATE,
           @BACKTEST_STATUS = RUN_STATUS
    FROM ecl_bt.BacktestRun
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID;

    IF @BACKTEST_STATUS IS NULL
        THROW 51931, 'Backtest run does not exist.', 1;
    IF @BACKTEST_STATUS <> 'OUTCOMES_LOADED'
        THROW 51932, 'Actual-loss loading requires OUTCOMES_LOADED status.', 1;

    SELECT @PROCESS_DATE = MIN(PROCESS_DATE)
    FROM ecl_bt.CohortAccount
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
      AND SOURCE_RUN_ID = @SOURCE_RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51933, 'No cohort rows found for the supplied source RUN_ID.', 1;

    IF EXISTS (
        SELECT 1
        FROM ecl_bt.AccountOutcome
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND SOURCE_RUN_ID = @SOURCE_RUN_ID
          AND ACTUAL_LOSS_STATUS <> 'PENDING'
    )
        THROW 51934, 'Actual-loss proxy has already been loaded for this cohort.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* First observed month-end where the account is currently in default. */
        SELECT c.BACKTEST_RUN_ID, c.SOURCE_RUN_ID, c.ACCOUNT_ID,
               MIN(TRY_CONVERT(date, s.process_date)) AS DEFAULT_DATE
        INTO #FirstDefault
        FROM ecl_bt.CohortAccount c
        JOIN [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB] s
          ON CONVERT(varchar(100), s.contract_id) = c.ACCOUNT_ID
         AND TRY_CONVERT(date, s.process_date) > c.PROCESS_DATE
         AND TRY_CONVERT(date, s.process_date) <= DATEADD(month, 12, c.PROCESS_DATE)
         AND TRY_CONVERT(date, s.process_date) <= @OUTCOME_AS_OF_DATE
         AND TRY_CONVERT(int, s.current_gb) = 1
        JOIN ecl_bt.AccountOutcome o
          ON o.BACKTEST_RUN_ID = c.BACKTEST_RUN_ID
         AND o.SOURCE_RUN_ID = c.SOURCE_RUN_ID
         AND o.ACCOUNT_ID = c.ACCOUNT_ID
         AND o.OUTCOME_STATUS = 'OBSERVED_DEFAULT'
        WHERE c.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND c.SOURCE_RUN_ID = @SOURCE_RUN_ID
        GROUP BY c.BACKTEST_RUN_ID, c.SOURCE_RUN_ID, c.ACCOUNT_ID;

        /* Do not choose arbitrarily if more than one source row exists on default month-end. */
        SELECT f.BACKTEST_RUN_ID, f.SOURCE_RUN_ID, f.ACCOUNT_ID, f.DEFAULT_DATE,
               COUNT_BIG(*) AS DEFAULT_DATE_ROW_COUNT,
               MIN(TRY_CONVERT(decimal(28,8), s.os_amount)) AS MIN_OS_AMOUNT,
               MAX(TRY_CONVERT(decimal(28,8), s.os_amount)) AS MAX_OS_AMOUNT,
               SUM(CASE WHEN TRY_CONVERT(decimal(28,8), s.os_amount) IS NULL THEN 1 ELSE 0 END) AS INVALID_OS_AMOUNT_COUNT
        INTO #DefaultSnapshot
        FROM #FirstDefault f
        JOIN [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB] s
          ON CONVERT(varchar(100), s.contract_id) = f.ACCOUNT_ID
         AND TRY_CONVERT(date, s.process_date) = f.DEFAULT_DATE
         AND TRY_CONVERT(int, s.current_gb) = 1
        GROUP BY f.BACKTEST_RUN_ID, f.SOURCE_RUN_ID, f.ACCOUNT_ID, f.DEFAULT_DATE;

        UPDATE o
        SET ACTUAL_LOSS_PROXY =
                CASE WHEN o.OUTCOME_STATUS = 'OBSERVED_DEFAULT'
                           AND d.DEFAULT_DATE_ROW_COUNT = 1
                           AND d.INVALID_OS_AMOUNT_COUNT = 0
                           AND d.MIN_OS_AMOUNT = d.MAX_OS_AMOUNT
                     THEN ABS(d.MIN_OS_AMOUNT)
                     ELSE NULL END,
            ACTUAL_LOSS_STATUS =
                CASE
                    WHEN o.OUTCOME_STATUS = 'ALREADY_DEFAULTED' THEN 'ALREADY_DEFAULTED'
                    WHEN o.OUTCOME_STATUS = 'DATA_ISSUE' THEN 'DATA_ISSUE'
                    WHEN o.OUTCOME_STATUS = 'IMMATURE' THEN 'IMMATURE'
                    WHEN EXISTS (
                        SELECT 1 FROM ecl_bt.BacktestFinding f
                        WHERE f.BACKTEST_RUN_ID = o.BACKTEST_RUN_ID
                          AND f.SOURCE_RUN_ID = o.SOURCE_RUN_ID
                          AND f.ACCOUNT_ID = o.ACCOUNT_ID
                          AND f.FINDING_CODE IN
                              ('OUTCOME_SNAPSHOT_MISSING','OUTCOME_LABEL_INVALID','OUTCOME_SNAPSHOT_DUPLICATE')
                    ) THEN 'UNRESOLVED'
                    WHEN o.OUTCOME_STATUS = 'OBSERVED_DEFAULT'
                         AND d.DEFAULT_DATE_ROW_COUNT = 1
                         AND d.INVALID_OS_AMOUNT_COUNT = 0
                         AND d.MIN_OS_AMOUNT = d.MAX_OS_AMOUNT THEN 'OBSERVED_DEFAULT'
                    WHEN o.OUTCOME_STATUS = 'OBSERVED_DEFAULT'
                         AND d.DEFAULT_DATE_ROW_COUNT > 1 THEN 'DATA_ISSUE'
                    WHEN o.OUTCOME_STATUS = 'OBSERVED_NO_DEFAULT'
                         AND @OUTCOME_AS_OF_DATE >= DATEADD(month, 12, c.PROCESS_DATE)
                         THEN 'ZERO_NO_DEFAULT'
                    ELSE 'UNRESOLVED'
                END
        FROM ecl_bt.AccountOutcome o
        JOIN ecl_bt.CohortAccount c
          ON c.BACKTEST_RUN_ID = o.BACKTEST_RUN_ID
         AND c.SOURCE_RUN_ID = o.SOURCE_RUN_ID
         AND c.ACCOUNT_ID = o.ACCOUNT_ID
        LEFT JOIN #DefaultSnapshot d
          ON d.BACKTEST_RUN_ID = o.BACKTEST_RUN_ID
         AND d.SOURCE_RUN_ID = o.SOURCE_RUN_ID
         AND d.ACCOUNT_ID = o.ACCOUNT_ID
        WHERE o.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND o.SOURCE_RUN_ID = @SOURCE_RUN_ID;

        INSERT INTO ecl_bt.BacktestFinding
            (BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID, FINDING_CODE, SEVERITY, FINDING_MESSAGE)
        SELECT o.BACKTEST_RUN_ID, o.SOURCE_RUN_ID, o.ACCOUNT_ID,
               CASE
                   WHEN o.OUTCOME_STATUS = 'OBSERVED_DEFAULT' AND d.ACCOUNT_ID IS NULL
                       THEN 'ACTUAL_LOSS_DEFAULT_MONTH_NOT_FOUND'
                   WHEN d.DEFAULT_DATE_ROW_COUNT > 1
                       THEN 'ACTUAL_LOSS_DEFAULT_MONTH_DUPLICATE'
                   WHEN d.INVALID_OS_AMOUNT_COUNT > 0
                       THEN 'ACTUAL_LOSS_OS_AMOUNT_INVALID'
                   ELSE 'ACTUAL_LOSS_UNRESOLVED'
               END,
               'WARN',
               CASE
                   WHEN o.OUTCOME_STATUS = 'OBSERVED_DEFAULT' AND d.ACCOUNT_ID IS NULL
                       THEN N'default_flag=1 but no monthly current_gb=1 snapshot was found within the observed 12-month window; proxy loss is unresolved.'
                   WHEN d.DEFAULT_DATE_ROW_COUNT > 1
                       THEN N'Multiple source rows exist on the first observed default month-end; proxy loss was not selected.'
                   WHEN d.INVALID_OS_AMOUNT_COUNT > 0
                       THEN N'os_amount is missing or nonnumeric on the observed default month-end; proxy loss is unresolved.'
                   ELSE N'Actual-loss proxy could not be assigned; review outcome maturity and source quality.'
               END
        FROM ecl_bt.AccountOutcome o
        LEFT JOIN #DefaultSnapshot d
          ON d.BACKTEST_RUN_ID = o.BACKTEST_RUN_ID
         AND d.SOURCE_RUN_ID = o.SOURCE_RUN_ID
         AND d.ACCOUNT_ID = o.ACCOUNT_ID
        WHERE o.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND o.SOURCE_RUN_ID = @SOURCE_RUN_ID
          AND o.ACTUAL_LOSS_STATUS IN ('UNRESOLVED','DATA_ISSUE')
          AND (
                (o.OUTCOME_STATUS = 'OBSERVED_DEFAULT' AND d.ACCOUNT_ID IS NULL)
             OR d.DEFAULT_DATE_ROW_COUNT > 1
             OR d.INVALID_OS_AMOUNT_COUNT > 0
             OR o.ACTUAL_LOSS_STATUS = 'UNRESOLVED'
          );

        UPDATE ecl_bt.BacktestRun
        SET RUN_STATUS = 'ACTUAL_LOSS_LOADED'
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND RUN_STATUS = 'OUTCOMES_LOADED';

        IF @@ROWCOUNT <> 1
            THROW 51935, 'Backtest run status changed during actual-loss proxy load.', 1;

        COMMIT TRANSACTION;

        SELECT ACTUAL_LOSS_STATUS, COUNT_BIG(*) AS ACCOUNT_COUNT,
               SUM(ACTUAL_LOSS_PROXY) AS ACTUAL_LOSS_PROXY_TOTAL
        FROM ecl_bt.AccountOutcome
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND SOURCE_RUN_ID = @SOURCE_RUN_ID
        GROUP BY ACTUAL_LOSS_STATUS
        ORDER BY ACTUAL_LOSS_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Aggregated comparison: 12-month ECL forecast versus default-exposure proxy.
   Only eligible accounts with resolved, mature outcomes are included. */
CREATE OR ALTER PROCEDURE ecl_bt.usp_Report12MonthActualLossBacktest
    @BACKTEST_RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1 FROM ecl_bt.BacktestRun
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND RUN_STATUS IN ('ACTUAL_LOSS_LOADED','COMPLETED')
    )
        THROW 51936, 'Load actual-loss proxy before requesting this report.', 1;

    SELECT c.PROCESS_DATE,
           c.POOL_NAME,
           c.STAGE,
           COUNT_BIG(*) AS RESOLVED_ACCOUNT_COUNT,
           SUM(CASE WHEN o.ACTUAL_LOSS_STATUS = 'OBSERVED_DEFAULT' THEN 1 ELSE 0 END) AS DEFAULT_ACCOUNT_COUNT,
           SUM(c.FORECAST_ECL_12_MONTH) AS FORECAST_ECL_12M_TOTAL,
           SUM(o.ACTUAL_LOSS_PROXY) AS ACTUAL_LOSS_PROXY_TOTAL,
           SUM(o.ACTUAL_LOSS_PROXY) - SUM(c.FORECAST_ECL_12_MONTH) AS ACTUAL_MINUS_ECL,
           CASE WHEN SUM(c.FORECAST_ECL_12_MONTH) = 0 THEN NULL
                ELSE SUM(o.ACTUAL_LOSS_PROXY) / NULLIF(SUM(c.FORECAST_ECL_12_MONTH), 0) END AS ACTUAL_TO_ECL_RATIO,
           SUM(CASE WHEN o.ACTUAL_LOSS_STATUS IN ('UNRESOLVED','DATA_ISSUE','IMMATURE','ALREADY_DEFAULTED','PENDING')
                    THEN 1 ELSE 0 END) AS EXCLUDED_ACCOUNT_COUNT
    FROM ecl_bt.CohortAccount c
    JOIN ecl_bt.AccountOutcome o
      ON o.BACKTEST_RUN_ID = c.BACKTEST_RUN_ID
     AND o.SOURCE_RUN_ID = c.SOURCE_RUN_ID
     AND o.ACCOUNT_ID = c.ACCOUNT_ID
    WHERE c.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
      AND c.IS_PD_BACKTEST_ELIGIBLE = 1
      AND o.ACTUAL_LOSS_STATUS IN ('OBSERVED_DEFAULT','ZERO_NO_DEFAULT')
    GROUP BY c.PROCESS_DATE, c.POOL_NAME, c.STAGE
    ORDER BY c.PROCESS_DATE, c.POOL_NAME, c.STAGE;

    /* Data-quality reconciliation for the same backtest run. */
    SELECT ACTUAL_LOSS_STATUS, COUNT_BIG(*) AS ACCOUNT_COUNT
    FROM ecl_bt.AccountOutcome
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
    GROUP BY ACTUAL_LOSS_STATUS
    ORDER BY ACTUAL_LOSS_STATUS;
END;
GO
