/*
IFRS 9 Retail ECL Engine — migration 011: load account-level 12-month outcomes.
Source: [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB], monthly month-end snapshots.
Account mapping: ecl_bt.CohortAccount.ACCOUNT_ID = source contract_id.

Agreed classification:
  current_gb=1 -> ALREADY_DEFAULTED
  current_gb=0 and default_flag=1 -> OBSERVED_DEFAULT (forward 12-month label)
  current_gb=0 and default_flag=0 -> OBSERVED_NO_DEFAULT only if horizon is mature
  missing snapshot / invalid labels -> OBSERVED_NO_DEFAULT plus WARN finding
  duplicate account/date source rows -> DATA_ISSUE plus WARN finding
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

ALTER TABLE ecl_bt.AccountOutcome DROP CONSTRAINT CK_BT_Outcome_Status;
GO
ALTER TABLE ecl_bt.AccountOutcome WITH CHECK ADD CONSTRAINT CK_BT_Outcome_Status CHECK (
    OUTCOME_STATUS IN
      ('PENDING','OBSERVED_DEFAULT','OBSERVED_NO_DEFAULT','IMMATURE','DATA_ISSUE','ALREADY_DEFAULTED')
);
GO

/* default_flag is a binary 12-month label; default date is not required. */
ALTER TABLE ecl_bt.AccountOutcome DROP CONSTRAINT CK_BT_Outcome_DefaultConsistency;
GO
ALTER TABLE ecl_bt.AccountOutcome WITH CHECK ADD CONSTRAINT CK_BT_Outcome_DefaultConsistency CHECK (
    OUTCOME_STATUS = 'OBSERVED_DEFAULT' OR DEFAULT_DATE IS NULL
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
            @COHORT_COUNT bigint;

    SELECT @OUTCOME_AS_OF_DATE = OUTCOME_AS_OF_DATE,
           @BACKTEST_STATUS = RUN_STATUS
    FROM ecl_bt.BacktestRun
    WHERE BACKTEST_RUN_ID = @BACKTEST_RUN_ID;

    IF @BACKTEST_STATUS IS NULL
        THROW 51921, 'Backtest run does not exist.', 1;
    IF @BACKTEST_STATUS <> 'COHORT_BUILT'
        THROW 51922, 'Outcome load requires a COHORT_BUILT backtest run.', 1;

    SELECT @PROCESS_DATE = MIN(PROCESS_DATE),
           @COHORT_COUNT = COUNT_BIG(*)
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
                    WHEN SOURCE_MATCH_COUNT > 1 THEN 'DATA_ISSUE'
                    WHEN SOURCE_MATCH_COUNT = 0 THEN 'OBSERVED_NO_DEFAULT'
                    WHEN CURRENT_GB = 1 THEN 'ALREADY_DEFAULTED'
                    WHEN CURRENT_GB IS NULL OR CURRENT_GB NOT IN (0,1)
                      OR DEFAULT_FLAG IS NULL OR DEFAULT_FLAG NOT IN (0,1)
                        THEN 'OBSERVED_NO_DEFAULT'
                    WHEN DEFAULT_FLAG = 1 THEN 'OBSERVED_DEFAULT'
                    WHEN DEFAULT_FLAG = 0
                      AND @OUTCOME_AS_OF_DATE >= HORIZON_END_DATE
                        THEN 'OBSERVED_NO_DEFAULT'
                    WHEN DEFAULT_FLAG = 0 THEN 'IMMATURE'
                    ELSE 'OBSERVED_NO_DEFAULT'
                END AS CLASSIFIED_STATUS
            FROM SourceOutcome
        )
        UPDATE o
        SET o.DEFAULT_DATE = NULL,
            o.OBSERVATION_END_DATE =
                CASE
                    WHEN x.CLASSIFIED_STATUS = 'IMMATURE' THEN @OUTCOME_AS_OF_DATE
                    WHEN x.CLASSIFIED_STATUS = 'OBSERVED_NO_DEFAULT'
                         AND x.SOURCE_MATCH_COUNT = 1
                         AND x.CURRENT_GB = 0 AND x.DEFAULT_FLAG = 0
                        THEN x.HORIZON_END_DATE
                    WHEN x.CLASSIFIED_STATUS = 'ALREADY_DEFAULTED' THEN x.PROCESS_DATE
                    ELSE NULL
                END,
            o.OUTCOME_STATUS = x.CLASSIFIED_STATUS,
            o.OUTCOME_SOURCE_OBJECT = N'[DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB]',
            o.OUTCOME_SOURCE_VERSION = CONVERT(varchar(100), @OUTCOME_AS_OF_DATE, 23),
            o.OUTCOME_NOTE =
                CASE
                    WHEN x.SOURCE_MATCH_COUNT = 0
                        THEN N'Missing account snapshot at cohort process_date; treated as non-default per agreed rule and logged as warning.'
                    WHEN x.SOURCE_MATCH_COUNT > 1
                        THEN N'Multiple source rows for account and cohort process_date; DATA_ISSUE pending review.'
                    WHEN x.CURRENT_GB = 1
                        THEN N'Already defaulted at cohort date; excluded from future-default denominator.'
                    WHEN x.CURRENT_GB IS NULL OR x.CURRENT_GB NOT IN (0,1)
                      OR x.DEFAULT_FLAG IS NULL OR x.DEFAULT_FLAG NOT IN (0,1)
                        THEN N'Missing/invalid current_gb or default_flag; treated as non-default per agreed rule and logged as warning.'
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

        /* Missing/invalid labels follow agreed non-default treatment but remain visible as WARN findings. */
        INSERT INTO ecl_bt.BacktestFinding (
            BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID, FINDING_CODE,
            SEVERITY, FINDING_MESSAGE
        )
        SELECT @BACKTEST_RUN_ID, x.SOURCE_RUN_ID, x.ACCOUNT_ID,
               CASE
                   WHEN x.SOURCE_MATCH_COUNT = 0 THEN 'OUTCOME_SNAPSHOT_MISSING'
                   WHEN x.SOURCE_MATCH_COUNT > 1 THEN 'OUTCOME_SNAPSHOT_DUPLICATE'
                   ELSE 'OUTCOME_LABEL_INVALID'
               END,
               'WARN',
               CASE
                   WHEN x.SOURCE_MATCH_COUNT = 0
                       THEN N'Missing source snapshot for this account/date; outcome treated as non-default. Check source completeness.'
                   WHEN x.SOURCE_MATCH_COUNT > 1
                       THEN N'Multiple source rows for this account/date; outcome classified DATA_ISSUE.'
                   ELSE N'Missing/invalid current_gb or default_flag; outcome treated as non-default. Check source values.'
               END
        FROM Classified x
        WHERE x.SOURCE_MATCH_COUNT <> 1
           OR x.CURRENT_GB IS NULL OR x.CURRENT_GB NOT IN (0,1)
           OR x.DEFAULT_FLAG IS NULL OR x.DEFAULT_FLAG NOT IN (0,1);

        /* One cohort-level warning makes a completely missing source snapshot conspicuous. */
        IF NOT EXISTS (
            SELECT 1
            FROM [DEFAULT].[dbo].[VW_ODR_CONTRACT_LEVEL_IRB] s
            WHERE TRY_CONVERT(date, s.process_date) = @PROCESS_DATE
        )
        BEGIN
            INSERT INTO ecl_bt.BacktestFinding (
                BACKTEST_RUN_ID, SOURCE_RUN_ID, ACCOUNT_ID, FINDING_CODE,
                SEVERITY, FINDING_MESSAGE
            )
            VALUES (
                @BACKTEST_RUN_ID, @SOURCE_RUN_ID, NULL,
                'OUTCOME_SOURCE_SNAPSHOT_EMPTY', 'WARN',
                N'No source rows exist at all for this cohort process_date. Missing accounts are treated as non-default by agreed rule; do not interpret results until source completeness is checked.'
            );
        END;

        /* Keep eligibility aligned with current default status; invalid/missing labels are non-default by agreed rule. */
        UPDATE c
        SET IS_PD_BACKTEST_ELIGIBLE =
                CASE WHEN c.STAGE IN (1,2)
                           AND c.FORECAST_PD_12M IS NOT NULL
                           AND o.OUTCOME_STATUS <> 'ALREADY_DEFAULTED'
                           AND o.OUTCOME_STATUS <> 'DATA_ISSUE'
                     THEN 1 ELSE 0 END,
            INELIGIBLE_REASON =
                CASE
                    WHEN c.STAGE = 3 THEN 'STAGE3_ALREADY_DEFAULTED'
                    WHEN c.FORECAST_PD_12M IS NULL THEN 'MISSING_PERIOD1_PD'
                    WHEN o.OUTCOME_STATUS = 'ALREADY_DEFAULTED' THEN 'DEFAULTED_AT_COHORT_DATE'
                    WHEN o.OUTCOME_STATUS = 'DATA_ISSUE' THEN 'DUPLICATE_OUTCOME_SOURCE'
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
