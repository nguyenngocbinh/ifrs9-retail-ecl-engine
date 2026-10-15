/*
IFRS 9 Retail ECL Engine — logical schema proposal v1.0
Target: SQL Server 2016
Scope: DDL foundation only. No ECL calculation procedures.
Review required before production deployment:
- PD grain approved: account/scenario/forecast period.
- LGD grain approved: account/forecast period.
- EAD grain approved: account/forecast period.
- EIR remains shared by forecast period; selected discount factor is DF(t) = 1 / (1 + EIR(t))^t, with t as forecast year.
- Lifetime horizon ends at each account's MATURITY_DATE.
- Scenario weights are user-confirmed: Downturn=15.68%, Base=68.64%, Upturn=15.68%; store them in immutable versioned configuration with VERSION_ID, PROCESS_DATE, effective dates and audit history. Official external source/provenance will be added later.
- Scenario-weighted ECL = ECL_DOWNTURN * 0.1568 + ECL_BASE * 0.6864 + ECL_UPTURN * 0.1568.
- Currency/reporting unit is VND; retain calculation precision internally and round final published ECL to the nearest whole VND.
- Lifetime horizon ends at maturity; for a partial final forecast year, FINAL_PERIOD_FRACTION = remaining months / 12. Detailed treatment of this fraction in each curve component must be specified before calculation SQL.
- POCI is out of v1 scope. If detected, record a configured validation finding; never silently calculate it as a regular account. Regardless of WARN vs ERROR/FATAL severity, exclude POCI from ordinary ECL calculation. ERROR/FATAL blocks the run; WARN may permit the run to continue only with the POCI account excluded and reconciled.
- Stage 3 uses PD=1 and the same annual EAD/LGD curves as Stage 2; calculate annual losses, discount by EIR, then aggregate. Calculation procedures are not included.
- Execute in a disposable database first; this script creates schemas/tables/indexes.
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'ecl_cfg') IS NULL EXEC(N'CREATE SCHEMA ecl_cfg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ecl_stg') IS NULL EXEC(N'CREATE SCHEMA ecl_stg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ecl_core') IS NULL EXEC(N'CREATE SCHEMA ecl_core AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ecl_result') IS NULL EXEC(N'CREATE SCHEMA ecl_result AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ecl_audit') IS NULL EXEC(N'CREATE SCHEMA ecl_audit AUTHORIZATION dbo;');
GO

CREATE TABLE ecl_cfg.ProductType (
    PRODUCT_TYPE varchar(30) NOT NULL,
    PRODUCT_NAME nvarchar(100) NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_ProductType_IsActive DEFAULT (1),
    CONSTRAINT PK_ProductType PRIMARY KEY CLUSTERED (PRODUCT_TYPE),
    CONSTRAINT UQ_ProductType_Name UNIQUE (PRODUCT_NAME)
);
GO

CREATE TABLE ecl_cfg.Scenario (
    SCENARIO_CODE varchar(20) NOT NULL,
    SCENARIO_NAME nvarchar(100) NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_Scenario_IsActive DEFAULT (1),
    CONSTRAINT PK_Scenario PRIMARY KEY CLUSTERED (SCENARIO_CODE),
    CONSTRAINT UQ_Scenario_Name UNIQUE (SCENARIO_NAME)
);
GO

CREATE TABLE ecl_cfg.ScenarioWeightVersion (
    VERSION_ID int NOT NULL,
    VERSION_NAME nvarchar(100) NOT NULL,
    EFFECTIVE_FROM date NOT NULL,
    EFFECTIVE_TO date NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_ScenarioWeightVersion_IsActive DEFAULT (0),
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_ScenarioWeightVersion_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CREATED_BY sysname NOT NULL CONSTRAINT DF_ScenarioWeightVersion_CreatedBy DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_ScenarioWeightVersion PRIMARY KEY CLUSTERED (VERSION_ID),
    CONSTRAINT CK_ScenarioWeightVersion_Dates CHECK (EFFECTIVE_TO IS NULL OR EFFECTIVE_TO >= EFFECTIVE_FROM)
);
GO

CREATE TABLE ecl_cfg.ScenarioWeight (
    VERSION_ID int NOT NULL,
    SCENARIO_CODE varchar(20) NOT NULL,
    SCENARIO_WEIGHT decimal(9,8) NOT NULL,
    PROCESS_DATE date NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_ScenarioWeight_IsActive DEFAULT (1),
    CONSTRAINT PK_ScenarioWeight PRIMARY KEY CLUSTERED (VERSION_ID, SCENARIO_CODE),
    CONSTRAINT FK_ScenarioWeight_Version FOREIGN KEY (VERSION_ID) REFERENCES ecl_cfg.ScenarioWeightVersion(VERSION_ID),
    CONSTRAINT FK_ScenarioWeight_Scenario FOREIGN KEY (SCENARIO_CODE) REFERENCES ecl_cfg.Scenario(SCENARIO_CODE),
    CONSTRAINT CK_ScenarioWeight_Range CHECK (SCENARIO_WEIGHT >= 0 AND SCENARIO_WEIGHT <= 1)
);
GO
CREATE INDEX IX_ScenarioWeight_ProcessDate_Active
    ON ecl_cfg.ScenarioWeight (PROCESS_DATE, IS_ACTIVE, VERSION_ID)
    INCLUDE (SCENARIO_CODE, SCENARIO_WEIGHT);
GO

CREATE TABLE ecl_core.RunControl (
    RUN_ID bigint IDENTITY(1,1) NOT NULL,
    PROCESS_DATE date NOT NULL,
    RUN_TYPE varchar(20) NOT NULL,
    RUN_STATUS varchar(20) NOT NULL,
    SCENARIO_WEIGHT_VERSION_ID int NOT NULL,
    REQUESTED_PRODUCT_TYPE varchar(30) NULL,
    REQUESTED_POOL_ID varchar(100) NULL,
    CALCULATION_VERSION varchar(30) NOT NULL,
    STARTED_AT datetime2(0) NOT NULL CONSTRAINT DF_RunControl_StartedAt DEFAULT (SYSUTCDATETIME()),
    FINISHED_AT datetime2(0) NULL,
    REQUESTED_BY sysname NOT NULL CONSTRAINT DF_RunControl_RequestedBy DEFAULT (SUSER_SNAME()),
    RUN_NOTE nvarchar(1000) NULL,
    ROW_VERSION rowversion NOT NULL,
    CONSTRAINT PK_RunControl PRIMARY KEY CLUSTERED (RUN_ID),
    CONSTRAINT FK_RunControl_WeightVersion FOREIGN KEY (SCENARIO_WEIGHT_VERSION_ID)
        REFERENCES ecl_cfg.ScenarioWeightVersion(VERSION_ID),
    CONSTRAINT FK_RunControl_Product FOREIGN KEY (REQUESTED_PRODUCT_TYPE)
        REFERENCES ecl_cfg.ProductType(PRODUCT_TYPE),
    CONSTRAINT CK_RunControl_Type CHECK (RUN_TYPE IN ('FULL', 'SELECTIVE')),
    CONSTRAINT CK_RunControl_Status CHECK (RUN_STATUS IN ('CREATED','VALIDATING','VALIDATION_FAILED','CALCULATING','RECONCILIATION_FAILED','SUCCEEDED','PUBLISHED','FAILED','CANCELLED')),
    CONSTRAINT CK_RunControl_Finish CHECK (FINISHED_AT IS NULL OR FINISHED_AT >= STARTED_AT),
    CONSTRAINT CK_RunControl_Selective CHECK (RUN_TYPE <> 'SELECTIVE' OR REQUESTED_PRODUCT_TYPE IS NOT NULL OR REQUESTED_POOL_ID IS NOT NULL)
);
GO
CREATE INDEX IX_RunControl_ProcessDate_Status
    ON ecl_core.RunControl (PROCESS_DATE, RUN_STATUS, RUN_ID DESC)
    INCLUDE (RUN_TYPE, CALCULATION_VERSION, SCENARIO_WEIGHT_VERSION_ID, FINISHED_AT);
GO

/* Canonical input snapshots. Each load is tied to a controlled RUN_ID.
   VERSION_ID identifies the upstream/logical input version; IS_ACTIVE is
   retained for controlled version selection, not as a substitute for RUN_ID. */
CREATE TABLE ecl_stg.AccountSnapshot (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    CUSTOMER_ID varchar(100) NULL,
    PRODUCT_TYPE varchar(30) NOT NULL,
    STAGE tinyint NOT NULL,
    POOL_ID varchar(100) NOT NULL,
    MATURITY_DATE date NOT NULL,
    VERSION_ID int NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_AccountSnapshot_IsActive DEFAULT (1),
    SOURCE_REFERENCE nvarchar(200) NULL,
    LOADED_AT datetime2(0) NOT NULL CONSTRAINT DF_AccountSnapshot_LoadedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_AccountSnapshot PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_AccountSnapshot_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT FK_AccountSnapshot_Product FOREIGN KEY (PRODUCT_TYPE) REFERENCES ecl_cfg.ProductType(PRODUCT_TYPE),
    CONSTRAINT CK_AccountSnapshot_Stage CHECK (STAGE IN (1,2,3))
);
GO
CREATE INDEX IX_AccountSnapshot_Run_Product_Stage
    ON ecl_stg.AccountSnapshot (RUN_ID, PRODUCT_TYPE, STAGE)
    INCLUDE (POOL_ID, ACCOUNT_ID, VERSION_ID, IS_ACTIVE);
CREATE INDEX IX_AccountSnapshot_Run_Pool
    ON ecl_stg.AccountSnapshot (RUN_ID, POOL_ID, ACCOUNT_ID)
    INCLUDE (PRODUCT_TYPE, STAGE, VERSION_ID, IS_ACTIVE);
GO

CREATE TABLE ecl_stg.PDCurve (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    SCENARIO_CODE varchar(20) NOT NULL,
    FORECAST_PERIOD smallint NOT NULL,
    MARGINAL_PD decimal(19,12) NOT NULL,
    VERSION_ID int NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_PDCurve_IsActive DEFAULT (1),
    CONSTRAINT PK_PDCurve PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD),
    CONSTRAINT FK_PDCurve_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID) REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_PDCurve_Scenario FOREIGN KEY (SCENARIO_CODE) REFERENCES ecl_cfg.Scenario(SCENARIO_CODE),
    CONSTRAINT CK_PDCurve_Period CHECK (FORECAST_PERIOD >= 1),
    CONSTRAINT CK_PDCurve_PD CHECK (MARGINAL_PD >= 0 AND MARGINAL_PD <= 1)
);
GO
CREATE INDEX IX_PDCurve_Run_Scenario_Period
    ON ecl_stg.PDCurve (RUN_ID, SCENARIO_CODE, FORECAST_PERIOD)
    INCLUDE (ACCOUNT_ID, MARGINAL_PD, VERSION_ID, IS_ACTIVE);
GO

CREATE TABLE ecl_stg.LGDCurve (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    FORECAST_PERIOD smallint NOT NULL,
    LGD decimal(19,12) NOT NULL,
    VERSION_ID int NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_LGDCurve_IsActive DEFAULT (1),
    CONSTRAINT PK_LGDCurve PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID, FORECAST_PERIOD),
    CONSTRAINT FK_LGDCurve_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID) REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
    CONSTRAINT CK_LGDCurve_Period CHECK (FORECAST_PERIOD >= 1),
    CONSTRAINT CK_LGDCurve_LGD CHECK (LGD >= 0 AND LGD <= 1)
);
GO
CREATE INDEX IX_LGDCurve_Run_Period
    ON ecl_stg.LGDCurve (RUN_ID, FORECAST_PERIOD)
    INCLUDE (ACCOUNT_ID, LGD, VERSION_ID, IS_ACTIVE);
GO

CREATE TABLE ecl_stg.EADCurve (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    FORECAST_PERIOD smallint NOT NULL,
    EAD decimal(19,4) NOT NULL,
    CURRENCY_CODE char(3) NOT NULL,
    VERSION_ID int NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_EADCurve_IsActive DEFAULT (1),
    CONSTRAINT PK_EADCurve PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID, FORECAST_PERIOD),
    CONSTRAINT FK_EADCurve_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID)
        REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
    CONSTRAINT CK_EADCurve_Period CHECK (FORECAST_PERIOD >= 1),
    CONSTRAINT CK_EADCurve_EAD CHECK (EAD >= 0)
);
GO
CREATE INDEX IX_EADCurve_Run_Period
    ON ecl_stg.EADCurve (RUN_ID, FORECAST_PERIOD)
    INCLUDE (ACCOUNT_ID, EAD, CURRENCY_CODE, VERSION_ID, IS_ACTIVE);
GO

CREATE TABLE ecl_stg.EIRCurve (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    FORECAST_PERIOD smallint NOT NULL,
    EIR decimal(19,12) NOT NULL,
    RATE_BASIS varchar(20) NOT NULL,
    VERSION_ID int NOT NULL,
    IS_ACTIVE bit NOT NULL CONSTRAINT DF_EIRCurve_IsActive DEFAULT (1),
    CONSTRAINT PK_EIRCurve PRIMARY KEY CLUSTERED (RUN_ID, FORECAST_PERIOD),
    CONSTRAINT FK_EIRCurve_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT CK_EIRCurve_Period CHECK (FORECAST_PERIOD >= 1),
    CONSTRAINT CK_EIRCurve_RateBasis CHECK (RATE_BASIS IN ('ANNUAL_EFFECTIVE','NOMINAL_ANNUAL','OTHER'))
);
GO

CREATE TABLE ecl_result.ECLDetail (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
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
    DISCOUNT_FACTOR decimal(28,16) NULL,
    SCENARIO_WEIGHT decimal(9,8) NOT NULL,
    ECL_UNWEIGHTED decimal(28,8) NOT NULL,
    ECL_WEIGHTED decimal(28,8) NOT NULL,
    CALCULATED_AT datetime2(0) NOT NULL CONSTRAINT DF_ECLDetail_CalculatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ECLDetail PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID, SCENARIO_CODE, FORECAST_PERIOD),
    CONSTRAINT FK_ECLDetail_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID)
        REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_ECLDetail_Scenario FOREIGN KEY (SCENARIO_CODE) REFERENCES ecl_cfg.Scenario(SCENARIO_CODE),
    CONSTRAINT CK_ECLDetail_Stage CHECK (STAGE IN (1,2,3)),
    CONSTRAINT CK_ECLDetail_Period CHECK (FORECAST_PERIOD >= 1),
    CONSTRAINT CK_ECLDetail_PD CHECK (PD_USED >= 0 AND PD_USED <= 1),
    CONSTRAINT CK_ECLDetail_LGD CHECK (LGD_USED >= 0 AND LGD_USED <= 1),
    CONSTRAINT CK_ECLDetail_EAD CHECK (EAD_USED >= 0),
    CONSTRAINT CK_ECLDetail_Weight CHECK (SCENARIO_WEIGHT >= 0 AND SCENARIO_WEIGHT <= 1),
    CONSTRAINT CK_ECLDetail_Amounts CHECK (ECL_UNWEIGHTED >= 0 AND ECL_WEIGHTED >= 0)
);
GO
CREATE INDEX IX_ECLDetail_Run_Product_Stage
    ON ecl_result.ECLDetail (RUN_ID, PRODUCT_TYPE, STAGE)
    INCLUDE (ACCOUNT_ID, POOL_ID, SCENARIO_CODE, FORECAST_PERIOD, ECL_WEIGHTED);
CREATE INDEX IX_ECLDetail_Run_Pool
    ON ecl_result.ECLDetail (RUN_ID, POOL_ID, SCENARIO_CODE, FORECAST_PERIOD)
    INCLUDE (PRODUCT_TYPE, STAGE, ECL_WEIGHTED);
GO

CREATE TABLE ecl_result.ECLAccount (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    ACCOUNT_ID varchar(100) NOT NULL,
    CUSTOMER_ID varchar(100) NULL,
    PRODUCT_TYPE varchar(30) NOT NULL,
    POOL_ID varchar(100) NOT NULL,
    STAGE tinyint NOT NULL,
    ECL_12_MONTH decimal(28,8) NOT NULL CONSTRAINT DF_ECLAccount_ECL12 DEFAULT (0),
    ECL_LIFETIME decimal(28,8) NOT NULL CONSTRAINT DF_ECLAccount_ECLLifetime DEFAULT (0),
    ECL_DEFAULT decimal(28,8) NOT NULL CONSTRAINT DF_ECLAccount_ECLDefault DEFAULT (0),
    ECL_TOTAL decimal(28,8) NOT NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_ECLAccount_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ECLAccount PRIMARY KEY CLUSTERED (RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_ECLAccount_Account FOREIGN KEY (RUN_ID, ACCOUNT_ID)
        REFERENCES ecl_stg.AccountSnapshot(RUN_ID, ACCOUNT_ID),
    CONSTRAINT FK_ECLAccount_Product FOREIGN KEY (PRODUCT_TYPE) REFERENCES ecl_cfg.ProductType(PRODUCT_TYPE),
    CONSTRAINT CK_ECLAccount_Stage CHECK (STAGE IN (1,2,3)),
    CONSTRAINT CK_ECLAccount_Amounts CHECK (
        ECL_12_MONTH >= 0 AND ECL_LIFETIME >= 0 AND ECL_DEFAULT >= 0 AND ECL_TOTAL >= 0
    )
);
GO
CREATE INDEX IX_ECLAccount_Run_Product_Stage
    ON ecl_result.ECLAccount (RUN_ID, PRODUCT_TYPE, STAGE)
    INCLUDE (POOL_ID, ECL_12_MONTH, ECL_LIFETIME, ECL_DEFAULT, ECL_TOTAL);
CREATE INDEX IX_ECLAccount_Run_Pool
    ON ecl_result.ECLAccount (RUN_ID, POOL_ID)
    INCLUDE (PRODUCT_TYPE, STAGE, ECL_TOTAL);
GO

CREATE TABLE ecl_result.ECLPortfolioSummary (
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    PRODUCT_TYPE varchar(30) NOT NULL,
    AGGREGATION_LEVEL varchar(10) NOT NULL,
    POOL_ID varchar(100) NOT NULL,
    STAGE tinyint NOT NULL,
    ACCOUNT_COUNT bigint NOT NULL,
    ECL_12_MONTH decimal(28,8) NOT NULL,
    ECL_LIFETIME decimal(28,8) NOT NULL,
    ECL_DEFAULT decimal(28,8) NOT NULL,
    ECL_TOTAL decimal(28,8) NOT NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_ECLPortfolioSummary_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ECLPortfolioSummary PRIMARY KEY CLUSTERED (RUN_ID, PRODUCT_TYPE, STAGE, AGGREGATION_LEVEL, POOL_ID),
    CONSTRAINT FK_ECLPortfolioSummary_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT FK_ECLPortfolioSummary_Product FOREIGN KEY (PRODUCT_TYPE) REFERENCES ecl_cfg.ProductType(PRODUCT_TYPE),
    CONSTRAINT CK_ECLPortfolioSummary_Level CHECK (AGGREGATION_LEVEL IN ('PORTFOLIO','POOL')),
    CONSTRAINT CK_ECLPortfolioSummary_Pool CHECK ((AGGREGATION_LEVEL = 'PORTFOLIO' AND POOL_ID = '__ALL_POOLS__') OR (AGGREGATION_LEVEL = 'POOL' AND POOL_ID <> '__ALL_POOLS__')),
    CONSTRAINT CK_ECLPortfolioSummary_Stage CHECK (STAGE IN (1,2,3)),
    CONSTRAINT CK_ECLPortfolioSummary_Count CHECK (ACCOUNT_COUNT >= 0),
    CONSTRAINT CK_ECLPortfolioSummary_Amounts CHECK (
        ECL_12_MONTH >= 0 AND ECL_LIFETIME >= 0 AND ECL_DEFAULT >= 0 AND ECL_TOTAL >= 0
    )
);
GO
CREATE INDEX IX_ECLPortfolioSummary_Run_Stage
    ON ecl_result.ECLPortfolioSummary (RUN_ID, STAGE, PRODUCT_TYPE)
    INCLUDE (ACCOUNT_COUNT, ECL_TOTAL);
GO

CREATE TABLE ecl_audit.RunEvent (
    EVENT_ID bigint IDENTITY(1,1) NOT NULL,
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    EVENT_AT datetime2(0) NOT NULL CONSTRAINT DF_RunEvent_EventAt DEFAULT (SYSUTCDATETIME()),
    EVENT_TYPE varchar(40) NOT NULL,
    EVENT_STATUS varchar(20) NOT NULL,
    EVENT_MESSAGE nvarchar(2000) NULL,
    ROW_COUNT bigint NULL,
    AMOUNT_VALUE decimal(28,8) NULL,
    ACTOR sysname NOT NULL CONSTRAINT DF_RunEvent_Actor DEFAULT (SUSER_SNAME()),
    CONSTRAINT PK_RunEvent PRIMARY KEY CLUSTERED (EVENT_ID),
    CONSTRAINT FK_RunEvent_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT CK_RunEvent_RowCount CHECK (ROW_COUNT IS NULL OR ROW_COUNT >= 0)
);
GO
CREATE INDEX IX_RunEvent_Run_Time
    ON ecl_audit.RunEvent (RUN_ID, EVENT_AT, EVENT_ID)
    INCLUDE (EVENT_TYPE, EVENT_STATUS, ROW_COUNT);
GO

CREATE TABLE ecl_audit.ValidationError (
    ERROR_ID bigint IDENTITY(1,1) NOT NULL,
    RUN_ID bigint NOT NULL,
    PROCESS_DATE date NOT NULL,
    VALIDATION_CODE varchar(50) NOT NULL,
    SEVERITY varchar(10) NOT NULL,
    PRODUCT_TYPE varchar(30) NULL,
    ACCOUNT_ID varchar(100) NULL,
    POOL_ID varchar(100) NULL,
    SCENARIO_CODE varchar(20) NULL,
    FORECAST_PERIOD smallint NULL,
    ERROR_MESSAGE nvarchar(2000) NOT NULL,
    CREATED_AT datetime2(0) NOT NULL CONSTRAINT DF_ValidationError_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ValidationError PRIMARY KEY CLUSTERED (ERROR_ID),
    CONSTRAINT FK_ValidationError_Run FOREIGN KEY (RUN_ID) REFERENCES ecl_core.RunControl(RUN_ID),
    CONSTRAINT CK_ValidationError_Severity CHECK (SEVERITY IN ('INFO','WARN','ERROR','FATAL'))
);
GO
CREATE INDEX IX_ValidationError_Run_Severity
    ON ecl_audit.ValidationError (RUN_ID, SEVERITY, ERROR_ID)
    INCLUDE (VALIDATION_CODE, PRODUCT_TYPE, ACCOUNT_ID, FORECAST_PERIOD);
GO

/* Seed logical product/scenario codes only. User-confirmed scenario weights must be
   loaded as an immutable versioned config set with VERSION_ID, PROCESS_DATE,
   effective dates, and audit history: DOWNTURN=0.1568, BASE=0.6864, UPTURN=0.1568.
   External official source/provenance is pending and may be added later. */
INSERT INTO ecl_cfg.ProductType (PRODUCT_TYPE, PRODUCT_NAME)
VALUES ('MORTGAGE', N'Mortgage'),
       ('AUTO', N'Auto'),
       ('CREDITCARD', N'Credit Card'),
       ('PERSONALLOAN', N'Personal Loan'),
       ('OTHER', N'Other Retail');

INSERT INTO ecl_cfg.Scenario (SCENARIO_CODE, SCENARIO_NAME)
VALUES ('DOWNTURN', N'Downturn'),
       ('BASE', N'Base'),
       ('UPTURN', N'Upturn');
GO
