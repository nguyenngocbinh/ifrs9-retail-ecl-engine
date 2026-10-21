/*
Synthetic end-to-end regression for IFRS 9 ECL calculation v1.
Prerequisite: migrations 001..005 deployed to a disposable SQL Server 2022 database.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @D date='20261016', @W int=2147482990, @R bigint, @ERR int, @STATUS varchar(20);
DECLARE @ST1 decimal(28,8), @ST2 decimal(28,8), @ST3 decimal(28,8), @DF decimal(28,16);
DECLARE @EXPECTED1 float, @EXPECTED2 float, @EXPECTED3 float;

BEGIN TRY
 BEGIN TRANSACTION;
 INSERT INTO ecl_cfg.ScenarioWeightVersion(VERSION_ID,VERSION_NAME,EFFECTIVE_FROM,EFFECTIVE_TO,IS_ACTIVE)
 VALUES(@W,N'Calculation synthetic regression',@D,@D,0);
 INSERT INTO ecl_cfg.ScenarioWeight(VERSION_ID,SCENARIO_CODE,SCENARIO_WEIGHT,PROCESS_DATE,IS_ACTIVE)
 VALUES(@W,'DOWNTURN',0.1568,@D,1),(@W,'BASE',0.6864,@D,1),(@W,'UPTURN',0.1568,@D,1);

 EXEC ecl_core.usp_CreateRun @PROCESS_DATE=@D,@RUN_TYPE='FULL',
   @SCENARIO_WEIGHT_VERSION_ID=@W,@CALCULATION_VERSION='ECL-CALC-TEST',@RUN_ID=@R OUTPUT;
 EXEC ecl_core.usp_TransitionRunStatus @R,'VALIDATING',N'Synthetic ECL formula regression';

 INSERT INTO ecl_stg.AccountSnapshot
  (RUN_ID,PROCESS_DATE,ACCOUNT_ID,CUSTOMER_ID,POOL_NAME,STAGE,POOL_ID,MATURITY_DATE,VERSION_ID,IS_ACTIVE,IS_POCI)
 VALUES(@R,@D,'SYN-CALC-S1','SYN-CUST-S1','RETAIL_LN_MORTGAGE',1,'POOL-CALC','20271016',1,1,0),
       (@R,@D,'SYN-CALC-S2','SYN-CUST-S2','RETAIL_LN_AUTO',2,'POOL-CALC','20280416',1,1,0),
       (@R,@D,'SYN-CALC-S3','SYN-CUST-S3','RETAIL_CARD',3,'POOL-CALC','20280416',1,1,0);

 INSERT INTO ecl_stg.PDCurve(RUN_ID,PROCESS_DATE,ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD,MARGINAL_PD,VERSION_ID,IS_ACTIVE)
 SELECT @R,@D,a.ACCOUNT_ID,s.SCENARIO_CODE,p.N,
        CASE s.SCENARIO_CODE WHEN 'DOWNTURN' THEN 0.03 WHEN 'BASE' THEN 0.02 ELSE 0.01 END,1,1
 FROM (VALUES('SYN-CALC-S1'),('SYN-CALC-S2'),('SYN-CALC-S3')) a(ACCOUNT_ID)
 CROSS JOIN (VALUES('DOWNTURN'),('BASE'),('UPTURN')) s(SCENARIO_CODE)
 CROSS JOIN (VALUES(1),(2)) p(N);

 INSERT INTO ecl_stg.LGDCurve(RUN_ID,PROCESS_DATE,ACCOUNT_ID,FORECAST_PERIOD,LGD,VERSION_ID,IS_ACTIVE)
 SELECT @R,@D,ACCOUNT_ID,p.N,0.4,1,1
 FROM (VALUES('SYN-CALC-S1'),('SYN-CALC-S2'),('SYN-CALC-S3')) a(ACCOUNT_ID)
 CROSS JOIN (VALUES(1),(2)) p(N);

 INSERT INTO ecl_stg.EADCurve(RUN_ID,PROCESS_DATE,ACCOUNT_ID,FORECAST_PERIOD,EAD,CURRENCY_CODE,VERSION_ID,IS_ACTIVE)
 SELECT @R,@D,ACCOUNT_ID,p.N,
        CASE WHEN p.N=1 THEN 100000000 ELSE 80000000 END,'VND',1,1
 FROM (VALUES('SYN-CALC-S1'),('SYN-CALC-S2'),('SYN-CALC-S3')) a(ACCOUNT_ID)
 CROSS JOIN (VALUES(1),(2)) p(N);

 INSERT INTO ecl_stg.EIRCurve(RUN_ID,PROCESS_DATE,FORECAST_PERIOD,EIR,RATE_BASIS,VERSION_ID,IS_ACTIVE)
 VALUES(@R,@D,1,0.05,'OTHER',1,1),(@R,@D,2,0.05,'OTHER',1,1);

 EXEC ecl_core.usp_RegisterRunInput @R,'ACCOUNT','TEST','synthetic.account','v1',3,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R,'PD','TEST','synthetic.pd','v1',18,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R,'LGD','TEST','synthetic.lgd','v1',6,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R,'EAD','TEST','synthetic.ead','v1',6,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R,'EIR','TEST','synthetic.eir','v1',2,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R,'SCENARIO_WEIGHT','TEST','synthetic.weights','v1',3,1,NULL;
 EXEC ecl_core.usp_SealRunInputs @R;
 EXEC ecl_core.usp_ValidateRunInputs @R;

 IF EXISTS(SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID=@R AND SEVERITY IN('ERROR','FATAL'))
   THROW 52500,'Synthetic calculation fixture failed input validation.',1;

 EXEC ecl_core.usp_ReconcileInputSnapshots @R;
 IF ISNULL((SELECT TOP(1) EVENT_STATUS FROM ecl_audit.RunEvent
            WHERE RUN_ID=@R AND EVENT_TYPE='INPUT_RECONCILIATION' ORDER BY EVENT_ID DESC),'')<>'SUCCEEDED'
   THROW 52501,'Synthetic calculation fixture failed input reconciliation.',1;

 EXEC ecl_core.usp_TransitionRunStatus @R,'CALCULATING',N'Begin synthetic ECL calculation';
 EXEC ecl_core.usp_CalculateECL @R;

 SELECT @STATUS=RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID=@R;
 IF @STATUS<>'SUCCEEDED' THROW 52502,'Calculation must finish in SUCCEEDED status.',1;

 /* Weighted PD is exactly 2%; annual PD/EAD are not prorated for the 18-month maturity. */
 SET @EXPECTED1=100000000.0*0.4*0.02/1.05;
 SET @EXPECTED2=@EXPECTED1+(80000000.0*0.4*0.02/POWER(CONVERT(float,1.05),1.5));
 SET @EXPECTED3=(100000000.0*0.4/1.05)+(80000000.0*0.4/POWER(CONVERT(float,1.05),1.5));

 SELECT @ST1=ECL_12_MONTH FROM ecl_result.ECLAccount WHERE RUN_ID=@R AND ACCOUNT_ID='SYN-CALC-S1';
 SELECT @ST2=ECL_LIFETIME FROM ecl_result.ECLAccount WHERE RUN_ID=@R AND ACCOUNT_ID='SYN-CALC-S2';
 SELECT @ST3=ECL_DEFAULT FROM ecl_result.ECLAccount WHERE RUN_ID=@R AND ACCOUNT_ID='SYN-CALC-S3';
 IF ABS(CONVERT(float,@ST1)-@EXPECTED1)>2 THROW 52503,'Stage 1 weighted 12-month ECL formula mismatch.',1;
 IF ABS(CONVERT(float,@ST2)-@EXPECTED2)>2
   THROW 52504,'Stage 2 lifetime ECL or fractional final discount time mismatch.',1;
 IF ABS(CONVERT(float,@ST3)-@EXPECTED3)>2 THROW 52505,'Stage 3 must use PD=1 and Stage 2 EAD/LGD/EIR discount logic.',1;

 SELECT @DF=DISCOUNT_FACTOR FROM ecl_result.ECLDetail
 WHERE RUN_ID=@R AND ACCOUNT_ID='SYN-CALC-S2' AND SCENARIO_CODE='BASE' AND FORECAST_PERIOD=2;
 IF ABS(CONVERT(float,@DF)-1.0/POWER(CONVERT(float,1.05),1.5))>0.0000000001
   THROW 52506,'Partial final period must change only the discount exponent to 1.5.',1;
 IF EXISTS(SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID=@R AND ACCOUNT_ID='SYN-CALC-S3' AND PD_USED<>1)
   THROW 52507,'Stage 3 PD_USED must be 1 in every scenario and forecast period.',1;

 /* Same RUN_ID must not be calculated twice; rejected retry leaves output unchanged. */
 SET @ERR=NULL;
 EXEC @ERR=ecl_core.usp_CalculateECL @R;
 IF @ERR<>51515 THROW 52508,'Calculation retry on completed RUN_ID should return rejection status 51515.',1;
 IF XACT_STATE()<>1 THROW 52509,'Rejected calculation retry must leave the caller transaction committable.',1;
 IF (SELECT COUNT(*) FROM ecl_result.ECLDetail WHERE RUN_ID=@R)<>15
   THROW 52513,'Rejected calculation retry changed detail output.',1;

 EXEC ecl_core.usp_PublishECL @R;
 SELECT @STATUS=RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID=@R;
 IF @STATUS<>'PUBLISHED' THROW 52510,'Publication must finish in PUBLISHED status.',1;
 IF NOT EXISTS(SELECT 1 FROM ecl_result.ECLPortfolioSummary
             WHERE RUN_ID=@R AND POOL_NAME='RETAIL_LN_MORTGAGE'
               AND AGGREGATION_LEVEL='POOL' AND POOL_ID='POOL-CALC')
   THROW 52514,'Pool-level summary must retain the canonical POOL_NAME.',1;
 IF NOT EXISTS(SELECT 1 FROM ecl_result.ECLPortfolioSummary
             WHERE RUN_ID=@R AND POOL_NAME='__ALL_POOLS__'
               AND AGGREGATION_LEVEL='PORTFOLIO' AND POOL_ID='__ALL_POOLS__')
   THROW 52515,'Portfolio-wide summary must use the all-pools sentinel for POOL_NAME and POOL_ID.',1;
 IF EXISTS(SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID=@R
           AND (ECL_TOTAL<>ROUND(ECL_TOTAL,0) OR ECL_12_MONTH<>ROUND(ECL_12_MONTH,0)
                OR ECL_LIFETIME<>ROUND(ECL_LIFETIME,0) OR ECL_DEFAULT<>ROUND(ECL_DEFAULT,0)))
   THROW 52511,'Published account-level ECL must be rounded to whole VND.',1;
 IF EXISTS(SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@R
           AND (ECL_TOTAL<>ROUND(ECL_TOTAL,0) OR ECL_12_MONTH<>ROUND(ECL_12_MONTH,0)
                OR ECL_LIFETIME<>ROUND(ECL_LIFETIME,0) OR ECL_DEFAULT<>ROUND(ECL_DEFAULT,0)))
   THROW 52512,'Published aggregate ECL must be rounded to whole VND.',1;

 ROLLBACK TRANSACTION;
 PRINT 'PASS: Stage 1/2/3 formulas, scenario weighting, fractional discount exponent, rerun rejection, atomic output lifecycle and VND publication rounding.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
