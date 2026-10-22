/*
IFRS 9 Retail ECL Engine — input validation migration 003
Target: SQL Server 2016.
Validates staged inputs before calculation. No ECL formulas are implemented.
Deploy after migrations 001 and 002 in a disposable/dev database first.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Nullable by design: NULL means upstream has not certified POCI classification.
   Do not default unknown POCI status to non-POCI. */
IF COL_LENGTH(N'ecl_stg.AccountSnapshot', N'IS_POCI') IS NULL
    ALTER TABLE ecl_stg.AccountSnapshot ADD IS_POCI bit NULL;
GO

IF OBJECT_ID(N'ecl_core.usp_ValidateRunInputs', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_ValidateRunInputs;
GO

CREATE PROCEDURE ecl_core.usp_ValidateRunInputs
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date;
    DECLARE @RUN_STATUS varchar(20);
    DECLARE @WEIGHT_VERSION_ID int;
    DECLARE @RUN_TYPE varchar(20);
    DECLARE @REQUESTED_POOL_NAME varchar(100);
    DECLARE @REQUESTED_POOL_ID varchar(100);
    DECLARE @MAX_HORIZON int;
    DECLARE @ERROR_COUNT int = 0;
    DECLARE @WARN_COUNT int = 0;

    SELECT
        @PROCESS_DATE = PROCESS_DATE,
        @RUN_STATUS = RUN_STATUS,
        @WEIGHT_VERSION_ID = SCENARIO_WEIGHT_VERSION_ID,
        @RUN_TYPE = RUN_TYPE,
        @REQUESTED_POOL_NAME = REQUESTED_POOL_NAME,
        @REQUESTED_POOL_ID = REQUESTED_POOL_ID
    FROM ecl_core.RunControl
    WHERE RUN_ID = @RUN_ID;

    IF @PROCESS_DATE IS NULL
        THROW 51300, 'Run does not exist.', 1;

    IF @RUN_STATUS <> 'VALIDATING'
        THROW 51301, 'Input validation requires run status VALIDATING.', 1;

    /* Every staged input row must use the run's reporting date. The keys intentionally
       exclude PROCESS_DATE, so a wrong-date row can otherwise coexist in a valid RUN_ID. */
    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID,
         SCENARIO_CODE, FORECAST_PERIOD, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_PROCESS_DATE_MISMATCH', 'FATAL',
           a.POOL_NAME, a.ACCOUNT_ID, a.POOL_ID, NULL, NULL,
           N'ACCOUNT input row PROCESS_DATE differs from the run reporting date.'
    FROM ecl_stg.AccountSnapshot a
    WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE <> @PROCESS_DATE
      AND NOT EXISTS (
          SELECT 1 FROM ecl_audit.ValidationError e
          WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_PROCESS_DATE_MISMATCH'
            AND e.ACCOUNT_ID = a.ACCOUNT_ID AND e.ERROR_MESSAGE = N'ACCOUNT input row PROCESS_DATE differs from the run reporting date.'
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID,
         SCENARIO_CODE, FORECAST_PERIOD, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_PROCESS_DATE_MISMATCH', 'FATAL',
           a.POOL_NAME, p.ACCOUNT_ID, a.POOL_ID, p.SCENARIO_CODE, p.FORECAST_PERIOD,
           N'PD input row PROCESS_DATE differs from the run reporting date.'
    FROM ecl_stg.PDCurve p
    JOIN ecl_stg.AccountSnapshot a ON a.RUN_ID = p.RUN_ID AND a.ACCOUNT_ID = p.ACCOUNT_ID
    WHERE p.RUN_ID = @RUN_ID AND p.PROCESS_DATE <> @PROCESS_DATE
      AND NOT EXISTS (
          SELECT 1 FROM ecl_audit.ValidationError e
          WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_PROCESS_DATE_MISMATCH'
            AND e.ACCOUNT_ID = p.ACCOUNT_ID AND e.SCENARIO_CODE = p.SCENARIO_CODE
            AND e.FORECAST_PERIOD = p.FORECAST_PERIOD
            AND e.ERROR_MESSAGE = N'PD input row PROCESS_DATE differs from the run reporting date.'
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID,
         SCENARIO_CODE, FORECAST_PERIOD, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_PROCESS_DATE_MISMATCH', 'FATAL',
           a.POOL_NAME, c.ACCOUNT_ID, a.POOL_ID, NULL, c.FORECAST_PERIOD,
           N'LGD input row PROCESS_DATE differs from the run reporting date.'
    FROM ecl_stg.LGDCurve c
    JOIN ecl_stg.AccountSnapshot a ON a.RUN_ID = c.RUN_ID AND a.ACCOUNT_ID = c.ACCOUNT_ID
    WHERE c.RUN_ID = @RUN_ID AND c.PROCESS_DATE <> @PROCESS_DATE
      AND NOT EXISTS (
          SELECT 1 FROM ecl_audit.ValidationError e
          WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_PROCESS_DATE_MISMATCH'
            AND e.ACCOUNT_ID = c.ACCOUNT_ID AND e.FORECAST_PERIOD = c.FORECAST_PERIOD
            AND e.ERROR_MESSAGE = N'LGD input row PROCESS_DATE differs from the run reporting date.'
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID,
         SCENARIO_CODE, FORECAST_PERIOD, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_PROCESS_DATE_MISMATCH', 'FATAL',
           a.POOL_NAME, c.ACCOUNT_ID, a.POOL_ID, NULL, c.FORECAST_PERIOD,
           N'EAD input row PROCESS_DATE differs from the run reporting date.'
    FROM ecl_stg.EADCurve c
    JOIN ecl_stg.AccountSnapshot a ON a.RUN_ID = c.RUN_ID AND a.ACCOUNT_ID = c.ACCOUNT_ID
    WHERE c.RUN_ID = @RUN_ID AND c.PROCESS_DATE <> @PROCESS_DATE
      AND NOT EXISTS (
          SELECT 1 FROM ecl_audit.ValidationError e
          WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_PROCESS_DATE_MISMATCH'
            AND e.ACCOUNT_ID = c.ACCOUNT_ID AND e.FORECAST_PERIOD = c.FORECAST_PERIOD
            AND e.ERROR_MESSAGE = N'EAD input row PROCESS_DATE differs from the run reporting date.'
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, FORECAST_PERIOD, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_PROCESS_DATE_MISMATCH', 'FATAL',
           NULL, N'EIR input row PROCESS_DATE differs from the run reporting date.'
    FROM ecl_stg.EIRCurve c
    WHERE c.RUN_ID = @RUN_ID AND c.PROCESS_DATE <> @PROCESS_DATE
      AND NOT EXISTS (
          SELECT 1 FROM ecl_audit.ValidationError e
          WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_PROCESS_DATE_MISMATCH'
            AND e.ERROR_MESSAGE = N'EIR input row PROCESS_DATE differs from the run reporting date.'
      );

    IF NOT EXISTS (SELECT 1 FROM ecl_core.RunInputManifest WHERE RUN_ID = @RUN_ID AND IS_SEALED = 1)
    BEGIN
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'MANIFEST_NOT_SEALED', 'FATAL',
               N'Input manifest must be sealed before validation.';
    END;

    ;WITH RequiredInputFamily AS
    (
        SELECT INPUT_FAMILY
        FROM (VALUES ('ACCOUNT'), ('PD'), ('LGD'), ('EAD'), ('EIR'), ('SCENARIO_WEIGHT')) v(INPUT_FAMILY)
    )
    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'INPUT_FAMILY_MISSING', 'FATAL',
           CONCAT(N'Required input family is missing or incomplete: ', r.INPUT_FAMILY, N'.')
    FROM RequiredInputFamily r
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM ecl_core.RunInputManifestItem m
        WHERE m.RUN_ID = @RUN_ID
          AND m.INPUT_FAMILY = r.INPUT_FAMILY
          AND m.IS_COMPLETE = 1
          AND m.SNAPSHOT_ROW_COUNT >= 0
    )
      AND NOT EXISTS
      (
        SELECT 1 FROM ecl_audit.ValidationError e
        WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'INPUT_FAMILY_MISSING'
          AND e.ERROR_MESSAGE = CONCAT(N'Required input family is missing or incomplete: ', r.INPUT_FAMILY, N'.')
      );

    IF NOT EXISTS
    (
        SELECT 1 FROM ecl_stg.AccountSnapshot
        WHERE RUN_ID = @RUN_ID AND PROCESS_DATE = @PROCESS_DATE AND IS_ACTIVE = 1
    )
    BEGIN
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'ACCOUNT_POPULATION_EMPTY', 'FATAL',
               N'No active account snapshots exist for this run and process date.'
        WHERE NOT EXISTS
        (
            SELECT 1 FROM ecl_audit.ValidationError
            WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'ACCOUNT_POPULATION_EMPTY'
        );
    END;

    /* A selective run must contain only the explicitly requested product/pool. */
    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'RUN_SCOPE_MISMATCH', 'FATAL',
           a.POOL_NAME, a.ACCOUNT_ID, a.POOL_ID,
           N'Account snapshot falls outside the requested selective run scope.'
    FROM ecl_stg.AccountSnapshot a
    WHERE a.RUN_ID = @RUN_ID AND a.IS_ACTIVE = 1
      AND @RUN_TYPE = 'SELECTIVE'
      AND ((@REQUESTED_POOL_NAME IS NOT NULL AND a.POOL_NAME <> @REQUESTED_POOL_NAME)
        OR (@REQUESTED_POOL_ID IS NOT NULL AND a.POOL_ID <> @REQUESTED_POOL_ID))
      AND NOT EXISTS
      (
        SELECT 1 FROM ecl_audit.ValidationError e
        WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'RUN_SCOPE_MISMATCH'
          AND e.ACCOUNT_ID = a.ACCOUNT_ID
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'MATURITY_DATE_INVALID', 'ERROR',
           a.POOL_NAME, a.ACCOUNT_ID, a.POOL_ID,
           N'Active account maturity date is earlier than the process date.'
    FROM ecl_stg.AccountSnapshot a
    WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
      AND a.IS_ACTIVE = 1 AND a.MATURITY_DATE < @PROCESS_DATE
      AND NOT EXISTS
      (
        SELECT 1 FROM ecl_audit.ValidationError e
        WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'MATURITY_DATE_INVALID'
          AND e.ACCOUNT_ID = a.ACCOUNT_ID
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'POCI_CLASSIFICATION_MISSING', 'ERROR',
           a.POOL_NAME, a.ACCOUNT_ID, a.POOL_ID,
           N'POCI classification is NULL. Upstream must explicitly classify the account before calculation.'
    FROM ecl_stg.AccountSnapshot a
    WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
      AND a.IS_ACTIVE = 1 AND a.IS_POCI IS NULL
      AND NOT EXISTS
      (
        SELECT 1 FROM ecl_audit.ValidationError e
        WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'POCI_CLASSIFICATION_MISSING'
          AND e.ACCOUNT_ID = a.ACCOUNT_ID
      );

    INSERT INTO ecl_audit.ValidationError
        (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, ERROR_MESSAGE)
    SELECT @RUN_ID, @PROCESS_DATE, 'POCI_EXCLUDED', 'ERROR',
           a.POOL_NAME, a.ACCOUNT_ID, a.POOL_ID,
           N'POCI account is out of v1 calculation scope and must be excluded from ordinary ECL calculation and reconciled.'
    FROM ecl_stg.AccountSnapshot a
    WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
      AND a.IS_ACTIVE = 1 AND a.IS_POCI = 1
      AND NOT EXISTS
      (
        SELECT 1 FROM ecl_audit.ValidationError e
        WHERE e.RUN_ID = @RUN_ID AND e.VALIDATION_CODE = 'POCI_EXCLUDED'
          AND e.ACCOUNT_ID = a.ACCOUNT_ID
      );

    /* Validate the version is effective on the reporting date and its three scenario weights sum to 1. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM ecl_cfg.ScenarioWeightVersion v
        WHERE v.VERSION_ID = @WEIGHT_VERSION_ID
          AND v.EFFECTIVE_FROM <= @PROCESS_DATE
          AND (v.EFFECTIVE_TO IS NULL OR v.EFFECTIVE_TO >= @PROCESS_DATE)
    )
    BEGIN
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'SCENARIO_WEIGHT_VERSION_INEFFECTIVE', 'FATAL',
               N'Selected scenario-weight version is not effective on the process date.'
        WHERE NOT EXISTS
        (
            SELECT 1 FROM ecl_audit.ValidationError
            WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'SCENARIO_WEIGHT_VERSION_INEFFECTIVE'
        );
    END;

    IF
    (
        SELECT COUNT(DISTINCT w.SCENARIO_CODE)
        FROM ecl_cfg.ScenarioWeight w
        WHERE w.VERSION_ID = @WEIGHT_VERSION_ID AND w.IS_ACTIVE = 1
    ) <> 3
    OR ABS(ISNULL((
        SELECT SUM(CONVERT(decimal(19,10), w.SCENARIO_WEIGHT))
        FROM ecl_cfg.ScenarioWeight w
        WHERE w.VERSION_ID = @WEIGHT_VERSION_ID AND w.IS_ACTIVE = 1
    ), 0) - 1.0) > 0.00000001
    OR EXISTS
    (
        SELECT 1 FROM ecl_cfg.Scenario s
        WHERE s.IS_ACTIVE = 1
          AND s.SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN')
          AND NOT EXISTS
          (
            SELECT 1 FROM ecl_cfg.ScenarioWeight w
            WHERE w.VERSION_ID = @WEIGHT_VERSION_ID
              AND w.SCENARIO_CODE = s.SCENARIO_CODE AND w.IS_ACTIVE = 1
          )
    )
    BEGIN
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'SCENARIO_WEIGHTS_INVALID', 'FATAL',
               N'Selected version must contain active Downturn/Base/Upturn weights that sum to 1.'
        WHERE NOT EXISTS
        (
            SELECT 1 FROM ecl_audit.ValidationError
            WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'SCENARIO_WEIGHTS_INVALID'
        );
    END;

    /* Horizon uses full annual curve periods through maturity. Partial-year fraction is
       reserved for the discount exponent; this validation does not prorate PD or EAD. */
    ;WITH AccountHorizon AS
    (
        SELECT a.ACCOUNT_ID, a.POOL_NAME, a.POOL_ID,
               CASE
                 WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                 ELSE
                   CASE WHEN
                     (DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                       + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE THEN 1 ELSE 0 END) <= 12
                   THEN 1
                   ELSE CEILING(CONVERT(decimal(10,2),
                     DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                       + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE THEN 1 ELSE 0 END
                   ) / 12.0)
                   END
               END AS HORIZON
        FROM ecl_stg.AccountSnapshot a
        WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
          AND a.IS_ACTIVE = 1 AND ISNULL(a.IS_POCI, 0) = 0
          AND a.MATURITY_DATE >= @PROCESS_DATE
    ),
    Numbers AS
    (
        SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    )
    SELECT @MAX_HORIZON = ISNULL(MAX(HORIZON), 0) FROM AccountHorizon;

    IF @MAX_HORIZON > 0
    BEGIN
        ;WITH AccountHorizon AS
        (
            SELECT a.ACCOUNT_ID, a.POOL_NAME, a.POOL_ID,
                   CASE
                     WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                     ELSE CEILING(CONVERT(decimal(10,2),
                       DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                         + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE THEN 1 ELSE 0 END
                     ) / 12.0)
                   END AS HORIZON
            FROM ecl_stg.AccountSnapshot a
            WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1 AND ISNULL(a.IS_POCI, 0) = 0
              AND a.MATURITY_DATE >= @PROCESS_DATE
        ),
        Numbers AS
        (
            SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects a CROSS JOIN sys.all_objects b
        ),
        ExpectedPeriod AS
        (
            SELECT h.ACCOUNT_ID, h.POOL_NAME, h.POOL_ID, n.N AS FORECAST_PERIOD
            FROM AccountHorizon h
            JOIN Numbers n ON n.N <= h.HORIZON
        )
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, FORECAST_PERIOD, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'CURVE_COVERAGE_MISSING', 'ERROR',
               e.POOL_NAME, e.ACCOUNT_ID, e.POOL_ID, e.FORECAST_PERIOD,
               CONCAT(N'Missing or inactive ', f.CURVE_FAMILY, N' curve coverage for required forecast period.')
        FROM ExpectedPeriod e
        CROSS JOIN (VALUES ('LGD'), ('EAD')) f(CURVE_FAMILY)
        WHERE
          (
            (f.CURVE_FAMILY = 'LGD' AND NOT EXISTS
               (SELECT 1 FROM ecl_stg.LGDCurve c WHERE c.RUN_ID = @RUN_ID AND c.ACCOUNT_ID = e.ACCOUNT_ID
                AND c.FORECAST_PERIOD = e.FORECAST_PERIOD AND c.IS_ACTIVE = 1))
            OR
            (f.CURVE_FAMILY = 'EAD' AND NOT EXISTS
               (SELECT 1 FROM ecl_stg.EADCurve c WHERE c.RUN_ID = @RUN_ID AND c.ACCOUNT_ID = e.ACCOUNT_ID
                AND c.FORECAST_PERIOD = e.FORECAST_PERIOD AND c.IS_ACTIVE = 1))
          )
          AND NOT EXISTS
          (
            SELECT 1 FROM ecl_audit.ValidationError v
            WHERE v.RUN_ID = @RUN_ID AND v.VALIDATION_CODE = 'CURVE_COVERAGE_MISSING'
              AND v.ACCOUNT_ID = e.ACCOUNT_ID AND v.FORECAST_PERIOD = e.FORECAST_PERIOD
              AND v.ERROR_MESSAGE = CONCAT(N'Missing or inactive ', f.CURVE_FAMILY, N' curve coverage for required forecast period.')
          );

        ;WITH AccountHorizon AS
        (
            SELECT a.ACCOUNT_ID, a.POOL_NAME, a.POOL_ID,
                   CASE
                     WHEN a.MATURITY_DATE <= @PROCESS_DATE THEN 1
                     ELSE CEILING(CONVERT(decimal(10,2),
                       DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE)
                         + CASE WHEN DATEADD(month, DATEDIFF(month, @PROCESS_DATE, a.MATURITY_DATE), @PROCESS_DATE) < a.MATURITY_DATE THEN 1 ELSE 0 END
                     ) / 12.0)
                   END AS HORIZON
            FROM ecl_stg.AccountSnapshot a
            WHERE a.RUN_ID = @RUN_ID AND a.PROCESS_DATE = @PROCESS_DATE
              AND a.IS_ACTIVE = 1 AND ISNULL(a.IS_POCI, 0) = 0
              AND a.MATURITY_DATE >= @PROCESS_DATE
        ),
        Numbers AS
        (
            SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
            FROM sys.all_objects a CROSS JOIN sys.all_objects b
        ),
        ExpectedPeriod AS
        (
            SELECT h.ACCOUNT_ID, h.POOL_NAME, h.POOL_ID, n.N AS FORECAST_PERIOD
            FROM AccountHorizon h JOIN Numbers n ON n.N <= h.HORIZON
        )
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, POOL_NAME, ACCOUNT_ID, POOL_ID, SCENARIO_CODE, FORECAST_PERIOD, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'PD_COVERAGE_MISSING', 'ERROR',
               e.POOL_NAME, e.ACCOUNT_ID, e.POOL_ID, s.SCENARIO_CODE, e.FORECAST_PERIOD,
               N'Missing or inactive PD curve coverage for required account/scenario/forecast period.'
        FROM ExpectedPeriod e
        CROSS JOIN (VALUES ('DOWNTURN'), ('BASE'), ('UPTURN')) s(SCENARIO_CODE)
        WHERE NOT EXISTS
        (
            SELECT 1 FROM ecl_stg.PDCurve p
            WHERE p.RUN_ID = @RUN_ID AND p.ACCOUNT_ID = e.ACCOUNT_ID
              AND p.SCENARIO_CODE = s.SCENARIO_CODE
              AND p.FORECAST_PERIOD = e.FORECAST_PERIOD AND p.IS_ACTIVE = 1
        )
          AND NOT EXISTS
          (
            SELECT 1 FROM ecl_audit.ValidationError v
            WHERE v.RUN_ID = @RUN_ID AND v.VALIDATION_CODE = 'PD_COVERAGE_MISSING'
              AND v.ACCOUNT_ID = e.ACCOUNT_ID AND v.SCENARIO_CODE = s.SCENARIO_CODE
              AND v.FORECAST_PERIOD = e.FORECAST_PERIOD
          );

        IF EXISTS
        (
            SELECT 1
            FROM
            (
                SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                FROM sys.all_objects a CROSS JOIN sys.all_objects b
            ) n
            WHERE n.N <= @MAX_HORIZON
              AND NOT EXISTS
              (SELECT 1 FROM ecl_stg.EIRCurve r
               WHERE r.RUN_ID = @RUN_ID AND r.FORECAST_PERIOD = n.N AND r.IS_ACTIVE = 1)
        )
        BEGIN
            INSERT INTO ecl_audit.ValidationError
                (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, FORECAST_PERIOD, ERROR_MESSAGE)
            SELECT @RUN_ID, @PROCESS_DATE, 'EIR_COVERAGE_MISSING', 'ERROR', n.N,
                   N'Missing or inactive shared EIR curve for required forecast period.'
            FROM
            (
                SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                FROM sys.all_objects a CROSS JOIN sys.all_objects b
            ) n
            WHERE n.N <= @MAX_HORIZON
              AND NOT EXISTS (SELECT 1 FROM ecl_stg.EIRCurve r
                              WHERE r.RUN_ID = @RUN_ID AND r.FORECAST_PERIOD = n.N AND r.IS_ACTIVE = 1)
              AND NOT EXISTS (SELECT 1 FROM ecl_audit.ValidationError v
                              WHERE v.RUN_ID = @RUN_ID AND v.VALIDATION_CODE = 'EIR_COVERAGE_MISSING'
                                AND v.FORECAST_PERIOD = n.N);
        END;
    END;

    IF EXISTS
    (
        SELECT 1 FROM ecl_stg.EIRCurve
        WHERE RUN_ID = @RUN_ID AND IS_ACTIVE = 1 AND EIR <= -1
    )
    BEGIN
        INSERT INTO ecl_audit.ValidationError
            (RUN_ID, PROCESS_DATE, VALIDATION_CODE, SEVERITY, ERROR_MESSAGE)
        SELECT @RUN_ID, @PROCESS_DATE, 'EIR_OUT_OF_RANGE', 'FATAL',
               N'Active EIR values must be greater than -1 for the selected discount-factor convention.'
        WHERE NOT EXISTS
        (
            SELECT 1 FROM ecl_audit.ValidationError
            WHERE RUN_ID = @RUN_ID AND VALIDATION_CODE = 'EIR_OUT_OF_RANGE'
        );
    END;

    SELECT @ERROR_COUNT = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND SEVERITY IN ('ERROR','FATAL');

    SELECT @WARN_COUNT = COUNT(*)
    FROM ecl_audit.ValidationError
    WHERE RUN_ID = @RUN_ID AND SEVERITY = 'WARN';

    INSERT INTO ecl_audit.RunEvent
        (RUN_ID, PROCESS_DATE, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, AMOUNT_VALUE, ACTOR)
    VALUES
        (@RUN_ID, @PROCESS_DATE, 'INPUT_VALIDATION',
         CASE WHEN @ERROR_COUNT > 0 THEN 'FAILED' ELSE 'SUCCEEDED' END,
         CONCAT(N'Input validation completed. ERROR/FATAL=', @ERROR_COUNT, N'; WARN=', @WARN_COUNT,
                N'. No ECL calculation was performed.'),
         @ERROR_COUNT, CONVERT(decimal(28,8), @WARN_COUNT), SUSER_SNAME());

    SELECT @RUN_ID AS RUN_ID,
           CASE WHEN @ERROR_COUNT > 0 THEN 'FAILED' ELSE 'SUCCEEDED' END AS VALIDATION_STATUS,
           @ERROR_COUNT AS ERROR_FATAL_COUNT,
           @WARN_COUNT AS WARN_COUNT;
END;
GO
