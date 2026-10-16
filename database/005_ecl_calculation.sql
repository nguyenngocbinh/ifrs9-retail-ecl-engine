/*
Migration 005: IFRS 9 Retail ECL calculation v1.
Calculates only from the canonical staged inputs. No source discovery or model building.
All result writes and lifecycle milestones are committed atomically in one transaction.
Deploy after migrations 001..004 in a disposable/dev database first.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'ecl_core.usp_CalculateECL', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_CalculateECL;
GO
CREATE PROCEDURE ecl_core.usp_CalculateECL
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PROCESS_DATE date, @RUN_STATUS varchar(20),
            @WEIGHT_VERSION_ID int, @RUN_TYPE varchar(20),
            @REQUESTED_PRODUCT_TYPE varchar(30), @REQUESTED_POOL_ID varchar(100),
            @DETAIL_COUNT bigint = 0, @ACCOUNT_COUNT bigint = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @PROCESS_DATE = PROCESS_DATE, @RUN_STATUS = RUN_STATUS,
               @WEIGHT_VERSION_ID = SCENARIO_WEIGHT_VERSION_ID,
               @RUN_TYPE = RUN_TYPE,
               @REQUESTED_PRODUCT_TYPE = REQUESTED_PRODUCT_TYPE,
               @REQUESTED_POOL_ID = REQUESTED_POOL_ID
        FROM ecl_core.RunControl WITH (UPDLOCK, HOLDLOCK)
        WHERE RUN_ID = @RUN_ID;

        IF @PROCESS_DATE IS NULL THROW 51510, 'Run does not exist.', 1;
        IF @RUN_STATUS <> 'CALCULATING' THROW 51511, 'ECL calculation requires CALCULATING status.', 1;
        IF NOT EXISTS (SELECT 1 FROM ecl_core.RunInputManifest WHERE RUN_ID=@RUN_ID AND IS_SEALED=1)
            THROW 51512, 'ECL calculation requires a sealed input manifest.', 1;
        IF EXISTS (SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID=@RUN_ID AND SEVERITY IN ('ERROR','FATAL'))
            THROW 51513, 'ECL calculation is blocked by ERROR/FATAL validation findings.', 1;
        IF ISNULL((SELECT TOP (1) EVENT_STATUS FROM ecl_audit.RunEvent
                   WHERE RUN_ID=@RUN_ID AND EVENT_TYPE='INPUT_RECONCILIATION'
                   ORDER BY EVENT_ID DESC),'') <> 'SUCCEEDED'
            THROW 51514, 'The latest input reconciliation must have succeeded before calculation.', 1;
        IF EXISTS (SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID=@RUN_ID)
           OR EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID=@RUN_ID)
           OR EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@RUN_ID)
            THROW 51515, 'This RUN_ID already has calculation output; use a new RUN_ID for reruns.', 1;

        IF NOT EXISTS (
            SELECT 1 FROM ecl_cfg.ScenarioWeightVersion v
            WHERE v.VERSION_ID=@WEIGHT_VERSION_ID
              AND v.EFFECTIVE_FROM<=@PROCESS_DATE
              AND (v.EFFECTIVE_TO IS NULL OR v.EFFECTIVE_TO>=@PROCESS_DATE)
        ) THROW 51516, 'Selected scenario-weight version is not effective for this run.', 1;

        IF (SELECT COUNT(*) FROM ecl_cfg.ScenarioWeight
            WHERE VERSION_ID=@WEIGHT_VERSION_ID AND PROCESS_DATE=@PROCESS_DATE AND IS_ACTIVE=1
              AND SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN')) <> 3
           OR ABS((SELECT SUM(SCENARIO_WEIGHT) FROM ecl_cfg.ScenarioWeight
                   WHERE VERSION_ID=@WEIGHT_VERSION_ID AND PROCESS_DATE=@PROCESS_DATE AND IS_ACTIVE=1
                     AND SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN'))-1.0) > 0.00000001
            THROW 51517, 'Selected scenario weights must contain Downturn/Base/Upturn and sum to one.', 1;

        /* Fail closed on missing, inactive, or incomplete curves even if validation was bypassed. */
        IF EXISTS (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            WHERE a.RUN_ID=@RUN_ID AND a.PROCESS_DATE=@PROCESS_DATE AND a.IS_ACTIVE=1
              AND (@RUN_TYPE='FULL' OR
                   (@REQUESTED_PRODUCT_TYPE IS NULL OR a.PRODUCT_TYPE=@REQUESTED_PRODUCT_TYPE)
                   AND (@REQUESTED_POOL_ID IS NULL OR a.POOL_ID=@REQUESTED_POOL_ID))
              AND (
                a.MATURITY_DATE<=@PROCESS_DATE
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.PDCurve p
                    WHERE p.RUN_ID=a.RUN_ID AND p.ACCOUNT_ID=a.ACCOUNT_ID AND p.IS_ACTIVE=1
                      AND p.PROCESS_DATE=@PROCESS_DATE AND p.SCENARIO_CODE='BASE')
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.LGDCurve l
                    WHERE l.RUN_ID=a.RUN_ID AND l.ACCOUNT_ID=a.ACCOUNT_ID AND l.IS_ACTIVE=1
                      AND l.PROCESS_DATE=@PROCESS_DATE)
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.EADCurve e
                    WHERE e.RUN_ID=a.RUN_ID AND e.ACCOUNT_ID=a.ACCOUNT_ID AND e.IS_ACTIVE=1
                      AND e.PROCESS_DATE=@PROCESS_DATE)
              )
        ) THROW 51518, 'Active in-scope accounts have invalid maturity or missing annual curve coverage.', 1;

        DECLARE @MAX_HORIZON int =
            (SELECT ISNULL(MAX(CEILING(DATEDIFF(month,@PROCESS_DATE,MATURITY_DATE)/12.0)),0)
             FROM ecl_stg.AccountSnapshot a
             WHERE a.RUN_ID=@RUN_ID AND a.PROCESS_DATE=@PROCESS_DATE AND a.IS_ACTIVE=1
               AND (@RUN_TYPE='FULL' OR
                    (@REQUESTED_PRODUCT_TYPE IS NULL OR a.PRODUCT_TYPE=@REQUESTED_PRODUCT_TYPE)
                    AND (@REQUESTED_POOL_ID IS NULL OR a.POOL_ID=@REQUESTED_POOL_ID));

        IF @MAX_HORIZON > 120 THROW 51519, 'Forecast horizon exceeds the supported 120 annual periods.', 1;

        IF EXISTS (
            SELECT 1
            FROM ecl_stg.AccountSnapshot a
            CROSS APPLY (SELECT CEILING(DATEDIFF(month,@PROCESS_DATE,a.MATURITY_DATE)/12.0) AS HORIZON) h
            JOIN (SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                  FROM sys.all_objects x CROSS JOIN sys.all_objects y) n ON n.N<=h.HORIZON
            WHERE a.RUN_ID=@RUN_ID AND a.PROCESS_DATE=@PROCESS_DATE AND a.IS_ACTIVE=1
              AND (@RUN_TYPE='FULL' OR
                   (@REQUESTED_PRODUCT_TYPE IS NULL OR a.PRODUCT_TYPE=@REQUESTED_PRODUCT_TYPE)
                   AND (@REQUESTED_POOL_ID IS NULL OR a.POOL_ID=@REQUESTED_POOL_ID))
              AND (
                NOT EXISTS (SELECT 1 FROM ecl_stg.PDCurve p
                  WHERE p.RUN_ID=a.RUN_ID AND p.ACCOUNT_ID=a.ACCOUNT_ID AND p.FORECAST_PERIOD=n.N
                    AND p.PROCESS_DATE=@PROCESS_DATE AND p.IS_ACTIVE=1
                    AND p.SCENARIO_CODE IN ('DOWNTURN','BASE','UPTURN'))
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.LGDCurve l
                  WHERE l.RUN_ID=a.RUN_ID AND l.ACCOUNT_ID=a.ACCOUNT_ID AND l.FORECAST_PERIOD=n.N
                    AND l.PROCESS_DATE=@PROCESS_DATE AND l.IS_ACTIVE=1)
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.EADCurve e
                  WHERE e.RUN_ID=a.RUN_ID AND e.ACCOUNT_ID=a.ACCOUNT_ID AND e.FORECAST_PERIOD=n.N
                    AND e.PROCESS_DATE=@PROCESS_DATE AND e.IS_ACTIVE=1 AND e.CURRENCY_CODE='VND')
                OR NOT EXISTS (SELECT 1 FROM ecl_stg.EIRCurve r
                  WHERE r.RUN_ID=@RUN_ID AND r.FORECAST_PERIOD=n.N AND r.PROCESS_DATE=@PROCESS_DATE
                    AND r.IS_ACTIVE=1 AND r.EIR>-1)
              )
        ) THROW 51520, 'Required period/scenario PD, LGD, VND EAD, or shared EIR coverage is missing or invalid.', 1;

        CREATE TABLE #Calc (
            ACCOUNT_ID varchar(100) NOT NULL,
            SCENARIO_CODE varchar(20) NOT NULL,
            FORECAST_PERIOD smallint NOT NULL,
            STAGE tinyint NOT NULL,
            PRODUCT_TYPE varchar(30) NOT NULL,
            POOL_ID varchar(100) NOT NULL,
            PD_USED decimal(19,12) NOT NULL,
            LGD_USED decimal(19,12) NOT NULL,
            EAD_USED decimal(19,4) NOT NULL,
            EIR_USED decimal(19,12) NOT NULL,
            DISCOUNT_FACTOR decimal(28,16) NOT NULL,
            SCENARIO_WEIGHT decimal(9,8) NOT NULL,
            ECL_UNWEIGHTED decimal(28,8) NOT NULL,
            ECL_WEIGHTED decimal(28,8) NOT NULL,
            PRIMARY KEY (ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD)
        );

        ;WITH InScope AS (
            SELECT a.RUN_ID,a.PROCESS_DATE,a.ACCOUNT_ID,a.CUSTOMER_ID,a.PRODUCT_TYPE,a.STAGE,a.POOL_ID,a.MATURITY_DATE,
                   CONVERT(int,CEILING(DATEDIFF(month,@PROCESS_DATE,a.MATURITY_DATE)/12.0)) AS HORIZON,
                   DATEDIFF(month,@PROCESS_DATE,a.MATURITY_DATE)/12.0 AS MATURITY_T
            FROM ecl_stg.AccountSnapshot a
            WHERE a.RUN_ID=@RUN_ID AND a.PROCESS_DATE=@PROCESS_DATE AND a.IS_ACTIVE=1
              AND (@RUN_TYPE='FULL' OR
                   (@REQUESTED_PRODUCT_TYPE IS NULL OR a.PRODUCT_TYPE=@REQUESTED_PRODUCT_TYPE)
                   AND (@REQUESTED_POOL_ID IS NULL OR a.POOL_ID=@REQUESTED_POOL_ID))
        ),
        Periods AS (
            SELECT a.*, n.N AS FORECAST_PERIOD,
                   CASE WHEN n.N=a.HORIZON THEN a.MATURITY_T ELSE CONVERT(decimal(19,8),n.N) END AS DISCOUNT_T
            FROM InScope a
            JOIN (SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
                  FROM sys.all_objects x CROSS JOIN sys.all_objects y) n ON n.N<=a.HORIZON
            WHERE a.STAGE IN (2,3) OR n.N=1
        ),
        Inputs AS (
            SELECT p.ACCOUNT_ID,p.STAGE,p.PRODUCT_TYPE,p.POOL_ID,p.FORECAST_PERIOD,p.DISCOUNT_T,
                   s.SCENARIO_CODE,
                   CONVERT(decimal(19,12),CASE WHEN p.STAGE=3 THEN 1 ELSE pd.MARGINAL_PD END) AS PD_USED,
                   lg.LGD AS LGD_USED, ea.EAD AS EAD_USED, ir.EIR AS EIR_USED,
                   sw.SCENARIO_WEIGHT,
                   CONVERT(decimal(28,16),1.0/POWER(1.0+CONVERT(float,ir.EIR),CONVERT(float,p.DISCOUNT_T))) AS DISCOUNT_FACTOR
            FROM Periods p
            CROSS JOIN (VALUES ('DOWNTURN'),('BASE'),('UPTURN')) s(SCENARIO_CODE)
            JOIN ecl_stg.PDCurve pd ON pd.RUN_ID=@RUN_ID AND pd.ACCOUNT_ID=p.ACCOUNT_ID
              AND pd.FORECAST_PERIOD=p.FORECAST_PERIOD AND pd.SCENARIO_CODE=s.SCENARIO_CODE
              AND pd.PROCESS_DATE=@PROCESS_DATE AND pd.IS_ACTIVE=1
            JOIN ecl_stg.LGDCurve lg ON lg.RUN_ID=@RUN_ID AND lg.ACCOUNT_ID=p.ACCOUNT_ID
              AND lg.FORECAST_PERIOD=p.FORECAST_PERIOD AND lg.PROCESS_DATE=@PROCESS_DATE AND lg.IS_ACTIVE=1
            JOIN ecl_stg.EADCurve ea ON ea.RUN_ID=@RUN_ID AND ea.ACCOUNT_ID=p.ACCOUNT_ID
              AND ea.FORECAST_PERIOD=p.FORECAST_PERIOD AND ea.PROCESS_DATE=@PROCESS_DATE
              AND ea.IS_ACTIVE=1 AND ea.CURRENCY_CODE='VND'
            JOIN ecl_stg.EIRCurve ir ON ir.RUN_ID=@RUN_ID AND ir.FORECAST_PERIOD=p.FORECAST_PERIOD
              AND ir.PROCESS_DATE=@PROCESS_DATE AND ir.IS_ACTIVE=1
            JOIN ecl_cfg.ScenarioWeight sw ON sw.VERSION_ID=@WEIGHT_VERSION_ID
              AND sw.PROCESS_DATE=@PROCESS_DATE AND sw.IS_ACTIVE=1 AND sw.SCENARIO_CODE=s.SCENARIO_CODE
        )
        INSERT INTO #Calc
        SELECT ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD,STAGE,PRODUCT_TYPE,POOL_ID,PD_USED,LGD_USED,EAD_USED,EIR_USED,
               DISCOUNT_FACTOR,SCENARIO_WEIGHT,
               CONVERT(decimal(28,8),CONVERT(decimal(38,12),PD_USED)*LGD_USED*EAD_USED*DISCOUNT_FACTOR),
               CONVERT(decimal(28,8),CONVERT(decimal(38,12),PD_USED)*LGD_USED*EAD_USED*DISCOUNT_FACTOR*SCENARIO_WEIGHT)
        FROM Inputs;

        IF NOT EXISTS (SELECT 1 FROM #Calc)
            THROW 51521, 'No in-scope ECL calculation rows were produced.', 1;

        INSERT INTO ecl_result.ECLDetail
            (RUN_ID,PROCESS_DATE,ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD,STAGE,PRODUCT_TYPE,POOL_ID,
             PD_USED,LGD_USED,EAD_USED,EIR_USED,DISCOUNT_FACTOR,SCENARIO_WEIGHT,ECL_UNWEIGHTED,ECL_WEIGHTED)
        SELECT @RUN_ID,@PROCESS_DATE,ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD,STAGE,PRODUCT_TYPE,POOL_ID,
               PD_USED,LGD_USED,EAD_USED,EIR_USED,DISCOUNT_FACTOR,SCENARIO_WEIGHT,ECL_UNWEIGHTED,ECL_WEIGHTED
        FROM #Calc;

        INSERT INTO ecl_result.ECLAccount
            (RUN_ID,PROCESS_DATE,ACCOUNT_ID,CUSTOMER_ID,PRODUCT_TYPE,POOL_ID,STAGE,
             ECL_12_MONTH,ECL_LIFETIME,ECL_DEFAULT,ECL_TOTAL)
        SELECT @RUN_ID,@PROCESS_DATE,a.ACCOUNT_ID,a.CUSTOMER_ID,a.PRODUCT_TYPE,a.POOL_ID,a.STAGE,
               CONVERT(decimal(28,8),CASE WHEN a.STAGE=1 THEN SUM(c.ECL_WEIGHTED) ELSE 0 END),
               CONVERT(decimal(28,8),CASE WHEN a.STAGE=2 THEN SUM(c.ECL_WEIGHTED) ELSE 0 END),
               CONVERT(decimal(28,8),CASE WHEN a.STAGE=3 THEN SUM(c.ECL_WEIGHTED) ELSE 0 END),
               CONVERT(decimal(28,8),SUM(c.ECL_WEIGHTED))
        FROM ecl_stg.AccountSnapshot a
        JOIN #Calc c ON c.ACCOUNT_ID=a.ACCOUNT_ID
        WHERE a.RUN_ID=@RUN_ID
        GROUP BY a.ACCOUNT_ID,a.CUSTOMER_ID,a.PRODUCT_TYPE,a.POOL_ID,a.STAGE;

        /* Pool and product portfolio summaries by stage. */
        INSERT INTO ecl_result.ECLPortfolioSummary
            (RUN_ID,PROCESS_DATE,PRODUCT_TYPE,AGGREGATION_LEVEL,POOL_ID,STAGE,ACCOUNT_COUNT,
             ECL_12_MONTH,ECL_LIFETIME,ECL_DEFAULT,ECL_TOTAL)
        SELECT @RUN_ID,@PROCESS_DATE,a.PRODUCT_TYPE,'POOL',a.POOL_ID,a.STAGE,COUNT_BIG(*),
               SUM(a.ECL_12_MONTH),SUM(a.ECL_LIFETIME),SUM(a.ECL_DEFAULT),SUM(a.ECL_TOTAL)
        FROM ecl_result.ECLAccount a
        WHERE a.RUN_ID=@RUN_ID
        GROUP BY a.PRODUCT_TYPE,a.POOL_ID,a.STAGE;

        INSERT INTO ecl_result.ECLPortfolioSummary
            (RUN_ID,PROCESS_DATE,PRODUCT_TYPE,AGGREGATION_LEVEL,POOL_ID,STAGE,ACCOUNT_COUNT,
             ECL_12_MONTH,ECL_LIFETIME,ECL_DEFAULT,ECL_TOTAL)
        SELECT @RUN_ID,@PROCESS_DATE,a.PRODUCT_TYPE,'PORTFOLIO','__ALL_POOLS__',a.STAGE,COUNT_BIG(*),
               SUM(a.ECL_12_MONTH),SUM(a.ECL_LIFETIME),SUM(a.ECL_DEFAULT),SUM(a.ECL_TOTAL)
        FROM ecl_result.ECLAccount a
        WHERE a.RUN_ID=@RUN_ID
        GROUP BY a.PRODUCT_TYPE,a.STAGE;

        SELECT @DETAIL_COUNT=COUNT_BIG(*) FROM ecl_result.ECLDetail WHERE RUN_ID=@RUN_ID;
        SELECT @ACCOUNT_COUNT=COUNT_BIG(*) FROM ecl_result.ECLAccount WHERE RUN_ID=@RUN_ID;

        EXEC ecl_core.usp_RecordRunMilestone
            @RUN_ID=@RUN_ID,@MILESTONE='RECONCILIATION',@MILESTONE_STATUS='SUCCEEDED',
            @EVENT_MESSAGE=N'Calculation outputs reconciled within one transaction.',
            @ROW_COUNT=@DETAIL_COUNT;

        EXEC ecl_core.usp_TransitionRunStatus
            @RUN_ID=@RUN_ID,@NEW_STATUS='SUCCEEDED',
            @EVENT_MESSAGE=N'Calculation and output writes completed atomically.';

        INSERT INTO ecl_audit.RunEvent
            (RUN_ID,PROCESS_DATE,EVENT_TYPE,EVENT_STATUS,EVENT_MESSAGE,ROW_COUNT,ACTOR)
        VALUES (@RUN_ID,@PROCESS_DATE,'ECL_CALCULATION','SUCCEEDED',
                N'Calculated account/scenario/period ECL; final published amount is rounded to whole VND at publication boundary.',
                @DETAIL_COUNT,SUSER_SNAME());

        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID,'SUCCEEDED' AS CALCULATION_STATUS,
               @ACCOUNT_COUNT AS ACCOUNT_COUNT,@DETAIL_COUNT AS DETAIL_ROW_COUNT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

IF OBJECT_ID(N'ecl_core.usp_PublishECL', N'P') IS NOT NULL
    DROP PROCEDURE ecl_core.usp_PublishECL;
GO
CREATE PROCEDURE ecl_core.usp_PublishECL
    @RUN_ID bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @PROCESS_DATE date,@STATUS varchar(20),@ROW_COUNT bigint;

    BEGIN TRY
        BEGIN TRANSACTION;
        SELECT @PROCESS_DATE=PROCESS_DATE,@STATUS=RUN_STATUS
        FROM ecl_core.RunControl WITH (UPDLOCK,HOLDLOCK) WHERE RUN_ID=@RUN_ID;
        IF @PROCESS_DATE IS NULL THROW 51530,'Run does not exist.',1;
        IF @STATUS<>'SUCCEEDED' THROW 51531,'Only a SUCCEEDED run can be published.',1;
        IF NOT EXISTS (SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID=@RUN_ID)
           OR NOT EXISTS (SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@RUN_ID)
            THROW 51532,'Account and summary outputs must exist before publication.',1;

        /* Publication boundary rounds monetary amounts to whole VND. */
        UPDATE ecl_result.ECLAccount
        SET ECL_12_MONTH=ROUND(ECL_12_MONTH,0),
            ECL_LIFETIME=ROUND(ECL_LIFETIME,0),
            ECL_DEFAULT=ROUND(ECL_DEFAULT,0),
            ECL_TOTAL=ROUND(ECL_TOTAL,0)
        WHERE RUN_ID=@RUN_ID;
        UPDATE ecl_result.ECLPortfolioSummary
        SET ECL_12_MONTH=ROUND(ECL_12_MONTH,0),
            ECL_LIFETIME=ROUND(ECL_LIFETIME,0),
            ECL_DEFAULT=ROUND(ECL_DEFAULT,0),
            ECL_TOTAL=ROUND(ECL_TOTAL,0)
        WHERE RUN_ID=@RUN_ID;

        SELECT @ROW_COUNT=COUNT_BIG(*) FROM ecl_result.ECLAccount WHERE RUN_ID=@RUN_ID;
        EXEC ecl_core.usp_RecordRunMilestone
            @RUN_ID=@RUN_ID,@MILESTONE='PUBLICATION',@MILESTONE_STATUS='SUCCEEDED',
            @EVENT_MESSAGE=N'Account and aggregate ECL outputs rounded to whole VND and published atomically.',
            @ROW_COUNT=@ROW_COUNT;
        EXEC ecl_core.usp_TransitionRunStatus
            @RUN_ID=@RUN_ID,@NEW_STATUS='PUBLISHED',
            @EVENT_MESSAGE=N'Account and portfolio outputs published.';
        COMMIT TRANSACTION;

        SELECT @RUN_ID AS RUN_ID,'PUBLISHED' AS PUBLICATION_STATUS,@ROW_COUNT AS ACCOUNT_COUNT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
