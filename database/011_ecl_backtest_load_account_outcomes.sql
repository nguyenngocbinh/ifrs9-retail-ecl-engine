/*
IFRS 9 Retail ECL Engine — migration 011: load account-level 12-month outcomes
Source contract confirmed for the target environment:
  [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB]
  account_id = contract_id; monthly month-end snapshots.
Additive to the backtest foundation. Validate source column types and permissions in DEV/UAT.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Distinguish accounts already in default at cohort date from future defaults. */
ALTER TABLE ecl_bt.AccountOutcome DROP CONSTRAINT CK_BT_Outcome_Status;
GO
ALTER TABLE ecl_bt.AccountOutcome WITH CHECK ADD CONSTRAINT CK_BT_Outcome_Status CHECK (
    OUTCOME_STATUS IN
      ('PENDING','OBSERVED_DEFAULT','OBSERVED_NO_DEFAULT','IMMATURE','DATA_ISSUE','ALREADY_DEFAULTED')
);
GO

CREATE OR ALTER PROCEDURE ecl_bt.usp_Load12MonthAccountOutcomes
    @BACKTEST_RUN_ID bigint,
    @SOURCE_RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OUTCOME_AS_OF_DATE date,
            @BACKTEST_STATUS varchar(20),
            @PROCESS_DATE date,
            @HORIZON_END_DATE date;

    SELECT @OUTCOME_AS_OF_DATE = OUTCOME_AS_OF_DATE,
           @BACKTEST_STATUS = RUN_STATUS
    FROM ecl_bt.BacktestRun
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID;

    IF @BACKTEST_STATUS IS NULL
        THROW 51921, 'Backtest run does not exist.', 1;
    IF @BACKTEST_STATUS <> 'COHORT_BUILT'
        THROW 51922, 'Outcome load requires a COHORT_BUILT backtest run.', 1;

    SELECT @PROCESS_DATE = MIN(PROCESS_DATE),
           @HORIZON_END_DATE = DATEADD(month, 12, MIN(PROCESS_DATE))
    FROM ecl_bt.CohortAccount
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
      AND SOURCE_RUN_ID = @SOURCE_RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51923, 'No cohort rows found for the supplied source RUN_ID.', 1;

    IF EXISTS (
        SELECT 1
        FROM ecl_bt.CohortAccount
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND SOURCE_RUN_ID = @SOURCE_RUN_ID
          AND PROCESS_DATE <> @PROCESS_DATE
    )
        THROW 51924, 'A single source RUN_ID unexpectedly contains multiple PROCESS_DATE values.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (
            SELECT 1
            FROM ecl_bt.AccountOutcome
            WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
              AND SOURCE_RUN_ID = @SOURCE_RUN_ID
              AND OUTCOME_STATUS <> 'PENDING'
        )
            THROW 51925, 'Outcome rows have already been loaded or reviewed for this cohort.', 1;

        ;WITH SourceOutcome AS (
            SELECT
                c.BACKTEST_RUN_ID,
                c.SOURCE_RUN_ID,
                c.ACCOUNT_ID,
                c.PROCESS_DATE,
                DATEADD(month, 12, c.PROCESS_DATE) AS HORIZON_END_DATE,
                TRY_CONVERT(int, s.current_gb) AS CURRENT_GB,
                TRY_CONVERT(int, s.default_flag) AS DEFAULT_FLAG,
                TRY_CONVERT(date, s.first_to_default) AS DEFAULT_DATE,
                COUNT(s.contract_id) OVER (PARTITION BY c.ACCOUNT_ID) AS SOURCE_MATCH_COUNT
            FROM ecl_bt.CohortAccount c
            LEFT JOIN [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB] s
              ON CONVERT(varchar(100), s.contract_id) = c.ACCOUNT_ID
             AND TRY_CONVERT(date, s.process_date) = c.PROCESS_DATE
            WHERE c.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
              AND c.SOURCE_RUN_ID = @SOURCE_RUN_ID
        ),
        Classified AS (
            SELECT *,
                CASE
                    WHEN SOURCE_MATCH_COUNT = 0 THEN 'DATA_ISSUE'
                    WHEN SOURCE_MATCH_COUNT > 1 THEN 'DATA_ISSUE'
                    WHEN CURRENT_GB IS NULL OR CURRENT_GB NOT IN (0,1)
                      OR DEFAULT_FLAG IS NULL OR DEFAULT_FLAG NOT IN (0,1)
                        THEN 'DATA_ISSUE'
                    WHEN CURRENT_GB = 1 THEN 'ALREADY_DEFAULTED'
                    WHEN DEFAULT_FLAG = 1
                      AND DEFAULT_DATE > PROCESS_DATE
                      AND DEFAULT_DATE <= HORIZON_END_DATE
                        THEN 'OBSERVED_DEFAULT'
                    WHEN DEFAULT_FLAG = 1 THEN 'DATA_ISSUE'
                    WHEN DEFAULT_FLAG = 0
                      AND @OUTCOME_AS_OF_DATE >= HORIZON_END_DATE
                        THEN 'OBSERVED_NO_DEFAULT'
                    ELSE 'IMMATURE'
                END AS CLASSIFIED_STATUS
            FROM SourceOutcome
        )
        UPDATE o
        SET o.DEFAULT_DATE =
                CASE WHEN x.CLASSIFIED_STATUS = 'OBSERVED_DEFAULT'
                     THEN x.DEFAULT_DATE ELSE NULL END,
            o.OBSERVATION_END_DATE =
                CASE
                    WHEN x.CLASSIFIED_STATUS = 'IMMATURE' THEN @OUTCOME_AS_OF_DATE
                    WHEN x.CLASSIFIED_STATUS = 'OBSERVED_NO_DEFAULT' THEN x.HORIZON_END_DATE
                    WHEN x.CLASSIFIED_STATUS = 'ALREADY_DEFAULTED' THEN x.PROCESS_DATE
                    ELSE NULL
                END,
            o.OUTCOME_STATUS = x.CLASSIFIED_STATUS,
            o.OUTCOME_SOURCE_OBJECT = N'[DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB]',
            o.OUTCOME_SOURCE_VERSION = CONVERT(varchar(100), @OUTCOME_AS_OF_DATE, 23),
            o.OUTCOME_NOTE =
                CASE
                    WHEN x.SOURCE_MATCH_COUNT = 0 THEN N'No source row for account and cohort process_date.'
                    WHEN x.SOURCE_MATCH_COUNT > 1 THEN N'Multiple source rows for account and cohort process_date.'
                    WHEN x.CURRENT_GB = 1 THEN N'Already defaulted at cohort date; excluded from future-default denominator.'
                    WHEN x.CLASSIFIED_STATUS = 'DATA_ISSUE'
                        THEN N'Inconsistent or incomplete current_gb/default_flag/default date mapping.'
                    WHEN x.CLASSIFIED_STATUS = 'IMMATURE'
                        THEN N'12-month observation horizon is not complete as of OUTCOME_AS_OF_DATE.'
                    ELSE NULL
                END,
            o.LOADED_AT = SYSUTCDATETIME()
        FROM ecl_bt.AccountOutcome o
        JOIN Classified x
          ON x.BACKTEST_RUN_ID = o.BACKTEST_RUN_ID
         AND x.SOURCE_RUN_ID = o.SOURCE_RUN_ID
         AND x.ACCOUNT_ID = o.ACCOUNT_ID
        WHERE o.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND o.SOURCE_RUN_ID = @SOURCE_RUN_ID;

        /* Keep PD backtest eligibility aligned with the observed cohort status. */
        UPDATE c
        SET IS_PD_BACKTEST_ELIGIBLE =
                CASE WHEN c.STAGE IN (1,2)
                           AND c.FORECAST_PD_12M IS NOT NULL
                           AND o.OUTCOME_STATUS <> 'ALREADY_DEFAULTED'
                     THEN 1 ELSE 0 END,
            INELIGIBLE_REASON =
                CASE
                    WHEN c.STAGE = 3 THEN 'STAGE3_ALREADY_DEFAULTED'
                    WHEN c.FORECAST_PD_12M IS NULL THEN 'MISSING_PERIOD1_PD'
                    WHEN o.OUTCOME_STATUS = 'ALREADY_DEFAULTED' THEN 'DEFAULTED_AT_COHORT_DATE'
                    ELSE NULL
                END
        FROM ecl_bt.CohortAccount c
        JOIN ecl_bt.AccountOutcome o
          ON o.BACKTEST_RUN_ID = c.BACKTEST_RUN_ID
         AND o.SOURCE_RUN_ID = c.SOURCE_RUN_ID
         AND o.ACCOUNT_ID = c.ACCOUNT_ID
        WHERE c.BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND c.SOURCE_RUN_ID = @SOURCE_RUN_ID;

        UPDATE ecl_bt.BacktestRun
        SET RUN_STATUS = 'OUTCOMES_LOADED'
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND RUN_STATUS = 'COHORT_BUILT';

        IF @@ROWCOUNT <> 1
            THROW 51926, 'Backtest run status changed during outcome load.', 1;

        COMMIT TRANSACTION;

        SELECT OUTCOME_STATUS, COUNT_BIG(*) AS ACCOUNT_COUNT
        FROM ecl_bt.AccountOutcome
        WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID
          AND SOURCE_RUN_ID = @SOURCE_RUN_ID
        GROUP BY OUTCOME_STATUS
        ORDER BY OUTCOME_STATUS;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
