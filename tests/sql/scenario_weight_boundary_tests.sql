/* Scenario-weight effective-date and missing-scenario regression tests. SQL Server 2016-compatible. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @D date='20261015', @R1 bigint, @R2 bigint;
DECLARE @V1 int=2147482994, @V2 int=2147482993;
BEGIN TRY
 BEGIN TRANSACTION;
 INSERT ecl_cfg.ScenarioWeightVersion(VERSION_ID,VERSION_NAME,EFFECTIVE_FROM,EFFECTIVE_TO,IS_ACTIVE)
 VALUES(@V1,N'Ineffective boundary',DATEADD(day,1,@D),DATEADD(year,1,@D),1);
 INSERT ecl_cfg.ScenarioWeight(VERSION_ID,SCENARIO_CODE,SCENARIO_WEIGHT,PROCESS_DATE,IS_ACTIVE)
 VALUES(@V1,'DOWNTURN',0.15680000,@D,1),(@V1,'BASE',0.68640000,@D,1),(@V1,'UPTURN',0.15680000,@D,1);
 EXEC ecl_core.usp_CreateRun @PROCESS_DATE=@D,@RUN_TYPE='FULL',@SCENARIO_WEIGHT_VERSION_ID=@V1,@CALCULATION_VERSION='WEIGHT-EFFECTIVITY-TEST',@RUN_ID=@R1 OUTPUT;
 EXEC ecl_core.usp_TransitionRunStatus @RUN_ID=@R1,@NEW_STATUS='VALIDATING',@EVENT_MESSAGE=N'Scenario-weight effective-date boundary';
 EXEC ecl_core.usp_RegisterRunInput @R1,'ACCOUNT','TEST','synthetic.account','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R1,'PD','TEST','synthetic.pd','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R1,'LGD','TEST','synthetic.lgd','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R1,'EAD','TEST','synthetic.ead','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R1,'EIR','TEST','synthetic.eir','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R1,'SCENARIO_WEIGHT','TEST','synthetic.weights','v1',3,1,NULL;
 EXEC ecl_core.usp_SealRunInputs @R1;
 EXEC ecl_core.usp_ValidateRunInputs @R1;
 IF NOT EXISTS(SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID=@R1 AND VALIDATION_CODE='SCENARIO_WEIGHT_VERSION_INEFFECTIVE' AND SEVERITY='FATAL')
  THROW 52001,'An otherwise valid weight set outside its effective date must be rejected.',1;

 INSERT ecl_cfg.ScenarioWeightVersion(VERSION_ID,VERSION_NAME,EFFECTIVE_FROM,EFFECTIVE_TO,IS_ACTIVE)
 VALUES(@V2,N'Missing scenario boundary',DATEADD(year,-1,@D),DATEADD(year,1,@D),1);
 INSERT ecl_cfg.ScenarioWeight(VERSION_ID,SCENARIO_CODE,SCENARIO_WEIGHT,PROCESS_DATE,IS_ACTIVE)
 VALUES(@V2,'DOWNTURN',0.15680000,@D,1),(@V2,'BASE',0.68640000,@D,1);
 EXEC ecl_core.usp_CreateRun @PROCESS_DATE=@D,@RUN_TYPE='FULL',@SCENARIO_WEIGHT_VERSION_ID=@V2,@CALCULATION_VERSION='WEIGHT-MISSING-SCENARIO-TEST',@RUN_ID=@R2 OUTPUT;
 EXEC ecl_core.usp_TransitionRunStatus @RUN_ID=@R2,@NEW_STATUS='VALIDATING',@EVENT_MESSAGE=N'Scenario-weight missing-scenario boundary';
 EXEC ecl_core.usp_RegisterRunInput @R2,'ACCOUNT','TEST','synthetic.account','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R2,'PD','TEST','synthetic.pd','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R2,'LGD','TEST','synthetic.lgd','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R2,'EAD','TEST','synthetic.ead','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R2,'EIR','TEST','synthetic.eir','v1',0,1,NULL;
 EXEC ecl_core.usp_RegisterRunInput @R2,'SCENARIO_WEIGHT','TEST','synthetic.weights','v1',2,1,NULL;
 EXEC ecl_core.usp_SealRunInputs @R2;
 EXEC ecl_core.usp_ValidateRunInputs @R2;
 IF NOT EXISTS(SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID=@R2 AND VALIDATION_CODE='SCENARIO_WEIGHTS_INVALID' AND SEVERITY='FATAL')
  THROW 52002,'A version missing UPTURN must be rejected.',1;
 IF EXISTS(SELECT 1 FROM ecl_result.ECLDetail WHERE RUN_ID IN(@R1,@R2))
    OR EXISTS(SELECT 1 FROM ecl_result.ECLAccount WHERE RUN_ID IN(@R1,@R2))
    OR EXISTS(SELECT 1 FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID IN(@R1,@R2))
  THROW 52003,'Scenario-weight validation failures must not create ECL output.',1;
 ROLLBACK TRANSACTION;
 PRINT 'PASS: scenario-weight effective-date and missing-scenario boundaries; no ECL output.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
