/*
Fault-injection regression for atomic ECL calculation writes.
Prerequisite: migrations 001..005 deployed to a disposable SQL Server 2022 database.
A test-only trigger fails after ECLDetail has been inserted and while ECLAccount is
being inserted. The procedure must roll back all output writes and leave the run in
CALCULATING state without successful calculation/reconciliation milestones.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @D date='20261016', @W int=2147482991, @R bigint;
DECLARE @CAUGHT_ERROR int=NULL, @STATUS varchar(20);
DECLARE @DETAIL_COUNT bigint, @ACCOUNT_COUNT bigint, @SUMMARY_COUNT bigint;
DECLARE @CALC_SUCCESS_COUNT bigint, @RECON_SUCCESS_COUNT bigint;

BEGIN TRY
    /* Keep setup committed so the test can inspect the run after the procedure
       rolls back its own transaction. All identifiers and data are synthetic. */
    INSERT INTO ecl_cfg.ScenarioWeightVersion
        (VERSION_ID,VERSION_NAME,EFFECTIVE_FROM,EFFECTIVE_TO,IS_ACTIVE)
    VALUES(@W,N'Fault injection rollback test',@D,@D,0);

    INSERT INTO ecl_cfg.ScenarioWeight
        (VERSION_ID,SCENARIO_CODE,SCENARIO_WEIGHT,IS_ACTIVE)
    VALUES(@W,'DOWNTURN',0.1568,1),(@W,'BASE',0.6864,1),(@W,'UPTURN',0.1568,1);

    EXEC ecl_core.usp_CreateRun
        @PROCESS_DATE=@D,@RUN_TYPE='FULL',
        @SCENARIO_WEIGHT_VERSION_ID=@W,
        @CALCULATION_VERSION='ECL-ROLLBACK-TEST',
        @RUN_ID=@R OUTPUT;

    EXEC ecl_core.usp_TransitionRunStatus @R,'VALIDATING',N'Synthetic rollback fault-injection test';

    INSERT INTO ecl_stg.AccountSnapshot
        (RUN_ID,PROCESS_DATE,ACCOUNT_ID,CUSTOMER_ID,POOL_NAME,STAGE,POOL_ID,
         MATURITY_DATE,VERSION_ID,IS_ACTIVE,IS_POCI)
    VALUES(@R,@D,'SYN-ROLLBACK-001','SYN-CUST-ROLLBACK-001','RETAIL_LN_MORTGAGE',2,
           'POOL-ROLLBACK','20280416',1,1,0);

    INSERT INTO ecl_stg.PDCurve
        (RUN_ID,PROCESS_DATE,ACCOUNT_ID,SCENARIO_CODE,FORECAST_PERIOD,MARGINAL_PD,VERSION_ID,IS_ACTIVE)
    VALUES
        (@R,@D,'SYN-ROLLBACK-001','DOWNTURN',1,0.03,1,1),
        (@R,@D,'SYN-ROLLBACK-001','BASE',1,0.02,1,1),
        (@R,@D,'SYN-ROLLBACK-001','UPTURN',1,0.01,1,1),
        (@R,@D,'SYN-ROLLBACK-001','DOWNTURN',2,0.03,1,1),
        (@R,@D,'SYN-ROLLBACK-001','BASE',2,0.02,1,1),
        (@R,@D,'SYN-ROLLBACK-001','UPTURN',2,0.01,1,1);

    INSERT INTO ecl_stg.LGDCurve
        (RUN_ID,PROCESS_DATE,ACCOUNT_ID,FORECAST_PERIOD,LGD,VERSION_ID,IS_ACTIVE)
    VALUES(@R,@D,'SYN-ROLLBACK-001',1,0.4,1,1),
          (@R,@D,'SYN-ROLLBACK-001',2,0.4,1,1);

    INSERT INTO ecl_stg.EADCurve
        (RUN_ID,PROCESS_DATE,ACCOUNT_ID,FORECAST_PERIOD,EAD,CURRENCY_CODE,VERSION_ID,IS_ACTIVE)
    VALUES(@R,@D,'SYN-ROLLBACK-001',1,100000000,'VND',1,1),
          (@R,@D,'SYN-ROLLBACK-001',2,80000000,'VND',1,1);

    INSERT INTO ecl_stg.EIRCurve
        (RUN_ID,PROCESS_DATE,FORECAST_PERIOD,EIR,RATE_BASIS,VERSION_ID,IS_ACTIVE)
    VALUES(@R,@D,1,0.05,'OTHER',1,1),(@R,@D,2,0.05,'OTHER',1,1);

    EXEC ecl_core.usp_RegisterRunInput @R,'ACCOUNT','TEST','synthetic.rollback.account','v1',1,1,NULL;
    EXEC ecl_core.usp_RegisterRunInput @R,'PD','TEST','synthetic.rollback.pd','v1',6,1,NULL;
    EXEC ecl_core.usp_RegisterRunInput @R,'LGD','TEST','synthetic.rollback.lgd','v1',2,1,NULL;
    EXEC ecl_core.usp_RegisterRunInput @R,'EAD','TEST','synthetic.rollback.ead','v1',2,1,NULL;
    EXEC ecl_core.usp_RegisterRunInput @R,'EIR','TEST','synthetic.rollback.eir','v1',2,1,NULL;
    EXEC ecl_core.usp_RegisterRunInput @R,'SCENARIO_WEIGHT','TEST','synthetic.rollback.weights','v1',3,1,NULL;
    EXEC ecl_core.usp_SealRunInputs @R;
    EXEC ecl_core.usp_ValidateRunInputs @R;

    IF EXISTS(SELECT 1 FROM ecl_audit.ValidationError WHERE RUN_ID=@R AND SEVERITY IN('ERROR','FATAL'))
        THROW 52601,'Fault-injection fixture did not pass input validation.',1;

    EXEC ecl_core.usp_ReconcileInputSnapshots @R;
    IF ISNULL((SELECT TOP(1) EVENT_STATUS FROM ecl_audit.RunEvent
               WHERE RUN_ID=@R AND EVENT_TYPE='INPUT_RECONCILIATION' ORDER BY EVENT_ID DESC),'')<>'SUCCEEDED'
        THROW 52602,'Fault-injection fixture did not reconcile successfully.',1;

    EXEC ecl_core.usp_TransitionRunStatus @R,'CALCULATING',N'Inject failure during account result write';

    /* The trigger is scoped to this test's synthetic account prefix only. It fires
       after detail rows have been inserted, forcing the procedure's CATCH to roll
       back all calculation writes made earlier in the transaction. */
    IF OBJECT_ID(N'ecl_result.trg_TestECLAccount_FaultInjection','TR') IS NOT NULL
        DROP TRIGGER ecl_result.trg_TestECLAccount_FaultInjection;

    EXEC(N'CREATE TRIGGER ecl_result.trg_TestECLAccount_FaultInjection
          ON ecl_result.ECLAccount
          AFTER INSERT
          AS
          BEGIN
              SET NOCOUNT ON;
              IF EXISTS (SELECT 1 FROM inserted WHERE ACCOUNT_ID LIKE ''SYN-ROLLBACK-%'')
                  THROW 52600, ''Intentional test fault after detail output insert.'', 1;
          END;');

    BEGIN TRY
        EXEC ecl_core.usp_CalculateECL @R;
        THROW 52603,'Expected injected calculation failure did not occur.',1;
    END TRY
    BEGIN CATCH
        SET @CAUGHT_ERROR=ERROR_NUMBER();
    END CATCH;

    IF OBJECT_ID(N'ecl_result.trg_TestECLAccount_FaultInjection','TR') IS NOT NULL
        DROP TRIGGER ecl_result.trg_TestECLAccount_FaultInjection;

    IF @CAUGHT_ERROR<>52600
        THROW 52604,'Calculation did not propagate the expected fault-injection error.',1;

    SELECT @DETAIL_COUNT=COUNT_BIG(*) FROM ecl_result.ECLDetail WHERE RUN_ID=@R;
    SELECT @ACCOUNT_COUNT=COUNT_BIG(*) FROM ecl_result.ECLAccount WHERE RUN_ID=@R;
    SELECT @SUMMARY_COUNT=COUNT_BIG(*) FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@R;
    SELECT @STATUS=RUN_STATUS FROM ecl_core.RunControl WHERE RUN_ID=@R;

    IF @DETAIL_COUNT<>0 OR @ACCOUNT_COUNT<>0 OR @SUMMARY_COUNT<>0
        THROW 52605,'Atomic rollback failed: partial ECL output rows remain after injected failure.',1;
    IF @STATUS<>'CALCULATING'
        THROW 52606,'Failed calculation must not transition the run out of CALCULATING.',1;

    SELECT @CALC_SUCCESS_COUNT=COUNT_BIG(*) FROM ecl_audit.RunEvent
    WHERE RUN_ID=@R AND EVENT_TYPE='ECL_CALCULATION' AND EVENT_STATUS='SUCCEEDED';
    SELECT @RECON_SUCCESS_COUNT=COUNT_BIG(*) FROM ecl_audit.RunEvent
    WHERE RUN_ID=@R AND EVENT_TYPE='RECONCILIATION' AND EVENT_STATUS='SUCCEEDED';

    IF @CALC_SUCCESS_COUNT<>0 OR @RECON_SUCCESS_COUNT<>0
        THROW 52607,'Failed calculation must not persist successful calculation/reconciliation milestones.',1;

    /* Cleanup committed fixture data in FK-safe order. */
    DELETE FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@R;
    DELETE FROM ecl_result.ECLAccount WHERE RUN_ID=@R;
    DELETE FROM ecl_result.ECLDetail WHERE RUN_ID=@R;
    DELETE FROM ecl_stg.PDCurve WHERE RUN_ID=@R;
    DELETE FROM ecl_stg.LGDCurve WHERE RUN_ID=@R;
    DELETE FROM ecl_stg.EADCurve WHERE RUN_ID=@R;
    DELETE FROM ecl_stg.EIRCurve WHERE RUN_ID=@R;
    DELETE FROM ecl_stg.AccountSnapshot WHERE RUN_ID=@R;
    DISABLE TRIGGER ecl_core.trg_RunInputManifestItem_Sealed ON ecl_core.RunInputManifestItem;
    DELETE FROM ecl_core.RunInputManifestItem WHERE RUN_ID=@R;
    DELETE FROM ecl_core.RunInputManifest WHERE RUN_ID=@R;
    ENABLE TRIGGER ecl_core.trg_RunInputManifestItem_Sealed ON ecl_core.RunInputManifestItem;
    DELETE FROM ecl_audit.ValidationError WHERE RUN_ID=@R;
    DELETE FROM ecl_audit.RunEvent WHERE RUN_ID=@R;
    DELETE FROM ecl_core.RunControl WHERE RUN_ID=@R;
    DELETE FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID=@W;
    DELETE FROM ecl_cfg.ScenarioWeightVersion WHERE VERSION_ID=@W;

    PRINT 'PASS: injected mid-write failure rolls back all ECL outputs and success milestones; run remains CALCULATING.';
END TRY
BEGIN CATCH
    IF OBJECT_ID(N'ecl_result.trg_TestECLAccount_FaultInjection','TR') IS NOT NULL
        DROP TRIGGER ecl_result.trg_TestECLAccount_FaultInjection;

    /* Best-effort cleanup if fixture setup or assertions fail. */
    IF @R IS NOT NULL
    BEGIN
        DELETE FROM ecl_result.ECLPortfolioSummary WHERE RUN_ID=@R;
        DELETE FROM ecl_result.ECLAccount WHERE RUN_ID=@R;
        DELETE FROM ecl_result.ECLDetail WHERE RUN_ID=@R;
        DELETE FROM ecl_stg.PDCurve WHERE RUN_ID=@R;
        DELETE FROM ecl_stg.LGDCurve WHERE RUN_ID=@R;
        DELETE FROM ecl_stg.EADCurve WHERE RUN_ID=@R;
        DELETE FROM ecl_stg.EIRCurve WHERE RUN_ID=@R;
        DELETE FROM ecl_stg.AccountSnapshot WHERE RUN_ID=@R;
        DISABLE TRIGGER ecl_core.trg_RunInputManifestItem_Sealed ON ecl_core.RunInputManifestItem;
        DELETE FROM ecl_core.RunInputManifestItem WHERE RUN_ID=@R;
        DELETE FROM ecl_core.RunInputManifest WHERE RUN_ID=@R;
        ENABLE TRIGGER ecl_core.trg_RunInputManifestItem_Sealed ON ecl_core.RunInputManifestItem;
        DELETE FROM ecl_audit.ValidationError WHERE RUN_ID=@R;
        DELETE FROM ecl_audit.RunEvent WHERE RUN_ID=@R;
        DELETE FROM ecl_core.RunControl WHERE RUN_ID=@R;
    END;
    DELETE FROM ecl_cfg.ScenarioWeight WHERE VERSION_ID=@W;
    DELETE FROM ecl_cfg.ScenarioWeightVersion WHERE VERSION_ID=@W;
    THROW;
END CATCH;
